import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileArtifacts

@Suite struct PreviewStorageTests {
    final class Channel: LinkChannel, @unchecked Sendable {
        let id: UInt32 = 1
        private let lock = NSLock()
        private var remaining: [Data]
        private var received = 0
        private var closed = false
        init(_ chunks: [Data]) { remaining = chunks }
        func send(_ data: Data) async throws {}
        func receive() async throws -> Data? {
            lock.withLock {
                received += 1
                return remaining.isEmpty ? nil : remaining.removeFirst()
            }
        }
        func close(code: String, reason: String) async { lock.withLock { closed = true } }
        var receiveCount: Int { lock.withLock { received } }
        var isClosed: Bool { lock.withLock { closed } }
        var closedBy: LinkError? { LinkError(code: "eof", message: "") }
    }

    actor TwoLoads {
        private var first: CheckedContinuation<Void, Never>?
        func meet() async {
            if let first {
                self.first = nil
                first.resume()
            } else {
                await withCheckedContinuation { first = $0 }
            }
        }
    }

    final class Link: MacLink, Sendable {
        let channel: Channel
        let rendezvous: TwoLoads?
        init(_ channel: Channel, rendezvous: TwoLoads? = nil) {
            self.channel = channel
            self.rendezvous = rendezvous
        }
        var transport: TransportKind { .wireGuard }
        var states: AsyncStream<LinkState> { AsyncStream { $0.finish() } }
        func openChannel(service: String, args: [String: String]) async throws -> any LinkChannel {
            #expect(service == "file-preview")
            await rendezvous?.meet()
            return channel
        }
        func ping() async throws -> UInt32 { 0 }
        func close() async {}
    }

    static func store() -> PreviewFileStore {
        PreviewFileStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("preview-lifetime-test-\(UUID().uuidString)"))
    }

    static func source(_ data: Data, store: PreviewFileStore) -> LinkFileArtifactSource {
        let link = Link(Channel([Data("{\"size\":\(data.count)}".utf8), data]))
        var source = LinkFileArtifactSource(macName: "Mac", baseDirectory: "/demo", availableCapacity: { _ in Int64.max }) { link }
        source.fileStore = store
        return source
    }

    @Test func concurrentLoadsOfTheSameArtifactKeepIndependentCompleteCopies() async throws {
        let artifact = TerminalArtifact(reference: "/demo/sample.pdf", kind: .pdf)
        let store = Self.store()
        defer { try? FileManager.default.removeItem(at: store.root) }
        func overlappingReads() async throws {
            let rendezvous = TwoLoads()
            let first = Link(Channel([Data("{\"size\":3}".utf8), Data([1, 2, 3])]), rendezvous: rendezvous)
            let second = Link(Channel([Data("{\"size\":3}".utf8), Data([4, 5, 6])]), rendezvous: rendezvous)
            async let firstCopy = LinkFileArtifactSource.read(path: artifact.reference, over: first, macName: "Mac", for: artifact,
                                                             capacity: { _ in Int64.max }, store: store)
            async let secondCopy = LinkFileArtifactSource.read(path: artifact.reference, over: second, macName: "Mac", for: artifact,
                                                              capacity: { _ in Int64.max }, store: store)
            let (firstFile, secondFile) = try await (firstCopy, secondCopy)
            defer { withExtendedLifetime((firstFile, secondFile)) {} }
            #expect(firstFile.url != secondFile.url)
            #expect(firstFile.url.lastPathComponent == artifact.name)
            #expect(secondFile.url.lastPathComponent == artifact.name)
            #expect(try Data(contentsOf: firstFile.url) == Data([1, 2, 3]))
            #expect(try Data(contentsOf: secondFile.url) == Data([4, 5, 6]))
        }
        try await overlappingReads()
        // No manual deletion: releasing production owners removes both snapshots.
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.root.path).isEmpty)
    }

    @Test func repeatedOpenAndDismissRemovesCopiesWhileAnotherViewerKeepsItsFile() async throws {
        let store = Self.store()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let artifact = TerminalArtifact(reference: "/demo/movie.mp4", kind: .video)
        var active: ArtifactContent? = try await Self.source(Data([7, 8, 9]), store: store).load(artifact)
        func url(_ content: ArtifactContent?) throws -> URL {
            guard case .ownedFile(let file, isVideo: true) = content else { throw ArtifactUnavailable("expected owned video") }
            return file.url
        }
        let activeURL = try url(active)
        for _ in 0..<5 {
            var reopened: ArtifactContent? = try await Self.source(Data([1, 2, 3]), store: store).load(artifact)
            let reopenedURL = try url(reopened)
            #expect(reopenedURL != activeURL)
            #expect(try Data(contentsOf: reopenedURL) == Data([1, 2, 3]))
            reopened = nil // The preview releases its loaded content on dismissal.
            #expect(!FileManager.default.fileExists(atPath: reopenedURL.deletingLastPathComponent().path))
            store.removeStaleCopies()
            #expect(try Data(contentsOf: activeURL) == Data([7, 8, 9]))
            #expect(try FileManager.default.contentsOfDirectory(atPath: store.root.path).count == 1)
        }
        withExtendedLifetime(active) {}
        active = nil
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.root.path).isEmpty)
    }

    @Test func inlineDecodingReleasesTheDownloadBeforeReturning() async throws {
        let store = Self.store()
        defer { try? FileManager.default.removeItem(at: store.root) }
        for kind in [TerminalArtifact.Kind.text, .image, .pdf] {
            let artifact = TerminalArtifact(reference: "/demo/sample", kind: kind)
            let content = try await Self.source(Data("sample".utf8), store: store).load(artifact)
            defer { withExtendedLifetime(content) {} }
            #expect(try FileManager.default.contentsOfDirectory(atPath: store.root.path).isEmpty)
        }
    }

    @Test func undecodableTextKeepsOnlyTheOwnedOriginalUntilReleased() async throws {
        let store = Self.store()
        defer { try? FileManager.default.removeItem(at: store.root) }
        var content: ArtifactContent? = try await Self.source(Data([0xFF]), store: store)
            .load(TerminalArtifact(reference: "/demo/sample.txt", kind: .text))
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.root.path).count == 1)
        withExtendedLifetime(content) {}
        content = nil
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.root.path).isEmpty)
    }

    @Test func launchSweepRemovesAbandonedFoldersButKeepsActiveAndUnrecognizedPaths() throws {
        let store = Self.store()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let active = try store.make(name: "active.bin")
        defer { withExtendedLifetime(active) {} }
        try Data([1]).write(to: active.url)
        let stale = store.root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: false)
        try Data([2]).write(to: stale.appendingPathComponent("abandoned.part"))
        let unrelated = store.root.appendingPathComponent("unrecognized")
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: false)
        let symlink = store.root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: unrelated)
        store.removeStaleCopies()
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(try Data(contentsOf: active.url) == Data([1]))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
        #expect(try symlink.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
    }

    @Test func anUnfittingRemoteFileStopsAfterMetadataBeforeReadingFileBytes() async throws {
        let size: Int64 = 8 << 30
        let channel = Channel([Data("{\"size\":\(size)}".utf8), Data([1, 2, 3])])
        let artifact = TerminalArtifact(reference: "/demo/sample.pdf", kind: .pdf)
        let store = Self.store()
        defer { try? FileManager.default.removeItem(at: store.root) }
        do {
            _ = try await LinkFileArtifactSource.read(path: artifact.reference, over: Link(channel), macName: "Mac", for: artifact,
                                                     capacity: { _ in size + PreviewStorage.reserveBytes - 1 }, store: store)
            Issue.record("insufficient capacity must refuse before downloading")
        } catch let error as PreviewInsufficientSpace {
            #expect(error.size == size)
            #expect(error.path == artifact.reference)
            #expect(error.errorDescription?.hasPrefix("Not enough free space on this iPhone to preview") == true)
        }
        #expect(channel.receiveCount == 1)
        #expect(channel.isClosed)
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.root.path).isEmpty)
    }

    @Test func fallingFreeSpaceStopsBeforeTheNextWriteAndRemovesThePartialFile() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let destination = folder.appendingPathComponent("sample.part")
        let channel = Channel([Data([1, 2, 3]), Data([4, 5, 6]), Data([7, 8, 9])])
        await #expect(throws: PreviewInsufficientSpace.self) {
            try await LinkFileArtifactSource.download(channel, to: destination, path: "/demo/sample.bin", macName: "Mac", expectedSize: 9) { url in
                let written = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
                // Another app consumes space after the first chunk reaches disk.
                return PreviewStorage.reserveBytes + (written == 0 ? 9 : 5)
            }
        }
        #expect(channel.receiveCount == 2)
        #expect(channel.isClosed)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func exactFitIsAcceptedAndFileSizeHasNoArtificialLimit() throws {
        let size: Int64 = 5 << 40
        try PreviewStorage.check(URL(fileURLWithPath: "/unused"), path: "/demo/huge.bin", size: size, remaining: size,
                                 capacity: { _ in size + PreviewStorage.reserveBytes })
    }

    @Test func aFileFitsAndStreamsWhenCapacityRemainsAvailable() async throws {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destination) }
        let channel = Channel([Data([1, 2]), Data([3])])
        let size = try await LinkFileArtifactSource.download(channel, to: destination, path: "/demo/sample.bin", macName: "Mac", expectedSize: 3,
                                                             capacity: { _ in PreviewStorage.reserveBytes + 3 })
        #expect(size == 3)
        #expect(try Data(contentsOf: destination) == Data([1, 2, 3]))
    }
}

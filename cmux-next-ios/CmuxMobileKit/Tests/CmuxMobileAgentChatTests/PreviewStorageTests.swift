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

    final class Link: MacLink, Sendable {
        let channel: Channel
        init(_ channel: Channel) { self.channel = channel }
        var transport: TransportKind { .wireGuard }
        var states: AsyncStream<LinkState> { AsyncStream { $0.finish() } }
        func openChannel(service: String, args: [String: String]) async throws -> any LinkChannel {
            #expect(service == "file-preview")
            return channel
        }
        func ping() async throws -> UInt32 { 0 }
        func close() async {}
    }

    @Test func anUnfittingRemoteFileStopsAfterMetadataBeforeReadingFileBytes() async throws {
        let size: Int64 = 8 << 30
        let channel = Channel([Data("{\"size\":\(size)}".utf8), Data([1, 2, 3])])
        let artifact = TerminalArtifact(reference: "/demo/\(UUID().uuidString).pdf", kind: .pdf)
        let destination = try ArtifactLocalCopy.destination(for: artifact)
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }
        do {
            _ = try await LinkFileArtifactSource.read(path: artifact.reference, over: Link(channel), macName: "Mac", for: artifact,
                                                     capacity: { _ in size + PreviewStorage.reserveBytes - 1 })
            Issue.record("insufficient capacity must refuse before downloading")
        } catch let error as PreviewInsufficientSpace {
            #expect(error.size == size)
            #expect(error.path == artifact.reference)
            #expect(error.errorDescription?.hasPrefix("Not enough free space on this iPhone to preview") == true)
        }
        #expect(channel.receiveCount == 1)
        #expect(channel.isClosed)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path).isEmpty)
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

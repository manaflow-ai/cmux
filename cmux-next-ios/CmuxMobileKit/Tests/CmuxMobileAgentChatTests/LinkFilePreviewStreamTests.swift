import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileArtifacts

/// A Mac file opened for preview has no size cap (Leo, 2026-10-26: "WE NEED ARBITARRILY LARGE
/// FILES OF ANY TYPE"): the phone streams it to a file in its temporary folder, one message at a
/// time, and previews from there, so its memory never holds the whole file.
@Suite struct LinkFilePreviewStreamTests {
    /// Past the old 24 MiB preview limit.
    static let chunk = 1 << 20
    static let chunks = 25
    static let tail = 3
    static var total: Int { chunks * chunk + tail }

    /// Sends `chunks` messages of `chunk` bytes, then `tail` bytes, then ends with `eof`. Before
    /// each message it reads how much of the earlier ones reached `destination` on disk.
    final class FloodChannel: LinkChannel, @unchecked Sendable {
        let id: UInt32 = 1
        let destination: URL?
        private let lock = NSLock()
        private var sent = 0
        private var index = 0
        /// The most bytes already sent that were not on disk yet when the next message went out.
        private var lag = 0
        private var metadata: Bool

        init(destination: URL?, metadata: Bool = false) { self.destination = destination; self.metadata = metadata }

        func send(_ data: Data) async throws {}
        func receive() async throws -> Data? {
            let onDisk = destination.flatMap { url in
                (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
            } ?? 0
            return lock.withLock {
                if metadata {
                    metadata = false
                    return Data("{\"size\":\(LinkFilePreviewStreamTests.total)}".utf8)
                }
                if destination != nil { lag = max(lag, sent - onDisk) }
                defer { index += 1 }
                let size: Int
                if index < LinkFilePreviewStreamTests.chunks {
                    size = LinkFilePreviewStreamTests.chunk
                } else if index == LinkFilePreviewStreamTests.chunks {
                    size = LinkFilePreviewStreamTests.tail
                } else {
                    return nil
                }
                sent += size
                return Data(repeating: UInt8(truncatingIfNeeded: index), count: size)
            }
        }
        func close(code: String, reason: String) async {}
        var closedBy: LinkError? { lock.withLock { index > LinkFilePreviewStreamTests.chunks ? LinkError(code: "eof", message: "") : nil } }
        var largestLag: Int { lock.withLock { lag } }
    }

    final class FloodLink: MacLink, @unchecked Sendable {
        var transport: TransportKind { .webRTC }
        var states: AsyncStream<LinkState> { AsyncStream { $0.finish() } }
        func openChannel(service: String, args: [String: String]) async throws -> any LinkChannel {
            FloodChannel(destination: nil, metadata: true)
        }
        func ping() async throws -> UInt32 { 0 }
        func close() async {}
    }

    @Test func aFileLargerThanTheOldLimitStreamsToDiskOneMessageAtATime() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-preview-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let destination = folder.appendingPathComponent("big.bin")
        let channel = FloodChannel(destination: destination)

        let written = try await LinkFileArtifactSource.download(channel, to: destination, path: "/Users/me/big.bin", macName: "Studio")

        #expect(written == Int64(Self.total))
        let size = try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber
        #expect(size?.intValue == Self.total)
        // Every message was on disk before the next one was asked for: the phone held one at a time.
        #expect(channel.largestLag == 0)
        let handle = try FileHandle(forReadingFrom: destination)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(24 * Self.chunk))
        #expect(try handle.read(upToCount: 1) == Data([24]))
        try handle.seek(toOffset: UInt64(Self.chunks * Self.chunk))
        #expect(try handle.readToEnd() == Data(repeating: UInt8(Self.chunks), count: Self.tail))
    }

    /// A file truncated on the Mac while it streams ends before the size the host first sent. The
    /// phone never previews that mix of old and new bytes: it asks for a retry and removes the
    /// partial copy (PROTOCOL.md, `file-preview`).
    @Test func aStreamShorterThanItsSizeAsksForARetryAndLeavesNoPartialFile() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-preview-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let destination = folder.appendingPathComponent("shrunk.bin")
        let channel = FloodChannel(destination: destination)

        await #expect(throws: ArtifactUnavailable.self) {
            try await LinkFileArtifactSource.download(channel, to: destination, path: "/Users/me/shrunk.bin", macName: "Studio",
                                                      expectedSize: Int64(Self.total + 1), capacity: { _ in Int64.max })
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func aLargeFilePreviewsFromItsLocalCopy() async throws {
        let source = LinkFileArtifactSource(macName: "Studio", baseDirectory: "/Users/me") { FloodLink() }
        let content = try await source.load(TerminalArtifact(reference: "/Users/me/huge-\(UUID().uuidString).zip", kind: .binary))
        guard case .ownedFile(let file, isVideo: false) = content else { Issue.record("not an owned local copy: \(content)"); return }
        defer { withExtendedLifetime(file) {} }
        let url = file.url
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        #expect(size?.intValue == Self.total)
        #expect(url.path.hasPrefix(FileManager.default.temporaryDirectory.path))
    }

    /// Text past what the phone decodes in memory opens in Quick Look from its local copy.
    @Test func largeTextOpensFromItsLocalCopyInsteadOfMemory() async throws {
        let source = LinkFileArtifactSource(macName: "Studio", baseDirectory: "/Users/me") { FloodLink() }
        let content = try await source.load(TerminalArtifact(reference: "/Users/me/huge-\(UUID().uuidString).log", kind: .text))
        guard case .ownedFile(let file, isVideo: false) = content else { Issue.record("not an owned local copy: \(content)"); return }
        defer { withExtendedLifetime(file) {} }
        let url = file.url
        #expect(url.lastPathComponent.hasSuffix(".log"))
    }
}

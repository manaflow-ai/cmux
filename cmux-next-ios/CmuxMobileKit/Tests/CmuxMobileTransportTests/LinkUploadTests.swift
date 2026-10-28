import Foundation
import Testing
@testable import CmuxMobileTransport

/// Attachments take arbitrarily large files of any type; there is no size cap.
/// A picked file streams from disk a chunk at a time, never read whole.
@Suite struct LinkUploadTests {
    /// The Mac's `upload` service: keeps the open args, counts the bytes, then answers the path.
    final class UploadLink: MacLink, @unchecked Sendable {
        let transport: TransportKind = .webRTC
        let states = AsyncStream<LinkState> { $0.finish() }
        let channel = UploadChannel()
        private let lock = NSLock()
        private var opened: [String: String]?

        var args: [String: String]? { lock.withLock { opened } }

        func openChannel(service: String, args: [String: String]) async throws -> any LinkChannel {
            lock.withLock { opened = args }
            return channel
        }

        func ping() async throws -> UInt32 { 1 }
        func close() async {}
    }

    final class UploadChannel: LinkChannel, @unchecked Sendable {
        let id: UInt32 = 1
        private let lock = NSLock()
        private var bytes = 0
        private var largestWrite = 0
        private var answered = false

        var received: (bytes: Int, largestWrite: Int) { lock.withLock { (bytes, largestWrite) } }

        func send(_ data: Data) async throws {
            lock.withLock {
                bytes += data.count
                largestWrite = max(largestWrite, data.count)
            }
        }

        func receive() async throws -> Data? {
            lock.withLock { () -> Data? in
                guard !answered else { return nil }
                answered = true
                return Data(#"{"path":"/w/.cmux/attachments/phone-1/big.bin","size":\#(bytes)}"#.utf8)
            }
        }

        func close(code: String, reason: String) async {}
    }

    /// A sparse file of `size` bytes: no disk or memory spent on its zeros.
    static func sparseFile(size: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-big.bin")
        #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(size))
        try handle.close()
        return url
    }

    /// Past the old 100 MiB phone cap: the whole file goes, in chunks, and the Mac's path comes back.
    @Test func aFileLargerThanTheOldCapStreamsInChunks() async throws {
        let size = (101 << 20) + 7
        let url = try Self.sparseFile(size: size)
        defer { try? FileManager.default.removeItem(at: url) }
        let link = UploadLink()

        let path = try await LinkUpload.upload(fileAt: url, name: "big.bin", cwd: "/w", over: link)

        #expect(path == "/w/.cmux/attachments/phone-1/big.bin")
        #expect(link.args == ["name": "big.bin", "size": String(size), "cwd": "/w"])
        let received = link.channel.received
        #expect(received.bytes == size)
        #expect(received.largestWrite <= LinkUpload.chunkBytes)
    }

    /// In-memory bytes (a pasted or camera image) take the same chunked path.
    @Test func bytesInMemoryGoInChunks() async throws {
        let data = Data(repeating: 0x2A, count: LinkUpload.chunkBytes * 2 + 3)
        let link = UploadLink()

        let path = try await LinkUpload.upload(.data(data), name: "a.png", cwd: nil, over: link)

        #expect(path == "/w/.cmux/attachments/phone-1/big.bin")
        #expect(link.args == ["name": "a.png", "size": String(data.count)])
        #expect(link.channel.received.bytes == data.count)
        #expect(link.channel.received.largestWrite == LinkUpload.chunkBytes)
    }

    /// A file the phone can't read is refused before anything opens on the Mac.
    @Test func anUnreadableFileOpensNothing() async {
        let link = UploadLink()
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-gone.bin")

        await #expect(throws: LinkUpload.Failure.self) {
            _ = try await LinkUpload.upload(.file(missing), name: "gone.bin", cwd: nil, over: link)
        }
        #expect(link.args == nil)
    }
}

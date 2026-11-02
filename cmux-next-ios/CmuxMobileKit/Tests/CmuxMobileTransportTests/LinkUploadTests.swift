import Foundation
import Testing
@testable import CmuxMobileTransport

/// Attachments take arbitrarily large files of any type; there is no size cap.
/// A picked file streams from disk a chunk at a time, never read whole.
@Suite struct LinkUploadTests {
    /// The Mac's `upload` service: keeps the open args, counts the bytes, then answers the path.
    ///
    /// It models the receiver after #26954, which removes the Mac's cap
    /// (`upload_max_bytes` / `CMUX_MOBILE_UPLOAD_MAX_BYTES` in config.rs and
    /// the `too_large` refusal in services.rs `receive_upload`): it takes any
    /// declared size. The real receiver's policy is proven end to end by the
    /// e2e test PR stacked on #26954 and #26959, not here.
    final class UploadLink: MacLink, @unchecked Sendable {
        let transport: TransportKind = .webRTC
        let states = AsyncStream<LinkState> { $0.finish() }
        let channel: UploadChannel
        /// The Mac refuses to open the channel (offline, a folder it won't write to).
        let refusal: LinkError?
        private let lock = NSLock()
        private var opened: [String: String]?

        init(scope: RecordingScope? = nil, refusal: LinkError? = nil) {
            channel = UploadChannel(scope: scope)
            self.refusal = refusal
        }

        var args: [String: String]? { lock.withLock { opened } }

        func openChannel(service: String, args: [String: String]) async throws -> any LinkChannel {
            if let refusal { throw refusal }
            lock.withLock { opened = args }
            return channel
        }

        func ping() async throws -> UInt32 { 1 }
        func close() async {}
    }

    final class UploadChannel: LinkChannel, @unchecked Sendable {
        let id: UInt32 = 1
        /// The file's scope, read at every write: open accesses then.
        let scope: RecordingScope?
        private let lock = NSLock()
        private var bytes = 0
        private var largestWrite = 0
        private var answered = false
        private var openAtWrites: Set<Int> = []

        init(scope: RecordingScope? = nil) { self.scope = scope }

        var received: (bytes: Int, largestWrite: Int) { lock.withLock { (bytes, largestWrite) } }
        /// How many accesses were open at each write (one value when it never changed).
        var scopeOpenAtWrites: Set<Int> { lock.withLock { openAtWrites } }

        func send(_ data: Data) async throws {
            let open = scope?.open
            lock.withLock {
                bytes += data.count
                largestWrite = max(largestWrite, data.count)
                if let open { openAtWrites.insert(open) }
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

    /// The Mac takes the bytes and never answers. A close ends the wait for its
    /// reply, as the link's does (closing a channel drops its receiver's sender).
    final class StalledLink: MacLink, @unchecked Sendable {
        let transport: TransportKind = .webRTC
        let states = AsyncStream<LinkState> { $0.finish() }
        let channel = StalledChannel()

        func openChannel(service: String, args: [String: String]) async throws -> any LinkChannel { channel }
        func ping() async throws -> UInt32 { 1 }
        func close() async {}
    }

    final class StalledChannel: LinkChannel, @unchecked Sendable {
        let id: UInt32 = 2
        /// Yields once the upload waits for the Mac's reply.
        let waits: AsyncStream<Void>
        private let waitsContinuation: AsyncStream<Void>.Continuation
        private let lock = NSLock()
        private var bytes = 0
        private var closeCode: String?
        private var waiting: CheckedContinuation<Data?, Never>?

        init() { (waits, waitsContinuation) = AsyncStream.makeStream() }

        var sent: Int { lock.withLock { bytes } }
        var closedWith: String? { lock.withLock { closeCode } }

        func send(_ data: Data) async throws {
            lock.withLock { bytes += data.count }
        }

        func receive() async throws -> Data? {
            await withCheckedContinuation { continuation in
                let closed = lock.withLock { () -> Bool in
                    if closeCode != nil { return true }
                    waiting = continuation
                    return false
                }
                if closed { continuation.resume(returning: nil) } else { waitsContinuation.yield() }
            }
        }

        func close(code: String, reason: String) async {
            let waiter = lock.withLock { () -> CheckedContinuation<Data?, Never>? in
                if closeCode == nil { closeCode = code }
                defer { waiting = nil }
                return waiting
            }
            waiter?.resume(returning: nil)
        }
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

    // MARK: Security scope (a Files pick is readable only inside it)

    /// A picked file is read inside its security scope for the whole stream,
    /// and the scope closes once the Mac answers.
    @Test func aPickedFileStaysInItsScopeForTheWholeStream() async throws {
        let size = LinkUpload.chunkBytes * 3 + 5
        let url = try Self.sparseFile(size: size)
        defer { try? FileManager.default.removeItem(at: url) }
        let scope = RecordingScope()
        let link = UploadLink(scope: scope)

        _ = try await LinkUpload.upload(.file(url), name: "big.bin", cwd: nil, over: link, scope: scope)

        #expect(link.channel.received.bytes == size)
        #expect(link.channel.scopeOpenAtWrites == [1])
        #expect(scope.starts == 1)
        #expect(scope.stops == 1)
    }

    /// A file the phone can't read: its scope still closes.
    @Test func anUnreadableFileClosesItsScope() async {
        let scope = RecordingScope()
        let link = UploadLink()
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-gone.bin")

        await #expect(throws: LinkUpload.Failure.self) {
            _ = try await LinkUpload.upload(.file(missing), name: "gone.bin", cwd: nil, over: link, scope: scope)
        }
        #expect(scope.starts == 1)
        #expect(scope.stops == 1)
    }

    /// The Mac refuses the upload before any byte goes: the scope closes too.
    @Test func aRefusedUploadClosesItsScope() async throws {
        let url = try Self.sparseFile(size: 10)
        defer { try? FileManager.default.removeItem(at: url) }
        let scope = RecordingScope()
        let link = UploadLink(refusal: LinkError(code: "offline", message: "the Mac isn't connected"))

        await #expect(throws: LinkUpload.Failure.self) {
            _ = try await LinkUpload.upload(.file(url), name: "a.bin", cwd: nil, over: link, scope: scope)
        }
        #expect(scope.starts == 1)
        #expect(scope.stops == 1)
    }

    // MARK: Cancellation (a large upload can be abandoned)

    /// Cancelling an upload whose reply never comes closes its channel, and
    /// the file's handle and scope close with it.
    @Test(.timeLimit(.minutes(1))) func cancellingAStalledUploadClosesItsChannelAndScope() async throws {
        let size = LinkUpload.chunkBytes + 1
        let url = try Self.sparseFile(size: size)
        defer { try? FileManager.default.removeItem(at: url) }
        let scope = RecordingScope()
        let link = StalledLink()
        let upload = Task { try await LinkUpload.upload(.file(url), name: "big.bin", cwd: nil, over: link, scope: scope) }

        for await _ in link.channel.waits { break }
        #expect(link.channel.sent == size)
        upload.cancel()

        await #expect(throws: CancellationError.self) { _ = try await upload.value }
        #expect(link.channel.closedWith == "cancelled")
        #expect(scope.starts == 1)
        #expect(scope.stops == 1)
    }

    /// An upload cancelled before its first chunk sends nothing more.
    @Test(.timeLimit(.minutes(1))) func aCancelledUploadStopsStreaming() async throws {
        let url = try Self.sparseFile(size: LinkUpload.chunkBytes * 4)
        defer { try? FileManager.default.removeItem(at: url) }
        let link = StalledLink()
        let upload = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await LinkUpload.upload(.file(url), name: "big.bin", cwd: nil, over: link, scope: RecordingScope())
        }

        await #expect(throws: CancellationError.self) { _ = try await upload.value }
        #expect(link.channel.sent == 0)
        #expect(link.channel.closedWith == "cancelled")
    }

    /// Bytes held in memory open no scope.
    @Test func bytesInMemoryOpenNoScope() async throws {
        let scope = RecordingScope()
        _ = try await LinkUpload.upload(.data(Data([1, 2, 3])), name: "a.png", cwd: nil, over: UploadLink(), scope: scope)
        #expect(scope.starts == 0)
        #expect(scope.stops == 0)
    }
}

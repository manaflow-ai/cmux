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
        #expect(link.args?.filter { $0.key != "id" } == ["name": "big.bin", "size": String(size), "cwd": "/w"])
        // Every upload names itself, so a link loss can resume it (`upload-status`).
        #expect(link.args?["id"]?.isEmpty == false)
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
        #expect(link.args?.filter { $0.key != "id" } == ["name": "a.png", "size": String(data.count)])
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

    // MARK: Bounds, resume, progress (Leo 2026-11-24: "it just blocked me endlessly on a send")

    /// A Mac that never answers: the upload ends as `stalled` within its bound, never spins.
    @Test(.timeLimit(.minutes(1))) func aMacThatNeverAnswersEndsAsStalled() async throws {
        let link = StalledLink()
        let options = LinkUpload.Options(replyWithin: .milliseconds(200))

        await #expect(throws: LinkUpload.Failure.self) {
            _ = try await LinkUpload.upload(.data(Data(count: 10)), name: "a.mov", cwd: nil, over: link, options: options)
        }
        #expect(link.channel.closedWith == "cancelled")
    }

    /// A link that drops mid-stream: the next link resumes from the Mac's copy, sending only the rest.
    @Test(.timeLimit(.minutes(1))) func aDroppedUploadResumesWhereTheMacStopped() async throws {
        let size = LinkUpload.chunkBytes * 4
        let kept = LinkUpload.chunkBytes * 2
        let first = ScriptedLink(dropAfter: kept, status: nil)
        let second = ScriptedLink(dropAfter: nil, status: #"{"offset":\#(kept)}"#)
        let steps = Steps()
        let options = LinkUpload.Options(nextLink: { second }, progress: { steps.add($0) })

        let path = try await LinkUpload.upload(.data(Data(count: size)), name: "big.mov", cwd: nil, over: first, options: options)

        #expect(path == "/up/big.mov")
        #expect(second.uploadArgs?["offset"] == String(kept))
        #expect(second.uploadArgs?["id"] == first.uploadArgs?["id"])
        #expect(second.received == size - kept)
        let all = steps.all
        #expect(all.contains { $0.phase == .waitingForLink })
        #expect(all.last?.phase == .saving)
        #expect(all.last?.sent == size)
    }

    /// A Mac without `upload-status` (older): the next attempt sends the file from the start.
    @Test(.timeLimit(.minutes(1))) func anOlderMacStartsOver() async throws {
        let size = LinkUpload.chunkBytes * 3
        let first = ScriptedLink(dropAfter: LinkUpload.chunkBytes, status: nil)
        let second = ScriptedLink(dropAfter: nil, status: nil)
        let options = LinkUpload.Options(nextLink: { second })

        _ = try await LinkUpload.upload(.data(Data(count: size)), name: "big.mov", cwd: nil, over: first, options: options)

        #expect(second.uploadArgs?["offset"] == nil)
        #expect(second.received == size)
    }

    /// The Mac saved it but its reply was lost: the next link learns the path, sends nothing.
    @Test(.timeLimit(.minutes(1))) func aSavedUploadWhoseReplyWasLostIsNotSentAgain() async throws {
        let first = ScriptedLink(dropAfter: 0, status: nil)
        let second = ScriptedLink(dropAfter: nil, status: #"{"path":"/up/done.mov","size":9}"#)
        let options = LinkUpload.Options(nextLink: { second })

        let path = try await LinkUpload.upload(.data(Data(count: 9)), name: "done.mov", cwd: nil, over: first, options: options)

        #expect(path == "/up/done.mov")
        #expect(second.uploadArgs == nil)
    }

    /// No next link (the Mac stays away): the upload fails after its loss, it does not wait forever.
    @Test(.timeLimit(.minutes(1))) func noNextLinkFailsTheUpload() async throws {
        let first = ScriptedLink(dropAfter: 0, status: nil)
        let options = LinkUpload.Options(nextLink: { nil })

        await #expect(throws: LinkUpload.Failure.self) {
            _ = try await LinkUpload.upload(.data(Data(count: 9)), name: "a.mov", cwd: nil, over: first, options: options)
        }
    }

    /// Per-hop timing comes back once, with the attempts and where it resumed.
    @Test(.timeLimit(.minutes(1))) func timingReportsTheHops() async throws {
        let size = LinkUpload.chunkBytes * 2
        let first = ScriptedLink(dropAfter: LinkUpload.chunkBytes, status: nil)
        let second = ScriptedLink(dropAfter: nil, status: #"{"offset":\#(LinkUpload.chunkBytes)}"#)
        let got = Steps.Timings()
        let options = LinkUpload.Options(nextLink: { second }, timing: { got.add($0) })

        _ = try await LinkUpload.upload(.data(Data(count: size)), name: "a.mov", cwd: nil, over: first, options: options)

        let timings = got.all
        #expect(timings.count == 1)
        #expect(timings.first?.attempts == 2)
        #expect(timings.first?.resumedFrom == LinkUpload.chunkBytes)
        #expect(timings.first?.outcome == "sent")
        #expect(timings.first?.line.contains("outcome=sent") == true)
    }

    /// A Mac link for resume: its `upload` channel drops after `dropAfter` bytes (nil: never),
    /// its `upload-status` answers `status` (nil: an older Mac that refuses it).
    final class ScriptedLink: MacLink, @unchecked Sendable {
        let transport: TransportKind = .webRTC
        let states = AsyncStream<LinkState> { $0.finish() }
        let dropAfter: Int?
        let status: String?
        private let lock = NSLock()
        private var args: [String: String]?
        private var bytes = 0

        init(dropAfter: Int?, status: String?) {
            self.dropAfter = dropAfter
            self.status = status
        }

        var uploadArgs: [String: String]? { lock.withLock { args } }
        var received: Int { lock.withLock { bytes } }

        func openChannel(service: String, args: [String: String]) async throws -> any LinkChannel {
            if service == "upload-status" {
                guard let status else { throw LinkError(code: "unknown_service", message: "no upload-status") }
                return ReplyChannel(reply: Data(status.utf8))
            }
            lock.withLock { self.args = args }
            return ScriptedChannel(link: self, start: Int(args["offset"] ?? "0") ?? 0, name: args["name"] ?? "")
        }

        /// Takes `count` bytes; false once the link has dropped.
        func take(_ count: Int) -> Bool {
            lock.withLock {
                if let dropAfter, bytes + count > dropAfter { return false }
                bytes += count
                return true
            }
        }

        func ping() async throws -> UInt32 { 1 }
        func close() async {}
    }

    final class ScriptedChannel: LinkChannel, @unchecked Sendable {
        let id: UInt32 = 3
        let link: ScriptedLink
        let name: String
        private let lock = NSLock()
        private var dropped = false
        private var answered = false

        init(link: ScriptedLink, start: Int, name: String) {
            self.link = link
            self.name = name
        }

        func send(_ data: Data) async throws {
            guard link.take(data.count) else {
                lock.withLock { dropped = true }
                throw LinkError(code: "closed", message: "the link dropped")
            }
        }

        func receive() async throws -> Data? {
            lock.withLock { () -> Data? in
                guard !dropped, !answered else { return nil }
                answered = true
                return Data(#"{"path":"/up/\#(name)","size":1}"#.utf8)
            }
        }

        func close(code: String, reason: String) async {}
    }

    final class ReplyChannel: LinkChannel, @unchecked Sendable {
        let id: UInt32 = 4
        private let lock = NSLock()
        private var reply: Data?

        init(reply: Data) { self.reply = reply }

        func send(_ data: Data) async throws {}
        func receive() async throws -> Data? { lock.withLock { defer { reply = nil }; return reply } }
        func close(code: String, reason: String) async {}
    }

    final class Steps: @unchecked Sendable {
        private let lock = NSLock()
        private var steps: [LinkUpload.Progress] = []
        func add(_ step: LinkUpload.Progress) { lock.withLock { steps.append(step) } }
        var all: [LinkUpload.Progress] { lock.withLock { steps } }

        final class Timings: @unchecked Sendable {
            private let lock = NSLock()
            private var timings: [LinkUpload.Timing] = []
            func add(_ timing: LinkUpload.Timing) { lock.withLock { timings.append(timing) } }
            var all: [LinkUpload.Timing] { lock.withLock { timings } }
        }
    }
}

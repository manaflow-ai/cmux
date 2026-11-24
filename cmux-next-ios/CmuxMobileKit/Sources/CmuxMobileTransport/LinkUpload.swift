import Foundation
#if canImport(os)
import os
#endif

/// Sends a file to the Mac over the link's `upload` service (PROTOCOL.md):
/// one channel per file, opened with `{name, size, cwd?, id?, offset?}`, the
/// bytes as data frames, then the Mac's one reply `{"path","size"}` or
/// `{"error","message"}`. The Mac writes a new file (never replacing one) in
/// `<cwd>/.cmux/attachments/phone-<session>/` when `cwd` is a folder of one
/// of its tabs, else in its own uploads folder, and answers its real path.
///
/// Every wait is bounded (Leo, 2026-11-24: "it just blocked me endlessly on a send"): a
/// chunk the link does not take within ``Options/stallAfter`` and a reply that does not come
/// within ``Options/replyWithin`` end the attempt as `stalled`. An attempt the link lost goes
/// again on the next link from where the Mac's copy stopped (`upload-status`, a Mac that says
/// `upload-resume-v1`), or from the start on an older Mac.
public enum LinkUpload {
    /// Bytes per channel write: the link splits larger writes anyway.
    static let chunkBytes = 192 << 10

    public struct Failure: Error, Equatable, Sendable, LocalizedError {
        public var code: String
        public var message: String

        public init(code: String, message: String) {
            self.code = code
            self.message = message
        }

        public var errorDescription: String? { message }

        /// The link lost the upload (a drop, a stall, the link gone): the next link may finish
        /// it. A refusal from the Mac (a folder, a name, a full disk) is its answer.
        public var isLinkLoss: Bool { Self.linkLossCodes.contains(code) }
        static let linkLossCodes: Set<String> = ["stalled", "closed", "offline", "link", "lost", "timeout", "unreachable"]
    }

    /// What an upload sends: bytes held in memory (a pasted or camera image),
    /// or a file on the phone, read `chunkBytes` at a time so a file of any
    /// size never sits whole in memory. There is no size cap.
    public enum Payload: Sendable, Equatable {
        case data(Data)
        case file(URL)
    }

    /// How far an upload is: bytes the link took of the total, and where it is.
    public struct Progress: Sendable, Equatable {
        public enum Phase: String, Sendable, Equatable {
            /// Opening the channel (and, on a retry, asking the Mac how far its copy is).
            case opening
            /// Streaming bytes.
            case sending
            /// Every byte went: the Mac is writing the file and answering.
            case saving
            /// The link dropped or stalled: waiting for the next link to go on.
            case waitingForLink
        }

        public var sent: Int
        public var total: Int
        public var phase: Phase
        /// Attempts so far (1 on the first).
        public var attempt: Int

        public init(sent: Int, total: Int, phase: Phase, attempt: Int = 1) {
            self.sent = sent
            self.total = total
            self.phase = phase
            self.attempt = attempt
        }

        public var fraction: Double { total > 0 ? min(1, Double(sent) / Double(total)) : 1 }
    }

    /// Per-hop timings of one upload, as the log line and the trace write them.
    public struct Timing: Sendable, Equatable {
        public var openMs: Double = 0
        public var firstChunkMs: Double = 0
        public var sendMs: Double = 0
        public var replyMs: Double = 0
        public var totalMs: Double = 0
        public var bytes: Int = 0
        public var resumedFrom: Int = 0
        public var attempts: Int = 0
        public var path: String = ""
        public var outcome: String = ""

        public var megabytesPerSecond: Double {
            sendMs > 0 ? Double(bytes - resumedFrom) / 1_048_576 / (sendMs / 1000) : 0
        }

        /// One `key=value` line, the hops in order.
        public var line: String {
            String(format: "upload outcome=%@ bytes=%d resumed_from=%d attempts=%d path=%@ open_ms=%.0f first_chunk_ms=%.0f send_ms=%.0f reply_ms=%.0f total_ms=%.0f mb_s=%.2f",
                   outcome, bytes, resumedFrom, attempts, path.isEmpty ? "-" : path, openMs, firstChunkMs, sendMs, replyMs, totalMs, megabytesPerSecond)
        }
    }

    /// Bounds, resume and progress of one upload.
    public struct Options: Sendable {
        /// The upload's id: the Mac keeps a lost attempt's bytes under it, and the next attempt
        /// goes on from there.
        public var id: String
        /// The longest one chunk may wait for the link to take it.
        public var stallAfter: Duration
        /// The longest the Mac's reply may take once every byte went (it writes and syncs the file).
        public var replyWithin: Duration
        /// Attempts in all, the first included (each after a link loss).
        public var attempts: Int
        /// The link for an attempt after a loss: waits (bounded) for the next one; nil when none
        /// comes. Nil: no retry.
        public var nextLink: (@Sendable () async -> (any MacLink)?)?
        public var progress: (@Sendable (Progress) -> Void)?
        /// The upload's per-hop timings, once it ends (sent or failed).
        public var timing: (@Sendable (Timing) -> Void)?

        public init(id: String = UUID().uuidString.lowercased(), stallAfter: Duration = .seconds(30),
                    replyWithin: Duration = .seconds(60), attempts: Int = 4,
                    nextLink: (@Sendable () async -> (any MacLink)?)? = nil,
                    progress: (@Sendable (Progress) -> Void)? = nil,
                    timing: (@Sendable (Timing) -> Void)? = nil) {
            self.id = id
            self.stallAfter = stallAfter
            self.replyWithin = replyWithin
            self.attempts = max(1, attempts)
            self.nextLink = nextLink
            self.progress = progress
            self.timing = timing
        }
    }

    /// Uploads `data` as `name` and returns the file's absolute path on the Mac.
    public static func upload(_ data: Data, name: String, cwd: String?, over link: any MacLink) async throws -> String {
        try await upload(.data(data), name: name, cwd: cwd, over: link)
    }

    /// Streams the file at `url` as `name` and returns its absolute path on the Mac.
    public static func upload(fileAt url: URL, name: String, cwd: String?, over link: any MacLink) async throws -> String {
        try await upload(.file(url), name: name, cwd: cwd, over: link)
    }

    /// Uploads `payload` as `name` and returns the file's absolute path on the Mac.
    /// Nonisolated async: the file reads run off the caller's actor.
    public static func upload(_ payload: Payload, name: String, cwd: String?, over link: any MacLink,
                              scope: any SecurityScope = SystemSecurityScope(),
                              options: Options = Options()) async throws -> String {
        switch payload {
        case .data(let data):
            return try await send(name: name, size: data.count, cwd: cwd, link: link, options: options) { offset, count in
                data.subdata(in: data.startIndex + offset..<data.startIndex + offset + count)
            } seek: { _ in }
        case .file(let url):
            // A Files pick is security-scoped: its access stays open for the whole
            // stream and closes when the upload ends, however it ends.
            let access = ScopedFile(url, scope: scope).open()
            defer { access.close() }
            let handle: FileHandle
            let size: Int
            do {
                handle = try FileHandle(forReadingFrom: url)
                size = Int(try handle.seekToEnd())
                try handle.seek(toOffset: 0)
            } catch {
                throw unreadable(name)
            }
            defer { try? handle.close() }
            return try await send(name: name, size: size, cwd: cwd, link: link, options: options) { _, count in
                try handle.read(upToCount: count) ?? Data()
            } seek: { offset in
                try handle.seek(toOffset: UInt64(offset))
            }
        }
    }

    static func unreadable(_ name: String) -> Failure {
        Failure(code: "unreadable", message: "Couldn't read \(name) on this iPhone.")
    }

    static func stalled(_ what: String, after bound: Duration) -> Failure {
        Failure(code: "stalled", message: "The link to the Mac stopped \(what) for \(bound.components.seconds) s.")
    }

    #if canImport(os)
    private static let log = Logger(subsystem: "dev.cmux.mobile", category: "upload")
    #endif

    /// Attempts until the Mac answers, a refusal, or the attempts run out; each after a link
    /// loss on the next link, from where the Mac's copy stopped.
    private static func send(name: String, size: Int, cwd: String?, link first: any MacLink, options: Options,
                             nextChunk: (_ offset: Int, _ count: Int) throws -> Data,
                             seek: (Int) throws -> Void) async throws -> String {
        let started = ContinuousClock.now
        var timing = Timing()
        timing.bytes = size
        var link: any MacLink = first
        var lastFailure: Failure?
        defer {
            timing.totalMs = ms(since: started)
            #if canImport(os)
            log.notice("\(timing.line, privacy: .public)")
            #endif
            options.timing?(timing)
        }
        for attempt in 1...options.attempts {
            timing.attempts = attempt
            if attempt > 1 {
                guard let nextLink = options.nextLink else { break }
                options.progress?(Progress(sent: timing.resumedFrom, total: size, phase: .waitingForLink, attempt: attempt))
                guard let next = await nextLink() else { break }
                try Task.checkCancellation()
                link = next
            }
            var offset = 0
            if attempt > 1 {
                options.progress?(Progress(sent: 0, total: size, phase: .opening, attempt: attempt))
                switch await status(id: options.id, over: link, within: min(options.replyWithin, .seconds(10))) {
                case .done(let path):
                    timing.outcome = "sent"
                    timing.path = path
                    return path
                case .at(let kept) where kept > 0 && kept <= size:
                    offset = kept
                case .at, .unknown:
                    offset = 0
                }
                do { try seek(offset) } catch { throw unreadable(name) }
                timing.resumedFrom = offset
            }
            do {
                let path = try await attemptUpload(name: name, size: size, offset: offset, cwd: cwd, link: link,
                                                   options: options, attempt: attempt, timing: &timing, nextChunk: nextChunk)
                timing.outcome = "sent"
                timing.path = path
                return path
            } catch let failure as Failure where failure.isLinkLoss || failure.code == "resume_mismatch" {
                lastFailure = failure
                timing.outcome = failure.code
                #if canImport(os)
                log.notice("upload attempt \(attempt, privacy: .public) of \(options.id, privacy: .public) lost: \(failure.code, privacy: .public) \(failure.message, privacy: .public)")
                #endif
                // A Mac whose copy does not line up starts over.
                if failure.code == "resume_mismatch" { do { try seek(0) } catch { throw unreadable(name) } }
                continue
            } catch {
                timing.outcome = (error as? Failure)?.code ?? (error is CancellationError ? "cancelled" : "failed")
                throw error
            }
        }
        throw lastFailure ?? Failure(code: "offline", message: "The Mac isn't connected.")
    }

    /// One channel: opens it at `offset`, streams the rest, reads the Mac's reply. Every wait
    /// is bounded; a bound that passes closes the channel and throws `stalled`.
    private static func attemptUpload(name: String, size: Int, offset start: Int, cwd: String?, link: any MacLink,
                                      options: Options, attempt: Int, timing: inout Timing,
                                      nextChunk: (_ offset: Int, _ count: Int) throws -> Data) async throws -> String {
        var args = ["name": name, "size": String(size), "id": options.id]
        if start > 0 { args["offset"] = String(start) }
        if let cwd, cwd.hasPrefix("/") { args["cwd"] = cwd }
        options.progress?(Progress(sent: start, total: size, phase: .opening, attempt: attempt))
        let opening = ContinuousClock.now
        let channel: any LinkChannel
        do {
            channel = try await bounded(options.stallAfter, "opening the upload") {
                try await link.openChannel(service: "upload", args: args)
            } onTimeout: {}
        } catch let error as LinkError {
            throw Failure(code: error.code, message: error.message)
        }
        timing.openMs += ms(since: opening)
        // Cancelling the upload closes its channel, which ends a wait for the
        // Mac's reply; the stream stops at its next chunk. The caller's file
        // handle and scope then close as the upload returns.
        return try await withTaskCancellationHandler {
            let sending = ContinuousClock.now
            var offset = start
            var lostSend = false
            options.progress?(Progress(sent: offset, total: size, phase: .sending, attempt: attempt))
            while offset < size {
                if Task.isCancelled {
                    await channel.close(code: "cancelled", reason: "cancelled")
                    throw CancellationError()
                }
                let chunk = (try? nextChunk(offset, min(chunkBytes, size - offset))) ?? Data()
                // The file shrank or stopped reading: cancel rather than hand the Mac a short file.
                guard !chunk.isEmpty else {
                    await channel.close(code: "cancelled", reason: "unreadable")
                    throw unreadable(name)
                }
                do {
                    try await bounded(options.stallAfter, "taking the video's bytes") {
                        try await channel.send(chunk)
                    } onTimeout: {
                        await channel.close(code: "cancelled", reason: "stalled")
                    }
                } catch let failure as Failure {
                    throw failure
                } catch is CancellationError {
                    await channel.close(code: "cancelled", reason: "cancelled")
                    throw CancellationError()
                } catch {
                    // The Mac may refuse before reading (a folder it won't write to): a
                    // failed send is not the answer, the reply is.
                    lostSend = true
                    break
                }
                if offset == start { timing.firstChunkMs = ms(since: sending) }
                offset += chunk.count
                options.progress?(Progress(sent: offset, total: size, phase: .sending, attempt: attempt))
            }
            timing.sendMs += ms(since: sending)
            options.progress?(Progress(sent: offset, total: size, phase: .saving, attempt: attempt))
            let replying = ContinuousClock.now
            let reply: Data
            do {
                reply = try await bounded(options.replyWithin, "answering") {
                    var reply = Data()
                    while let chunk = try await channel.receive() {
                        reply.append(chunk)
                    }
                    return reply
                } onTimeout: {
                    await channel.close(code: "cancelled", reason: "stalled")
                }
            } catch is CancellationError {
                // Closed before this returns, so the Mac drops the upload (and the caller sees it closed).
                await channel.close(code: "cancelled", reason: "cancelled")
                throw CancellationError()
            }
            timing.replyMs += ms(since: replying)
            try Task.checkCancellation()
            if reply.isEmpty, lostSend || offset < size {
                throw Failure(code: "lost", message: "The link to the Mac dropped during the upload.")
            }
            return try path(fromReply: reply)
        } onCancel: {
            Task { await channel.close(code: "cancelled", reason: "cancelled") }
        }
    }

    // MARK: Resume

    enum Status: Equatable {
        /// The Mac finished this id already (its reply was lost): its path.
        case done(String)
        /// The Mac holds this many bytes of it.
        case at(Int)
        /// An older Mac (no `upload-status`), or no answer: start over.
        case unknown
    }

    /// Asks the Mac how far its copy of `id` is (`upload-status`, PROTOCOL.md).
    static func status(id: String, over link: any MacLink, within bound: Duration) async -> Status {
        do {
            return try await bounded(bound, "answering") {
                let channel = try await link.openChannel(service: "upload-status", args: ["id": id])
                var reply = Data()
                while let chunk = try await channel.receive() { reply.append(chunk) }
                return status(fromReply: reply)
            } onTimeout: {}
        } catch {
            return .unknown
        }
    }

    static func status(fromReply reply: Data) -> Status {
        guard let object = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any] else { return .unknown }
        if let path = object["path"] as? String, path.hasPrefix("/") { return .done(path) }
        if let offset = object["offset"] as? Int, offset >= 0 { return .at(offset) }
        if let text = object["offset"] as? String, let offset = Int(text), offset >= 0 { return .at(offset) }
        return .unknown
    }

    // MARK: Bounds

    /// Runs `operation`, or throws `stalled` once `bound` passes without it ending (after
    /// `onTimeout`, which unblocks it: a closed channel ends its send and its read). Unlike a
    /// task group, a timed-out operation that never returns is left behind, not awaited.
    static func bounded<T: Sendable>(_ bound: Duration, _ what: String,
                                     _ operation: @escaping @Sendable () async throws -> T,
                                     onTimeout: @escaping @Sendable () async -> Void) async throws -> T {
        let once = Once<T>()
        let work = Task {
            do { await once.finish(with: .success(try await operation())) } catch { await once.finish(with: .failure(error)) }
        }
        let timer = Task {
            try? await Task.sleep(for: bound)
            guard !Task.isCancelled else { return }
            if await once.finish(with: .failure(stalled(what, after: bound))) {
                await onTimeout()
                work.cancel()
            }
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try await once.value()
        } onCancel: {
            work.cancel()
            Task { await once.finish(with: .failure(CancellationError())) }
        }
    }

    /// The first result of a race, handed to its one waiter.
    private actor Once<T: Sendable> {
        private var result: Result<T, any Error>?
        private var waiter: CheckedContinuation<T, any Error>?

        @discardableResult
        func finish(with result: Result<T, any Error>) -> Bool {
            guard self.result == nil else { return false }
            self.result = result
            waiter?.resume(with: result)
            waiter = nil
            return true
        }

        func value() async throws -> T {
            if let result { return try result.get() }
            return try await withCheckedThrowingContinuation { waiter = $0 }
        }
    }

    private static func ms(since start: ContinuousClock.Instant) -> Double {
        let elapsed = (ContinuousClock.now - start).components
        return Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
    }

    // MARK: Replies

    /// The path in the Mac's reply, or its refusal.
    public static func path(fromReply reply: Data) throws -> String {
        guard let object = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any] else {
            throw Failure(code: "closed", message: "The Mac closed the upload without an answer.")
        }
        if let path = object["path"] as? String, path.hasPrefix("/") { return path }
        throw Failure(code: object["error"] as? String ?? "failed", message: object["message"] as? String ?? "The upload failed.")
    }

    /// `<cwd>` with a trailing slash removed, or nil.
    public static func folder(_ cwd: String?) -> String? {
        guard var cwd, cwd.hasPrefix("/") else { return nil }
        while cwd.count > 1, cwd.hasSuffix("/") { cwd.removeLast() }
        return cwd
    }
}

#if DEBUG
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its Swift side.
import CmuxNextCompat
import Darwin

/// The state of one ``ChromiumHostControlChannel``, shared by the channel,
/// its reader thread and the main-thread drains it posts, so a channel
/// dropped without `close()` still deinits (its `deinit` ends the core; the
/// reader then stops).
///
/// One `Mutex` (the lock carve-out, as ``ChromiumHostWireState``: short
/// critical sections around an outbox push, an inbox append or a flush,
/// taken on every control op where an actor would add a hop). A flush is one
/// non-blocking `sendmsg` per batch of up to 16 KiB of waiting frames (the
/// outbox batches them), so a send waits behind at most a few syscalls.
/// No call under it waits: the socket and the wake pipe are non-blocking.
/// The reader thread is the only one that closes the descriptors, under the
/// lock, so no side touches a number the system may have reused.
nonisolated final class ChromiumHostControlCore: Sendable {
    typealias Reply = Result<ChromiumHostControlMessage, ChromiumHostControlError>

    private struct State: Sendable {
        var fd: Int32
        var wakeRead: Int32 = -1
        var wakeWrite: Int32 = -1
        var outbox: ChromiumHostControlOutbox
        var endReason: ChromiumHostControlEnd?
        /// A write found the host's end closed: nothing more is written, and
        /// the reader reads what the host sent until EOF, as Mojo's
        /// `ChannelPosix::OnWriteError` keeps reading on `kDisconnected`.
        var rejectWrites = false
        var overSince: ContinuousClock.Instant?
        var quotaExcess: UInt64 = 0
        var coalesced: UInt64 = 0
        /// Read and not run on main yet; the drain takes it whole.
        var inbox: [ChromiumHostControlMessage] = []
        var drainPosted = false
        /// The inbox is at its limit: the reader does not read.
        var paused = false
        /// The reader closed its descriptors: the end may be delivered.
        var readerDone = false
        var endDelivered = false
        var lastToken: UInt32 = 0
        var replies: [UInt32: CheckedContinuation<Reply, Never>] = [:]
        /// Tokens of posts whose ACK goes to the mirror on main.
        var acks: Set<UInt32> = []
        /// The mirror refused a frame: nothing read after it runs.
        var refused = false

        /// Why nothing can be sent, if so.
        var unwritable: ChromiumHostControlEnd? { endReason ?? (rejectWrites ? .peerClosed : nil) }
    }

    /// What the reader waits for in one `poll`.
    private struct PollPlan {
        var events: Int16
        var wantsRead: Bool
        var wantsWrite: Bool
        var timeoutMilliseconds: Int32
    }

    private let options: ChromiumHostControlChannel.Options
    private let post: ChromiumHostControlChannel.MainPost
    /// Takes the MIRROR and ACK frames of each batch on main.
    let mirror: ChromiumHostMirror?
    private let onMessages: @MainActor @Sendable ([ChromiumHostControlMessage]) -> Void
    private let onEnd: @MainActor @Sendable (ChromiumHostControlEnd) -> Void
    private let state: Mutex<State>

    init(fd: Int32, options: ChromiumHostControlChannel.Options, post: @escaping ChromiumHostControlChannel.MainPost,
         mirror: ChromiumHostMirror?,
         onMessages: @escaping @MainActor @Sendable ([ChromiumHostControlMessage]) -> Void,
         onEnd: @escaping @MainActor @Sendable (ChromiumHostControlEnd) -> Void) {
        self.options = options
        self.post = post
        self.mirror = mirror
        self.onMessages = onMessages
        self.onEnd = onEnd
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var noSigPipe: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var initial = State(fd: fd, outbox: ChromiumHostControlOutbox(quotaBytes: options.quotaBytes,
                                                                       quotaMessages: options.quotaMessages))
        var wake: [Int32] = [-1, -1]
        if Darwin.pipe(&wake) == 0 {
            for end in wake {
                _ = fcntl(end, F_SETFL, fcntl(end, F_GETFL) | O_NONBLOCK)
                _ = fcntl(end, F_SETFD, FD_CLOEXEC)
            }
            initial.wakeRead = wake[0]
            initial.wakeWrite = wake[1]
        } else {
            initial.endReason = .ioError  // the reader stops at once and reports it
        }
        state = Mutex(initial)
    }

    // MARK: Any thread

    func send(_ frame: [UInt8], fds: [Int32], stateKey: UInt64?) -> Bool {
        state.withLock { Self.sendLocked(&$0, frame, fds: fds, stateKey: stateKey) }
    }

    /// Sends `message` under a fresh token; `continuation` resumes with the
    /// reply (on the reader thread) or the end.
    func request(_ message: ChromiumHostControlMessage, _ continuation: CheckedContinuation<Reply, Never>) {
        let failure = state.withLock { state -> ChromiumHostControlError? in
            if let reason = state.unwritable { return .hostGone(reason) }
            let token = Self.nextTokenLocked(&state)
            var tokened = message
            tokened.token = token
            tokened.isReply = false
            guard let frame = tokened.encoded() else { return .unsendable }
            state.replies[token] = continuation
            guard Self.sendLocked(&state, frame, fds: message.fds, stateKey: nil) else {
                state.replies[token] = nil
                return state.unwritable.map { .hostGone($0) } ?? .unsendable
            }
            return nil
        }
        if let failure { continuation.resume(returning: .failure(failure)) }
    }

    /// Sends `message` under a fresh token whose ACK joins the main-thread
    /// batch (for the mirror); the token, or nil when nothing was sent.
    func sendAwaitingAck(_ message: ChromiumHostControlMessage) -> UInt32? {
        state.withLock { state -> UInt32? in
            guard state.unwritable == nil else { return nil }
            var tokened = message
            tokened.token = Self.nextTokenLocked(&state)
            tokened.isReply = false
            guard let frame = tokened.encoded(),
                  Self.sendLocked(&state, frame, fds: message.fds, stateKey: nil) else { return nil }
            state.acks.insert(tokened.token)
            return tokened.token
        }
    }

    func end(_ reason: ChromiumHostControlEnd) {
        state.withLock { Self.endLocked(&$0, reason) }
    }

    var stats: ChromiumHostControlChannel.Stats {
        state.withLock { state -> ChromiumHostControlChannel.Stats in
            ChromiumHostControlChannel.Stats(quotaExcess: state.quotaExcess, coalesced: state.coalesced,
                                             pendingMessages: state.outbox.messages, pendingBytes: state.outbox.bytes)
        }
    }

    func pendingCount(stateKey: UInt64) -> Int {
        state.withLock { $0.outbox.count(key: stateKey) }
    }

    // MARK: Reader thread

    /// The reader thread `com.cmuxterm.chromium-host.control`: waits in
    /// `poll` for input, for the socket to take a waiting outbox, for a wake,
    /// or for the quota ceiling; ends with the channel, then closes the
    /// descriptors, resumes waiting requests and posts the end.
    func run() {
        var buffer: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        var control = [UInt8](repeating: 0, count: ChromiumHostControlSocket.receiveControlSize)
        var fds: [Int32] = []
        let (fd, wakeRead) = state.withLock { ($0.fd, $0.wakeRead) }
        let socket = ChromiumHostControlSocket(fd: fd)
        while let plan = state.withLock({ pollPlan($0) }) {
            // Paused with nothing to write: a hang-up must not spin the loop.
            var polls = [pollfd(fd: plan.events == 0 ? -1 : fd, events: plan.events, revents: 0),
                         pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0)]
            let ready = Darwin.poll(&polls, 2, plan.timeoutMilliseconds)
            if ready < 0, errno != EINTR {
                end(.ioError)
                break
            }
            if ready > 0, polls[1].revents != 0 { Self.drainWakePipe(wakeRead) }
            let got = Int32(polls[0].revents)
            if plan.wantsWrite, got & Int32(POLLOUT | POLLERR | POLLHUP) != 0 {
                // On a hang-up the write fails as peerClosed and the read below finds EOF.
                state.withLock { state -> Void in
                    if state.unwritable == nil { _ = Self.flushLocked(&state) }
                }
            }
            if plan.wantsRead, got & Int32(POLLIN | POLLERR | POLLHUP) != 0,
               let reason = readAvailable(socket, &buffer, &chunk, &control, &fds) {
                end(reason)
                break
            }
            state.withLock { state -> Void in
                guard let since = state.overSince, ContinuousClock.now - since >= options.quotaCeiling else { return }
                if state.outbox.isOverQuota {
                    Self.endLocked(&state, .quotaCeiling)
                } else {
                    state.overSince = nil
                }
            }
        }
        for received in fds { Darwin.close(received) }
        let (waiters, reason, postsDrain) = state.withLock {
            state -> ([CheckedContinuation<Reply, Never>], ChromiumHostControlEnd, Bool) in
            Darwin.close(state.fd)
            state.fd = -1
            Darwin.close(state.wakeRead)
            Darwin.close(state.wakeWrite)
            state.wakeRead = -1
            state.wakeWrite = -1
            state.readerDone = true
            let waiters = Array(state.replies.values)
            state.replies = [:]
            state.acks = []
            return (waiters, state.endReason ?? .closed, Self.claimDrain(&state))
        }
        for waiter in waiters { waiter.resume(returning: .failure(.hostGone(reason))) }
        if postsDrain { scheduleDrain() }
    }

    private func pollPlan(_ state: State) -> PollPlan? {
        guard state.endReason == nil else { return nil }
        let wantsRead = !state.paused
        let wantsWrite = !state.outbox.isEmpty
        let events = (wantsRead ? Int32(POLLIN) : 0) | (wantsWrite ? Int32(POLLOUT) : 0)
        var timeout: Int32 = -1
        if let since = state.overSince { timeout = Self.milliseconds(until: since + options.quotaCeiling) }
        return PollPlan(events: Int16(events), wantsRead: wantsRead, wantsWrite: wantsWrite,
                        timeoutMilliseconds: timeout)
    }

    /// Reads what the socket holds; the reason when the connection must end.
    /// Each pass reads once; the loop ends when the socket has nothing more (EAGAIN).
    private func readAvailable(_ socket: ChromiumHostControlSocket, _ buffer: inout [UInt8], _ chunk: inout [UInt8],
                               _ control: inout [UInt8], _ fds: inout [Int32]) -> ChromiumHostControlEnd? {
        var outcome = socket.receive(into: &chunk, control: &control, fds: &fds)
        while outcome != .wouldBlock {
            switch outcome {
            case .interrupted, .wouldBlock: break
            case .endOfStream: return .peerClosed
            case .truncated: return .malformed  // more descriptors than any frame may carry
            case .failed: return .ioError
            case .read(let count):
                buffer.append(contentsOf: chunk[0..<count])
                let (failure, paused) = deliver(&buffer, &fds)
                if let failure { return failure }
                if paused { return nil }
            }
            outcome = socket.receive(into: &chunk, control: &control, fds: &fds)
        }
        return nil
    }

    /// Decodes the whole frames of `buffer`: a reply resumes its request
    /// here, every other message joins the inbox (one drain posted per batch).
    private func deliver(_ buffer: inout [UInt8], _ fds: inout [Int32]) -> (ChromiumHostControlEnd?, paused: Bool) {
        var start = 0
        var postsDrain = false
        var paused = false
        var failure: ChromiumHostControlEnd?
        var decoded = ChromiumHostControlMessage.decode(buffer[start...], fds: &fds)
        while failure == nil, case .frame(let message, let consumed) = decoded {
            start += consumed
            if message.isReply, let waiter = state.withLock({ $0.replies.removeValue(forKey: message.token) }) {
                waiter.resume(returning: .success(message))
            } else if message.isReply, !state.withLock({ ChromiumHostMirror.isAck(message, awaited: &$0.acks) }) {
                for received in message.fds { Darwin.close(received) }
                failure = .malformed  // a reply to no request
            } else {
                // An ACK of a post joins the batch, in order, for the mirror.
                let (claimed, full) = state.withLock { state -> (Bool, Bool) in
                    state.inbox.append(message)
                    if state.inbox.count >= options.inboxLimit { state.paused = true }
                    return (Self.claimDrain(&state), state.paused)
                }
                postsDrain = postsDrain || claimed
                paused = paused || full
            }
            decoded = ChromiumHostControlMessage.decode(buffer[start...], fds: &fds)
        }
        if decoded == .malformed { failure = .malformed }
        // Descriptors that came with a frame declaring fewer, which no later frame may take.
        if failure == nil, !ChromiumHostControlMessage.pendingFdsFit(buffer[start...], pending: fds.count) {
            failure = .malformed
        }
        buffer.removeFirst(start)
        if postsDrain { scheduleDrain() }
        return (failure, paused)
    }

    private func scheduleDrain() {
        post { [self] in drain() }
    }

    // MARK: Main thread

    /// The batch read since the last drain, then, once the reader has
    /// stopped, the end; a reader paused at the inbox limit reads again.
    @MainActor private func drain() {
        let (batch, end) = state.withLock { state -> ([ChromiumHostControlMessage], ChromiumHostControlEnd?) in
            let batch = state.refused ? [] : state.inbox
            for received in state.refused ? state.inbox.flatMap(\.fds) : [] { Darwin.close(received) }
            state.inbox = []
            state.drainPosted = false
            if state.paused {
                state.paused = false
                Self.wake(state.wakeWrite)
            }
            guard state.readerDone, !state.endDelivered else { return (batch, nil) }
            state.endDelivered = true
            return (batch, state.endReason ?? .closed)
        }
        if !batch.isEmpty { handOver(batch) }
        if let end {
            mirror?.hostEnded()
            onEnd(end)
        }
    }

    /// A malformed MIRROR or ACK ends the connection; nothing from it on runs.
    @MainActor private func handOver(_ batch: [ChromiumHostControlMessage]) {
        guard let mirror else { return onMessages(batch) }
        guard let bad = mirror.deliver(batch, to: onMessages) else { return }
        for received in batch[bad...].flatMap(\.fds) { Darwin.close(received) }
        state.withLock { state -> Void in
            state.refused = true
            Self.endLocked(&state, .malformed)
        }
    }

    // MARK: Under the lock

    private static func sendLocked(_ state: inout State, _ frame: [UInt8], fds: [Int32], stateKey: UInt64?) -> Bool {
        guard state.unwritable == nil else { return false }
        var copies: [Int32] = []
        for fd in fds {
            let copy = fcntl(fd, F_DUPFD_CLOEXEC, 0)
            guard copy >= 0 else {
                for made in copies { Darwin.close(made) }
                return false
            }
            copies.append(copy)
        }
        let wasEmpty = state.outbox.isEmpty
        if state.outbox.push(frame, fds: copies, key: stateKey) { state.coalesced += 1 }
        if wasEmpty {
            guard flushLocked(&state) else { return false }
            if !state.outbox.isEmpty { wake(state.wakeWrite) }  // the reader now waits for the socket to take more
        }
        if state.outbox.isOverQuota {
            state.quotaExcess += 1
            if state.overSince == nil {
                state.overSince = ContinuousClock.now
                wake(state.wakeWrite)  // the reader now keeps the ceiling's deadline
            }
        } else {
            state.overSince = nil  // coalescing can bring it under quota while the socket takes nothing
        }
        return true
    }

    /// Writes what the outbox holds while the socket takes it. False when
    /// nothing more can be written: the socket failed (the channel ends), or
    /// the host closed its end (the outbox is dropped; the reader reads to EOF).
    private static func flushLocked(_ state: inout State) -> Bool {
        let socket = ChromiumHostControlSocket(fd: state.fd)
        switch state.outbox.flush({ bytes, fds in socket.send(bytes, fds: fds) }) {
        case .drained, .blocked:
            if !state.outbox.isOverQuota { state.overSince = nil }
            return true
        case .peerClosed:
            state.rejectWrites = true
            state.outbox.removeAll()
            state.overSince = nil
            wake(state.wakeWrite)
            return false
        case .failed:
            endLocked(&state, .ioError)
            return false
        }
    }

    /// Ends the channel once: the socket shuts down (the host reads EOF), the
    /// outbox is dropped and the reader stops.
    private static func endLocked(_ state: inout State, _ reason: ChromiumHostControlEnd) {
        guard state.endReason == nil else { return }
        state.endReason = reason
        state.outbox.removeAll()
        state.overSince = nil
        if state.fd >= 0 { Darwin.shutdown(state.fd, SHUT_RDWR) }
        wake(state.wakeWrite)
    }

    private static func nextTokenLocked(_ state: inout State) -> UInt32 {
        state.lastToken = state.lastToken == UInt32.max ? 1 : state.lastToken + 1
        return state.lastToken
    }

    /// True when the caller must post a drain (none is posted yet).
    private static func claimDrain(_ state: inout State) -> Bool {
        guard !state.drainPosted else { return false }
        state.drainPosted = true
        return true
    }
}
#endif

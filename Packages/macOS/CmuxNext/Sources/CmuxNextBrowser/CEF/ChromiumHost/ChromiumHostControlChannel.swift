#if DEBUG || CMUX_BENCH_HOOKS
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its Swift side.
import CmuxNextWakeups
import Darwin
import Foundation
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation

/// cmux's end of the control channel to the Chromium host
/// (plans/cmux-next/chrome-parity/p01-process.md 3.1; the C++ end is
/// `ChromiumHost/src/chromium_host_control.h`). Input frames go on the shm
/// ring (task 041); everything else goes here, on one stream socket.
///
/// - A bytes or str field too large for a 64 KiB frame goes in a sealed
///   shared memory region passed with the frame (``ChromiumHostSharedRegion``,
///   task 020), as `mojo_base::BigBuffer` does: no socket frame is larger.
/// - ``send(_:stateKey:)`` from any thread never blocks: a frame the socket
///   refuses waits in the ``ChromiumHostControlOutbox`` and the reader thread
///   writes it once the socket takes more (Mojo's ChannelPosix,
///   `mojo/core/channel_posix.cc`). State ops coalesce there by
///   ``stateKey(op:browser:)``.
/// - Over quota (256 KiB or 4,096 waiting) is counted in ``Stats/quotaExcess``
///   and ends nothing, as `mojo/public/cpp/bindings/lib/message_quota_checker.cc`
///   only reports; only 60 s over quota without a break, or the person's
///   Reload (``close()``), ends the host.
/// - A malformed frame ends the connection, as
///   `bad_message::ReceivedBadMessage` ends a renderer (`content/browser/bad_message.cc`).
/// - The reader thread `com.cmuxterm.chromium-host.control` resumes
///   ``request(_:)`` replies where it reads them, off main, and hands every
///   other message to main in one ``ChromiumHostControlBatch`` per drain
///   (``MainPost``: one visible task and one `onMessages` call per batch,
///   so at most one per frame).
/// - Each channel owns its ``mirror`` (task 016b): the batch applies its
///   MIRROR and ACK frames there in arrival order with its events, and
///   ``post(_:)`` gives cmux read-your-writes on the keys an op changes
///   until the host's ACK.
nonisolated final class ChromiumHostControlChannel: Sendable {
    /// Runs `drain` on the main thread; production: ``visibleWork(_:)``.
    typealias MainPost = @Sendable (_ drain: @escaping @MainActor @Sendable () -> Void) -> Void

    struct Options: Sendable {
        var quotaBytes = 256 * 1024
        var quotaMessages = 4_096
        var quotaCeiling: Duration = .seconds(60)
        /// Messages read and not run on main yet: past it the reader stops
        /// reading until main drains (the host's outbox then holds them).
        var inboxLimit = 4_096
        /// Payload bytes read and not run on main yet (``ChromiumHostControlMessage/payloadByteCount``):
        /// past it the reader stops too, so large shared payloads cannot pile
        /// up on the heap; the inbox holds at most this plus one message.
        var inboxBytesLimit = 2 * ChromiumHostSharedRegion.maxBytes
    }

    struct Stats: Equatable, Sendable {
        /// Sends while the outbox was over quota (`debug.chromium_host quota_excess`).
        var quotaExcess: UInt64 = 0
        /// Waiting state ops replaced by a newer one.
        var coalesced: UInt64 = 0
        var pendingMessages = 0
        var pendingBytes = 0
    }

    private let core: ChromiumHostControlCore

    /// Takes `fd` (a connected stream socket) and starts the reader thread.
    /// `onMessages`, then once `onEnd`, run on main through `post`.
    /// MIRROR and ACK frames go to ``mirror``, never to `onMessages`, and
    /// the mirror is emptied before `onEnd`.
    init(fd: Int32, options: Options = Options(), post: @escaping MainPost,
         onMessages: @escaping @MainActor @Sendable (ChromiumHostControlBatch) -> Void,
         onEnd: @escaping @MainActor @Sendable (ChromiumHostControlEnd) -> Void) {
        let core = ChromiumHostControlCore(fd: fd, options: options, post: post,
                                           onMessages: onMessages, onEnd: onEnd)
        self.core = core
        // The thread holds the core, never the channel: a channel dropped without close() still deinits.
        let thread = Thread { core.run() }
        thread.name = "com.cmuxterm.chromium-host.control"
        // Replies and the page's state arrive here: what the person sees next.
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    deinit {
        close()
    }

    /// The key a state op of one page coalesces by.
    static func stateKey(op: UInt16, browser: Int32) -> UInt64 {
        UInt64(op) << 32 | UInt64(UInt32(bitPattern: browser))
    }

    /// Main-thread batches as one visible task each, on the app's scheduler.
    static func visibleWork(_ work: MainWorkScheduler) -> MainPost {
        let owner = work.board.owner("ChromiumHost.control")
        return { drain in work.postFromAnyThread(.visible, owner: owner, drain) }
    }

    /// This connection's mirror values, read on main. A new host connection
    /// is a new channel with a new mirror.
    var mirror: ChromiumHostMirror { core.mirror }

    /// Queues `message` (its descriptors duplicated) and writes it when the
    /// socket takes it; never waits. With `stateKey`, a waiting message with
    /// the same key is replaced. False when the channel has ended, the
    /// message breaks a bound, or its op has `pending_keys` (only
    /// ``post(_:)`` sends those); then nothing is sent.
    @discardableResult
    func send(_ message: ChromiumHostControlMessage, stateKey: UInt64? = nil) -> Bool { // perf-hot: 5us cef-host-control (every posted shim op)
        guard !ChromiumHostMirror.PendingKey.marks(message) else { return false }
        let shared = message.sharedFieldIndices()
        // A payload too large for a frame is copied to its region here, before the lock (task 020).
        guard let frame = message.encoded(sharing: shared),
              let payloads = ChromiumHostSharedPayloads(message, sharing: shared) else { return false }
        return core.send(frame, fds: message.fds, payloads: payloads, stateKey: stateKey)
    }

    /// Sends an op with `pending_keys` under a fresh token and marks the
    /// mirror keys it changes (``ChromiumHostOp/pendingKeys``, filled in from
    /// the message's fields) pending in this turn: a read before the host's
    /// ACK of that token gets ``ChromiumHostMirror/Read/pending``, never the
    /// value from before the post. Never waits. False when nothing was sent
    /// (the op has no `pending_keys`, the frame lacks a key's field, the
    /// channel has ended or the message breaks a bound); then nothing is marked.
    @MainActor @discardableResult
    func post(_ message: ChromiumHostControlMessage) -> Bool {
        guard let keys = ChromiumHostMirror.PendingKey.changed(by: message), !keys.isEmpty,
              let token = core.sendAwaitingAck(message) else { return false }
        // The ACK applies in a later main-thread batch, never before this mark.
        core.mirror.markPending(token: token, keys)
        return true
    }

    /// Sends `message` with a fresh token and returns the host's reply,
    /// resumed on the reader thread. Throws when the channel ends first.
    func request(_ message: ChromiumHostControlMessage) async throws(ChromiumHostControlError) -> ChromiumHostControlMessage {
        // Its answer is an ACK for the mirror, not a reply.
        guard !ChromiumHostMirror.PendingKey.marks(message) else { throw .changesMirror }
        // A request the core dropped unanswered (abandoned) ends as the channel's close does.
        let result = try? await withOnceContinuation {
            (continuation: OnceContinuation<ChromiumHostControlCore.Reply, OnceContinuationError>) in
            core.request(message, continuation)
        }
        return try (result ?? .failure(.hostGone(.closed))).get()
    }

    /// Ends the connection (the person's Reload, or the host's end): the
    /// host reads EOF; waiting requests throw.
    func close() {
        core.end(.closed)
    }

    var stats: Stats { core.stats }

    /// Waiting messages with `stateKey` (0 or 1); one the socket has taken
    /// part of is in flight, not waiting.
    func pendingCount(stateKey: UInt64) -> Int {
        core.pendingCount(stateKey: stateKey)
    }
}

/// Why a control channel ended.
nonisolated enum ChromiumHostControlEnd: Equatable, Sendable {
    /// ``ChromiumHostControlChannel/close()``.
    case closed
    /// The host closed its end.
    case peerClosed
    /// A bad frame, or a reply to no request.
    case malformed
    /// Over quota for the whole ceiling.
    case quotaCeiling
    case ioError
}

nonisolated enum ChromiumHostControlError: Error, Equatable, Sendable {
    /// The channel ended before the reply came.
    case hostGone(ChromiumHostControlEnd)
    /// The message breaks a bound of the frame; nothing was sent.
    case unsendable
    /// The op has `pending_keys`: ``ChromiumHostControlChannel/post(_:)``
    /// sends it; nothing was sent.
    case changesMirror
}
#endif

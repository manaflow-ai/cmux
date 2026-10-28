import CmuxNextCompat
import CmuxNextTrace
import Dispatch
import Foundation

/// The decode sequence of one connection. The reader only cuts lines and routes them; each event's
/// decode, each reply's resolution, a snapshot inflate and a bulk decode run here, in wire order. Chrome's IO
/// thread does the same: `ChannelProxy::Context::OnMessageReceived` (ipc/ipc_channel_proxy.cc) only posts each
/// message to its listener's task runner, and `MultiplexRouter` (mojo/public/cpp/bindings/lib/multiplex_router.cc)
/// posts to each endpoint's sequence.
///
/// A light item (a reply, a small terminal output chunk) runs inline on the reader while nothing of the lane is
/// queued or running, so the common case costs no thread hop. A heavy item (a control event's decode, a snapshot
/// inflate, a replay) always runs on the lane's serial queue, never on the reader. Once an item is queued, every
/// later one queues behind it until the queue drains, so the order never changes. A light item queued behind a
/// heavy one carries the reader's class and so raises the queue to it until it runs (GCD's QoS override of a
/// serial queue, Chrome's `UpdatePriority` of a sequence).
///
/// Bounded: the reader waits (``waitForRoom()``, after each line and outside its hang scope) while more than
/// ``highWater`` line bytes are queued, until they drain to ``lowWater``. Lane items never wait on a consumer (a
/// bounded consumer's wait is the reader's, ``EventDispatch/readerWait``), so that wait always ends.
///
/// Only the connection's reader thread posts; ``post(_:bytes:_:)`` relies on that.
final class DecodeLane: Sendable {
    /// Whether an item may run inline on the reader.
    enum Weight: Sendable, Equatable {
        /// Runs inline on the reader when nothing of the lane is queued or running.
        case light
        /// Always runs on the lane's queue.
        case heavy
    }

    /// Lines up to this size are light unless their kind is bulk (``EventDispatch``); larger ones are heavy.
    static let lightLineLimit = 64 << 10
    /// The reader waits above this many queued line bytes ...
    static let defaultHighWater = 8 << 20
    /// ... until they drain to this many.
    static let defaultLowWater = 2 << 20
    /// A lane item's budget before the hang watch reports it: a 32 MiB replay decodes well within it.
    static let hangDeadline: Duration = .milliseconds(500)

    let highWater: Int
    let lowWater: Int
    private let queue: DispatchQueue
    /// The class a light item queued behind a heavy one runs at (the reader's).
    private let lightQoS: DispatchQoS
    /// Items posted to the queue and not finished: the reader runs a light item inline only at 0.
    private let pending = Atomic<Int>(0)
    /// Line bytes of the items in `pending`.
    private let pendingBytes = Atomic<Int>(0)
    /// The reader waits on `readerWake`; whoever clears this signals it exactly once.
    private let readerParked = Atomic<Bool>(false)
    // concurrency-allow: the lane's bounded backlog: only the connection's dedicated reader thread waits on it, never
    // the main thread or a pool thread, and the lane items that signal it never wait on anything.
    private let readerWake = DispatchSemaphore(value: 0)
    private let hangWatched: HangWatchedLane?
    /// Called before the reader parks above ``highWater`` (tests); must not block.
    private let onReaderBlocked: (@Sendable () -> Void)?

    /// - Parameters:
    ///   - label: the queue's label, which shows in traces and crash reports.
    ///   - qos: the class of heavy items (userInitiated for control decode, utility for bulk and inflate).
    ///   - lightQoS: the class of a light item that has to queue: the reader's.
    ///   - hangs: watches each queued item for ``hangDeadline``; nil watches nothing.
    init(label: String, qos: DispatchQoS, lightQoS: DispatchQoS, hangs: (any HangWatchScoping)? = nil,
         highWater: Int = DecodeLane.defaultHighWater, lowWater: Int = DecodeLane.defaultLowWater,
         onReaderBlocked: (@Sendable () -> Void)? = nil) {
        queue = DispatchQueue(label: label, qos: qos)
        self.lightQoS = lightQoS
        self.highWater = highWater
        self.lowWater = min(lowWater, highWater)
        self.onReaderBlocked = onReaderBlocked
        hangWatched = hangs.map { HangWatchedLane("daemon.decode", deadline: Self.hangDeadline, on: $0) }
    }

    deinit {
        // Every queued item holds the lane, so none runs under the registration after this.
        hangWatched?.unregister()
    }

    /// Reader thread. Runs `work` inline when it is light and nothing of the lane is queued or running, else
    /// queues it behind everything posted before. Never waits: the reader calls ``waitForRoom()`` after the line.
    func post(_ weight: Weight, bytes: Int, _ work: @escaping @Sendable () -> Void) {
        // Acquiring: the effects of every finished item are visible to an inline one.
        if weight == .light, pending.load(ordering: .acquiring) == 0 {
            work()
            return
        }
        pending.add(1, ordering: .relaxed)
        pendingBytes.add(bytes, ordering: .sequentiallyConsistent)
        let run: @Sendable () -> Void = { [self] in
            if let hangWatched { hangWatched.run(work) } else { work() }
            finished(bytes: bytes)
        }
        if weight == .light {
            queue.async(qos: lightQoS, flags: .enforceQoS, execute: run)
        } else {
            queue.async(execute: run)
        }
    }

    /// Items queued or running on the lane (tests, diagnostics).
    var queuedItems: Int { pending.load(ordering: .acquiring) }

    /// True on a connection's reader thread (``markReader()``): bulk work asserts it is not there.
    static var isReaderThread: Bool { Thread.current.threadDictionary[readerKey] != nil }

    /// Marks the calling thread as a connection reader for ``isReaderThread``; the reader calls it once.
    static func markReader() { Thread.current.threadDictionary[readerKey] = true }

    private static let readerKey = "com.cmuxterm.next.daemon.reader"

    private func finished(bytes: Int) {
        let left = pendingBytes.subtract(bytes, ordering: .sequentiallyConsistent).newValue
        // Releasing: an inline item that sees 0 sees this item's effects.
        pending.subtract(1, ordering: .releasing)
        if left <= lowWater, readerParked.exchange(false, ordering: .sequentiallyConsistent) { readerWake.signal() }
    }

    /// Reader thread, after each line and outside its hang scope (a wait for a queue slot is not a hang): parks
    /// while the backlog is above ``highWater``, until it drains to ``lowWater``. Returns at once otherwise.
    func waitForRoom() {
        guard pendingBytes.load(ordering: .sequentiallyConsistent) > highWater else { return }
        onReaderBlocked?()
        readerParked.store(true, ordering: .sequentiallyConsistent)
        // The lane may have drained between the check and the mark: whoever clears the mark signals.
        if pendingBytes.load(ordering: .sequentiallyConsistent) <= lowWater,
           readerParked.exchange(false, ordering: .sequentiallyConsistent) {
            return
        }
        // The designed backpressure: a checked wait, only on the connection's dedicated reader thread; the lane
        // items that end it never wait.
        readerWake.blockingWait()
    }
}

/// How the reader hands one event line to its connection's ``DecodeLane`` (``LineTransport/start(dispatch:onCausedEvent:onClose:)``).
struct EventDispatch: Sendable {
    /// Reader thread: the event's weight, from its name and size only (it must not parse the line).
    var weigh: @Sendable (_ name: String, _ line: Data) -> DecodeLane.Weight
    /// Reader thread, after each line it handled: the backpressure wait of the bounded consumer the handler
    /// feeds (``TerminalEventQueue/waitWhileFull()``, ``DaemonEventRoute/waitWhileReaderParked()``), outside the
    /// line's hang scope. The handler itself never waits.
    var readerWait: (@Sendable () -> Void)?

    init(weigh: @escaping @Sendable (_ name: String, _ line: Data) -> DecodeLane.Weight,
         readerWait: (@Sendable () -> Void)? = nil) {
        self.weigh = weigh
        self.readerWait = readerWait
    }

    /// Every event decodes on the lane's queue: a control connection's events and the other roles'
    /// (control decode on a serial queue, never on the reader).
    static var control: EventDispatch { control(readerWait: nil) }

    /// ``control`` with the reader's wait for the consumer its handler feeds (``DaemonEventRoute/waitWhileReaderParked()``).
    static func control(readerWait: (@Sendable () -> Void)?) -> EventDispatch {
        EventDispatch(weigh: { _, _ in .heavy }, readerWait: readerWait)
    }
}

extension DaemonWireStats.Role {
    /// The class of this connection's decode lane (``DecodeLane``): control decode at user-initiated, where a
    /// person waits for its result; snapshot inflate, replays and journal reads at utility (threading-model.md, the
    /// QoS table). A loopback forward keeps its reader's class: its lines are the page bytes a load waits for.
    var decodeQoS: DispatchQoS {
        switch self {
        case .control, .pageRelay, .agentSessionAttach, .sessionEnding, .shutdown: .userInitiated
        case .loopbackForward: writerQoS
        case .terminalAttach, .journalRead, .socketProbe: .utility
        }
    }
}

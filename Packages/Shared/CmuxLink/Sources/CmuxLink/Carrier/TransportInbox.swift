import os

/// The bounded receive buffer between a carrier's ingress and the one
/// consumer of its `events` (a3-link.md section 8, E1 back-pressure).
///
/// Policy by event kind:
/// - reliable frames are counted against `limits.reliableBytes`. A carrier
///   that can stop reading (a socket) awaits `waitForRoom()` before it reads
///   more; a carrier fed by callbacks bounds its peer with credit granted from
///   `onConsume`, which fires when the consumer takes a frame, not when it
///   arrives. Past `limits.reliableOverflowBytes` `yield` refuses with
///   `.overflow` and the carrier ends the transport: the peer ignored credit.
/// - unreliable and partial frames past `limits.unreliableBytes` are dropped
///   on arrival and counted (`stats.droppedFrames`), like a full datagram socket.
/// - `rtt` and `health` keep only the newest unconsumed sample.
/// - `pathChanged` and `mediaTrack` are rare and queue in order.
/// - `closed` is delivered after everything queued before it and ends the
///   inbox; later events are ignored.
public final class TransportInbox: Sendable {
    public struct Limits: Sendable, Hashable {
        /// Reliable bytes queued before `hasRoom` turns false.
        public var reliableBytes: Int
        /// Reliable bytes queued before `yield` refuses with `.overflow`.
        public var reliableOverflowBytes: Int
        /// Unreliable and partial bytes queued before new ones drop.
        public var unreliableBytes: Int

        public init(reliableBytes: Int = 4 << 20, reliableOverflowBytes: Int = 16 << 20, unreliableBytes: Int = 1 << 20) {
            self.reliableBytes = reliableBytes
            self.reliableOverflowBytes = max(reliableOverflowBytes, reliableBytes)
            self.unreliableBytes = unreliableBytes
        }
    }

    public enum Admission: Sendable, Hashable {
        case accepted
        /// An unreliable frame did not fit and was dropped.
        case dropped
        /// A reliable frame past the hard limit; the carrier must end the transport.
        case overflow
        /// The inbox already ended.
        case finished
    }

    public struct Stats: Sendable, Hashable {
        public var queuedReliableBytes = 0
        public var queuedUnreliableBytes = 0
        /// Highest reliable bytes queued at once.
        public var peakReliableBytes = 0
        public var droppedFrames = 0
        public var droppedBytes = 0
    }

    private struct Entry {
        var event: TransportEvent
        var cost: Int
        var reliableBytes: Int
        var unreliableBytes: Int
    }

    private struct State {
        var entries: [Entry?] = []
        var head = 0
        /// Index of the queued, unconsumed `rtt` and `health` entries.
        var rttIndex: Int?
        var healthIndex: Int?
        var stats = Stats()
        var ended = false
        var waiter: CheckedContinuation<TransportEvent?, Never>?
        var roomWaiters: [CheckedContinuation<Void, Never>] = []
        var onConsume: (@Sendable (TransportFrame, Int) -> Void)?
    }

    public let limits: Limits
    // carve-out: ingress runs on carrier callback threads (libwebrtc) that
    // must not hop to an actor; the lock is never held across a suspension
    // or while calling `onConsume`.
    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    public init(limits: Limits = Limits()) {
        self.limits = limits
    }

    /// Called with each frame and its `yield` cost when the consumer takes
    /// it (credit on consumption). Set once, before frames arrive.
    public func setConsumeHandler(_ handler: @escaping @Sendable (TransportFrame, Int) -> Void) {
        state.withLockUnchecked { $0.onConsume = handler }
    }

    /// The consumer's sequence. One consumer: every iterator reads the same queue.
    public var events: AsyncStream<TransportEvent> {
        AsyncStream(unfolding: { [self] in await next() })
    }

    public var stats: Stats { state.withLockUnchecked { $0.stats } }

    /// Whether reliable ingress may continue without waiting.
    public var hasRoom: Bool {
        state.withLockUnchecked { $0.ended || $0.stats.queuedReliableBytes < limits.reliableBytes }
    }

    public var isFinished: Bool { state.withLockUnchecked { $0.ended } }

    /// Queues one event. `cost` is handed back to `onConsume` (defaults to
    /// the frame size).
    @discardableResult
    public func yield(_ event: TransportEvent, cost: Int? = nil) -> Admission {
        let (admission, handoff) = state.withLockUnchecked { state -> (Admission, (CheckedContinuation<TransportEvent?, Never>, Entry)?) in
            guard !state.ended else { return (.finished, nil) }
            var entry = Entry(event: event, cost: 0, reliableBytes: 0, unreliableBytes: 0)
            switch event {
            case let .frame(frame):
                let size = frame.bytes.count
                entry.cost = cost ?? size
                if frame.lane.reliability.isReliable {
                    guard state.stats.queuedReliableBytes + size <= limits.reliableOverflowBytes else { return (.overflow, nil) }
                    entry.reliableBytes = size
                } else {
                    let queued = state.stats.queuedUnreliableBytes
                    guard queued == 0 || queued + size <= limits.unreliableBytes else {
                        state.stats.droppedFrames += 1
                        state.stats.droppedBytes += size
                        return (.dropped, nil)
                    }
                    entry.unreliableBytes = size
                }
            case .rtt:
                if let index = state.rttIndex {
                    state.entries[index]?.event = event
                    return (.accepted, nil)
                }
            case .health:
                if let index = state.healthIndex {
                    state.entries[index]?.event = event
                    return (.accepted, nil)
                }
            case .closed:
                state.ended = true
            case .pathChanged, .mediaTrack:
                break
            }
            if let waiter = state.waiter {
                state.waiter = nil
                return (.accepted, (waiter, entry))
            }
            state.stats.queuedReliableBytes += entry.reliableBytes
            state.stats.queuedUnreliableBytes += entry.unreliableBytes
            state.stats.peakReliableBytes = max(state.stats.peakReliableBytes, state.stats.queuedReliableBytes)
            switch event {
            case .rtt: state.rttIndex = state.entries.count
            case .health: state.healthIndex = state.entries.count
            default: break
            }
            state.entries.append(entry)
            return (.accepted, nil)
        }
        if let (waiter, entry) = handoff {
            consumed(entry)
            waiter.resume(returning: entry.event)
        }
        if case .closed = event, admission == .accepted { resumeRoomWaiters() }
        return admission
    }

    /// Ends the inbox: the consumer reads what is queued, then the sequence
    /// ends. Producers waiting for room resume.
    public func finish() {
        let waiter = state.withLockUnchecked { state -> CheckedContinuation<TransportEvent?, Never>? in
            state.ended = true
            guard state.head == state.entries.count else { return nil }
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(returning: nil)
        resumeRoomWaiters()
    }

    /// Returns once reliable bytes queued are below `limits.reliableBytes`
    /// or the inbox ended. For producers that can stop reading.
    public func waitForRoom() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ready = state.withLockUnchecked { state -> Bool in
                if state.ended || state.stats.queuedReliableBytes < limits.reliableBytes { return true }
                state.roomWaiters.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }

    /// The next event, waiting while the inbox is empty; nil once it ended
    /// and drained, or when the waiting task is cancelled.
    public func next() async -> TransportEvent? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<TransportEvent?, Never>) in
                let (taken, room) = state.withLockUnchecked { state -> (Entry??, Bool) in
                    if let entry = Self.pop(&state) {
                        return (.some(entry), state.stats.queuedReliableBytes < limits.reliableBytes)
                    }
                    if state.ended || Task.isCancelled { return (.some(nil), false) }
                    state.waiter = continuation
                    return (nil, false)
                }
                guard let taken else { return }
                if let entry = taken { consumed(entry) }
                if room { resumeRoomWaiters() }
                continuation.resume(returning: taken?.event)
            }
        } onCancel: {
            let waiter = state.withLockUnchecked { state -> CheckedContinuation<TransportEvent?, Never>? in
                defer { state.waiter = nil }
                return state.waiter
            }
            waiter?.resume(returning: nil)
        }
    }

    private static func pop(_ state: inout State) -> Entry? {
        guard state.head < state.entries.count, let entry = state.entries[state.head] else { return nil }
        state.entries[state.head] = nil
        if state.rttIndex == state.head { state.rttIndex = nil }
        if state.healthIndex == state.head { state.healthIndex = nil }
        state.head += 1
        state.stats.queuedReliableBytes -= entry.reliableBytes
        state.stats.queuedUnreliableBytes -= entry.unreliableBytes
        if state.head == state.entries.count {
            state.entries.removeAll(keepingCapacity: true)
            state.head = 0
        } else if state.head > 1024, state.head * 2 > state.entries.count {
            state.entries.removeFirst(state.head)
            if let index = state.rttIndex { state.rttIndex = index - state.head }
            if let index = state.healthIndex { state.healthIndex = index - state.head }
            state.head = 0
        }
        return entry
    }

    private func consumed(_ entry: Entry) {
        guard case let .frame(frame) = entry.event,
              let handler = state.withLockUnchecked({ $0.onConsume }) else { return }
        handler(frame, entry.cost)
    }

    private func resumeRoomWaiters() {
        let waiters = state.withLockUnchecked { state -> [CheckedContinuation<Void, Never>] in
            guard state.ended || state.stats.queuedReliableBytes < limits.reliableBytes else { return [] }
            defer { state.roomWaiters = [] }
            return state.roomWaiters
        }
        for waiter in waiters { waiter.resume() }
    }
}

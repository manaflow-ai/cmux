import CmuxNextCompat

/// Items that arrive on any thread, handed to the main actor in one batch per display frame.
/// Chrome's `MainThreadEventQueue` does this for continuous input
/// (third_party/blink/renderer/platform/widget/input/main_thread_event_queue.cc): the IO thread
/// queues each event and asks for a main frame only when none is pending (`SetNeedsMainFrame`),
/// and that frame dispatches everything queued (`DispatchRafAlignedInput`). A flood costs the main
/// thread one post and one delivery per frame, never one per item.
///
/// ``offer(_:)`` never waits for the main thread: it appends under the outbox's lock and asks its
/// ``FrameOutboxWake`` for a flush only when none is pending. ``flush()`` takes every held item, so
/// the next offer asks again: at most one wake is pending at a time, and the app's wake runs each
/// flush on a display frame (``FrameOutboxWake/nextFrame(owner:on:)``).
///
/// Past `limit` held items, or on ``offerGap()``, the outbox drops what it holds and every later
/// item until the flush, and the flush reports a gap: the consumer re-reads instead of applying a
/// frame's worth of changes one at a time (mojo bounds what a receiver leaves unread the same way,
/// `MOJO_QUOTA_TYPE_UNREAD_MESSAGE_COUNT`, mojo/public/cpp/bindings/message_quota_checker.h).
///
/// ```swift
/// let outbox = FrameOutbox<Event>(limit: 256, wake: .nextFrame(owner: "pages.events", on: mainWork)) { events, gap in
///     if gap { listeners.resync() } else { listeners.deliver(events) }
/// }
/// outbox.offer(event) // on the socket reader
/// ```
public final class FrameOutbox<Item: Sendable>: Sendable {
    /// One flush: the items in arrival order, and whether items were dropped before them.
    public typealias Deliver = @MainActor @Sendable (_ items: [Item], _ gap: Bool) -> Void

    private struct State {
        var items: [Item] = []
        var gap = false
        var wakePending = false
        var wakes = 0
    }

    private let state = Mutex(State())
    private let limit: Int
    private let wake: FrameOutboxWake
    private let deliver: Deliver

    /// - Parameters:
    ///   - limit: The most items held for one flush (at least 1); one more makes a gap.
    ///   - wake: Asks for the flush on the main actor.
    ///   - deliver: Takes each flush's items on the main actor.
    public init(limit: Int, wake: FrameOutboxWake, deliver: @escaping Deliver) {
        self.limit = max(1, limit)
        self.wake = wake
        self.deliver = deliver
    }

    /// Holds `item` for the next flush (any thread), asking for one when none is pending.
    public func offer(_ item: Item) {
        let asks = state.withLock { state -> Bool in
            if !state.gap {
                if state.items.count < limit {
                    state.items.append(item)
                } else {
                    state.items.removeAll()
                    state.gap = true
                }
            }
            return Self.armWake(&state)
        }
        if asks { wake.request { [weak self] in self?.flush() } }
    }

    /// Items were lost before this point (a reconnect, a source that overflowed): drops what the
    /// outbox holds and every later item until the flush, which reports the gap.
    public func offerGap() {
        let asks = state.withLock { state -> Bool in
            state.items.removeAll()
            state.gap = true
            return Self.armWake(&state)
        }
        if asks { wake.request { [weak self] in self?.flush() } }
    }

    /// Hands every held item, and the gap if one came, to `deliver`; the next offer asks for a new
    /// flush. The wake calls it; a flush with nothing held delivers nothing.
    @MainActor public func flush() {
        let (items, gap) = state.withLock { state -> ([Item], Bool) in
            var items: [Item] = []
            swap(&items, &state.items)
            let gap = state.gap
            state.gap = false
            state.wakePending = false
            return (items, gap)
        }
        guard gap || !items.isEmpty else { return }
        deliver(items, gap)
    }

    /// Wakes asked for so far: each is one main-thread post (tests and benches).
    public var wakeCount: Int { state.withLock { $0.wakes } }

    /// Items held for the next flush.
    public var heldCount: Int { state.withLock { $0.items.count } }

    /// Whether this offer must ask for a flush: none is pending yet.
    private static func armWake(_ state: inout State) -> Bool {
        guard !state.wakePending else { return false }
        state.wakePending = true
        state.wakes += 1
        return true
    }
}

/// How a ``FrameOutbox`` asks for its flush on the main actor: called from any thread, at most once
/// per flush, with the flush to run.
public struct FrameOutboxWake: Sendable {
    public typealias Flush = @MainActor @Sendable () -> Void

    private let ask: @Sendable (_ flush: @escaping Flush) -> Void

    /// A wake that hands each flush to `ask` (tests drive frames by hand with one).
    public init(_ ask: @escaping @Sendable (_ flush: @escaping Flush) -> Void) {
        self.ask = ask
    }

    /// Asks for one run of `flush` on the main actor.
    public func request(_ flush: @escaping Flush) {
        ask(flush)
    }

    /// The app's wake: one `.visible` post from the offering thread, which queues the flush on a
    /// budgeted `.visible` frame queue of `work`, so the flush runs in the next display frame behind
    /// the person's input and the higher classes, and never twice in one frame.
    ///
    /// - Parameters:
    ///   - owner: Names the post on the board and in the watchdog's records; the frame queue that
    ///     runs the flush is `<owner>.flush` there.
    ///   - work: The app's one main-thread scheduler.
    @MainActor public static func nextFrame(owner: String, on work: MainWorkScheduler) -> FrameOutboxWake {
        let frames = FrameBatchQueue(owner: owner + ".flush", budgeted: .visible, on: work)
        let post = work.board.owner(owner)
        return FrameOutboxWake { [weak work] flush in
            work?.postFromAnyThread(.visible, owner: post) { frames.enqueue(flush) }
        }
    }
}

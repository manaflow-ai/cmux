public import AppKit

/// Keys typed while a window shows its launch picture, the terminal stand-in buffer. A key changes
/// only this buffer in its turn and asks the window to build its focused pane's slice in the next frame
/// (``begin(window:shell:raise:)``); it never builds the window. Two kinds of key wait here:
///
/// - Keys for a focused terminal whose live view is not built (``hold(_:for:)``). When the terminal is live its keys
///   go to it in the order typed, each exactly once, even when focus moved on since (a chord runs its registry
///   action at once, and the keys typed after it go to the new focus's buffer).
/// - Keys typed before the window can decide them: it has no controller yet, or its focus has not resolved
///   (``holdUndecided(_:window:)``). They are sent again through the key router, in order, once ``replay`` can
///   decide them; a later key of the window queues behind them, so none overtakes another.
///
/// A key whose terminal or window never gets there is dropped after ``init(limit:now:deliver:)``'s limit.
///
/// Chrome keeps input for a page that cannot take it yet the same way: `RenderWidgetHostImpl` queues key events in
/// its `InputRouter` until the renderer is ready and delivers them in order
/// (content/browser/renderer_host/input/input_router_impl.cc); none is dropped for a slow first frame.
///
/// ```swift
/// keys.begin(window: "w1", shell: window) { pane in slices.raise(pane) }   // the picture frame (pane nil: not known)
/// keys.holdUndecided(event, window: "w1")                                  // no focus yet
/// keys.hold(event, for: .init(window: "w1", pane: "p", tab: "t"))          // a terminal still a picture
/// keys.retry()                                                             // a focus settle, the pane's first frame
/// keys.end(window: "w1")                                                   // the picture left
/// ```
@MainActor
public final class LaunchPictureKeys {
    /// The terminal a key was typed for.
    public nonisolated struct Target: Hashable, Sendable {
        /// The window's stable id (`WindowState.id`).
        public let window: String
        public let pane: String
        public let tab: String

        public init(window: String, pane: String, tab: String) {
            (self.window, self.pane, self.tab) = (window, pane, tab)
        }
    }

    /// Gives `events` to `target`'s live terminal, in order; false while it has no live view (they stay held).
    public typealias Deliver = @MainActor (_ target: Target, _ events: [NSEvent]) -> Bool
    /// Sends `events`, typed in `window` before it could decide them, through the key router again, in order; false
    /// while the window still cannot decide them (they stay held, ahead of any later key).
    public typealias Replay = @MainActor (_ window: String, _ events: [NSEvent]) -> Bool

    private struct Held {
        var events: [NSEvent]
        let since: ContinuousClock.Instant
    }

    private struct Picture {
        weak var shell: NSWindow?
        let raise: @MainActor (_ pane: String?) -> Void
    }

    /// The windows showing their picture, with the call that raises a pane's build slice to the next frame.
    private var pictures: [String: Picture] = [:] { didSet { noteActivity() } }
    /// Each target's keys in the order typed; targets in the order their first key came.
    private var held: [Target: Held] = [:] { didSet { noteActivity() } }
    private var order: [Target] = []
    /// Each window's keys it could not decide yet, in the order typed; windows in the order their first key came.
    private var undecided: [String: Held] = [:] { didSet { noteActivity() } }
    private var undecidedOrder: [String] = []
    private var raised: Set<Target> = []
    private var raisedWindows: Set<String> = []
    private var wasActive = false
    private let deliver: Deliver
    private let limit: Duration
    private let now: @MainActor () -> ContinuousClock.Instant

    /// Runs with the new value whenever ``isActive`` changes (the key router's mode).
    public var onActiveChange: (@MainActor (Bool) -> Void)?
    /// Decides a window's undecided keys again (the key router); nil keeps them until the limit.
    public var replay: Replay?
    /// Keys dropped because their terminal or window never got there within the limit.
    public private(set) var dropped = 0

    /// - Parameters:
    ///   - limit: How long a key waits; the visible-pane bound of the startup (p08-startup 3A P5).
    ///   - now: The clock's reading (tests pass their own).
    public init(limit: Duration = .seconds(5), now: @escaping @MainActor () -> ContinuousClock.Instant = { .now },
                deliver: @escaping Deliver) {
        (self.limit, self.now, self.deliver) = (limit, now, deliver)
    }

    /// Some window shows its picture or some key waits: the key router asks ``holds(window:)`` per key.
    public var isActive: Bool { !pictures.isEmpty || !held.isEmpty || !undecided.isEmpty }

    /// Whether keys typed in `window` may wait here: it shows its picture, or earlier keys of it still wait.
    public func holds(window: String) -> Bool {
        pictures[window] != nil || undecided[window] != nil || order.contains { $0.window == window }
    }

    /// Whether `window` shows its picture (between ``begin(window:shell:raise:)`` and ``end(window:)``).
    public func showsPicture(window: String) -> Bool { pictures[window] != nil }

    /// The window showing its picture in `shell`, for a key typed there before the window has a controller.
    public func window(showing shell: NSWindow) -> String? {
        pictures.first { $0.value.shell === shell }?.key
    }

    /// Whether keys typed for `target` wait.
    public func isHolding(_ target: Target) -> Bool { held[target] != nil }

    /// Whether keys typed in `window` wait to be decided: a later key of it waits behind them.
    public func isHoldingUndecided(window: String) -> Bool { undecided[window] != nil }

    /// `window` shows its picture in `shell` from now on; `raise` builds a pane's slice in the next frame (nil: the
    /// focused pane, which the window does not know yet).
    public func begin(window: String, shell: NSWindow?, raise: @escaping @MainActor (_ pane: String?) -> Void) {
        pictures[window] = Picture(shell: shell, raise: raise)
    }

    /// `window`'s picture left (every region live, its bound, a resize): its keys go on now, and the ones that still
    /// cannot keep waiting, up to the limit.
    public func end(window: String) {
        pictures[window] = nil
        raisedWindows.remove(window)
        retry()
    }

    /// Holds `event` for `target` and raises that pane's slice to the next frame (once per target). Delivered at
    /// once when the terminal is live already, after the keys typed for it before.
    public func hold(_ event: NSEvent, for target: Target) {
        let at = now()
        if held[target] == nil {
            order.append(target)
            held[target] = Held(events: [event], since: at)
        } else {
            held[target]?.events.append(event)
        }
        if raised.insert(target).inserted { pictures[target.window]?.raise(target.pane) }
        retry(target, at: at)
    }

    /// Holds `event`, typed in `window` before the window could decide it, until ``replay`` can, and raises the
    /// window's focused-pane slice to the next frame (once per window).
    public func holdUndecided(_ event: NSEvent, window: String) {
        if raisedWindows.insert(window).inserted { pictures[window]?.raise(nil) }
        if undecided[window] == nil {
            undecidedOrder.append(window)
            undecided[window] = Held(events: [event], since: now())
        } else {
            undecided[window]?.events.append(event)
        }
    }

    /// Sends every window's undecided keys through the router when it can decide them, then gives every waiting
    /// target its keys when its terminal is live; drops the ones past the limit.
    public func retry() {
        let at = now()
        for window in undecidedOrder { replayUndecided(window, at: at) }
        for target in order { retry(target, at: at) }
    }

    private func replayUndecided(_ window: String, at: ContinuousClock.Instant) {
        guard let waiting = undecided[window] else { return }
        // Out of the queue first: the router decides them as new keys, and a key it holds again goes to its terminal.
        undecided[window] = nil
        undecidedOrder.removeAll { $0 == window }
        if replay?(window, waiting.events) == true { return }
        if waiting.since.duration(to: at) > limit {
            dropped += waiting.events.count
            return
        }
        undecided[window] = waiting
        undecidedOrder.insert(window, at: 0)
    }

    private func retry(_ target: Target, at: ContinuousClock.Instant) {
        guard let waiting = held[target] else { return }
        if deliver(target, waiting.events) {
            forget(target)
        } else if waiting.since.duration(to: at) > limit {
            dropped += waiting.events.count
            forget(target)
        }
    }

    private func forget(_ target: Target) {
        held[target] = nil
        order.removeAll { $0 == target }
        raised.remove(target)
    }

    private func noteActivity() {
        guard isActive != wasActive else { return }
        wasActive = isActive
        onActiveChange?(wasActive)
    }
}

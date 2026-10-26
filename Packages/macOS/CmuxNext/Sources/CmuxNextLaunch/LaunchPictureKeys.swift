public import AppKit

/// Keys typed while a window shows its launch picture (p08-startup-061), for a terminal whose live view is not built
/// yet: the terminal's stand-in buffer. A key changes only this buffer in its turn and asks the window to build that
/// pane's slice in the next frame (``begin(window:raise:)``); it never builds the window. When the terminal is live,
/// its keys go to it in the order typed, each exactly once, even when focus moved on since (a chord runs its
/// registry action at once, and the keys typed after it go to the new focus's buffer).
///
/// Chrome keeps input for a page that cannot take it yet the same way: `RenderWidgetHostImpl` queues key events in
/// its `InputRouter` until the renderer is ready, and its `InputEventAckWaiter` delivers them in order
/// (content/browser/renderer_host/input/input_router_impl.cc); none is dropped for a slow first frame.
///
/// ```swift
/// keys.begin(window: "w1") { pane in slices.raise(pane) }   // the picture frame
/// keys.hold(event, for: .init(window: "w1", pane: "p", tab: "t"))
/// keys.retry()                                              // a focus settle, the pane's first frame
/// keys.end(window: "w1")                                    // the picture left
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

    private struct Held {
        var events: [NSEvent]
        let since: ContinuousClock.Instant
    }

    /// The windows showing their picture, with the call that raises a pane's build slice to the next frame.
    private var raisers: [String: @MainActor (_ pane: String) -> Void] = [:] { didSet { noteActivity() } }
    /// Each target's keys in the order typed; targets in the order their first key came.
    private var held: [Target: Held] = [:] { didSet { noteActivity() } }
    private var order: [Target] = []
    private var raised: Set<Target> = []
    private var wasActive = false
    private let deliver: Deliver
    private let limit: Duration
    private let now: @MainActor () -> ContinuousClock.Instant

    /// Runs with the new value whenever ``isActive`` changes (the key router's mode).
    public var onActiveChange: (@MainActor (Bool) -> Void)?
    /// Keys dropped because their terminal never went live within the limit.
    public private(set) var dropped = 0

    /// - Parameters:
    ///   - limit: How long a key waits for its terminal; the visible-pane bound of the startup (p08-startup 3A P5).
    ///   - now: The clock's reading (tests pass their own).
    public init(limit: Duration = .seconds(5), now: @escaping @MainActor () -> ContinuousClock.Instant = { .now },
                deliver: @escaping Deliver) {
        (self.limit, self.now, self.deliver) = (limit, now, deliver)
    }

    /// Some window shows its picture or some key waits: the key router asks ``holds(window:)`` per key.
    public var isActive: Bool { !raisers.isEmpty || !held.isEmpty }

    /// Whether keys typed in `window` may wait here: it shows its picture, or earlier keys of it still wait.
    public func holds(window: String) -> Bool {
        raisers[window] != nil || order.contains { $0.window == window }
    }

    /// Whether keys typed for `target` wait.
    public func isHolding(_ target: Target) -> Bool { held[target] != nil }

    /// `window` shows its picture from now on; `raise` builds a pane's slice in the next frame.
    public func begin(window: String, raise: @escaping @MainActor (_ pane: String) -> Void) {
        raisers[window] = raise
    }

    /// `window`'s picture left (every region live, its bound, a resize): its keys go to their terminals now, and the
    /// ones whose terminal is still not live keep waiting for it.
    public func end(window: String) {
        raisers[window] = nil
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
        if raised.insert(target).inserted { raisers[target.window]?(target.pane) }
        retry(target, at: at)
    }

    /// Gives every waiting target its keys whose terminal is live now; drops the ones past the limit.
    public func retry() {
        let at = now()
        for target in order { retry(target, at: at) }
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

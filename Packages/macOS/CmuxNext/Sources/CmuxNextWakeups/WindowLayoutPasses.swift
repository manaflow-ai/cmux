public import AppKit

/// A window whose outermost layout passes are told to the views that follow an ancestor's move (the app's
/// shell window).
@MainActor
public protocol WindowLayoutPassHosting: NSWindow {
    /// This window's layout passes.
    var layoutPasses: WindowLayoutPasses { get }
}

/// One window's finished layout passes, told directly to the views that read their place in the window
/// after an ancestor moved them without a layout of their own (a sidebar or divider drag moves a pane's
/// container): a remote page's popup panels, the Home transcript's device-pixel snap. The move happens in the
/// window's layout pass, so they read their place once per pass, never per event (a key typed lays nothing
/// out). Chrome tells a view of a change of its bounds in the root from the ancestor's bounds change
/// (`View::RegisterForVisibleBoundsNotification`, `VisibleBoundsChanged` from `SetBoundsRect`,
/// ui/views/view.cc), not from each event.
///
/// ```swift
/// passWatch = (window as? any WindowLayoutPassHosting)?.layoutPasses.observe(owner: "Popups") { [weak self] in
///     self?.checkPlacement()
/// }
/// ```
@MainActor public final class WindowLayoutPasses {
    private var observers: [UInt64: @MainActor () -> Void] = [:]
    /// Observer ids in the order they started observing (ids grow).
    private var order: [UInt64] = []
    private var nextID: UInt64 = 0

    /// A window's passes with no observer.
    public init() {}

    /// Calls `handler` after each outermost layout pass of the window, until the returned token is
    /// released or cancelled.
    ///
    /// - Parameters:
    ///   - owner: The observer's name for diagnostics.
    ///   - handler: Main-actor work that reads the observer's place in the window.
    /// - Returns: The observation; keep it, releasing it ends it.
    public func observe(owner: String, _ handler: @escaping @MainActor () -> Void) -> Observation {
        nextID &+= 1
        observers[nextID] = handler
        order.append(nextID)
        return Observation(owner: owner, passes: self, id: nextID)
    }

    /// The window's outermost layout pass ended: every view has its final frame. Observers are called in
    /// the order they started observing; one that leaves during the walk is not called.
    public func didLayout() { // perf-hot: 0.05ms drag-frame (one call per window layout pass, O(observers))
        for id in order {
            observers[id]?()
        }
    }

    /// How many observations are live.
    public var observerCount: Int { observers.count }

    fileprivate func remove(_ id: UInt64) {
        guard observers.removeValue(forKey: id) != nil else { return }
        order.removeAll { $0 == id }
    }

    /// One observer of a window's layout passes. Releasing it (or ``cancel()``) ends it.
    @MainActor public final class Observation {
        /// The observer's name for diagnostics.
        public let owner: String
        private weak var passes: WindowLayoutPasses?
        private let id: UInt64

        fileprivate init(owner: String, passes: WindowLayoutPasses, id: UInt64) {
            self.owner = owner
            self.passes = passes
            self.id = id
        }

        /// Ends the observation now: no later call. Idempotent.
        public func cancel() {
            passes?.remove(id)
            passes = nil
        }

        deinit {
            guard let passes else { return }
            let id = self.id
            // main-hop-allow: a deinit may run off main; inline on main, the hop only removes this subscriber
            MainDelivery().run { passes.remove(id) }
        }
    }
}

public import Foundation
public import AppKit

/// Owns main-window identity and the close-broadcast subscription that drives
/// per-window teardown.
///
/// This is the app delegate's window-lifecycle layer, lifted out of the `@main`
/// app target so window identity stops living as loose stored properties on the
/// delegate. It holds the irreducible window-identity plumbing: the
/// ``WindowManaging`` coordinator (window↔id identity and the single
/// window-closed stream), the reverse index from a per-window object's
/// `ObjectIdentifier` to its ``WindowID``, the set of window ids whose
/// closed-window history is suppressed, and the cascade anchor for placing new
/// windows. The actual teardown each close triggers stays app-side behind the
/// ``WindowLifecycleHosting`` seam.
///
/// Not `@Observable`: every member is lifecycle plumbing (a task handle, a
/// reverse index, an `NSPoint` cascade anchor, the window-identity coordinator
/// handle), none of it view state.
///
/// `@MainActor` because every mutator and the close subscription originate on
/// the main thread from AppKit callbacks, so the state lives where its callers
/// live and no bridging is needed (mirrors ``WindowCoordinator``'s isolation
/// ruling).
@MainActor
public final class WindowLifecycleCoordinator<Host: WindowLifecycleHosting> {
    /// App-side teardown + god-type-leaf seam, held weakly so the app delegate ↔
    /// coordinator ownership stays one-directional (the app delegate owns this
    /// coordinator strongly). Generic over the concrete host so the resolver and
    /// removal methods can speak the host's app-target value types
    /// (`RegisteredMainWindow`, `TabManager`, `MainWindowFocusController`) through
    /// its associated types, which a package type cannot name directly.
    public weak var host: Host?

    /// Owns window identity and lifecycle: the live ``WindowID`` set, the
    /// `NSWindow` handle per window, and the single window-closed broadcast.
    /// Constructed once at the composition root and held as `any WindowManaging`;
    /// `windowClosed` is consumed by ``observeWindowCoordinatorClosures()`` to
    /// drive the app-side `unregisterMainWindow` teardown.
    public let windowCoordinator: any WindowManaging

    /// The single subscription task draining ``WindowManaging/windowClosed``.
    /// Internal to this coordinator: started once by
    /// ``observeWindowCoordinatorClosures()`` and never resubscribed.
    private var windowCoordinatorClosureTask: Task<Void, Never>?

    /// Reverse index from a per-window object's `ObjectIdentifier` (e.g. a tab
    /// manager handle) to its ``WindowID``. `ObjectIdentifier` is type-erased, so
    /// this index names no domain type. Kept in sync by its owner whenever a
    /// window's object is (re)bound and torn down alongside the window's slice.
    public var tabManagerWindowIds: [ObjectIdentifier: WindowID] = [:]

    /// Window ids whose closed-window undo history is suppressed for the next
    /// close (set when a window is closed/discarded without recording history,
    /// consumed on the matching teardown).
    public var closedWindowHistorySuppressedWindowIds: Set<UUID> = []

    /// Tracks the cascade point for new windows, matching Ghostty's upstream
    /// algorithm. Reset to `.zero` so the first window seeds the point from its
    /// own position.
    public var lastCascadePoint: NSPoint = .zero

    /// Creates the window-lifecycle coordinator. The app target constructs
    /// exactly one at the composition root and injects itself as `host`.
    public init(
        windowCoordinator: any WindowManaging = WindowCoordinator(),
        host: Host? = nil
    ) {
        self.windowCoordinator = windowCoordinator
        self.host = host
    }

    /// Subscribes once to the window coordinator's close broadcast and drives the
    /// host's `unregisterMainWindow` for each closing window. This replaces the
    /// per-window `WindowCloseObserver` that called `unregisterMainWindow`
    /// directly from `NSWindow.willCloseNotification`.
    ///
    /// Behavior delta (faithful-lift discipline): the legacy observer ran
    /// `unregisterMainWindow` synchronously inside `willClose`; the coordinator's
    /// `AsyncStream` defers it by one main-actor turn. The closing window is
    /// resolved through `windowCoordinator.window(for:)`, which pins it strongly
    /// from `willClose` until this consumer calls `unregister` (see
    /// `WindowCoordinator.handleClose(of:)`). The pin is load-bearing: a
    /// `CmuxMainWindow` uses the stock `isReleasedWhenClosed = true` and its sole
    /// strong owner drops synchronously in `willClose`, so without it the
    /// autorelease pool could drain the window before this turn and the whole
    /// teardown (geometry persist, history, active repoint, snapshot save,
    /// palette removal, notification clearing) would be silently dropped.
    /// Resolving through the coordinator (not a weak `window`) is therefore
    /// guaranteed non-nil; the only observable difference is that those effects
    /// land one turn later, unread synchronously then.
    public func observeWindowCoordinatorClosures() {
        guard windowCoordinatorClosureTask == nil else { return }
        let closedEvents = windowCoordinator.windowClosed
        windowCoordinatorClosureTask = Task { @MainActor [weak self] in
            for await closedId in closedEvents {
                guard let self else { return }
                // Resolve the closing window from the coordinator's strong pin
                // (held across the one-turn defer), not a weak `window`, so
                // teardown cannot be dropped by autorelease timing.
                guard let window = self.windowCoordinator.window(for: closedId) else { continue }
                self.host?.unregisterMainWindow(window)
            }
        }
    }

    /// The ``WindowID`` bound to `object`'s identity, if any.
    public func windowId(forObject object: ObjectIdentifier) -> WindowID? {
        tabManagerWindowIds[object]
    }

    /// Binds `object`'s identity to `id` in the reverse index.
    public func bindWindowId(_ id: WindowID, forObject object: ObjectIdentifier) {
        tabManagerWindowIds[object] = id
    }

    /// Drops `object`'s entry from the reverse index, returning the prior
    /// ``WindowID`` if one was bound.
    @discardableResult
    public func unbindWindowId(forObject object: ObjectIdentifier) -> WindowID? {
        tabManagerWindowIds.removeValue(forKey: object)
    }

    /// Marks `windowId`'s closed-window history as suppressed for its next close.
    public func insertSuppressedWindowId(_ windowId: UUID) {
        closedWindowHistorySuppressedWindowIds.insert(windowId)
    }

    /// Clears `windowId`'s suppression, returning whether it was suppressed.
    @discardableResult
    public func removeSuppressedWindowId(_ windowId: UUID) -> Bool {
        closedWindowHistorySuppressedWindowIds.remove(windowId) != nil
    }

    /// Whether `windowId`'s closed-window history is currently suppressed.
    public func containsSuppressedWindowId(_ windowId: UUID) -> Bool {
        closedWindowHistorySuppressedWindowIds.contains(windowId)
    }

    // MARK: - Registry resolvers

    /// The resolved registered window for `id`, or `nil` if none is registered.
    /// Funnels through ``WindowLifecycleHosting/resolveRegisteredWindow(for:)``,
    /// which reads the app-side per-domain stores and resolves the live
    /// `NSWindow`. Every other resolver routes here.
    public func registeredWindow(for id: WindowID) -> Host.RegisteredWindow? {
        host?.resolveRegisteredWindow(for: id)
    }

    /// Every registered main window as a resolved value, in no guaranteed order
    /// (faithfully matching the old dictionary iteration, which was likewise
    /// unordered).
    public var registeredWindows: [Host.RegisteredWindow] {
        guard let host else { return [] }
        return host.registeredWindowIds.compactMap { host.resolveRegisteredWindow(for: $0) }
    }

    /// The resolved registered window owning the tab manager identified by
    /// `object`, via the ``tabManagerWindowIds`` reverse index this coordinator
    /// owns.
    public func registeredWindow(forManagerObject object: ObjectIdentifier) -> Host.RegisteredWindow? {
        guard let id = tabManagerWindowIds[object] else { return nil }
        return host?.resolveRegisteredWindow(for: id)
    }

    /// The resolved registered window for the NSWindow `window`, by window-object
    /// identity. The ``WindowManaging`` coordinator owns window↔id identity (first
    /// clause); a resolved value's window is compared for the
    /// late-bound-identifier fallback.
    public func registeredWindow(forWindow window: NSWindow) -> Host.RegisteredWindow? {
        if let id = windowCoordinator.id(for: window),
           let context = host?.resolveRegisteredWindow(for: id) {
            return context
        }
        guard let host else { return nil }
        return registeredWindows.first(where: { host.window(of: $0) === window })
    }

    // MARK: - Registry binding + removal funnel

    /// Binds `tabManager` to `id` in the app-side tab-manager store and keeps the
    /// ``tabManagerWindowIds`` reverse index consistent: drops any stale entry for
    /// a manager previously bound to `id`, then records the new mapping. The store
    /// write + stale-object detection is the host's
    /// ``WindowLifecycleHosting/rebindTabManagerSlice(_:for:)``; the reverse-index
    /// mutations stay here.
    public func rebindTabManager(_ tabManager: Host.WindowTabManagerModel, for id: WindowID) {
        if let staleObject = host?.rebindTabManagerSlice(tabManager, for: id) {
            tabManagerWindowIds.removeValue(forKey: staleObject)
        }
        tabManagerWindowIds[ObjectIdentifier(tabManager)] = id
    }

    /// Drops every per-window slice for `id` across the app-side domain stores
    /// plus this coordinator's reverse index. The single removal funnel for both
    /// window teardown paths (the AppKit close path and the explicit/windowless
    /// path). The app-side store drops happen behind
    /// ``WindowLifecycleHosting/removeWindowModelSlices(for:)``; the reverse-index
    /// drop, keyed by the removed manager's `ObjectIdentifier`, stays here.
    @discardableResult
    public func removeWindowSlices(
        for id: WindowID
    ) -> (tabManager: Host.WindowTabManagerModel, focusController: Host.WindowFocusModel?)? {
        guard let removed = host?.removeWindowModelSlices(for: id) else { return nil }
        tabManagerWindowIds.removeValue(forKey: ObjectIdentifier(removed.tabManager))
        return removed
    }
}

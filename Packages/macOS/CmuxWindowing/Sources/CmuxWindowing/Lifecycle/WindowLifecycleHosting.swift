public import AppKit

/// App-target seam for the window-teardown effect and the god-type leaf reads
/// the ``WindowLifecycleCoordinator`` orchestrates but cannot own.
///
/// The coordinator owns window identity and the close-broadcast subscription
/// (`windowCoordinator` plus its single-consumer closure task) and the
/// `tabManager`-object → ``WindowID`` reverse index. The registry resolver and
/// removal funnel it now drives still reach into per-domain stores keyed by
/// `WindowID` that hold app-target model types (`TabManager`,
/// `MainWindowFocusController`) and assemble an app-target resolved-window value
/// (`RegisteredMainWindow`). Those types are declared in the executable app
/// target, so a package type cannot name them; the host exposes them through
/// these associated types and the seam methods below. The app delegate conforms
/// and injects itself as the host so the resolver/removal orchestration lives in
/// this package while the typed-store reads/writes stay where their state lives.
///
/// `AnyObject` + held `weak` by the coordinator so the app delegate ↔ coordinator
/// reference is one-directional in ownership: the app delegate owns the
/// coordinator strongly; the coordinator weak-refs back, so there is no retain
/// cycle (mirrors the notification-nav seam adapter pattern).
@MainActor
public protocol WindowLifecycleHosting: AnyObject {
    /// The app-target resolved-window value the resolver methods build on demand
    /// from the per-domain stores (`AppDelegate.RegisteredMainWindow`). Owns no
    /// state; rebuilt each lookup.
    associatedtype RegisteredWindow

    /// The app-target per-window tab-manager model (`TabManager`). Class-bound so
    /// the coordinator can key its reverse index by `ObjectIdentifier` and compare
    /// instances with `!==` during a rebind.
    associatedtype WindowTabManagerModel: AnyObject

    /// The app-target per-window keyboard-focus model (`MainWindowFocusController`),
    /// returned alongside the tab manager when a window's slices are dropped.
    associatedtype WindowFocusModel

    /// Runs the full teardown for a closing main `window`: cascade-point reset,
    /// closed-window history, geometry persist, context unregistration, palette
    /// and notification cleanup, and active-window repoint. Driven once per
    /// window from the coordinator's close-broadcast subscription.
    func unregisterMainWindow(_ window: NSWindow)

    /// Assembles the resolved registered-window value for `id` by reading the
    /// app-side per-domain stores (tab manager + focus controller) and resolving
    /// the live `NSWindow`, or `nil` if no window is registered under `id`. The
    /// single god-type leaf the coordinator's resolvers funnel through.
    func resolveRegisteredWindow(for id: WindowID) -> RegisteredWindow?

    /// The `WindowID`s currently registered, in no guaranteed order (the
    /// tab-manager store's id set). Backs the coordinator's `registeredWindows`
    /// enumeration.
    var registeredWindowIds: [WindowID] { get }

    /// The live `NSWindow` bound to `registeredWindow`, for the
    /// late-bound-identifier fallback in
    /// ``WindowLifecycleCoordinator/registeredWindow(forWindow:)``.
    func window(of registeredWindow: RegisteredWindow) -> NSWindow?

    /// Binds `tabManager` to `id` in the app-side tab-manager store, returning the
    /// `ObjectIdentifier` of the manager previously bound to `id` when it differs
    /// from `tabManager` (so the coordinator can drop that stale reverse-index
    /// entry), or `nil` when there was no distinct prior manager.
    func rebindTabManagerSlice(_ tabManager: WindowTabManagerModel, for id: WindowID) -> ObjectIdentifier?

    /// Drops every per-window slice for `id` across the app-side domain stores
    /// (tab manager, focus controller, config, sidebar selection, sidebar,
    /// file explorer), returning the removed tab manager and focus controller, or
    /// `nil` if nothing was registered under `id`. The coordinator drops the
    /// matching reverse-index entry around this call.
    func removeWindowModelSlices(for id: WindowID) -> (tabManager: WindowTabManagerModel, focusController: WindowFocusModel?)?
}

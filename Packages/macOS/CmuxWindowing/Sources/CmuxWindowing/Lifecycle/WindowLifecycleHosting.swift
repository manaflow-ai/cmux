public import AppKit
public import Foundation

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

    /// The app-target bundle of per-window UI-state slices a window-registration
    /// carries (`AppDelegate.MainWindowRegistrationSlices`: sidebar, sidebar
    /// selection, optional file explorer, optional cmux-config store). These are
    /// app-declared `@MainActor` model types a package type cannot name, so the
    /// coordinator forwards this value opaquely from the registration entrypoint
    /// into the seed/rebind callbacks; only the host unpacks its fields.
    associatedtype RegistrationSlices

    /// Drops any recoverable-route ledger entry for `windowId` at the start of a
    /// registration (the route is being claimed by a live window). The ledger is
    /// app-side state.
    func forgetRecoverableMainWindowRoute(windowId: UUID)

    /// Whether a tab-manager slice is currently registered under `id` (the
    /// app-side `windowTabManagers` membership check the coordinator branches on
    /// to decide rebind-vs-seed).
    func isMainWindowRegistered(_ id: WindowID) -> Bool

    /// The live `NSWindow` the app last bound to `windowId`, resolved through the
    /// app-side window-identity fallback, or `nil`. Backs the coordinator's
    /// duplicate-window check.
    func windowForMainWindowId(_ windowId: UUID) -> NSWindow?

    /// Reconciles the existing live window registered under `existingId` when a
    /// `duplicate` window arrives for the same id (re-points the existing tab
    /// manager + focus controller at `existingWindow`, emits the duplicate-ignored
    /// debug log). The coordinator orders the duplicate `window`'s `orderOut`/`close`
    /// after this returns.
    func handleDuplicateMainWindowRegistration(
        windowId: UUID,
        existingId: WindowID,
        existingWindow: NSWindow,
        duplicate: NSWindow
    )

    /// Re-points the per-window slices for an already-registered `resolvedId` at
    /// `window`/`tabManager` (tab-manager window/id, optional file-explorer +
    /// config-store seeding, focus-controller update). The coordinator owns the
    /// reverse-index rebind and the `windowCoordinator.register` identity write
    /// around this call.
    func rebindRegisteredWindowSlices(
        window: NSWindow,
        resolvedId: WindowID,
        tabManager: WindowTabManagerModel,
        slices: RegistrationSlices
    )

    /// Seeds every per-window slice for a brand-new window `newId` (tab-manager
    /// window/id, a freshly constructed focus controller, sidebar / sidebar
    /// selection / optional file-explorer / optional config-store stores). The
    /// coordinator owns the reverse-index rebind and the identity write around
    /// this call.
    func seedNewMainWindowSlices(
        window: NSWindow,
        windowId: UUID,
        newId: WindowID,
        tabManager: WindowTabManagerModel,
        slices: RegistrationSlices
    )

    /// Registers `windowId` with the app-side command-palette presentation
    /// coordinator.
    func commandPaletteRegisterWindow(_ windowId: UUID)

    /// Ensures the per-tab-manager socket listener exists when socket control is
    /// enabled, tagged with `source` for debug tracing.
    func ensureSocketListener(for tabManager: WindowTabManagerModel, source: String)

    /// Ensures a mobile workspace-list observer exists for `tabManager` (the
    /// app-side `mobileWorkspaceListObservers` index).
    func ensureMobileWorkspaceListObserver(for tabManager: WindowTabManagerModel)

    /// Posts the app-side `mainWindowContextsDidChange` notification after the
    /// registry mutates.
    func notifyMainWindowContextsDidChange()

    /// Makes `window` the active main window (active-tab-manager repoint + key
    /// focus). Called only when the freshly registered `window` is already key.
    func setActiveMainWindow(_ window: NSWindow)

    /// Applies the one-shot startup session restore if it has not run yet,
    /// returning whether a restore was applied this call.
    func attemptStartupSessionRestore(primaryWindow: NSWindow) -> Bool

    /// Whether a session snapshot should be written immediately after this
    /// registration (the app-side persistence policy reading `isTerminatingApp`
    /// / `isApplyingSessionRestore` alongside `didApplyStartupSessionRestore`).
    func shouldSaveSnapshotAfterMainWindowRegistration(didApplyStartupSessionRestore: Bool) -> Bool

    /// Writes the post-registration session snapshot (no scrollback).
    func saveSessionSnapshotAfterMainWindowRegistration()

    #if DEBUG
    /// The currently active tab manager, captured before a registration mutates
    /// the registry so the post-registration debug log can report the prior
    /// active manager. DEBUG-only, matching the app's debug logging.
    var activeTabManagerForRegistrationDebug: WindowTabManagerModel? { get }

    /// Emits the `mainWindow.register` debug log after the registry mutates,
    /// given the registered `window`/`tabManager` and the `priorActiveTabManager`
    /// captured before the mutation. DEBUG-only.
    func logMainWindowRegistered(
        windowId: UUID,
        window: NSWindow,
        tabManager: WindowTabManagerModel,
        priorActiveTabManager: WindowTabManagerModel?
    )

    /// Seeds every per-window slice for the DEBUG-only testing registration of
    /// `testId` (no live `NSWindow`): tab-manager id, a window-less focus
    /// controller, and the sidebar / sidebar selection / optional file-explorer /
    /// optional config-store stores. DEBUG-only test scaffold.
    func seedTestingMainWindowSlices(
        windowId: UUID,
        testId: WindowID,
        tabManager: WindowTabManagerModel,
        slices: RegistrationSlices
    )
    #endif

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

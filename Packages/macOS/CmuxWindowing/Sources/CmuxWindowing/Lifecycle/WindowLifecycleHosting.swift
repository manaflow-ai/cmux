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

    // MARK: - Teardown + active-repoint seam

    /// Whether `window` is one of the app's main terminal windows (the
    /// ``WindowManaging`` identity check plus the `cmux.main` identifier prefix).
    /// The leaf gate for ``WindowLifecycleCoordinator/contextForMainTerminalWindow(_:reindex:)``.
    func isMainTerminalWindow(_ window: NSWindow) -> Bool

    /// The window id carried by `registeredWindow` (`RegisteredMainWindow.windowId`).
    /// Lets the coordinator key slice/identity removal and palette/lifecycle calls
    /// by the resolved context's id without naming the app value type's field.
    func windowId(of registeredWindow: RegisteredWindow) -> UUID

    /// Records a recoverable route for `context` (window id + tab manager +
    /// optional window) into the app-side ledger before its slices are dropped,
    /// so a later re-open can reclaim the route.
    func rememberRecoverableMainWindowRoute(for context: RegisteredWindow)

    /// Drops `context`'s tab manager from the app-side mobile workspace-list
    /// observer index when no remaining window references it.
    func removeMobileWorkspaceListObserver(forClosing context: RegisteredWindow)

    /// Removes `windowId` from the app-side command-palette presentation
    /// coordinator (the teardown counterpart of `commandPaletteRegisterWindow`).
    func commandPaletteRemoveWindow(_ windowId: UUID)

    /// Clears every notification owned by `context`'s window id and tab manager
    /// tabs once the window is gone, so stale notifications can't reopen a dead
    /// window.
    func clearNotifications(forClosing context: RegisteredWindow)

    /// Whether `context`'s tab manager is the app's current active tab manager,
    /// gating whether teardown must repoint the active window.
    func activeTabManagerMatches(_ context: RegisteredWindow) -> Bool

    /// Repoints the app's active-window pointers (tab manager + sidebar / sidebar
    /// selection / file-explorer slices + terminal-control active manager) at
    /// `context`, or clears them when `context` is `nil`. The active-pointer
    /// god-type writes stay app-side.
    func repointActiveMainWindow(to context: RegisteredWindow?)

    /// Makes `context` the active main window for a key `window`: captures the
    /// before-state debug token, repoints the active pointers, and emits the
    /// `mainWindow.active` debug log (the debug ordering stays app-side).
    func setActiveMainWindowContext(_ context: RegisteredWindow, keyWindow window: NSWindow)

    /// Pushes a closed-window undo-history entry for `context` unless suppressed,
    /// terminating, or applying a session restore (the app-side history policy +
    /// snapshot capture).
    func recordClosedWindowHistoryIfNeeded(for context: RegisteredWindow)

    /// Whether closing `context` would remove only crash-diagnostic session state.
    /// The app-side witness owns the snapshot inspection policy.
    func closingWindowIsCrashDiagnostic(_ context: RegisteredWindow) -> Bool

    /// Persists `window`'s geometry as a placement fallback for the next window,
    /// skipped while the app is terminating (the `!isTerminatingApp` guard stays
    /// app-side).
    func persistWindowGeometryOnClose(from window: NSWindow)

    /// Notifies the app-side main-window visibility controller that `window` has
    /// closed so it can drop any cached visibility state.
    func discardClosedWindow(_ window: NSWindow)

    /// Publishes the `window.closed` cmux lifecycle event for `windowId` with the
    /// `appkit_close` origin.
    func publishMainWindowClosed(windowId: UUID)

    /// Saves a post-unregister session snapshot (no scrollback) when the app-side
    /// persistence policy allows it (skipped during termination, which already
    /// persisted a full snapshot).
    func saveSessionSnapshotOnWindowUnregisterIfNeeded(
        removeWhenEmpty: Bool,
        preserveManualRestoreBackupOnMissingPrimary: Bool
    )

    /// The key window used to prefer the next active context during teardown (the
    /// app-side shortcut-routing key window).
    var shortcutRoutingKeyWindow: NSWindow? { get }

    /// Whether the app is currently terminating, gating the should-close warning.
    var isTerminatingApp: Bool { get }

    /// Routes the quit-shortcut warning when a should-close is blocked on the last
    /// remaining main window (the app-side warning presentation).
    func handleMainTerminalWindowQuitWarning()

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

    // MARK: - Focus + close decision seam

    /// Focuses `window` for an explicit focus request, returning whether the
    /// app-side visibility controller actually brought it forward (the
    /// `.focusMainWindow` reason). The live `NSWindow` focus stays app-side.
    func focusMainWindowForFocusRequest(_ window: NSWindow) -> Bool

    /// Publishes the `window.focused` cmux lifecycle event for `windowId` with the
    /// `focus_request` origin, after a focus request actually took.
    func publishMainWindowFocused(windowId: UUID)

    /// Sends `window` the standard AppKit close (`performClose`), which routes
    /// through the should-close gate. The live `NSWindow` close stays app-side.
    func performMainWindowClose(_ window: NSWindow)

    /// Closes `window` immediately (`close`), bypassing the should-close gate, for
    /// the discard-without-history path. The live `NSWindow` close stays app-side.
    func closeMainWindowImmediately(_ window: NSWindow)

    /// Presents the close-window confirmation alert for `window` and returns
    /// whether the user confirmed the close. The live `NSAlert` plus its
    /// localized strings stay app-side (with the DEBUG confirmation-handler hook).
    func confirmCloseMainWindow(_ window: NSWindow) -> Bool
}

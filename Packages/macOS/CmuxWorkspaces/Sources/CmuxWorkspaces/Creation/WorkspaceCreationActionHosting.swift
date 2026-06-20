public import Foundation
public import CmuxWindowing
public import CmuxSettings

/// The app-side seam ``WorkspaceCreationActionCoordinator`` drives for the
/// **new-workspace / new-browser / cloud-VM action routing** it cannot own from
/// the package: every reach into the cross-window `MainWindowContext` aggregate,
/// the per-window config store (`resolvedNewWorkspaceAction` / workspace-group
/// config), the configured-`cmux`-action executor, the remote-tmux controller,
/// the `CloudVMActionLauncher`, and the window-selection / window-creation
/// primitives. `AppDelegate` is the single conformer.
///
/// **What stays in the coordinator vs. inverts here.** The coordinator owns the
/// *routing decision logic* — the initial-surface branching, the no-main-window
/// fallback, the gate ordering between the remote-tmux short-circuit, the
/// configured-new-workspace override, the in-group create, the preferred-tab
/// path, and the new-window fallback, plus the close-initial-workspace
/// condition and the in-group async-join wiring. Those are pure sequencing over
/// opaque ``CmuxWindowing/WindowID`` window tokens and `Sendable` values, so
/// they live in the package. Every concrete app effect (resolving a context,
/// reading the selected workspace, adding a workspace, executing a configured
/// action, focusing a browser address bar, launching a cloud VM) inverts
/// through one method here. The **order** in which the coordinator interleaves
/// these effects is the observable behavior and is lifted byte-for-byte from the
/// legacy `AppDelegate` action bodies.
///
/// **Opaque selection token.** The legacy entrypoints take per-call app inputs
/// (`TabManager?`, `NSEvent?`, `NSWindow?`) that cannot cross the module
/// boundary. The app captures them into an opaque ``SelectionContext`` the host alone
/// interprets; the coordinator threads it through the resolution calls without
/// inspecting it, so the app types stay app-side while the routing sequence is
/// owned in one place.
///
/// **Why synchronous and `@MainActor`.** Every effect is one main-actor turn
/// driven by a `performNewWorkspaceAction` / `performCloudVMAction` call over the
/// main-actor `MainWindowContext`/`TabManager` graph; co-locating on the main
/// actor removes any bridging (mirrors the sibling workspace coordinators'
/// isolation ruling).
@MainActor
public protocol WorkspaceCreationActionHosting: AnyObject {
    /// The opaque per-call selection carrier (the app's
    /// `(preferredTabManager, event, preferredWindow)` tuple). The coordinator
    /// never inspects it; only the host produces and reads it.
    associatedtype SelectionContext

    // MARK: Window-context resolution

    /// The live preferred window token for the call's ``SelectionContext`` preferred
    /// `TabManager`, discarding an orphaned context, or `nil` when there is no
    /// (live) preferred manager (legacy `livePreferredContext` computation).
    func livePreferredWindowToken(for selector: SelectionContext) -> WindowID?

    /// Whether no main windows currently exist (legacy
    /// `mainWindowContexts.isEmpty`).
    var hasNoMainWindows: Bool { get }

    /// The preferred main-window token for a new-workspace creation, selecting
    /// the active/event/fallback context (legacy
    /// `preferredMainWindowContextForWorkspaceCreation(event:debugSource:)`),
    /// or `nil` when no context can be chosen.
    func preferredWindowTokenForCreation(
        selector: SelectionContext,
        debugSource: String
    ) -> WindowID?

    /// The window token whose `TabManager` matches the call's preferred manager,
    /// else the token for the preferred `NSWindow`, else the creation-preferred
    /// token (legacy `performCloudVMAction` context resolution).
    func windowTokenForCloudVM(
        selector: SelectionContext,
        debugSource: String
    ) -> WindowID?

    // MARK: Window creation / new-window fallback

    /// Creates a fresh main window and returns its token (legacy
    /// `createMainWindow()`).
    func createMainWindowToken() -> WindowID

    /// Opens a new main window with no preferred anchor (legacy
    /// `openNewMainWindow(nil)`).
    func openNewMainWindow()

    /// Emits the DEBUG `fallback_new_window` routing breadcrumb for `reason`
    /// (legacy `logWorkspaceCreationRouting(phase:"fallback_new_window", ...)`).
    /// A no-op in release.
    func logFallbackNewWindow(selector: SelectionContext, source: String, reason: String)

    // MARK: Workspace reads / creation over a window token

    /// The selected workspace id in `windowToken`'s `TabManager` (legacy
    /// `context.tabManager.selectedWorkspace?.id`).
    func selectedWorkspaceId(in windowToken: WindowID) -> UUID?

    /// Adds a workspace of `initialSurface` to `windowToken`'s `TabManager`,
    /// returning its id and whether it is a browser-initial workspace whose
    /// address bar must be focused (legacy `context.tabManager.addWorkspace(...)`).
    func addWorkspace(in windowToken: WindowID, initialSurface: NewWorkspaceInitialSurface) -> UUID?

    /// Whether the call carries a preferred `TabManager` (legacy `if let
    /// preferredTabManager`).
    func hasPreferredTabManager(selector: SelectionContext) -> Bool

    /// Whether the call's preferred `TabManager` is not tracked as a
    /// main-window context (legacy `preferredContext == nil`, where
    /// `preferredContext = preferredTabManager.flatMap { mainWindowContext(for:) }`).
    /// `false` when there is no preferred manager.
    func preferredTabManagerHasNoMainWindowContext(selector: SelectionContext) -> Bool

    /// Adds a workspace of `initialSurface` to the call's preferred `TabManager`
    /// (legacy `preferredTabManager.addWorkspace(initialSurface:)`).
    func addWorkspaceToPreferredTabManager(
        selector: SelectionContext,
        initialSurface: NewWorkspaceInitialSurface
    ) -> UUID?

    /// Creates a workspace inside `target`'s group in `windowToken`'s
    /// `TabManager`, returning its id or `nil` on failure (legacy
    /// `context.tabManager.createWorkspaceInGroup(...)`).
    func createWorkspaceInGroup(
        in windowToken: WindowID,
        target: WorkspaceGroupNewWorkspaceTarget,
        initialSurface: NewWorkspaceInitialSurface
    ) -> UUID?

    /// Adds a workspace through the preferred main window, returning its id and
    /// whether it must focus the browser address bar, or `nil` when creation
    /// failed (legacy `addWorkspaceInPreferredMainWindow(...)`).
    func addWorkspaceInPreferredMainWindow(
        selector: SelectionContext,
        initialSurface: NewWorkspaceInitialSurface,
        debugSource: String
    ) -> UUID?

    /// Focuses the address bar of the freshly-created browser-initial workspace
    /// `workspaceId` (legacy `focusInitialBrowserAddressBar(in:)`). A no-op when
    /// the workspace has no browser panel.
    func focusInitialBrowserAddressBar(workspaceId: UUID)

    /// The number of workspaces ("tabs") in `windowToken`'s `TabManager` (legacy
    /// `context.tabManager.tabs.count`).
    func workspaceCount(in windowToken: WindowID) -> Int

    /// Whether a workspace with `workspaceId` exists in `windowToken`'s
    /// `TabManager` (legacy `context.tabManager.tabs.first(where:) != nil`).
    func containsWorkspace(_ workspaceId: UUID, in windowToken: WindowID) -> Bool

    /// Closes the workspace `workspaceId` in `windowToken` without recording
    /// close history (legacy `context.tabManager.closeWorkspace(_, recordHistory:
    /// false)`). The coordinator owns the gating condition; this performs only
    /// the close.
    func closeWorkspace(_ workspaceId: UUID, in windowToken: WindowID)

    // MARK: Remote tmux / browser availability

    /// Whether a dedicated remote-tmux window handled the new-workspace request
    /// by creating a remote session instead (legacy
    /// `remoteTmuxController.handleRemoteWindowNewWorkspaceRequested(windowId:)`).
    func handleRemoteWindowNewWorkspaceRequested(in windowToken: WindowID) -> Bool

    /// Whether the in-app browser is enabled (legacy
    /// `BrowserAvailabilitySettings.isEnabled()`).
    var isBrowserEnabled: Bool { get }

    /// Beeps for the cloud-VM no-context path (legacy `NSSound.beep()`).
    func beep()

    /// Emits the DEBUG `blocked_browser_disabled` breadcrumb then beeps for the
    /// browser-disabled new-browser path (legacy `cmuxDebugLog(...)` +
    /// `NSSound.beep()`). The breadcrumb is a no-op in release.
    func beepBrowserDisabled(source: String)

    // MARK: Configured-action override + group target

    /// The selected workspace's group membership in `windowToken`, when it is
    /// grouped: the selected workspace id, its group id, and the group's anchor
    /// workspace cwd (legacy `workspaceGroupNewWorkspaceTarget(in:)` group lookup
    /// over `selectedTabId` / `workspaceGroups` / the anchor workspace's
    /// `currentDirectory`). `nil` when the selected workspace is not grouped or
    /// its group is gone. The coordinator resolves the placement from this.
    func selectedWorkspaceGroupMembership(
        in windowToken: WindowID
    ) -> WorkspaceGroupMembership?

    /// The configured new-workspace placement for `windowToken`'s group anchored
    /// at `anchorCwd`, or `nil` when unconfigured (legacy
    /// `windowConfigStores.model(for:)?.resolveWorkspaceGroupConfig(forCwd:)?.newWorkspacePlacement`).
    func configuredWorkspaceGroupNewPlacement(
        in windowToken: WindowID,
        anchorCwd: String?
    ) -> WorkspaceGroupNewPlacement?

    /// The stored default in-group new-workspace placement setting (legacy
    /// `UserDefaultsSettingsClient(defaults: .standard).value(for:
    /// SettingCatalog().workspaceGroups.newWorkspacePlacement)`).
    var defaultWorkspaceGroupNewPlacement: WorkspaceGroupNewPlacement { get }

    /// Executes the window's configured new-workspace action when one is set,
    /// returning whether it ran (legacy
    /// `executeConfiguredNewWorkspaceActionIfAvailable(...)`). The whole
    /// configured-action machinery (config-store read, `executeConfiguredCmuxAction`,
    /// the in-group async-join observer, the close-initial callback) is
    /// irreducibly app-coupled, so it inverts as one call; the coordinator only
    /// decides whether to attempt it and on which window/target.
    func executeConfiguredNewWorkspaceActionIfAvailable(
        in windowToken: WindowID,
        debugSource: String,
        replacingInitialWorkspaceId: UUID?,
        target: WorkspaceGroupNewWorkspaceTarget?
    ) -> Bool

    // MARK: Cloud VM

    /// Launches `cmux vm new` against the active socket for `windowToken`,
    /// returning whether the launch started; `onCompletion` reports the launch
    /// result (legacy `CloudVMActionLauncher.shared.start(...)`).
    func startCloudVM(
        in windowToken: WindowID,
        selector: SelectionContext,
        onCompletion: ((CloudVMActionCompletion) -> Void)?
    ) -> Bool
}

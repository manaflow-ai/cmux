import AppKit
import CmuxFoundation
import CmuxTerminalCore
import SwiftUI
import Foundation
import Observation
import Bonsplit
import CmuxBrowser
import CmuxCommandPalette
import CmuxGit
import CmuxNotifications
import CmuxPanes
import CmuxSettings
import CmuxSidebar
import CmuxSidebarGit
import CmuxTestSupport
import CmuxWorkspaces
import CoreVideo
import Combine
import CoreServices
import Darwin
import OSLog
import CmuxTerminal

// MARK: - Tab Type Alias for Backwards Compatibility
// The old Tab class is replaced by Workspace
typealias Tab = Workspace

private let tabManagerLogger = Logger(subsystem: "com.cmuxterm.app", category: "TabManager")

// The DEBUG-only vsync IOSurface timeline capture seam (CVDisplayLink lifecycle,
// NSLock-guarded in-flight coordination, C trampoline) lives in
// CmuxTestSupport's VsyncIOSurfaceTimelineCapture, beside the pure
// VsyncIOSurfaceTimelineAnalyzer. The app maps each GhosttySurfaceScrollView
// DebugFrameSample to a VsyncFrameSample at the call site in
// captureVsyncIOSurfaceTimeline so the package owns no app type.

// WorkspaceGroup, WorkspaceReorderPlanItem, WorkspaceBatchReorderError, and
// the pure batch-reorder planning live in CmuxWorkspaces.

@MainActor
@Observable
class TabManager {
    /// The window that owns this TabManager. Set by AppDelegate.registerMainWindow().
    /// Used to apply title updates to the correct window instead of NSApp.keyWindow.
    weak var window: NSWindow?
    /// Stable identifier of the owning macOS window. Used only for opt-in title
    /// templates that expose a WM-matchable per-window token.
    var windowId: UUID?
    /// Weak reach path back to process-lifetime services while call sites migrate
    /// away from `AppDelegate.shared`.
    private(set) weak var appEnvironment: AppEnvironment?

    /// Attaches the composition-root environment. Nil reads through this
    /// property preserve the optional short-circuit shape of `AppDelegate.shared?`.
    func attachAppEnvironment(_ environment: AppEnvironment) {
        appEnvironment = environment
    }

    // Wave-4 sub-model (TabManager decomposition): the workspace list, the
    // sidebar group sections, and the selected-workspace id storage live in
    // WorkspacesModel (CmuxWorkspaces). TabManager stays the per-window
    // composition point: it owns the model, forwards the legacy accessors
    // below, and implements WorkspacesHosting (bottom of this file) for the
    // selection side effects (willSet DEBUG switch tracing + didSet selection
    // chain). TabManager is now `@Observable`, so SwiftUI observers track this
    // model directly through the forwarders; the legacy `objectWillChange`-
    // re-emission willSet hooks and the CurrentValueSubject bridges were retired.
    let workspaces = WorkspacesModel<Workspace>()

    /// Window-title + per-surface shell-activity reads/mutations over the
    /// workspace list (CmuxWorkspaces). The PR-refresh half of
    /// `updateSurfaceShellActivity` stays in this composition root because it
    /// routes through `pullRequestProbing`, which CmuxWorkspaces does not import.
    @ObservationIgnored
    private(set) lazy var surfaceMetadata = SurfaceMetadataCoordinator(model: workspaces)

    var tabs: [Workspace] {
        get { workspaces.tabs }
        set { workspaces.tabs = newValue }
    }
    /// Named groupings of workspaces shown as collapsible sections in the sidebar.
    /// Group order in this array defines section order in the sidebar.
    /// Each member workspace stores its `groupId` on the `Workspace` model.
    var workspaceGroups: [WorkspaceGroup] {
        get { workspaces.workspaceGroups }
        set { workspaces.workspaceGroups = newValue }
    }

    /// Set by `restoreSessionSnapshot` to suppress side-effects (like auto-
    /// expanding a group on focus) that would mutate restored state mid-restore.
    private var isRestoringSessionSnapshot: Bool = false
    /// The snapshot decoded from disk for the in-progress restore. The
    /// `SessionSnapshotRestoreCoordinator` owns the ordering and calls back through
    /// `SessionSnapshotRestoreHosting` for the god-coupled steps; the
    /// `buildRestoredWorkspaces()` witness reads this to construct the workspaces.
    /// Set for the duration of one synchronous restore turn and cleared in the
    /// same turn. Lives in the class body (not the session-persistence extension)
    /// because extensions cannot hold stored properties.
    private var pendingSessionRestoreSnapshot: SessionTabManagerSnapshot?
    /// Background-workspace-load + cycle-hot bookkeeping (CmuxWorkspaces). The
    /// `@Observable` sub-model is the single observation source of truth: app
    /// observers (ContentView, the background-prime coordinator) track these via
    /// Observation instead of the retired `@Published` Combine bridges. The
    /// `private(set)` external contract is preserved because TabManager exposes
    /// read-only forwarders and is the only writer.
    let backgroundWorkspaceLoad = BackgroundWorkspaceLoadModel()
    var isWorkspaceCycleHot: Bool {
        get { backgroundWorkspaceLoad.isWorkspaceCycleHot }
        set { backgroundWorkspaceLoad.isWorkspaceCycleHot = newValue }
    }
    var pendingBackgroundWorkspaceLoadIds: Set<UUID> {
        backgroundWorkspaceLoad.pendingBackgroundWorkspaceLoadIds
    }
    var mountedBackgroundWorkspaceLoadIds: Set<UUID> {
        backgroundWorkspaceLoad.mountedBackgroundWorkspaceLoadIds
    }
    var debugPinnedWorkspaceLoadIds: Set<UUID> {
        backgroundWorkspaceLoad.debugPinnedWorkspaceLoadIds
    }

    /// Monotonic allocator for CMUX_PORT ordinal assignment, shared across every
    /// window's `TabManager` so port ranges don't overlap (each window has its
    /// own `TabManager`). Injected, with the process-wide shared default at the
    /// composition point (see `sharedPortOrdinalAllocator` / `init`).
    let portOrdinalAllocator: WorkspacePortOrdinalAllocator
    /// Recently-closed-item history store (workspaces, panels, windows), owned by
    /// the composition root (`AppDelegate.closedItemHistory`) and injected here so
    /// this per-window `TabManager` no longer reaches the transitional
    /// `ClosedItemHistoryStore.shared` global. `AppDelegate` passes its single
    /// instance at construction; the SwiftUI-App and test construction paths fall
    /// back to the transitional `.shared` default, which resolves to that same
    /// composition-root instance. `@ObservationIgnored`: an injected collaborator,
    /// not observable UI state of this model.
    @ObservationIgnored
    let closedItemHistory: ClosedItemHistoryStore
    var selectedTabId: UUID? {
        get { workspaces.selectedTabId }
        set { workspaces.selectedTabId = newValue }
    }

    // MARK: - WorkspacesHosting hooks (DEBUG switch tracing + selection effects)

    /// Legacy `@Published selectedTabId` willSet; reads the old `selectedTabId`
    /// before storage changes. `TabManager` is now `@Observable`, so SwiftUI
    /// observers track the `workspaces` sub-model directly; the only surviving
    /// work here is the DEBUG workspace-switch tracing.
    func selectedWorkspaceIdWillChange(to newValue: UUID?) {
#if DEBUG
        workspaceSwitchDebug.noteSelectedWorkspaceWillChange(
            to: newValue,
            currentSelected: selectedTabId,
            isCycleHot: isWorkspaceCycleHot,
            tabCount: tabs.count
        )
#endif
    }

    /// Legacy `@Published selectedTabId` didSet: forwards to the selection
    /// side-effect chain, now owned by `WorkspaceSelectionSideEffectsCoordinator`
    /// (CmuxWorkspaces). The app-coupled effects invert back through this window
    /// via `WorkspaceSelectionSideEffectsHosting`.
    func selectedWorkspaceIdDidChange(from oldValue: UUID?) {
        selectionSideEffects.selectedWorkspaceIdDidChange(from: oldValue)
    }

    // MARK: - WorkspaceSelectionSideEffectsHosting witnesses

    /// The notification-dismissal context taken synchronously during a selection
    /// change and applied in the deferred turn. Stashed app-side because
    /// `NotificationDismissalContext` is owned by a sibling package and never
    /// crosses into CmuxWorkspaces. Transient deferred-turn bookkeeping, so
    /// `@ObservationIgnored`.
    @ObservationIgnored
    private var pendingDeferredSelectionDismissalContext: NotificationDismissalContext = .activeFocus

    var isSelectionSideEffectsRestoring: Bool { isRestoringSessionSnapshot }

    func recordWorkspaceSwitchBreadcrumb(tabCount: Int) {
        sentryBreadcrumb("workspace.switch", data: [
            "tabCount": tabCount
        ])
    }

    func publishWorkspaceSelectedChange(fromPreviousWorkspaceId previousWorkspaceId: UUID?) {
        publishCmuxWorkspaceSelectedChange(from: previousWorkspaceId)
    }

    func takePendingNotificationDismissalContextForDeferredSideEffects() {
        pendingDeferredSelectionDismissalContext = notificationDismissal.takePendingSelectionContext() ?? .activeFocus
    }

    func scheduleDeferredSelectionSideEffects(generation: UInt64, previousWorkspaceId: UUID?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.selectionSideEffects.runDeferredSelectionSideEffects(
                generation: generation,
                previousWorkspaceId: previousWorkspaceId
            )
        }
    }

    func applyDeferredSelectionAppEffects() {
        updateWindowTitleForSelectedTab()
        if let selectedTabId {
            dismissFocusedPanelNotificationIfActive(
                tabId: selectedTabId,
                context: pendingDeferredSelectionDismissalContext
            )
        }
    }

    func debugLogSelectionDidChange(
        fromPreviousWorkspaceId previousWorkspaceId: UUID?,
        toSelectedWorkspaceId selectedWorkspaceId: UUID?
    ) {
#if DEBUG
        workspaceSwitchDebug.logSelectionDidChange(from: previousWorkspaceId, to: selectedWorkspaceId)
#endif
    }

    func debugLogSelectionSideEffectsDone() {
#if DEBUG
        workspaceSwitchDebug.logSelectionSideEffectsDone(selected: selectedTabId)
#endif
    }
    // Typed NotificationCenter subscriptions, each owning its observer token and
    // unregistering it in its own (nonisolated) deinit when this TabManager
    // deallocates. `@ObservationIgnored` (bookkeeping, not observable UI state).
    // Built in `init` after the first `addWorkspace`, matching the legacy
    // inline-observer registration site/order; their decode + `queue: .main` +
    // `MainActor.assumeIsolated` synchronous delivery preserves the original
    // emission timing.
    @ObservationIgnored
    private var ghosttyTitleSubscription: GhosttyTitleChangeSubscription?
    @ObservationIgnored
    private var ghosttyFocusSurfaceSubscription: GhosttyFocusSurfaceSubscription?
    @ObservationIgnored
    private var workspaceCurrentDirectorySubscription: WorkspaceCurrentDirectorySubscription?
    @ObservationIgnored
    private var userDefaultsChangeSubscription: UserDefaultsChangeSubscription?
    /// Per-window focused-surface bookkeeping (remembered focused panel per
    /// workspace) + the deferred previous-workspace unfocus state machine
    /// (CmuxWorkspaces). TabManager hosts its seam
    /// (`TabManager+FocusedSurfaceHosting`) and forwards the legacy entry
    /// points below.
    let focusedSurface = FocusedSurfaceModel()
    /// Pure panel/surface id resolution over `workspaces` (CmuxWorkspaces); the
    /// `focusedPanelId(for:)` / `panelId(forSurfaceOrPanelId:…)` entry points
    /// forward here. Built in `init` (depends on `workspaces`).
    let panelIdResolver: PanelIdResolver<Workspace>
    // Wave-3 sub-models (TabManager decomposition): TabManager is the
    // per-window composition point. It owns the concrete sub-models, hosts
    // their seams, and forwards its legacy entry points.
    /// Per-panel notification-dismissal flow (CmuxNotifications).
    let notificationDismissal: any NotificationDismissing = NotificationDismissalModel()
    /// Recently-closed browser panel history (CmuxBrowser).
    let browserModel = BrowserModel<ClosedBrowserPanelRestoreSnapshot>()
    /// Focused-browser/markdown command surface: zoom, focus mode, developer
    /// tools, and the omnibar toggle, routed to the focused panel (CmuxBrowser).
    /// `lazy` so the resolver closures can read this window's focus state
    /// (`focusedBrowserPanel`/`focusedMarkdownPanel`); both close over `self`
    /// weakly and run on the MainActor where TabManager lives.
    @ObservationIgnored
    private(set) lazy var focusedBrowserController = FocusedBrowserController(
        resolveFocusedBrowser: { [weak self] in self?.focusedBrowserPanel },
        resolveFocusedMarkdown: { [weak self] in self?.focusedMarkdownPanel }
    )
    /// Focused-terminal command surface: find/search, keyboard copy-mode, the
    /// Ctrl-F force-stop chord, the text-box input toggle/focus/attach, the
    /// keep-scrollback clear, and the text-box hide-escape arm, routed to the
    /// focused terminal panel with the find commands falling back to the focused
    /// browser panel (CmuxTerminal). `lazy` so the resolver closures can read
    /// this window's focus state; all three close over `self` weakly and run on
    /// the MainActor where TabManager lives. Mirrors `focusedBrowserController`.
    @ObservationIgnored
    private(set) lazy var focusedTerminalCommands = FocusedTerminalCommandCoordinator(
        resolveFocusedTerminal: { [weak self] in self?.selectedTerminalPanel },
        resolveFocusedBrowser: { [weak self] in self?.focusedBrowserPanel },
        resolveWorkspaceTerminals: { [weak self] in self?.selectedWorkspaceTerminalPanels ?? [] }
    )
    /// Browser-panel open/split/surface creation orchestration (CmuxBrowser):
    /// the workspace resolution, select-if-not-selected step, split-right
    /// reuse/split-source policy, and default focused-or-first-pane open path.
    /// TabManager hosts its seam (TabManager+BrowserOpenHosting) — supplying the
    /// target workspace handle, the selection flow with its app-side
    /// notification-store dismissal, the focus memory, and the browser-enabled
    /// gate — and forwards the legacy `openBrowser`/`newBrowserSplit`/
    /// `newBrowserSurface` entry points.
    let browserOpen = BrowserOpenCoordinator()
    /// Reopen-most-recently-closed-browser-panel orchestration (CmuxBrowser):
    /// the Cmd+Shift+T legacy-stack drain, origin-workspace resolution +
    /// select-if-not-selected, the bonsplit placement walk (through the
    /// workspace handle), and the two-runloop-turn focus re-assertion. TabManager
    /// hosts its seam (TabManager+ClosedBrowserPanelReopenHosting) — supplying the
    /// target workspace handle, the selection flow with its app-side
    /// notification-store dismissal, the focus memory, the pre-reopen focused-panel
    /// read, and the browser-enabled gate — and each `Workspace` conforms to
    /// ``ClosedBrowserPanelReopenWorkspaceHandle``. The recently-closed stack is
    /// the per-window ``browserModel`` injected at construction.
    @ObservationIgnored
    private(set) lazy var browserReopen = ClosedBrowserPanelReopenCoordinator(
        browserModel: browserModel
    )
    /// Surface-navigation, terminal-split-creation, and split-operation
    /// orchestration (CmuxPanes). Owns the `selectedWorkspace`/`tabs.first(where:)`
    /// resolution + the focused-panel/panel-existence guards + the
    /// `clearSplitZoom`/`newTerminalSplit` creation sequence the legacy
    /// `TabManager` surface/split entry points inlined; this window conforms to
    /// ``SurfaceSplitHosting`` (workspace resolution + the app-side Sentry
    /// breadcrumb and notification-store clear) and each `Workspace` conforms to
    /// ``SurfaceSplitWorkspaceHandle``.
    let surfaceSplit = SurfaceSplitCoordinator()
    /// React Grab toggle resolution + orchestration (CmuxBrowser). Stateless;
    /// each call passes the target workspace as a `ReactGrabWorkspaceContext`.
    let reactGrabController = ReactGrabController()
    /// Sidebar multi-selection state + sync events (CmuxSidebar).
    let sidebarMultiSelection = SidebarMultiSelectionModel()
    /// Typed synchronous settings access (CmuxSettings).
    private let settings: any SettingsWriting
    private let settingsCatalog = SettingCatalog()

    /// Monotonic focus-history revision counter. Its only observation channel is
    /// the `.tabManagerFocusHistoryRevisionDidChange` notification posted from
    /// `didSet` (no SwiftUI body or `$`-subscriber ever read it), so it carries
    /// no `@Published`/Combine machinery; the NotificationCenter post is the
    /// faithful, unchanged observation seam.
    private(set) var focusHistoryRevision: UInt64 = 0 {
        didSet {
            guard focusHistoryRevision != oldValue else { return }
            NotificationCenter.default.post(name: .tabManagerFocusHistoryRevisionDidChange, object: self)
        }
    }
    // The focus-history back/forward stack lives in FocusHistoryModel
    // (CmuxWorkspaceNavigation); this window is its host via
    // FocusHistoryHosting and republishes its revision bumps through
    // `focusHistoryRevision` above.
    let focusHistoryNavigation: any FocusHistoryNavigating = FocusHistoryModel()
    // Stateless split-geometry application (equalize/resize divider moves);
    // the pure planning lives in CmuxPanes' ExternalTreeNode extensions.
    let paneLayout = PaneLayoutService()
    // Pure workspace-group snapshot math for session persistence
    // (CmuxWorkspaces): assemble persisted group snapshots at save and rebuild
    // groups at restore. The app shell gathers live state and applies results.
    let sessionSnapshotGroups = SessionSnapshotGroupCoordinator()
    // Pure value-assembly of a window's tab-manager session snapshot
    // (CmuxWorkspaces): the restorable filter+cap, selected-index lookup,
    // per-group restorable-member map, and group-snapshot orchestration. The
    // app shell flattens each workspace into a value input and supplies the
    // per-workspace snapshot closure so the live `Workspace` read stays here.
    let sessionSnapshotBuilder = SessionSnapshotBuilder()
    // Pure planner for the closed-panel-history workspace-id remaps a restore
    // requires (CmuxWorkspaces); the app shell applies each op to the closed-
    // item history store and flushes once.
    let closedPanelHistoryRemapPlanner = ClosedPanelHistoryRemapPlanner()
    /// Owns this window's recently-closed reopen routing (CmuxWorkspaces): the
    /// `AppDelegate.shared` delegation guard, the per-entry routing table, the
    /// reopen-by-id remove → restore → re-insert bookkeeping, and the panel
    /// restore's focus-history suppression ordering. This `TabManager` is its
    /// ``ClosedPanelRestoreHosting`` witness (TabManager+ClosedItemReopenRouting):
    /// the store mutations, live `Workspace` lookup/restore, selection, and the
    /// still-app-side `restoreClosedWorkspace` invert back through it.
    @ObservationIgnored
    private(set) lazy var closedItemReopenRouting = ClosedItemReopenRouting(host: self)
    // Owns the whole-window session-snapshot restore ordering (CmuxWorkspaces):
    // reset → off-publish build → resolve selection/groups → atomic @Published
    // commit → prune/release/schedule/remap/post. Shares the same group-snapshot
    // and history-remap collaborators so save and restore stay one source of
    // truth; this TabManager is its SessionSnapshotRestoreHosting witness.
    @ObservationIgnored
    lazy var sessionSnapshotRestore = SessionSnapshotRestoreCoordinator<Workspace>(
        groupCoordinator: sessionSnapshotGroups,
        remapPlanner: closedPanelHistoryRemapPlanner
    )
    // Reorder/pin flows over the workspaces model (CmuxWorkspaces); owns
    // the pure batch-reorder planner.
    let workspaceReordering: WorkspaceReorderCoordinator<Workspace>
    // Workspace-command menu logic (selected-workspace index math, move/close
    // tab-list slicing, per-item enablement) over the workspaces model
    // (CmuxWorkspaces); the irreducible app-coupled effects (pin toggle,
    // NSAlert close confirmation, cross-window move, notification mark
    // read/unread, palette rename/edit) invert through WorkspaceCommandHosting
    // (this file's class body). The cmuxApp @CommandsBuilder menu shell drives
    // it through `menuState()` + the action methods.
    let workspaceCommands: WorkspaceCommandCoordinator<Workspace>
    // Workspace-group lifecycle flows over the workspaces model
    // (CmuxWorkspaces); creation/teardown/selection invert through
    // WorkspaceGroupHosting.
    let workspaceGrouping: WorkspaceGroupCoordinator<Workspace>
    // Pure close-planning over the workspaces model (CmuxWorkspaces): ordered
    // closable/sidebar-selected workspaces and the WorkspaceClosePlan
    // (title/message/acceptCmdD). The NSAlert presentation + Workspace/window
    // teardown stay here, inverted through the CloseConfirming conformance
    // (localized strings + confirmClose), now owned by
    // `closeConfirmationPresenter`.
    let workspaceClosing: WorkspaceCloseCoordinator<Workspace>
    // The app-side CloseConfirming witness: localized confirmation strings +
    // NSAlert presentation via the shared `runCmuxModalAlert`. Held strongly
    // (the coordinator's `confirming` ref is weak) and attached to the
    // coordinator in init; its preferred host window is wired from `window`.
    let closeConfirmationPresenter = WorkspaceCloseConfirmationPresenter()
    /// Close-confirmation forwarders matching main's TabManager API (used by the
    /// Dock split-store). Our refactor moved the state into `workspaceClosing`.
    var isCloseConfirmationInFlight: Bool { workspaceClosing.isCloseConfirmationInFlight }
    func confirmClose(title: String, message: String, acceptCmdD: Bool) -> Bool {
        workspaceClosing.confirmClose(title: title, message: message, acceptCmdD: acceptCmdD)
    }
    // Pure new-workspace insertion planning over the workspaces model
    // (CmuxWorkspaces): the pre-creation snapshot, its live-order remap, and the
    // placement-driven insertion index. The creation orchestration (Workspace
    // boot, chrome inheritance, port ordinal, lifecycle publish, selection/focus,
    // welcome send) is irreducibly app-coupled and stays in this file, calling
    // these computations.
    let workspaceCreating: WorkspaceCreationCoordinator<Workspace>
    // Pure config-inheritance decisions for a new workspace (candidate panel
    // ordering + first-live selection, and the positive-guard font inheritance).
    // The forwarders below flatten the live source `Workspace` into the
    // resolver's `Sendable` value inputs through the
    // `WorkspaceCreationInheritanceReading` seam.
    private let workspaceCreationInheritanceResolver = WorkspaceCreationInheritanceResolver()
    // Selection-navigation flows over the workspaces model + background-load
    // model (CmuxWorkspaces): the next/prev wrap-around order math, select-by-
    // index, select-last, and the cycle-hot window state machine (generation +
    // cooldown task + isWorkspaceCycleHot). The irreducible app-coupled effects
    // (the private selectWorkspaceId mutation chain, the sidebar multi-selection
    // collapse, and DEBUG switch tracing) invert through
    // WorkspaceSelectionHosting (TabManager+WorkspaceSelectionHosting.swift).
    let workspaceSelection: WorkspaceSelectionCoordinator<Workspace>
    // Selection side-effect chain over the workspaces / focused-surface /
    // focus-history models (CmuxWorkspaces): the group auto-expand, the
    // previous/next focus-history record ordering, and the generation-guarded
    // deferred turn that focuses the selected panel, updates the window title,
    // and dismisses the focused-panel notification. The app-coupled effects
    // (Sentry breadcrumb, the Workspace-god focused-panel read, the
    // CmuxWorkspaceSelected publish, the cross-package notification-dismissal
    // context, DEBUG switch tracing, and the DispatchQueue.main.async hop)
    // invert through WorkspaceSelectionSideEffectsHosting (witnesses below).
    let selectionSideEffects: WorkspaceSelectionSideEffectsCoordinator<Workspace>
    var sidebarSelectedWorkspaceIds: Set<UUID> { sidebarMultiSelection.selectedWorkspaceIds }
    private var currentWindowTabBarLeadingInset: CGFloat?
    /// Periodic agent-PID liveness sweep (extracted to CmuxWorkspaces).
    /// TabManager constructs the service, implements
    /// `AgentPIDLivenessSweepHosting` (see
    /// `TabManager+AgentPIDLivenessSweepHosting.swift`) to supply the
    /// per-workspace agent-PID snapshot and apply the stale clears, and starts
    /// it in `init`. The service self-cancels via its `[weak self]` periodic
    /// task when this TabManager deallocates.
    private let agentPIDLivenessSweep = AgentPIDLivenessSweepService()
#if DEBUG
    /// Per-window DEBUG workspace-switch instrumentation (switch timer/counter
    /// state machine + the byte-identical `ws.switch.*`/`ws.hot.*`/`ws.select.*`
    /// /`ws.unfocus.*`/`ws.handoff.*`/`workspace.title.enqueue` trace builders),
    /// relocated to `CmuxWorkspaces`. The `debug*`/`log*` hooks below forward
    /// here; live per-window reads (`isWorkspaceCycleHot`, `tabs.count`,
    /// `selectedTabId`, the from/to ids) are passed in.
    private let workspaceSwitchDebug = WorkspaceSwitchDebugTracker()
#endif

#if DEBUG
    private var didSetupUITestSplitScaffolds = false
    private var uiTestCancellables = Set<AnyCancellable>()
    /// `@Observable` workspace-list watches for the DEBUG UI-test close
    /// scaffold, replacing the retired `tabsPublisher` Combine bridge. Held
    /// alongside `uiTestCancellables` and torn down with it.
    private var uiTestWorkspacesObservations: [WorkspacesObservation] = []
    /// The workspace pinned by the child-exit scaffolds for their lifetime,
    /// matching the legacy bodies' `let tab = selectedWorkspace` strong capture
    /// (which stayed valid after the workspace left the open list). Set by
    /// `pinSelectedWorkspace()` and read by every `ChildExitScaffoldDriving`
    /// member so panel counts reflect the captured workspace, not a fresh
    /// `selectedWorkspace` lookup.
    private var childExitScaffoldPinnedWorkspace: Workspace?
#endif

    // Process-wide cap on concurrent sidebar git snapshot probes, shared by
    // every window's SidebarGitMetadataService. A static (not a per-instance
    // default) on purpose: the cap is per process, not per window, matching
    // the legacy shared limiter; tests inject their own instance.
    private static let sharedWorkspaceGitProbeLimiter = WorkspaceGitMetadataProbeLimiter(limit: 2)

    // Process-wide CMUX_PORT ordinal allocator, shared by every window's
    // TabManager so port ranges never overlap. A static (not a per-instance
    // default) on purpose: the counter is per process, not per window, matching
    // the legacy `static var nextPortOrdinal`; tests inject their own instance.
    @MainActor private static let sharedPortOrdinalAllocator = WorkspacePortOrdinalAllocator()

    // The sidebar git/PR subsystem (extracted to CmuxSidebarGit). TabManager
    // is the per-window composition point: it constructs the concrete
    // services, stores only the seams, implements SidebarGitHosting
    // (see TabManager+SidebarGitHosting.swift), and forwards its legacy
    // entry points.
    let sidebarGitMetadataService: any SidebarGitMetadataServing
    let pullRequestProbing: any PullRequestProbing

    init(
        initialWorkspaceTitle: String? = nil,
        initialWorkingDirectory: String? = nil,
        initialTerminalInput: String? = nil,
        autoWelcomeIfNeeded: Bool = true,
        commandRunner: any CommandRunning = CommandRunner(),
        gitMetadataService: GitMetadataService = GitMetadataService(),
        workspaceGitMetadataReader: (any WorkspaceGitMetadataReading)? = nil,
        gitPollClock: any GitPollClock = SystemGitPollClock(),
        gitProbeLimiter: WorkspaceGitMetadataProbeLimiter? = nil,
        portOrdinalAllocator: WorkspacePortOrdinalAllocator? = nil,
        settings: any SettingsWriting = UserDefaultsSettingsClient(defaults: .standard),
        closedItemHistory: ClosedItemHistoryStore? = nil
    ) {
        self.settings = settings
        self.closedItemHistory = closedItemHistory ?? .shared
        self.portOrdinalAllocator = portOrdinalAllocator ?? Self.sharedPortOrdinalAllocator
        workspaceReordering = WorkspaceReorderCoordinator(model: workspaces)
        workspaceCommands = WorkspaceCommandCoordinator(model: workspaces, reordering: workspaceReordering)
        workspaceGrouping = WorkspaceGroupCoordinator(model: workspaces)
        workspaceClosing = WorkspaceCloseCoordinator(
            model: workspaces,
            settings: settings,
            catalog: settingsCatalog
        )
#if DEBUG
        let workspaceCreationDebugLog: @Sendable (String) -> Void = { cmuxDebugLog($0) }
#else
        let workspaceCreationDebugLog: @Sendable (String) -> Void = { _ in }
#endif
        workspaceCreating = WorkspaceCreationCoordinator(
            model: workspaces,
            settings: settings,
            catalog: settingsCatalog,
            debugLog: workspaceCreationDebugLog
        )
        workspaceSelection = WorkspaceSelectionCoordinator(
            model: workspaces,
            backgroundLoad: backgroundWorkspaceLoad
        )
        selectionSideEffects = WorkspaceSelectionSideEffectsCoordinator(
            model: workspaces,
            focusedSurface: focusedSurface,
            focusHistory: focusHistoryNavigation
        )
        panelIdResolver = PanelIdResolver(model: workspaces)
#if DEBUG
        let sidebarGitDebugLog: @Sendable (String) -> Void = { cmuxDebugLog($0) }
#else
        let sidebarGitDebugLog: @Sendable (String) -> Void = { _ in }
#endif
        let pullRequestProbeService = PullRequestProbeService(
            commandRunner: commandRunner,
            debugLog: sidebarGitDebugLog
        )
        let pullRequestPollService = PullRequestPollService(
            gitMetadataService: gitMetadataService,
            probeService: pullRequestProbeService,
            clock: gitPollClock,
            debugLog: sidebarGitDebugLog
        )
        self.pullRequestProbing = pullRequestPollService
        self.sidebarGitMetadataService = SidebarGitMetadataService(
            workspaceGitMetadataReader: workspaceGitMetadataReader ?? gitMetadataService,
            gitMetadataService: gitMetadataService,
            pullRequestProbing: pullRequestPollService,
            probeLimiter: gitProbeLimiter ?? Self.sharedWorkspaceGitProbeLimiter,
            clock: gitPollClock,
            debugLog: sidebarGitDebugLog
        )
        // Wire the host seam before the first workspace is added so the
        // initial git probe scheduling (addWorkspace below) reaches the
        // services, matching the legacy in-class scheduling timing.
        pullRequestProbing.attach(host: self)
        sidebarGitMetadataService.attach(host: self)
        notificationDismissal.attach(host: self)
        focusHistoryNavigation.attach(host: self)
        focusedSurface.attach(host: self)
        browserOpen.attach(host: self)
        browserReopen.attach(host: self)
        surfaceSplit.attach(host: self)
        surfaceMetadata.attach(titleHost: self)
        // Workspace-list/group/selection storage (CmuxWorkspaces). Attached
        // before the first addWorkspace so the property-observer hooks fire
        // from the very first insertion, matching the legacy @Published
        // observer timing.
        workspaces.attach(host: self)
        workspaceReordering.attach(host: self)
        workspaceCommands.attach(host: self)
        workspaceSelection.attach(host: self)
        selectionSideEffects.attach(host: self)
        workspaceGrouping.attach(host: self)
        closeConfirmationPresenter.attach(presentingWindow: { [weak self] in self?.window })
        workspaceClosing.attach(confirming: closeConfirmationPresenter)
        workspaceClosing.attach(host: self)
        // The confirmation decision routes through the live close-tab warning
        // settings, matching the legacy `CloseTabWarningStore(defaults: .standard)`
        // the in-class `shouldConfirmClose` constructed per call.
        workspaceClosing.attach(closeTabWarning: CloseTabWarningStore(defaults: .standard))
        // Wire the creation host before the first addWorkspace so the initial
        // workspace's creation effects (chrome inheritance, lifecycle publish,
        // git-metadata schedule, welcome send) reach the host with the legacy
        // in-class timing.
        workspaceCreating.attach(host: self)
        sessionSnapshotRestore.attach(host: self)
        addWorkspace(
            title: initialWorkspaceTitle,
            workingDirectory: initialWorkingDirectory,
            initialTerminalInput: initialTerminalInput,
            autoWelcomeIfNeeded: autoWelcomeIfNeeded
        )
        ghosttyTitleSubscription = GhosttyTitleChangeSubscription(synchronous: true) { [weak self] change in
            guard let self else { return }
            enqueuePanelTitleUpdate(tabId: change.tabId, panelId: change.surfaceId, title: change.title)
        }
        ghosttyFocusSurfaceSubscription = GhosttyFocusSurfaceSubscription { [weak self] change in
            guard let self else { return }
            let panelId = panelIdForFocusHistorySurface(change.surfaceId, workspaceId: change.tabId)
            if selectedTabId == change.tabId {
                if change.explicitFocusIntent {
                    focusHistoryNavigation.recordFocusInHistory(
                        workspaceId: change.tabId,
                        panelId: panelId,
                        preservingForwardBranch: false
                    )
                } else {
                    focusHistoryNavigation.recordImplicitFocusInHistory(workspaceId: change.tabId, panelId: panelId)
                }
            }
            dismissPanelNotificationOnFocus(tabId: change.tabId, panelId: panelId, explicitFocusIntent: change.explicitFocusIntent)
            focusedSurfaceTitleDidChange(tabId: change.tabId)
        }
        workspaceCurrentDirectorySubscription = WorkspaceCurrentDirectorySubscription { [weak self] workspaceId in
            guard let self else { return }
            workspaceCurrentDirectoryDidChange(workspaceId: workspaceId)
        }

        // Wire and arm the agent-PID liveness sweep. Attached after the first
        // workspace is added (matching the legacy call site at the end of init),
        // so the first sweep one interval later sees the initial workspace.
        agentPIDLivenessSweep.attach(host: self)
        agentPIDLivenessSweep.start()
        userDefaultsChangeSubscription = UserDefaultsChangeSubscription { [weak self] in
            self?.sidebarMetadataSettingsDidChange()
            self?.refreshTabCloseButtonVisibility()
            self?.refreshWindowTitle()
        }
#if DEBUG
        setupUITestSplitScaffoldsIfNeeded()
#endif
    }

    deinit {
        // The typed NotificationCenter subscriptions
        // (ghosttyTitle/ghosttyFocusSurface/workspaceCurrentDirectory/userDefaultsChange)
        // unregister their observer tokens in their own deinits as this
        // TabManager deallocates and releases them; no explicit teardown here.
        // The workspace-cycle cooldown task is owned by `workspaceSelection`
        // (CmuxWorkspaces); it deallocates with this TabManager and its task's
        // `[weak self]` guard no-ops after dealloc, so no explicit cancel is
        // needed from this nonisolated deinit.
        // The agent-PID liveness sweep service deallocates with this TabManager;
        // its repeating task's `[weak self]` guard no-ops after dealloc, so no
        // explicit cancel is needed from this nonisolated deinit (same as the
        // workspace-cycle cooldown task above and the sidebar git/PR services
        // below).
        // The sidebar git/PR services cancel their own poll, probe, snapshot,
        // and refresh tasks in their deinits; they deallocate with this
        // TabManager (the host back-references are weak).
    }

    // MARK: - Sidebar git/PR forwarders (subsystem extracted to CmuxSidebarGit)

    private func sidebarMetadataSettingsDidChange() {
        sidebarGitMetadataService.sidebarGitMetadataWatchSettingsDidChange()
        pullRequestProbing.sidebarPullRequestPollingSettingsDidChange()
        refreshRemotePortScanningEnablement()
    }

    /// Last ports-visibility enablement fanned out to remote sessions; gates
    /// the `UserDefaults.didChangeNotification` firehose to actual transitions.
    private var lastRemotePortScanningEnabled: Bool?

    /// Propagates the sidebar ports-visibility settings to every live remote
    /// session so that disabling `sidebar.showPorts` (or enabling
    /// `sidebar.hideAllDetails`) actually stops the backend ssh port-scan loop,
    /// not just the sidebar display (issue #6123). New remote workspaces pick
    /// up the current value at creation, so this only needs to react to a
    /// change for already-connected sessions.
    private func refreshRemotePortScanningEnablement() {
        let enabled = Workspace.remotePortScanningEnabledFromSettings()
        guard enabled != lastRemotePortScanningEnabled else { return }
        lastRemotePortScanningEnabled = enabled
        for tab in tabs where tab.isRemoteWorkspace {
            tab.applyRemotePortScanningEnabled(enabled)
        }
    }

    func refreshTrackedWorkspaceGitMetadataForTesting() {
        sidebarGitMetadataService.refreshTrackedWorkspaceGitMetadata(reason: "test")
    }

    func sidebarGitMetadataWatchSettingsDidChangeForTesting() {
        sidebarMetadataSettingsDidChange()
    }

    func trackedWorkspaceGitMetadataPollCandidatePanelIdsForTesting(workspaceId: UUID) -> Set<UUID> {
        sidebarGitMetadataService.trackedWorkspaceGitMetadataPollCandidatePanelIds(workspaceId: workspaceId)
    }

    func activeWorkspaceGitProbePanelIdsForTesting(workspaceId: UUID) -> Set<UUID> {
        sidebarGitMetadataService.activeWorkspaceGitProbePanelIds(workspaceId: workspaceId)
    }

    func workspacePullRequestTrackedPanelIdsForTesting(workspaceId: UUID) -> Set<UUID> {
        pullRequestProbing.workspacePullRequestTrackedPanelIds(workspaceId: workspaceId)
    }


    func scheduleInitialWorkspaceGitMetadataRefreshIfPossible(
        workspaceId: UUID,
        panelId: UUID,
        reason: String = "initial"
    ) {
#if DEBUG
        didScheduleInitialWorkspaceGitMetadataRefreshForTesting(
            workspaceId: workspaceId,
            panelId: panelId,
            reason: reason
        )
#endif
        sidebarGitMetadataService.scheduleInitialWorkspaceGitMetadataRefreshIfPossible(
            workspaceId: workspaceId,
            panelId: panelId,
            reason: reason
        )
    }


    func wireClosedBrowserTracking(for workspace: Workspace) {
        workspace.onClosedBrowserPanel = { [weak self] snapshot in
            self?.browserModel.recordClosedBrowserPanel(snapshot)
        }
    }

    private func unwireClosedBrowserTracking(for workspace: Workspace) {
        workspace.onClosedBrowserPanel = nil
    }

    var selectedWorkspace: Workspace? {
        guard let selectedTabId else { return nil }
        return tabs.first(where: { $0.id == selectedTabId })
    }

    // Keep selectedTab as convenience alias
    var selectedTab: Workspace? { selectedWorkspace }

    // MARK: - Surface/Panel Compatibility Layer

    /// Returns the focused terminal surface for the selected workspace
    var selectedSurface: TerminalSurface? {
        selectedWorkspace?.focusedTerminalPanel?.surface
    }

    /// Returns the focused panel's terminal panel (if it is a terminal)
    var selectedTerminalPanel: TerminalPanel? {
        selectedWorkspace?.focusedTerminalPanel
    }

    private var selectedWorkspaceTerminalPanels: [TerminalPanel] {
        selectedWorkspace?.panels.values.compactMap { $0 as? TerminalPanel } ?? []
    }

    // MARK: - Focused-terminal command surface (CmuxTerminal)
    //
    // The find/search, keyboard copy-mode, Ctrl-F chord, text-box, and
    // keep-scrollback-clear command bodies live in
    // `FocusedTerminalCommandCoordinator` (CmuxTerminal), driven by the
    // `focusedTerminalCommands` coordinator above through the
    // `FocusedTerminalCommanding` / `FocusedTerminalFindFallback` seams the
    // panels conform to. These remain as thin forwarders for the existing call
    // sites (keyboard shortcuts, command palette, View menu, the command
    // socket). Mirrors the `focusedBrowserController` forwarders.

    var isFindVisible: Bool {
        focusedTerminalCommands.isFindVisible
    }

    var canUseSelectionForFind: Bool {
        focusedTerminalCommands.canUseSelectionForFind
    }

    @discardableResult
    func startSearch() -> Bool {
        focusedTerminalCommands.startSearch()
    }

    func searchSelection() {
        focusedTerminalCommands.searchSelection()
    }

    func findNext() {
        focusedTerminalCommands.findNext()
    }

    func findPrevious() {
        focusedTerminalCommands.findPrevious()
    }

    @discardableResult
    func toggleFocusedTerminalCopyMode() -> Bool {
        focusedTerminalCommands.toggleFocusedTerminalCopyMode()
    }

    @discardableResult
    func sendCtrlFToFocusedTerminal() -> Bool {
        focusedTerminalCommands.sendCtrlFToFocusedTerminal()
    }

    @discardableResult
    func toggleFocusedTerminalTextBox() -> Bool {
        focusedTerminalCommands.toggleFocusedTerminalTextBox()
    }

    @discardableResult
    func clearFocusedTerminalKeepingScrollback() -> Bool {
        focusedTerminalCommands.clearFocusedTerminalKeepingScrollback()
    }

    @discardableResult
    func focusFocusedTerminalTextBoxInputOrTerminal() -> Bool {
        focusedTerminalCommands.focusFocusedTerminalTextBoxInputOrTerminal()
    }

    @discardableResult
    func attachFileToFocusedTerminalTextBoxInput() -> Bool {
        focusedTerminalCommands.attachFileToFocusedTerminalTextBoxInput()
    }

    @discardableResult
    func consumeFocusedTerminalTextBoxHideEscapeIfArmed(in window: NSWindow?) -> Bool {
        focusedTerminalCommands.consumeFocusedTerminalTextBoxHideEscapeIfArmed(in: window)
    }

    func clearFocusedTerminalTextBoxHideEscapeArm() {
        focusedTerminalCommands.clearFocusedTerminalTextBoxHideEscapeArm()
    }

    func hideFind() {
        focusedTerminalCommands.hideFind()
    }

    func makeWorkspaceForCreation(
        title: String,
        workingDirectory: String?,
        portOrdinal: Int,
        configTemplate: CmuxSurfaceConfigTemplate?,
        initialSurface: NewWorkspaceInitialSurface = .terminal,
        initialTerminalCommand: String?,
        initialTerminalInput: String? = nil,
        initialTerminalEnvironment: [String: String],
        workspaceEnvironment: [String: String] = [:]
    ) -> Workspace {
        Workspace(
            title: title,
            workingDirectory: workingDirectory,
            portOrdinal: portOrdinal,
            configTemplate: configTemplate,
            initialSurface: initialSurface,
            initialTerminalCommand: initialTerminalCommand,
            initialTerminalInput: initialTerminalInput,
            initialTerminalEnvironment: initialTerminalEnvironment,
            workspaceEnvironment: workspaceEnvironment
        )
    }

    func applyCreationChromeInheritance(
        to newWorkspace: Workspace,
        from sourceWorkspace: Workspace?
    ) {
        // Sidebar-toggle relayout updates the live Bonsplit leading inset so minimal-mode
        // workspaces reserve traffic-light space. New workspaces need that same inset
        // copied immediately because creation itself does not trigger the resync path.
        //
        // The pure inset resolution (window inset ?? source inset) lives in
        // WorkspaceCreationCoordinator (CmuxWorkspaces); the currentWindowTabBarLeadingInset
        // stored property and the source workspace's bonsplit-appearance read stay window-side
        // and are threaded through. The source read is a closure so it stays lazy behind ??.
        let inheritedLeadingInset = workspaceCreating.inheritedTabBarLeadingInset(
            currentWindowTabBarLeadingInset: currentWindowTabBarLeadingInset,
            sourceTabBarLeadingInset: {
                sourceWorkspace?.bonsplitController.configuration.appearance.tabBarLeadingInset
            }
        )
        guard let inheritedLeadingInset else { return }
        applyTabBarLeadingInset(inheritedLeadingInset, to: newWorkspace)
    }

    func syncWorkspaceTabBarLeadingInset(_ inset: CGFloat) {
        // The max(0,) normalization lives in WorkspaceCreationCoordinator (CmuxWorkspaces);
        // the currentWindowTabBarLeadingInset stored property stays window-side.
        let normalizedInset = workspaceCreating.normalizedTabBarLeadingInset(inset)
        currentWindowTabBarLeadingInset = normalizedInset
        for tab in tabs {
            applyTabBarLeadingInset(normalizedInset, to: tab)
        }
    }

    private func applyTabBarLeadingInset(_ inset: CGFloat, to workspace: Workspace) {
        // The change-gate (current != new) lives in WorkspaceCreationCoordinator
        // (CmuxWorkspaces); the actual bonsplit-appearance write stays window-side as the
        // witness effect.
        let current = workspace.bonsplitController.configuration.appearance.tabBarLeadingInset
        if workspaceCreating.tabBarLeadingInsetNeedsApply(current: current, new: inset) {
            workspace.bonsplitController.configuration.appearance.tabBarLeadingInset = inset
        }
    }

    /// Test seam for mutating live workspace state after the creation snapshot is captured.
    func didCaptureWorkspaceCreationSnapshot() {}

#if DEBUG
    /// Test seam: invoked when an initial workspace git-metadata refresh is
    /// scheduled, so tests can observe scheduling without the network probe.
    func didScheduleInitialWorkspaceGitMetadataRefreshForTesting(
        workspaceId: UUID,
        panelId: UUID,
        reason: String
    ) {}
#endif

#if DEBUG
    func maybeMutateSelectionDuringWorkspaceCreationForDev(
        snapshot: WorkspaceCreationSnapshot
    ) {
        let env = ProcessInfo.processInfo.environment
        let isEnabled: Bool = {
            if let raw = env["CMUX_DEV_MUTATE_WORKSPACE_SELECTION_DURING_CREATION"] {
                return raw == "1" || raw.caseInsensitiveCompare("true") == .orderedSame
            }
            return UserDefaults.standard.bool(forKey: "cmuxDevMutateWorkspaceSelectionDuringCreation")
        }()
        guard isEnabled,
              let selectedTabId = snapshot.selectedTabId,
              let targetId = snapshot.tabs.lazy.map(\.id).first(where: { $0 != selectedTabId }),
              tabs.contains(where: { $0.id == targetId }) else {
            return
        }
        cmuxDebugLog(
            "workspace.create.devSelectionMutation from=\(selectedTabId.uuidString.prefix(5)) " +
            "to=\(targetId.uuidString.prefix(5))"
        )
        self.selectedTabId = targetId
    }
#endif

    // Creation orchestration lives in WorkspaceCreationCoordinator (CmuxWorkspaces);
    // this forwarder keeps the legacy entry point. Every app-coupled effect
    // inverts back through WorkspaceCreationHosting (witnesses below).
    @discardableResult
    func addWorkspace(
        title: String? = nil,
        workingDirectory overrideWorkingDirectory: String? = nil,
        initialSurface: NewWorkspaceInitialSurface = .terminal,
        initialTerminalCommand: String? = nil,
        initialTerminalInput: String? = nil,
        initialTerminalEnvironment: [String: String] = [:],
        workspaceEnvironment: [String: String] = [:],
        inheritWorkingDirectory: Bool = true,
        select: Bool = true,
        eagerLoadTerminal: Bool = false,
        placementOverride: WorkspacePlacement? = nil,
        autoWelcomeIfNeeded: Bool = true,
        autoRefreshMetadata: Bool = true,
        normalizeWorkspaceGroupsAfterInsert: Bool = true
    ) -> Workspace {
        workspaceCreating.addWorkspace(
            title: title,
            workingDirectory: overrideWorkingDirectory,
            initialSurface: initialSurface,
            initialTerminalCommand: initialTerminalCommand,
            initialTerminalInput: initialTerminalInput,
            initialTerminalEnvironment: initialTerminalEnvironment,
            workspaceEnvironment: workspaceEnvironment,
            inheritWorkingDirectory: inheritWorkingDirectory,
            select: select,
            eagerLoadTerminal: eagerLoadTerminal,
            placementOverride: placementOverride,
            autoWelcomeIfNeeded: autoWelcomeIfNeeded,
            autoRefreshMetadata: autoRefreshMetadata,
            normalizeWorkspaceGroupsAfterInsert: normalizeWorkspaceGroupsAfterInsert
        )
    }

    @MainActor
    private func sendWelcomeWhenReady(to workspace: Workspace) {
        if let terminalPanel = workspace.focusedTerminalPanel,
           terminalPanel.surface.surface != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                UserDefaults.standard.set(true, forKey: AccountCatalogSection().welcomeShown.userDefaultsKey)
                terminalPanel.sendText("cmux welcome\n")
            }
            return
        }

        var resolved = false
        var readyObserver: NSObjectProtocol?
        var panelsCancellable: AnyCancellable?

        func finishIfReady() {
            guard !resolved,
                  let terminalPanel = workspace.focusedTerminalPanel,
                  terminalPanel.surface.surface != nil else { return }
            resolved = true
            if let readyObserver {
                NotificationCenter.default.removeObserver(readyObserver)
            }
            panelsCancellable?.cancel()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                UserDefaults.standard.set(true, forKey: AccountCatalogSection().welcomeShown.userDefaultsKey)
                terminalPanel.sendText("cmux welcome\n")
            }
        }

        panelsCancellable = workspace.panelsPublisher
            .map { _ in () }
            .sink { _ in
                Task { @MainActor in
                    finishIfReady()
                }
            }
        readyObserver = NotificationCenter.default.addObserver(
            forName: .terminalSurfaceDidBecomeReady,
            object: nil,
            queue: .main
        ) { note in
            guard let workspaceId = note.userInfo?["workspaceId"] as? UUID,
                  workspaceId == workspace.id else { return }
            Task { @MainActor in
                finishIfReady()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            Task { @MainActor in
                if let readyObserver, !resolved {
                    NotificationCenter.default.removeObserver(readyObserver)
                }
                if !resolved {
                    panelsCancellable?.cancel()
                }
            }
        }
    }

    func requestBackgroundWorkspaceLoad(for workspaceId: UUID) {
        guard !pendingBackgroundWorkspaceLoadIds.contains(workspaceId) else { return }
        var updated = pendingBackgroundWorkspaceLoadIds
        updated.insert(workspaceId)
        backgroundWorkspaceLoad.pendingBackgroundWorkspaceLoadIds = updated
    }

    func completeBackgroundWorkspaceLoad(for workspaceId: UUID) {
        guard pendingBackgroundWorkspaceLoadIds.contains(workspaceId) else { return }
        var updated = pendingBackgroundWorkspaceLoadIds
        updated.remove(workspaceId)
        backgroundWorkspaceLoad.pendingBackgroundWorkspaceLoadIds = updated
        releaseBackgroundWorkspaceMount(for: workspaceId)
    }

    func retainBackgroundWorkspaceMount(for workspaceId: UUID) {
        guard !mountedBackgroundWorkspaceLoadIds.contains(workspaceId) else { return }
        var updated = mountedBackgroundWorkspaceLoadIds
        updated.insert(workspaceId)
        backgroundWorkspaceLoad.mountedBackgroundWorkspaceLoadIds = updated
    }

    func releaseBackgroundWorkspaceMount(for workspaceId: UUID) {
        guard mountedBackgroundWorkspaceLoadIds.contains(workspaceId) else { return }
        var updated = mountedBackgroundWorkspaceLoadIds
        updated.remove(workspaceId)
        backgroundWorkspaceLoad.mountedBackgroundWorkspaceLoadIds = updated
    }

    func retainDebugWorkspaceLoads(for workspaceIds: Set<UUID>) {
        guard !workspaceIds.isEmpty else { return }
        var updated = debugPinnedWorkspaceLoadIds
        updated.formUnion(workspaceIds)
        guard updated != debugPinnedWorkspaceLoadIds else { return }
        backgroundWorkspaceLoad.debugPinnedWorkspaceLoadIds = updated
    }

    func releaseDebugWorkspaceLoads(for workspaceIds: Set<UUID>) {
        guard !workspaceIds.isEmpty else { return }
        var updated = debugPinnedWorkspaceLoadIds
        updated.subtract(workspaceIds)
        guard updated != debugPinnedWorkspaceLoadIds else { return }
        backgroundWorkspaceLoad.debugPinnedWorkspaceLoadIds = updated
    }

    func pruneBackgroundWorkspaceLoads(existingIds: Set<UUID>) {
        let pruned = pendingBackgroundWorkspaceLoadIds.intersection(existingIds)
        if pruned != pendingBackgroundWorkspaceLoadIds {
            backgroundWorkspaceLoad.pendingBackgroundWorkspaceLoadIds = pruned
        }
        let mounted = mountedBackgroundWorkspaceLoadIds.intersection(existingIds)
        if mounted != mountedBackgroundWorkspaceLoadIds {
            backgroundWorkspaceLoad.mountedBackgroundWorkspaceLoadIds = mounted
        }
        let retained = debugPinnedWorkspaceLoadIds.intersection(existingIds)
        if retained != debugPinnedWorkspaceLoadIds {
            backgroundWorkspaceLoad.debugPinnedWorkspaceLoadIds = retained
        }
    }

    // Keep addTab as convenience alias (forwards through the creation coordinator).
    @discardableResult
    func addTab(select: Bool = true, eagerLoadTerminal: Bool = false) -> Workspace {
        workspaceCreating.addTab(select: select, eagerLoadTerminal: eagerLoadTerminal)
    }

    func terminalPanelForWorkspaceConfigInheritanceSource() -> TerminalPanel? {
        terminalPanelForWorkspaceConfigInheritanceSource(workspace: selectedWorkspace)
    }

    /// Build a snapshot using pre-extracted value-type data. The caller is responsible
    /// for obtaining `preferredWorkingDirectory` and `inheritedTerminalFontPoints` through
    /// `self` (where `self.tabs` keeps all Workspace objects alive) so that no local
    /// Workspace references are needed here.
    // Snapshot building lives in WorkspaceCreationCoordinator (CmuxWorkspaces);
    // this forwarder keeps the legacy entry point for the creation paths that
    // already hold the captured live workspaces.
    func workspaceCreationSnapshotLite(
        currentTabs: [Workspace],
        currentSelectedTabId: UUID?,
        preferredWorkingDirectory: String?,
        inheritedTerminalFontPoints: Float?
    ) -> WorkspaceCreationSnapshot {
        workspaceCreating.workspaceCreationSnapshotLite(
            currentTabs: currentTabs,
            currentSelectedTabId: currentSelectedTabId,
            preferredWorkingDirectory: preferredWorkingDirectory,
            inheritedTerminalFontPoints: inheritedTerminalFontPoints
        )
    }

    private func workspaceCreationSnapshot() -> WorkspaceCreationSnapshot {
        workspaceCreationSnapshotLite(
            currentTabs: tabs,
            currentSelectedTabId: selectedTabId,
            preferredWorkingDirectory: preferredWorkingDirectoryForNewTab(),
            inheritedTerminalFontPoints: inheritedTerminalFontPointsForNewWorkspace()
        )
    }

    private func terminalPanelForWorkspaceConfigInheritanceSource(
        workspace: Workspace?
    ) -> TerminalPanel? {
        guard let workspace else { return nil }
        // Prefer cached/published panel state here instead of walking live Bonsplit focus
        // during Cmd+N; rapid workspace creation can observe transient pane/tab selection.
        // The candidate ordering + first-live selection lives in the package-pure
        // WorkspaceCreationInheritanceResolver; the seam flattens the live panels into
        // its Sendable input and we map the chosen id back to the live panel here.
        guard let panelId = workspaceCreationInheritanceResolver.configInheritanceSourcePanelId(
            from: workspace.configInheritancePanelSource
        ) else {
            return nil
        }
        return workspace.terminalPanel(for: panelId)
    }

    private func inheritedTerminalConfigForNewWorkspace() -> CmuxSurfaceConfigTemplate? {
        inheritedTerminalConfigForNewWorkspace(workspace: selectedWorkspace)
    }

    private func cachedInheritedTerminalFontPointsForNewWorkspace(
        workspace: Workspace?
    ) -> Float? {
        guard let workspace else { return nil }
        // New workspace creation only seeds font size into a fresh Swift-owned template.
        // Avoid reading live panel/surface state here; the arm64 Nightly Cmd+N crash path
        // was repeatedly dereferencing pointer-backed terminal objects while preparing the
        // new workspace. The workspace already caches the rooted font lineage we need.
        // The positive-guard decision lives in WorkspaceCreationInheritanceResolver; the
        // read stays under the same extended-lifetime ARC pin as the legacy body.
        return withExtendedLifetime(workspace) {
            workspaceCreationInheritanceResolver.inheritedTerminalFontPoints(
                rememberedFontPoints: workspace.rememberedTerminalFontPointsForConfigInheritance
            )
        }
    }

    func inheritedTerminalConfigForNewWorkspace(
        workspace: Workspace?
    ) -> CmuxSurfaceConfigTemplate? {
        guard let fontPoints = cachedInheritedTerminalFontPointsForNewWorkspace(workspace: workspace) else {
            return nil
        }
        var config = CmuxSurfaceConfigTemplate()
        config.fontSize = fontPoints
        return config
    }

    private func inheritedTerminalFontPointsForNewWorkspace() -> Float? {
        inheritedTerminalFontPointsForNewWorkspace(workspace: selectedWorkspace)
    }

    func inheritedTerminalFontPointsForNewWorkspace(
        workspace: Workspace?
    ) -> Float? {
        cachedInheritedTerminalFontPointsForNewWorkspace(workspace: workspace)
    }

    // Inherited-surface config-template building lives in
    // WorkspaceCreationCoordinator (CmuxWorkspaces); this forwarder keeps the
    // legacy entry point used by the creation host witness and the
    // detached-workspace path.
    func workspaceCreationConfigTemplate(
        inheritedTerminalFontPoints: Float?
    ) -> CmuxSurfaceConfigTemplate? {
        workspaceCreating.workspaceCreationConfigTemplate(
            inheritedTerminalFontPoints: inheritedTerminalFontPoints
        )
    }

    func normalizedWorkingDirectory(_ directory: String?) -> String? {
        // Single source of truth: the normalization moved to CmuxSidebarGit
        // with the git subsystem; non-git callers (workspace creation) keep
        // this forwarder.
        directory?.nonEmptyNormalizedGitProbeDirectory
    }

    private func newTabInsertIndex(placementOverride: WorkspacePlacement? = nil) -> Int {
        newTabInsertIndex(snapshot: workspaceCreationSnapshot(), placementOverride: placementOverride)
    }

    // Placement-driven insertion-index math lives in
    // WorkspaceCreationCoordinator (CmuxWorkspaces); this forwarder keeps the
    // legacy entry point used by the creation paths.
    func newTabInsertIndex(
        snapshot: WorkspaceCreationSnapshot,
        placementOverride: WorkspacePlacement? = nil
    ) -> Int {
        workspaceCreating.newTabInsertIndex(snapshot: snapshot, placementOverride: placementOverride)
    }

    private func preferredWorkingDirectoryForNewTab() -> String? {
        preferredWorkingDirectoryForNewTab(workspace: selectedWorkspace)
    }

    // The working-directory inheritance decision (first non-empty normalized
    // directory from [currentDirectory] + panelDirectories.values) lives in
    // WorkspaceCreationCoordinator (CmuxWorkspaces); this forwarder flattens the
    // live workspace through the WorkspaceCreationInheritanceReading seam and
    // passes the app-side git-probe normalizer in as a closure.
    func preferredWorkingDirectoryForNewTab(
        workspace: Workspace?
    ) -> String? {
        guard let workspace else {
            return nil
        }
        return workspaceCreating.preferredWorkingDirectoryForNewTab(
            currentDirectory: workspace.currentDirectory,
            orderedPanelDirectories: workspace.orderedPanelDirectories,
            normalize: { self.normalizedWorkingDirectory($0) }
        )
    }

    // The settings-gated wrapper decision lives in WorkspaceCreationCoordinator
    // (CmuxWorkspaces); the inherit-working-directory setting read stays app-side
    // and is threaded in as the bool.
    func implicitWorkingDirectoryForNewWorkspace(from sourceWorkspace: Workspace?) -> String? {
        workspaceCreating.implicitWorkingDirectoryForNewWorkspace(
            inheritWorkingDirectory: settings.value(for: settingsCatalog.app.workspaceInheritWorkingDirectory),
            currentDirectory: sourceWorkspace?.currentDirectory,
            orderedPanelDirectories: sourceWorkspace?.orderedPanelDirectories ?? [],
            normalize: { self.normalizedWorkingDirectory($0) }
        )
    }

    // MARK: - Reordering (WorkspaceReorderCoordinator, CmuxWorkspaces)

    func moveTabToTop(_ tabId: UUID) {
        workspaceReordering.moveTabToTop(tabId)
    }

    func moveTabsToTop(_ tabIds: Set<UUID>) {
        workspaceReordering.moveTabsToTop(tabIds)
    }

    func moveTabToTopForNotification(_ tabId: UUID) {
        workspaceReordering.moveTabToTopForNotification(tabId)
    }

    @discardableResult
    func reorderWorkspace(tabId: UUID, toIndex targetIndex: Int, isDragOperation: Bool = false) -> Bool {
        workspaceReordering.reorderWorkspace(tabId: tabId, toIndex: targetIndex, isDragOperation: isDragOperation)
    }

    func sidebarReorderWorkspaceIds(
        forDraggedWorkspaceId draggedWorkspaceId: UUID?,
        targetWorkspaceId: UUID? = nil,
        usesTopLevelRows: Bool = false
    ) -> [UUID] {
        workspaceReordering.sidebarReorderWorkspaceIds(
            forDraggedWorkspaceId: draggedWorkspaceId,
            targetWorkspaceId: targetWorkspaceId,
            usesTopLevelRows: usesTopLevelRows
        )
    }

    func sidebarReorderPinnedWorkspaceIds(
        forDraggedWorkspaceId draggedWorkspaceId: UUID?,
        targetWorkspaceId: UUID? = nil,
        usesTopLevelRows: Bool = false
    ) -> Set<UUID> {
        workspaceReordering.sidebarReorderPinnedWorkspaceIds(
            forDraggedWorkspaceId: draggedWorkspaceId,
            targetWorkspaceId: targetWorkspaceId,
            usesTopLevelRows: usesTopLevelRows
        )
    }

    func sidebarReorderLegalInsertionRange(
        forDraggedWorkspaceId draggedWorkspaceId: UUID?,
        targetWorkspaceId: UUID? = nil,
        usesTopLevelRows: Bool = false
    ) -> ClosedRange<Int>? {
        workspaceReordering.sidebarReorderLegalInsertionRange(
            forDraggedWorkspaceId: draggedWorkspaceId,
            targetWorkspaceId: targetWorkspaceId,
            usesTopLevelRows: usesTopLevelRows
        )
    }

    @discardableResult
    func reorderSidebarWorkspace(
        tabId: UUID,
        toIndex targetIndex: Int,
        isDragOperation: Bool = false,
        usesTopLevelRows: Bool = false
    ) -> Bool {
        workspaceReordering.reorderSidebarWorkspace(
            tabId: tabId,
            toIndex: targetIndex,
            isDragOperation: isDragOperation,
            usesTopLevelRows: usesTopLevelRows
        )
    }

    func sidebarReorderUsesTopLevelRows(
        forDraggedWorkspaceId draggedWorkspaceId: UUID?,
        targetWorkspaceId: UUID?
    ) -> Bool {
        workspaceReordering.sidebarReorderUsesTopLevelRows(
            forDraggedWorkspaceId: draggedWorkspaceId,
            targetWorkspaceId: targetWorkspaceId
        )
    }

    func sidebarReorderUsesTopLevelRows(
        forDraggedWorkspaceId draggedWorkspaceId: UUID?,
        targetWorkspaceId: UUID?,
        workspaceGroupIdByWorkspaceId: [UUID: UUID?]
    ) -> Bool {
        workspaceReordering.sidebarReorderUsesTopLevelRows(
            forDraggedWorkspaceId: draggedWorkspaceId,
            targetWorkspaceId: targetWorkspaceId,
            workspaceGroupIdByWorkspaceId: workspaceGroupIdByWorkspaceId
        )
    }

    func workspaceReorderPlan(tabId: UUID, toIndex targetIndex: Int) -> WorkspaceReorderPlanItem? {
        workspaceReordering.workspaceReorderPlan(tabId: tabId, toIndex: targetIndex)
    }

    /// Legacy `postWorkspaceOrderDidChange`: NotificationCenter + app event
    /// bus publication (WorkspaceOrderHosting; the reorder/group
    /// coordinators invert observable order-change publication through
    /// this hook).
    func workspaceOrderDidChange(movedWorkspaceIds: [UUID]) {
        guard !movedWorkspaceIds.isEmpty else { return }
        NotificationCenter.default.post(
            name: WorkspaceOrderDidChangeEvent.notificationName,
            object: self,
            userInfo: WorkspaceOrderDidChangeEvent(movedWorkspaceIds: movedWorkspaceIds).userInfo()
        )
        CmuxEventBus.shared.publishWorkspaceReordered(
            workspaceIds: tabs.map(\.id),
            movedWorkspaceIds: movedWorkspaceIds,
            pinnedWorkspaceIds: tabs.filter(\.isPinned).map(\.id),
            source: "workspace.lifecycle"
        )
    }

    @discardableResult
    func reorderWorkspace(tabId: UUID, before beforeId: UUID? = nil, after afterId: UUID? = nil, isDragOperation: Bool = false) -> Bool {
        workspaceReordering.reorderWorkspace(tabId: tabId, before: beforeId, after: afterId, isDragOperation: isDragOperation)
    }

    func workspaceReorderPlan(tabId: UUID, before beforeId: UUID? = nil, after afterId: UUID? = nil) -> WorkspaceReorderPlanItem? {
        workspaceReordering.workspaceReorderPlan(tabId: tabId, before: beforeId, after: afterId)
    }

    func workspaceBatchReorderPlan(
        orderedWorkspaceIds: [UUID]
    ) -> Result<[WorkspaceReorderPlanItem], WorkspaceBatchReorderError> {
        workspaceReordering.workspaceBatchReorderPlan(orderedWorkspaceIds: orderedWorkspaceIds)
    }

    @discardableResult
    func reorderWorkspaces(
        orderedWorkspaceIds: [UUID],
        dryRun: Bool = false
    ) -> Result<[WorkspaceReorderPlanItem], WorkspaceBatchReorderError> {
        workspaceReordering.reorderWorkspaces(orderedWorkspaceIds: orderedWorkspaceIds, dryRun: dryRun)
    }

    /// Sets, replaces, or clears a workspace custom title. Returns whether the
    /// write landed (`.auto` writes are rejected over user-set titles; see
    /// ``Workspace/setCustomTitle(_:source:)``).
    @discardableResult
    func setCustomTitle(tabId: UUID, title: String?, source: Workspace.CustomTitleSource = .user) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == tabId }) else { return false }
        let applied = tabs[index].setCustomTitle(title, source: source)
        if applied, selectedTabId == tabId {
            updateWindowTitle(for: tabs[index])
        }
        // A remote tmux mirror workspace rename propagates to `rename-session`,
        // but only when the write landed (an `.auto` write rejected over a
        // user-set title must not desync the remote session name).
        if applied, tabs[index].isRemoteTmuxMirror {
            appEnvironment?.remoteTmuxController.handleMirrorWorkspaceRenamed(
                workspaceId: tabId, title: title
            )
        }
        return applied
    }

    func clearCustomTitle(tabId: UUID) {
        setCustomTitle(tabId: tabId, title: nil)
    }

    func setCustomDescription(tabId: UUID, description: String?) {
        guard let index = tabs.firstIndex(where: { $0.id == tabId }) else { return }
        tabs[index].setCustomDescription(description)
    }

    func clearCustomDescription(tabId: UUID) {
        setCustomDescription(tabId: tabId, description: nil)
    }

    func setTabColor(tabId: UUID, color: String?) {
        workspaceReordering.setTabColor(tabId: tabId, color: color)
    }

    func applyWorkspaceColor(_ color: String?, toWorkspaceIds workspaceIds: [UUID]) {
        workspaceReordering.applyWorkspaceColor(color, toWorkspaceIds: workspaceIds)
    }

    func applyWorkspacePaletteColor(named name: String, toWorkspaceIds workspaceIds: [UUID]) {
        // The palette-name → hex codec is an app-side `UserDefaults`-backed
        // settings namespace (a separate settings slice); resolve here, then
        // forward the resolved hex to the reorder coordinator's apply plan.
        guard let color = WorkspaceTabColorSettings.currentColorHex(named: name) else { return }
        applyWorkspaceColor(color, toWorkspaceIds: workspaceIds)
    }

    func setWorkspaceTerminalScrollBarHidden(tabId: UUID, hidden: Bool) {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return }
        tab.setTerminalScrollBarHidden(hidden)
    }

    func setWorkspaceTerminalScrollBarHidden(hidden: Bool, forWorkspaceIds workspaceIds: [UUID]) {
        guard !workspaceIds.isEmpty else { return }
        if workspaceIds.count == 1, let workspaceId = workspaceIds.first {
            setWorkspaceTerminalScrollBarHidden(tabId: workspaceId, hidden: hidden)
            return
        }

        let targetIds = Set(workspaceIds)
        for tab in tabs where targetIds.contains(tab.id) {
            tab.setTerminalScrollBarHidden(hidden)
        }
    }

    func togglePin(tabId: UUID) {
        workspaceReordering.togglePin(tabId: tabId)
    }

    func setPinned(_ tab: Workspace, pinned: Bool) {
        workspaceReordering.setPinned(tab, pinned: pinned)
    }

    @discardableResult
    func setPinned(workspaceIds: [UUID], pinned: Bool) -> [UUID] {
        workspaceReordering.setPinned(workspaceIds: workspaceIds, pinned: pinned)
    }

    // MARK: - Workspace Groups (WorkspaceGroupCoordinator, CmuxWorkspaces)

    @discardableResult
    func createWorkspaceGroup(
        name: String,
        childWorkspaceIds: [UUID] = [],
        anchorWorkingDirectory: String? = nil,
        selectAnchor: Bool = true,
        collapseSidebarSelection: Bool = true
    ) -> UUID? {
        workspaceGrouping.createWorkspaceGroup(
            name: name,
            childWorkspaceIds: childWorkspaceIds,
            anchorWorkingDirectory: anchorWorkingDirectory,
            selectAnchor: selectAnchor,
            collapseSidebarSelection: collapseSidebarSelection
        )
    }

    @discardableResult
    func createWorkspaceInGroup(
        groupId: UUID,
        placement explicitPlacement: WorkspaceGroupNewPlacement? = nil,
        referenceWorkspaceId: UUID? = nil,
        select: Bool = true,
        initialSurface: NewWorkspaceInitialSurface = .terminal
    ) -> Workspace? {
        workspaceGrouping.createWorkspaceInGroup(
            groupId: groupId,
            placement: explicitPlacement,
            referenceWorkspaceId: referenceWorkspaceId,
            select: select,
            initialSurface: initialSurface
        )
    }

    func addWorkspaceToGroup(
        workspaceId: UUID,
        groupId: UUID,
        placement: WorkspaceGroupNewPlacement? = nil,
        referenceWorkspaceId: UUID? = nil
    ) {
        workspaceGrouping.addWorkspaceToGroup(
            workspaceId: workspaceId,
            groupId: groupId,
            placement: placement,
            referenceWorkspaceId: referenceWorkspaceId
        )
    }

    func removeWorkspaceFromGroup(workspaceId: UUID) {
        workspaceGrouping.removeWorkspaceFromGroup(workspaceId: workspaceId)
    }

    func ungroupWorkspaceGroup(groupId: UUID) {
        workspaceGrouping.ungroupWorkspaceGroup(groupId: groupId)
    }

    @discardableResult
    func deleteWorkspaceGroup(groupId: UUID, recordHistory: Bool = true) -> Int {
        workspaceGrouping.deleteWorkspaceGroup(groupId: groupId, recordHistory: recordHistory)
    }

    func renameWorkspaceGroup(groupId: UUID, name: String) {
        workspaceGrouping.renameWorkspaceGroup(groupId: groupId, name: name)
    }

    func toggleWorkspaceGroupCollapsed(groupId: UUID) {
        workspaceGrouping.toggleWorkspaceGroupCollapsed(groupId: groupId)
    }

    func setWorkspaceGroupCollapsed(groupId: UUID, isCollapsed: Bool) {
        workspaceGrouping.setWorkspaceGroupCollapsed(groupId: groupId, isCollapsed: isCollapsed)
    }

    func toggleWorkspaceGroupPinned(groupId: UUID) {
        workspaceGrouping.toggleWorkspaceGroupPinned(groupId: groupId)
    }

    func setWorkspaceGroupPinned(groupId: UUID, isPinned: Bool) {
        workspaceGrouping.setWorkspaceGroupPinned(groupId: groupId, isPinned: isPinned)
    }

    func setWorkspaceGroupColor(groupId: UUID, hex: String?) {
        workspaceGrouping.setWorkspaceGroupColor(groupId: groupId, hex: hex)
    }

    @discardableResult
    func setWorkspaceGroupIcon(groupId: UUID, symbol: String?) -> String? {
        workspaceGrouping.setWorkspaceGroupIcon(groupId: groupId, symbol: symbol)
    }

    func setWorkspaceGroupAnchor(groupId: UUID, workspaceId: UUID) {
        workspaceGrouping.setWorkspaceGroupAnchor(groupId: groupId, workspaceId: workspaceId)
    }

    func moveWorkspaceGroup(groupId: UUID, toIndex targetIndex: Int) {
        workspaceGrouping.moveWorkspaceGroup(groupId: groupId, toIndex: targetIndex)
    }

    /// Compatibility shim. With anchor-bound group lifecycle, "empty" groups
    /// are no longer possible — a group exists iff its anchor exists in
    /// `tabs[]`.
    func pruneEmptyWorkspaceGroups() {}

    // MARK: - WorkspaceGroupHosting (effects the group coordinator inverts)

    func createGroupAnchorWorkspace(
        title: String,
        workingDirectory: String?,
        inheritWorkingDirectory: Bool,
        select: Bool
    ) -> Workspace {
        addWorkspace(
            title: title,
            workingDirectory: workingDirectory,
            inheritWorkingDirectory: inheritWorkingDirectory,
            select: select,
            placementOverride: .top,
            autoWelcomeIfNeeded: false,
            normalizeWorkspaceGroupsAfterInsert: false
        )
    }

    func createWorkspaceForGroup(
        workingDirectory: String?,
        initialSurface: NewWorkspaceInitialSurface,
        inheritWorkingDirectory: Bool,
        select: Bool
    ) -> Workspace {
        addWorkspace(
            workingDirectory: workingDirectory,
            initialSurface: initialSurface,
            inheritWorkingDirectory: inheritWorkingDirectory,
            select: select,
            autoWelcomeIfNeeded: false
        )
    }

    func closeWorkspaceForGroupDeletion(_ tab: Workspace, recordHistory: Bool) {
        closeWorkspace(tab, recordHistory: recordHistory)
    }

    func collapseSidebarSelectionForGroupCreation(
        hiddenWorkspaceIds: Set<UUID>,
        anchorId: UUID
    ) {
        sidebarMultiSelection.replaceSelection(with: [anchorId])
        sidebarMultiSelection.postDidHide(hiddenWorkspaceIds: hiddenWorkspaceIds, focusedWorkspaceId: anchorId)
    }

    func subtractSidebarSelection(
        hiddenWorkspaceIds: Set<UUID>,
        focusedWorkspaceId: UUID?
    ) {
        sidebarMultiSelection.subtractSelection(hiddenWorkspaceIds)
        sidebarMultiSelection.postDidHide(
            hiddenWorkspaceIds: hiddenWorkspaceIds,
            focusedWorkspaceId: focusedWorkspaceId
        )
    }

    var localizedAutoGroupNameFormat: String {
        String(
            localized: "workspaceGroup.autoName.numbered",
            defaultValue: "Group %lld"
        )
    }

    var defaultNewWorkspacePlacementInGroup: WorkspaceGroupNewPlacement {
        settings.value(for: settingsCatalog.workspaceGroups.newWorkspacePlacement)
    }

    func normalizedGroupIconSymbol(_ symbol: String?) -> String? {
        RenderableSystemSymbol.normalized(symbol)
    }

    func workspaceGroupNameDidChange() {
        updateWindowTitleForSelectedTab()
        NotificationCenter.default.post(name: .workspaceGroupNameDidChange, object: self)
    }

    // MARK: - Surface Directory Updates (Backwards Compatibility)

    func updateSurfaceDirectory(tabId: UUID, surfaceId: UUID, directory: String) {
        sidebarGitMetadataService.updateSurfaceDirectory(
            workspaceId: tabId,
            panelId: surfaceId,
            directory: directory
        )
    }

    func updateSurfaceGitBranch(
        tabId: UUID,
        surfaceId: UUID,
        branch: String,
        isDirty: Bool?
    ) {
        sidebarGitMetadataService.updateSurfaceGitBranch(
            workspaceId: tabId,
            panelId: surfaceId,
            branch: branch,
            isDirty: isDirty
        )
    }

    func clearSurfaceGitBranch(tabId: UUID, surfaceId: UUID) {
        sidebarGitMetadataService.clearSurfaceGitBranch(workspaceId: tabId, panelId: surfaceId)
    }

    func updateSurfaceShellActivity(
        tabId: UUID,
        surfaceId: UUID,
        state: PanelShellActivityState
    ) {
        let shouldRefreshPullRequest = surfaceMetadata.applySurfaceShellActivity(
            tabId: tabId,
            surfaceId: surfaceId,
            state: state
        )
        if shouldRefreshPullRequest {
            pullRequestProbing.scheduleWorkspacePullRequestRefresh(
                workspaceId: tabId,
                panelId: surfaceId,
                reason: "shellPrompt"
            )
        }
    }

    func handleWorkspacePullRequestCommandHint(
        tabId: UUID,
        surfaceId: UUID,
        action: String,
        target: String?
    ) {
        pullRequestProbing.handleWorkspacePullRequestCommandHint(
            workspaceId: tabId,
            panelId: surfaceId,
            action: action,
            target: target
        )
    }


    func closeWorkspace(_ workspace: Workspace, recordHistory: Bool = true) {
        // Lifecycle execution lives in WorkspaceCloseCoordinator (CmuxWorkspaces);
        // the teardown effects invert back through WorkspaceCloseHosting below.
        workspaceClosing.closeWorkspace(workspace, recordHistory: recordHistory)
    }


    /// Detach a workspace from this window without closing its panels.
    /// Used by the socket API for cross-window moves.
    @discardableResult
    func detachWorkspace(tabId: UUID) -> Workspace? {
        workspaceClosing.detachWorkspace(tabId: tabId)
    }

    /// Attach an existing workspace to this window.
    func attachWorkspace(_ workspace: Workspace, at index: Int? = nil, select: Bool = true) {
        workspaceClosing.attachWorkspace(workspace, at: index, select: select)
    }

    // Keep closeTab as convenience alias
    func closeTab(_ tab: Workspace) { closeWorkspace(tab) }
    func closeCurrentTabWithConfirmation() { closeCurrentWorkspaceWithConfirmation() }

    func closeCurrentWorkspace() {
        guard let selectedId = selectedTabId,
              let workspace = tabs.first(where: { $0.id == selectedId }) else { return }
        closeWorkspace(workspace)
    }

    func closeCurrentPanelWithConfirmation() {
#if DEBUG
        UITestRecorder.incrementInt("closePanelInvocations")
#endif
        guard !workspaceClosing.isCloseConfirmationInFlight else { return }
        guard let selectedId = selectedTabId,
              let tab = tabs.first(where: { $0.id == selectedId }) else { return }
        reconcileFocusedPanelFromFirstResponderForKeyboard()
        guard let focusedPanelId = shortcutCloseTargetPanelId(in: tab) else { return }
        closePanelWithConfirmation(tab: tab, panelId: focusedPanelId)
    }

    func canCloseOtherTabsInFocusedPane() -> Bool {
        closeOtherTabsInFocusedPanePlan() != nil
    }

    func closeOtherTabsInFocusedPaneWithConfirmation() {
        guard !workspaceClosing.isCloseConfirmationInFlight else { return }
        guard let workspace = selectedWorkspace else { return }
        guard let plan = FocusedPaneCloseTargetPlanner(host: workspace).closeOtherTabsPlan() else { return }

        if CloseTabWarningStore(defaults: .standard).shouldConfirmClose(requiresConfirmation: true, source: .shortcut) {
            let prompt = CloseOtherTabsConfirmationPrompt(titles: plan.titles)
            guard workspaceClosing.confirmClose(
                title: prompt.title,
                message: prompt.message,
                acceptCmdD: false
            ) else { return }
        }

        for panelId in plan.panelIds {
            workspace.markCloseHistoryEligible(panelId: panelId)
            _ = workspace.closePanel(panelId, force: true)
        }
    }

    func closeCurrentWorkspaceWithConfirmation() {
#if DEBUG
        UITestRecorder.incrementInt("closeTabInvocations")
#endif
        guard !workspaceClosing.isCloseConfirmationInFlight else { return }
        let sidebarSelectionIds = workspaceClosing.orderedSidebarSelectedWorkspaceIds(
            sidebarSelectedWorkspaceIds: sidebarSelectedWorkspaceIds
        )
        if sidebarSelectionIds.count > 1 {
            closeWorkspacesWithConfirmation(sidebarSelectionIds, allowPinned: true)
            return
        }
        guard let selectedId = selectedTabId,
              let workspace = tabs.first(where: { $0.id == selectedId }) else { return }
        closeWorkspaceWithConfirmation(workspace)
    }

    func canCloseWorkspace(_ workspace: Workspace, allowPinned: Bool = false) -> Bool {
        allowPinned || !workspace.isPinned
    }

    // The single/batch close-with-confirmation decision flow lives in
    // WorkspaceCloseCoordinator (Close/WorkspaceCloseCoordinator+Confirmation.swift);
    // it drives the whole decision over the model + CloseConfirming seam and
    // inverts the AppKit window-close / remote-tmux-mark effects through this
    // window's WorkspaceCloseHosting witnesses. These entrypoints forward.

    @discardableResult
    func closeWorkspaceWithConfirmation(_ workspace: Workspace) -> Bool {
        workspaceClosing.closeWorkspaceWithConfirmation(workspace)
    }

    @discardableResult
    func closeWorkspaceFromCloseTabGesture(_ workspace: Workspace) -> Bool {
        workspaceClosing.closeWorkspaceFromCloseTabGesture(workspace)
    }

    @discardableResult
    func closeWorkspaceFromTabCloseButton(_ workspace: Workspace) -> Bool {
        workspaceClosing.closeWorkspaceFromTabCloseButton(workspace)
    }

    @discardableResult
    func closeWorkspaceWithConfirmation(tabId: UUID) -> Bool {
        guard let workspace = tabs.first(where: { $0.id == tabId }) else { return false }
        return closeWorkspaceWithConfirmation(workspace)
    }

    func setSidebarSelectedWorkspaceIds(_ workspaceIds: Set<UUID>) {
        let existingIds = Set(tabs.map(\.id))
        sidebarMultiSelection.replaceSelection(with: workspaceIds.intersection(existingIds))
    }

    func closeWorkspacesWithConfirmation(_ workspaceIds: [UUID], allowPinned: Bool) {
        workspaceClosing.closeWorkspacesWithConfirmation(workspaceIds, allowPinned: allowPinned)
    }

    func selectWorkspace(_ workspace: Workspace) {
#if DEBUG
        debugPrimeWorkspaceSwitchTrigger("select", to: workspace.id)
#endif
        selectWorkspaceId(workspace.id, notificationDismissalContext: .explicitWorkspaceResume)
    }

    // Keep selectTab as convenience alias
    func selectTab(_ tab: Workspace) { selectWorkspace(tab) }

    // MARK: - WorkspaceCloseHosting (WorkspaceCloseCoordinator's teardown seam)
    //
    // The close/detach/attach orchestration (order, model mutations, group
    // dissolve, selection-after-close index math) lives in
    // WorkspaceCloseCoordinator; these witnesses perform each app-coupled
    // teardown effect against the Workspace god object / AppDelegate, lifted
    // verbatim from the legacy in-class closeWorkspace/detachWorkspace/
    // attachWorkspace bodies.

    func recordWorkspaceCloseBreadcrumb(remainingTabCount: Int) {
        sentryBreadcrumb("workspace.close", data: ["tabCount": remainingTabCount])
    }

    func isRemoteTmuxMirror(_ tab: Workspace) -> Bool {
        tab.isRemoteTmuxMirror
    }

    func killRemoteTmuxMirror(_ tab: Workspace) {
        appEnvironment?.remoteTmuxController.handleWorkspaceClosed(workspaceId: tab.id)
    }

    func isRestorableInSessionSnapshot(_ tab: Workspace) -> Bool {
        tab.isRestorableInSessionSnapshot
    }

    func recordClosedWorkspaceHistory(_ tab: Workspace, index: Int) {
        // Prefer the warm cached agent index over a synchronous
        // RestorableAgentSessionIndex.load() (sysctl-per-record + disk) so closing a
        // workspace does not freeze the main thread; fall back to a fresh load only
        // while the cache has not loaded yet. See closedPanelHistoryEntry.
        let snapshot = tab.sessionSnapshot(
            includeScrollback: true,
            restorableAgentIndex: SharedLiveAgentIndex.shared.currentIndexSchedulingRefresh()
                ?? RestorableAgentSessionIndex.load()
        )
        closedItemHistory.push(.workspace(ClosedWorkspaceHistoryEntry(
            workspaceId: tab.id,
            windowId: appEnvironment?.windowRegistry.windowId(for: self),
            workspaceIndex: index,
            snapshot: snapshot
        )))
    }

    func clearWorkspaceGitProbes(workspaceId: UUID) {
        sidebarGitMetadataService.clearWorkspaceGitProbes(workspaceId: workspaceId)
    }

    func clearWorkspacePullRequestTracking(workspaceId: UUID) {
        pullRequestProbing.clearWorkspacePullRequestTracking(workspaceId: workspaceId)
    }

    func removeFromSidebarSelection(workspaceId: UUID) {
        sidebarMultiSelection.removeFromSelection(workspaceId)
    }

    func invalidateFocusHistoryTarget(workspaceId: UUID) {
        invalidateFocusHistoryTarget(workspaceId: workspaceId, panelId: nil)
    }

    func clearNotifications(workspaceId: UUID) {
        appEnvironment?.notificationStore?.clearNotifications(forTabId: workspaceId)
    }

    func teardownAllPanels(_ tab: Workspace) {
        tab.withClosedPanelHistorySuppressed {
            tab.teardownAllPanels()
        }
    }

    func teardownRemoteConnection(_ tab: Workspace) {
        tab.teardownRemoteConnection()
    }

    func unwireClosedBrowserTracking(_ tab: Workspace) {
        unwireClosedBrowserTracking(for: tab)
    }

    func wireClosedBrowserTracking(_ tab: Workspace) {
        wireClosedBrowserTracking(for: tab)
    }

    func removeClosedBrowserPanels(workspaceId: UUID) {
        browserModel.removeClosedBrowserPanels(forWorkspaceId: workspaceId)
    }

    func clearOwningTabManager(_ tab: Workspace) {
        tab.owningTabManager = nil
    }

    func setOwningTabManager(_ tab: Workspace) {
        tab.owningTabManager = self
    }

    func publishWorkspaceClosed(_ tab: Workspace) {
        publishCmuxWorkspaceClosed(tab)
    }

    func clearGroupMembership(_ tab: Workspace) {
        tab.groupId = nil
    }

    func forgetRememberedFocus(workspaceId: UUID) {
        focusedSurface.forgetRememberedFocus(workspaceId: workspaceId)
    }

    func addReplacementWorkspaceForEmptyWindow() {
        _ = addWorkspace()
    }

    func needsConfirmClose(_ tab: Workspace) -> Bool {
        workspaceNeedsConfirmClose(tab)
    }

    func markRemoteTmuxKillOnWindowClose() {
        guard let windowId = appEnvironment?.windowRegistry.windowId(for: self) else { return }
        appEnvironment?.remoteTmuxController.markKillSessionsOnWindowClose(windowId: windowId)
    }

    @discardableResult
    func closeWindow(containingWorkspaceId workspaceId: UUID) -> Bool {
        if let window {
            window.performClose(nil)
            return true
        }
        if let router = appEnvironment?.mainWindowRouter {
            router.closeWindowContaining(tabId: workspaceId)
            return true
        }
        return false
    }

    // MARK: Child-exit-path effects (legacy TabManager.closePanelAfterChildExited)
    // The routing decision + branch order lives in
    // WorkspaceCloseCoordinator+ChildExit (CmuxWorkspaces); these witnesses
    // perform each app-coupled read/effect against the Workspace god object /
    // AppDelegate, lifted verbatim from the legacy in-class body.
    // `closeRuntimeSurface(tabId:surfaceId:)` already exists above and witnesses
    // the protocol requirement directly.

    func keepsPersistentRemoteSurfaceOpenAfterChildExit(_ tab: Workspace, surfaceId: UUID) -> Bool {
        tab.shouldKeepPersistentRemoteSurfaceOpenAfterChildExit(surfaceId)
    }

    func shouldDemoteWorkspaceAfterChildExit(_ tab: Workspace, surfaceId: UUID) -> Bool {
        tab.shouldDemoteWorkspaceAfterChildExit(surfaceId: surfaceId)
    }

    func panelCount(_ tab: Workspace) -> Int {
        tab.panels.count
    }

    func markRemoteTerminalSessionEnded(_ tab: Workspace, surfaceId: UUID) {
        let relayPort: Int?
        if tab.remoteConfiguration?.transport == .ssh {
            relayPort = tab.remoteConfiguration?.relayPort
        } else {
            relayPort = nil
        }
        tab.markRemoteTerminalSessionEnded(
            surfaceId: surfaceId,
            relayPort: relayPort,
            allowUntracked: !tab.isRemoteTerminalSurface(surfaceId)
        )
    }

    func markPersistentRemotePTYAttachFailed(_ tab: Workspace, surfaceId: UUID) {
        tab.markPersistentRemotePTYAttachFailed(surfaceId: surfaceId)
    }

    @discardableResult
    func closeWindowForLastChildExit(workspaceId: UUID) -> Bool {
        guard let appEnvironment else { return false }
        appEnvironment.notificationStore?.clearNotifications(forTabId: workspaceId)
        appEnvironment.mainWindowRouter.closeWindowContaining(tabId: workspaceId, recordHistory: false)
        return true
    }

    func logChildExitCloseDecision(
        _ tab: Workspace,
        surfaceId: UUID,
        workspaceCount: Int,
        handlesRemoteExitThroughWorkspace: Bool,
        keepsPersistentRemoteSurfaceOpen: Bool
    ) {
#if DEBUG
        cmuxDebugLog(
            "surface.close.childExited tab=\(tab.id.uuidString.prefix(5)) " +
            "surface=\(surfaceId.uuidString.prefix(5)) panels=\(tab.panels.count) workspaces=\(workspaceCount) " +
            "remoteWorkspace=\(tab.isRemoteWorkspace ? 1 : 0) keepRemote=\(handlesRemoteExitThroughWorkspace ? 1 : 0) " +
            "keepPersistentRemote=\(keepsPersistentRemoteSurfaceOpen ? 1 : 0)"
        )
#endif
    }

    // MARK: - WorkspaceCreationHosting (WorkspaceCreationCoordinator's effect seam)
    // The creation orchestration lives in WorkspaceCreationCoordinator; these
    // witnesses perform each app-coupled effect against the Workspace god object /
    // AppDelegate, lifted verbatim from the legacy in-class addWorkspace body.
    // Shared inheritance helpers (makeWorkspaceForCreation /
    // applyCreationChromeInheritance / etc.) stay in the class body for
    // TabManager+DetachedWorkspace and the test subclasses; these forward to them.
    // See TabManager+WorkspaceCreationHosting.swift for the full mapping.

    func creationSourceWorkspace() -> Workspace? {
        selectedWorkspace
    }

    func implicitWorkingDirectory(inheritWorkingDirectory: Bool, from source: Workspace?) -> String? {
        inheritWorkingDirectory
            ? implicitWorkingDirectoryForNewWorkspace(from: source)
            : nil
    }

    func inheritedTerminalFontPoints(from source: Workspace?) -> Float? {
        inheritedTerminalFontPointsForNewWorkspace(workspace: source)
    }

    func recordWorkspaceCreateBreadcrumb(tabCount: Int) {
        sentryBreadcrumb("workspace.create", data: ["tabCount": tabCount])
    }

    func terminalDefaultWorkspaceTitle(tabNumber: Int) -> String {
        "Terminal \(tabNumber)"
    }

    func browserDefaultWorkspaceTitle() -> String {
        // Match the browser surface's blank new-tab title; the
        // single-panel title sync keeps the workspace title following
        // the page title once the user navigates.
        String(localized: "browser.newTab", defaultValue: "New tab")
    }

    func makeWorkspaceForCreation(
        title: String,
        explicitTitle: String?,
        workingDirectory: String?,
        portOrdinal: Int,
        inheritedTerminalFontPoints: Float?,
        initialSurface: NewWorkspaceInitialSurface,
        initialTerminalCommand: String?,
        initialTerminalInput: String?,
        initialTerminalEnvironment: [String: String],
        workspaceEnvironment: [String: String],
        chromeInheritanceSource: Workspace?
    ) -> Workspace {
        let inheritedConfig = workspaceCreationConfigTemplate(
            inheritedTerminalFontPoints: inheritedTerminalFontPoints
        )
        let newWorkspace = makeWorkspaceForCreation(
            title: title,
            workingDirectory: workingDirectory,
            portOrdinal: portOrdinal,
            configTemplate: inheritedConfig,
            initialSurface: initialSurface,
            initialTerminalCommand: initialTerminalCommand,
            initialTerminalInput: initialTerminalInput,
            initialTerminalEnvironment: initialTerminalEnvironment,
            workspaceEnvironment: workspaceEnvironment
        )
        applyCreationChromeInheritance(
            to: newWorkspace,
            from: chromeInheritanceSource
        )
        newWorkspace.owningTabManager = self
        if explicitTitle != nil {
            newWorkspace.setCustomTitle(explicitTitle)
        }
        wireClosedBrowserTracking(for: newWorkspace)
        return newWorkspace
    }

    func nextPortOrdinal() -> Int {
        portOrdinalAllocator.next()
    }

    func requestBackgroundWorkspaceLoad(workspaceId: UUID) {
        requestBackgroundWorkspaceLoad(for: workspaceId)
    }

    func scheduleInitialWorkspaceGitMetadataRefreshIfPossible(_ tab: Workspace) {
        if let terminalPanel = tab.focusedTerminalPanel {
            scheduleInitialWorkspaceGitMetadataRefreshIfPossible(
                workspaceId: tab.id,
                panelId: terminalPanel.id
            )
        }
    }

    func requestBackgroundSurfaceStartIfNeeded(_ tab: Workspace) {
        tab.focusedTerminalPanel?.surface.requestBackgroundSurfaceStartIfNeeded()
    }

    func publishWorkspaceCreated(_ tab: Workspace, selected: Bool) {
        publishCmuxWorkspaceCreated(tab, selected: selected)
    }

    func publishInitialSurfaceCreated(_ tab: Workspace, selected: Bool) {
        publishCmuxInitialSurfaceCreated(tab, selected: selected)
    }

    func postDidFocusTab(workspaceId: UUID) {
        NotificationCenter.default.post(
            name: .ghosttyDidFocusTab,
            object: nil,
            userInfo: [GhosttyNotificationKey.tabId: workspaceId]
        )
    }

    func shouldSendWelcomeCommand() -> Bool {
        !UserDefaults.standard.bool(forKey: AccountCatalogSection().welcomeShown.userDefaultsKey)
    }

    func sendWelcomeCommandWhenReady(to tab: Workspace) {
        if let appDelegate = AppDelegate.shared {
            appDelegate.sendWelcomeCommandWhenReady(to: tab, markShownOnSend: true)
        } else {
            sendWelcomeWhenReady(to: tab)
        }
    }

#if DEBUG
    func debugPrimeWorkspaceSwitchTrigger(to workspaceId: UUID) {
        debugPrimeWorkspaceSwitchTrigger("create", to: workspaceId)
    }

    func recordAddTabUITestTelemetry(tabCount: Int, selectedTabId: String) {
        UITestRecorder.incrementInt("addTabInvocations")
        UITestRecorder.record([
            "tabCount": String(tabCount),
            "selectedTabId": selectedTabId
        ])
    }
#endif

    private func closeOtherTabsInFocusedPanePlan() -> CloseOtherTabsInFocusedPanePlan? {
        guard let workspace = selectedWorkspace else { return nil }
        return FocusedPaneCloseTargetPlanner(host: workspace).closeOtherTabsPlan()
    }

    private func shouldCloseWorkspaceOnLastSurfaceShortcut(_ workspace: Workspace, panelId: UUID) -> Bool {
        FocusedPaneCloseTargetPlanner(host: workspace).shouldCloseWorkspaceOnLastSurfaceShortcut(
            panelId: panelId,
            keepWorkspaceOpenWhenClosingLastSurface:
                settings.value(for: settingsCatalog.app.keepWorkspaceOpenWhenClosingLastSurface)
        )
    }

    private func closePanelWithConfirmation(tab: Workspace, panelId: UUID) {
        guard tab.panels[panelId] != nil else {
#if DEBUG
            cmuxDebugLog(
                "surface.close.shortcut.skip tab=\(tab.id.uuidString.prefix(5)) " +
                "panel=\(panelId.uuidString.prefix(5)) reason=missingPanel"
            )
#endif
            return
        }

        let bonsplitTabCount = tab.bonsplitController.allPaneIds.reduce(0) { partial, paneId in
            partial + tab.bonsplitController.tabs(inPane: paneId).count
        }
        let panelKind: String = {
            guard let panel = tab.panels[panelId] else { return "missing" }
            if panel is TerminalPanel { return "terminal" }
            if panel is BrowserPanel { return "browser" }
            return String(describing: type(of: panel))
        }()
        let closesWorkspaceOnLastSurfaceShortcut = shouldCloseWorkspaceOnLastSurfaceShortcut(tab, panelId: panelId)
#if DEBUG
        cmuxDebugLog(
            "surface.close.shortcut.begin tab=\(tab.id.uuidString.prefix(5)) " +
            "panel=\(panelId.uuidString.prefix(5)) kind=\(panelKind) " +
            "panelCount=\(tab.panels.count) bonsplitTabs=\(bonsplitTabCount) " +
            "closeWorkspaceOnLastSurface=\(closesWorkspaceOnLastSurfaceShortcut ? 1 : 0)"
        )
#endif

        // The last-surface shortcut preference only affects the Close Tab shortcut path.
        // The tab close button continues to use Workspace's explicit-close path when it
        // closes the last surface.
        if closesWorkspaceOnLastSurfaceShortcut,
           let surfaceId = tab.surfaceIdFromPanelId(panelId) {
            tab.markExplicitClose(surfaceId: surfaceId)
        }
        tab.markCloseHistoryEligible(panelId: panelId)
        let closed = tab.closePanel(panelId)
#if DEBUG
        cmuxDebugLog(
            "surface.close.shortcut tab=\(tab.id.uuidString.prefix(5)) " +
            "panel=\(panelId.uuidString.prefix(5)) closed=\(closed ? 1 : 0) " +
            "panelsAfterCall=\(tab.panels.count)"
        )
#endif
    }

    private func shortcutCloseTargetPanelId(in workspace: Workspace) -> UUID? {
        FocusedPaneCloseTargetPlanner(host: workspace).shortcutCloseTargetPanelId()
    }

    func closePanelWithConfirmation(tabId: UUID, surfaceId: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return }
        closePanelWithConfirmation(tab: tab, panelId: surfaceId)
    }

    /// Runtime close requests from Ghostty should only ever target the specific surface.
    /// They must not escalate into workspace/window-close semantics for "last tab".
    func closeRuntimeSurfaceWithConfirmation(tabId: UUID, surfaceId: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return }
        guard tab.panels[surfaceId] != nil else { return }

        let requiresConfirmation: Bool
        if let terminalPanel = tab.terminalPanel(for: surfaceId),
           tab.panelNeedsConfirmClose(panelId: surfaceId, fallbackNeedsConfirmClose: terminalPanel.needsConfirmClose()) {
            requiresConfirmation = true
        } else {
            requiresConfirmation = false
        }

        if CloseTabWarningStore(defaults: .standard).shouldConfirmClose(
            requiresConfirmation: requiresConfirmation,
            source: .shortcut
        ) {
            guard workspaceClosing.confirmClose(
                title: String(localized: "dialog.closeTab.title", defaultValue: "Close tab?"),
                message: String(localized: "dialog.closeTab.message", defaultValue: "This will close the current tab."),
                acceptCmdD: false
            ) else { return }
        }

        _ = tab.closePanel(surfaceId, force: true)
        appEnvironment?.notificationStore?.clearNotifications(forTabId: tab.id, surfaceId: surfaceId)
    }

    /// Runtime close requests from Ghostty without confirmation (e.g. child-exit).
    /// This path must only close the addressed surface and must never close the workspace window.
    func closeRuntimeSurface(tabId: UUID, surfaceId: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return }
        guard tab.panels[surfaceId] != nil else { return }

#if DEBUG
        cmuxDebugLog(
            "surface.close.runtime tab=\(tabId.uuidString.prefix(5)) " +
            "surface=\(surfaceId.uuidString.prefix(5)) panelsBefore=\(tab.panels.count)"
        )
#endif

        // Keep AppKit first responder in sync with workspace focus before routing the close.
        // If split reparenting caused a temporary model/view mismatch, fallback close logic in
        // Workspace.closePanel uses focused selection to resolve the correct tab deterministically.
        reconcileFocusedPanelFromFirstResponderForKeyboard()
        let closed = tab.closePanel(surfaceId, force: true)
#if DEBUG
        cmuxDebugLog(
            "surface.close.runtime.done tab=\(tabId.uuidString.prefix(5)) " +
            "surface=\(surfaceId.uuidString.prefix(5)) closed=\(closed ? 1 : 0) panelsAfter=\(tab.panels.count)"
        )
#endif
        appEnvironment?.notificationStore?.clearNotifications(forTabId: tab.id, surfaceId: surfaceId)
    }

    /// Close a panel because its child process exited (e.g. the user hit Ctrl+D).
    ///
    /// This should never prompt: the process is already gone, and Ghostty emits the
    /// `SHOW_CHILD_EXITED` action specifically so the host app can decide what to do.
    func closePanelAfterChildExited(tabId: UUID, surfaceId: UUID) {
        // Routing decision + branch order lives in WorkspaceCloseCoordinator
        // (CmuxWorkspaces, Close/WorkspaceCloseCoordinator+ChildExit.swift); the
        // app-coupled reads/effects invert back through the child-exit
        // WorkspaceCloseHosting witnesses above.
        workspaceClosing.closePanelAfterChildExited(tabId: tabId, surfaceId: surfaceId)
    }

    private func workspaceNeedsConfirmClose(_ workspace: Workspace) -> Bool {
        FocusedPaneCloseTargetPlanner(host: workspace).workspaceNeedsConfirmClose()
    }

    func titleForTab(_ tabId: UUID) -> String? {
        surfaceMetadata.titleForTab(tabId)
    }

    // MARK: - Panel/Surface ID Access

    /// Returns the focused panel ID for a tab (forwards to `PanelIdResolver`).
    func focusedPanelId(for tabId: UUID) -> UUID? {
        panelIdResolver.focusedPanelId(forWorkspaceId: tabId)
    }

    /// Returns the focused panel if it's a BrowserPanel, nil otherwise
    var focusedBrowserPanel: BrowserPanel? {
        guard let tab = selectedWorkspace,
              let panelId = tab.focusedPanelId else { return nil }
        return tab.panels[panelId] as? BrowserPanel
    }

    /// Returns the focused panel if it's a MarkdownPanel showing the rendered
    /// preview, nil otherwise. Zoom applies to the preview WKWebView, so the raw
    /// text-edit mode is deliberately excluded.
    var focusedMarkdownPanel: MarkdownPanel? {
        guard let tab = selectedWorkspace,
              let panelId = tab.focusedPanelId,
              let panel = tab.panels[panelId] as? MarkdownPanel,
              panel.displayMode == .preview else { return nil }
        return panel
    }

    // The focused-browser/markdown zoom, focus-mode, developer-tools, and
    // omnibar commands forward to `focusedBrowserController` (CmuxBrowser),
    // which resolves the focused panel through this window's
    // `focusedBrowserPanel`/`focusedMarkdownPanel` and acts through the
    // `FocusedBrowserActing`/`FocusedMarkdownZooming` seams.
    @discardableResult
    func zoomInFocusedBrowser() -> Bool {
        focusedBrowserController.zoomInFocusedBrowser()
    }

    @discardableResult
    func zoomOutFocusedBrowser() -> Bool {
        focusedBrowserController.zoomOutFocusedBrowser()
    }

    @discardableResult
    func resetZoomFocusedBrowser() -> Bool {
        focusedBrowserController.resetZoomFocusedBrowser()
    }

    var canToggleBrowserFocusModeForFocusedBrowser: Bool {
        focusedBrowserController.canToggleBrowserFocusModeForFocusedBrowser
    }

    @discardableResult
    func toggleBrowserFocusModeForFocusedBrowser(reason: String) -> Bool {
        focusedBrowserController.toggleBrowserFocusModeForFocusedBrowser(reason: reason)
    }

    @discardableResult
    func setFocusedBrowserFocusModeActive(_ active: Bool, reason: String) -> Bool {
        focusedBrowserController.setFocusedBrowserFocusModeActive(active, reason: reason)
    }

    @discardableResult
    func zoomInFocusedMarkdown() -> Bool {
        focusedBrowserController.zoomInFocusedMarkdown()
    }

    @discardableResult
    func zoomOutFocusedMarkdown() -> Bool {
        focusedBrowserController.zoomOutFocusedMarkdown()
    }

    @discardableResult
    func resetZoomFocusedMarkdown() -> Bool {
        focusedBrowserController.resetZoomFocusedMarkdown()
    }

    @discardableResult
    func toggleDeveloperToolsFocusedBrowser() -> Bool {
        focusedBrowserController.toggleDeveloperToolsFocusedBrowser()
    }

    @discardableResult
    func showJavaScriptConsoleFocusedBrowser() -> Bool {
        focusedBrowserController.showJavaScriptConsoleFocusedBrowser()
    }

    @discardableResult
    func toggleOmnibarFocusedBrowser() -> Bool {
        focusedBrowserController.toggleOmnibarFocusedBrowser()
    }

    @discardableResult
    func toggleReactGrabFromCurrentFocus() -> Bool {
        guard let workspace = selectedWorkspace else { return false }
        return toggleReactGrab(in: workspace, browserSurfaceId: nil, returnTerminalSurfaceId: nil) != nil
    }

    /// Toggles React Grab for a specific workspace. When `browserSurfaceId`/`returnTerminalSurfaceId`
    /// are nil this mirrors the keyboard shortcut: it resolves the browser + return terminal from the
    /// focused panel layout. An explicit browser surface (must be a browser) or return terminal
    /// (must be a terminal) overrides that route. Used by both the Cmd+Shift+G shortcut and the
    /// `cmux browser react-grab toggle` CLI command so both share one action path.
    /// Returns the resolved browser surface id it acted on, or nil if it could not resolve/act
    /// (so callers can report the actual browser surface rather than the focused panel).
    ///
    /// The resolution + toggle orchestration lives in `reactGrabController`
    /// (CmuxBrowser); `Workspace` conforms to `ReactGrabWorkspaceContext` so the
    /// controller drives it without importing the app target.
    @discardableResult
    func toggleReactGrab(
        in workspace: Workspace,
        browserSurfaceId: UUID?,
        returnTerminalSurfaceId: UUID?
    ) -> UUID? {
        reactGrabController.toggleReactGrab(
            in: workspace,
            browserSurfaceId: browserSurfaceId,
            returnTerminalSurfaceId: returnTerminalSurfaceId
        )
    }

    /// Backwards compatibility: returns the focused surface ID
    func focusedSurfaceId(for tabId: UUID) -> UUID? {
        focusedPanelId(for: tabId)
    }

    func rememberFocusedSurface(tabId: UUID, surfaceId: UUID) {
        focusedSurface.rememberFocusedSurface(workspaceId: tabId, surfaceId: surfaceId)
    }

    func applyWindowBackgroundForSelectedTab() {
        guard let selectedTabId,
              let tab = tabs.first(where: { $0.id == selectedTabId }),
              let terminalPanel = tab.focusedTerminalPanel else { return }
        terminalPanel.applyWindowBackgroundIfActive()
    }

    func applyWindowBackdropModeForAllTabs(reason: String) {
        let backgroundColor = GhosttyApp.shared.defaultBackgroundColor
        let backgroundOpacity = GhosttyApp.shared.defaultBackgroundOpacity
        for tab in tabs {
            tab.applyGhosttyChrome(
                backgroundColor: backgroundColor,
                backgroundOpacity: backgroundOpacity,
                reason: reason
            )
        }
        applyWindowBackgroundForSelectedTab()
    }

    func completePendingWorkspaceUnfocus(reason: String) {
        focusedSurface.completePendingWorkspaceUnfocus(reason: reason)
    }

    /// Legacy static decision predicate retained for the app-host unit tests
    /// that call `TabManager.shouldUnfocusPendingWorkspace`; forwards to the
    /// model's owning copy (CmuxWorkspaces).
    static func shouldUnfocusPendingWorkspace(pendingTabId: UUID, selectedTabId: UUID?) -> Bool {
        FocusedSurfaceModel.shouldUnfocusPendingWorkspace(
            pendingTabId: pendingTabId,
            selectedTabId: selectedTabId
        )
    }

    // MARK: Notification dismissal (CmuxNotifications)
    //
    // The dismissal decision flow lives in NotificationDismissalModel;
    // TabManager hosts its seam (TabManager+NotificationDismissalHosting)
    // and forwards the legacy entry points below.

    /// Selects `workspaceId` for the `CmuxBrowser` ``BrowserOpenCoordinator``'s
    /// open flow, satisfying `BrowserOpenHosting.selectWorkspaceForBrowserOpen`.
    /// A narrow internal wrapper co-located with the `private selectWorkspaceId`
    /// it forwards to, so the private selection flow (and its app-side
    /// notification-store dismissal) stays private. Byte-faithful to the legacy
    /// `openBrowser` body's
    /// `selectWorkspaceId(tabId, notificationDismissalContext: .explicitWorkspaceResume)`.
    func selectWorkspaceForBrowserOpen(_ workspaceId: UUID) {
        selectWorkspaceId(workspaceId, notificationDismissalContext: .explicitWorkspaceResume)
    }

    // Narrow internal entry point witnessing the `CmuxBrowser`
    // ``ClosedBrowserPanelReopenHosting`` `selectWorkspaceForBrowserReopen(_:)`
    // requirement, co-located with the `private selectWorkspaceId(_:notification…)`
    // it wraps so that private selection flow — and its app-side notification-store
    // dismissal — stays private rather than widening to internal. Identical to the
    // legacy reopen body's
    // `selectWorkspaceId(_, notificationDismissalContext: .explicitWorkspaceResume)`.
    func selectWorkspaceForBrowserReopen(_ workspaceId: UUID) {
        selectWorkspaceId(workspaceId, notificationDismissalContext: .explicitWorkspaceResume)
    }

    private func selectWorkspaceId(
        _ tabId: UUID,
        notificationDismissalContext: NotificationDismissalContext?
    ) {
        guard selectedTabId != tabId else {
            notificationDismissal.setPendingSelectionContext(nil)
            if let notificationDismissalContext {
                notificationDismissal.dismissFocusedPanelNotificationIfActive(
                    workspaceId: tabId,
                    context: notificationDismissalContext
                )
            }
            return
        }

        notificationDismissal.setPendingSelectionContext(notificationDismissalContext)
        selectedTabId = tabId
    }

    private func dismissFocusedPanelNotificationIfActive(
        tabId: UUID,
        context: NotificationDismissalContext = .activeFocus
    ) {
        notificationDismissal.dismissFocusedPanelNotificationIfActive(workspaceId: tabId, context: context)
    }

    private func dismissPanelNotificationOnFocus(tabId: UUID, panelId: UUID, explicitFocusIntent: Bool) {
        notificationDismissal.dismissPanelNotificationOnFocus(
            workspaceId: tabId,
            panelId: panelId,
            explicitFocusIntent: explicitFocusIntent
        )
    }

    @discardableResult
    func dismissNotificationOnDirectInteraction(tabId: UUID, surfaceId: UUID?) -> Bool {
        notificationDismissal.dismissNotificationOnDirectInteraction(workspaceId: tabId, surfaceId: surfaceId)
    }

    @discardableResult
    func dismissNotificationOnTerminalInteraction(tabId: UUID, surfaceId: UUID?) -> Bool {
        notificationDismissal.dismissNotificationOnTerminalInteraction(workspaceId: tabId, surfaceId: surfaceId)
    }


    private func enqueuePanelTitleUpdate(tabId: UUID, panelId: UUID, title: String) {
        surfaceMetadata.enqueuePanelTitleUpdate(tabId: tabId, panelId: panelId, title: title)
    }

    func focusedSurfaceTitleDidChange(tabId: UUID) {
        surfaceMetadata.focusedSurfaceTitleDidChange(tabId: tabId)
    }

    /// Flushes any coalesced panel-title updates immediately so a workspace
    /// snapshot (e.g. move-tab-to-new-workspace) captures the current titles
    /// rather than stale pre-coalesce ones. Forwards to the metadata coordinator
    /// that owns the title-update coalescer (`panelTitleUpdateCoalescer` on the
    /// pre-refactor `TabManager`).
    func flushPendingPanelTitleUpdatesForWorkspaceSnapshot() {
        surfaceMetadata.flushPendingPanelTitleUpdates()
    }

    // MARK: SurfaceMetadataTitleHosting (panel-title app effects)
    // Witnesses live here in the class body because they touch the selected
    // workspace's `NSWindow` title chrome and the DEBUG id/title formatters; the
    // conformance is bound by the extension below. The panel-title coalescer
    // now lives in the coordinator (CmuxWorkspaces), so it is no longer hosted
    // here.

    func surfaceMetadataUpdateWindowTitleIfSelected(workspaceId: UUID) {
        guard selectedTabId == workspaceId,
              let tab = tabs.first(where: { $0.id == workspaceId }) else { return }
        updateWindowTitle(for: tab)
    }

    func surfaceMetadataLogPanelTitleEnqueue(workspaceId: UUID, panelId: UUID, title: String) {
#if DEBUG
        workspaceSwitchDebug.logPanelTitleEnqueue(workspaceId: workspaceId, panelId: panelId, title: title)
#endif
    }

    func focusTab(
        _ tabId: UUID,
        surfaceId: UUID? = nil,
        suppressFlash: Bool = false,
        focusIntent: PanelFocusIntent? = nil,
        dismissRestoredUnreadOnResume: Bool? = nil
    ) {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return }
        let targetPanelId = surfaceId.flatMap { panelId(forSurfaceOrPanelId: $0, in: tab) }
        if let targetPanelId {
            // Keep selected-surface intent stable across selectedTabId didSet async restore.
            focusedSurface.rememberFocusedSurface(workspaceId: tabId, surfaceId: targetPanelId)
        }
        let shouldDismissRestoredUnread = dismissRestoredUnreadOnResume ?? !suppressFlash
        let dismissalContext: NotificationDismissalContext? = shouldDismissRestoredUnread ? .explicitWorkspaceResume : nil
        let shouldDeferSelectedWorkspaceDismissal =
            selectedTabId == tabId &&
            targetPanelId.map { $0 != focusedPanelId(for: tabId) } == true
#if DEBUG
        debugPrimeWorkspaceSwitchTrigger("focus", to: tabId)
#endif
        selectWorkspaceId(
            tabId,
            notificationDismissalContext: shouldDeferSelectedWorkspaceDismissal ? nil : dismissalContext
        )
        NotificationCenter.default.post(
            name: .ghosttyDidFocusTab,
            object: nil,
            userInfo: [GhosttyNotificationKey.tabId: tabId]
        )

        if let surfaceId {
            let focusPanelId = targetPanelId ?? surfaceId
            if !suppressFlash {
                focusSurface(tabId: tabId, surfaceId: focusPanelId)
            } else {
                tab.focusPanel(focusPanelId, focusIntent: focusIntent)
            }
            if let dismissalContext {
                _ = notificationDismissal.dismissNotification(
                    workspaceId: tabId,
                    surfaceId: surfaceId,
                    context: dismissalContext
                )
            }
        }
    }

    @discardableResult
    func focusTabFromNotification(_ tabId: UUID, surfaceId: UUID? = nil) -> Bool {
        guard let tab = tabs.first(where: { $0.id == tabId }) else {
#if DEBUG
            cmuxDebugLog("notification.focus.fail tab=\(tabId.uuidString.prefix(5)) reason=missingTab")
#endif
            return false
        }
        let requestedPanelId = surfaceId.flatMap { panelId(forSurfaceOrPanelId: $0, in: tab) }
        if let surfaceId, requestedPanelId == nil {
#if DEBUG
            cmuxDebugLog("notification.focus.fail tab=\(tabId.uuidString.prefix(5)) panel=\(surfaceId.uuidString.prefix(5)) reason=missingPanel")
#endif
            return false
        }
        let desiredPanelId = requestedPanelId ?? tab.focusedPanelId
#if DEBUG
        if let desiredPanelId {
            AppDelegate.shared?.armJumpUnreadFocusRecord(tabId: tabId, surfaceId: desiredPanelId)
        }
#endif
        // Jump-to-unread should reveal the destination pane instead of keeping an old split-zoom
        // state active around it.
        tab.clearSplitZoom()
        notificationDismissal.setSuppressesFocusFlash(true)
        focusTab(tabId, surfaceId: desiredPanelId, suppressFlash: true)
        notificationDismissal.setSuppressesFocusFlash(false)

        if let targetPanelId = desiredPanelId ?? tab.focusedPanelId,
           tab.panels[targetPanelId] != nil {
            _ = dismissNotificationOnDirectInteraction(tabId: tabId, surfaceId: targetPanelId)
        }
        return true
    }

    func focusSurface(tabId: UUID, surfaceId: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return }
        tab.focusPanel(panelId(forSurfaceOrPanelId: surfaceId, in: tab) ?? surfaceId)
    }

    func panelId(forSurfaceOrPanelId surfaceOrPanelId: UUID, in workspace: Workspace) -> UUID? {
        panelIdResolver.panelId(forSurfaceOrPanelId: surfaceOrPanelId, in: workspace)
    }

    func selectNextTab() {
        workspaceSelection.selectNextTab()
    }

    func selectPreviousTab() {
        workspaceSelection.selectPreviousTab()
    }

    // MARK: WorkspaceSelectionHosting (selection-navigation app effects)
    // Witnesses live here in the class body because they touch the `private`
    // `selectWorkspaceId` mutation chain, the `private` DEBUG switch-trace
    // helpers, and the `private` DEBUG switch-id/start-time state; the
    // conformance is bound by TabManager+WorkspaceSelectionHosting.swift.

    func selectWorkspaceFromNavigation(id: UUID) {
        selectWorkspaceId(id, notificationDismissalContext: .explicitWorkspaceResume)
    }

    /// Reduce sidebar multi-selection to a single workspace (or clear if
    /// `except` isn't a known tab). Called from keyboard-nav paths so a
    /// stale Shift-click range doesn't survive after the user moves focus.
    /// Posts the should-collapse event so the SwiftUI binding
    /// in ContentView (a @State Set<UUID> separate from this tab manager)
    /// can collapse to the focused workspace too.
    func collapseSidebarMultiSelection(except workspaceId: UUID) {
        sidebarMultiSelection.collapseSelection(
            to: workspaceId,
            isKnownWorkspace: tabs.contains(where: { $0.id == workspaceId })
        )
    }

    func debugPrimeWorkspaceSwitch(trigger: String, to target: UUID?) {
#if DEBUG
        debugPrimeWorkspaceSwitchTrigger(trigger, to: target)
#endif
    }

    func debugPrepareWorkspaceSwitch(trigger: String, from: UUID?, to: UUID?) {
#if DEBUG
        workspaceSwitchDebug.prepareSwitch(
            trigger,
            from: from,
            to: to,
            isCycleHot: isWorkspaceCycleHot,
            tabCount: tabs.count
        )
#endif
    }

    func debugLogWorkspaceCycleHotOn(generation: UInt64) {
#if DEBUG
        workspaceSwitchDebug.logCycleHotOn(generation: generation)
#endif
    }

    func debugLogWorkspaceCycleHotCancelPrevious(generation: UInt64) {
#if DEBUG
        workspaceSwitchDebug.logCycleHotCancelPrevious(generation: generation)
#endif
    }

    func debugLogWorkspaceCycleHotCooldownCanceled(generation: UInt64) {
#if DEBUG
        workspaceSwitchDebug.logCycleHotCooldownCanceled(generation: generation)
#endif
    }

    func debugLogWorkspaceCycleHotOff(generation: UInt64) {
#if DEBUG
        workspaceSwitchDebug.logCycleHotOff(generation: generation)
#endif
    }

#if DEBUG
    func debugCurrentWorkspaceSwitchSnapshot() -> (id: UInt64, startedAt: CFTimeInterval)? {
        workspaceSwitchDebug.currentSwitchSnapshot()
    }

    func debugPrimeWorkspaceSwitchTrigger(_ trigger: String, to target: UUID?) {
        workspaceSwitchDebug.primeSwitchTrigger(trigger, to: target, currentSelected: selectedTabId)
    }
#endif

    func selectTab(at index: Int) {
        workspaceSelection.selectTab(at: index)
    }

    func selectLastTab() {
        workspaceSelection.selectLastTab()
    }

    // MARK: - Surface Navigation

    /// Select the next surface in the currently focused pane of the selected workspace
    func selectNextSurface() {
        surfaceSplit.selectNextSurface()
    }

    /// Select the previous surface in the currently focused pane of the selected workspace
    func selectPreviousSurface() {
        surfaceSplit.selectPreviousSurface()
    }

    /// Select a surface by index in the currently focused pane of the selected workspace
    func selectSurface(at index: Int) {
        surfaceSplit.selectSurface(at: index)
    }

    /// Select the last surface in the currently focused pane of the selected workspace
    func selectLastSurface() {
        surfaceSplit.selectLastSurface()
    }

    /// Create a new terminal surface in the focused pane of the selected workspace
    func newSurface() {
        surfaceSplit.newSurface()
    }

    func newSurface(initialInput: String) {
        surfaceSplit.newSurface(initialInput: initialInput)
    }

    // MARK: - Split Creation

    /// Create a new split in the current tab
    @discardableResult
    func createSplit(direction: SplitDirection) -> UUID? {
        surfaceSplit.createSplit(direction: direction)
    }

    /// Create a new split from an explicit source panel.
    @discardableResult
    func createSplit(tabId: UUID, surfaceId: UUID, direction: SplitDirection, focus: Bool = true) -> UUID? {
        surfaceSplit.createSplit(tabId: tabId, surfaceId: surfaceId, direction: direction, focus: focus)
    }

    /// Create a new browser split from the currently focused panel.
    @discardableResult
    func createBrowserSplit(direction: SplitDirection, url: URL? = nil) -> UUID? {
        guard let selectedTabId,
              let tab = tabs.first(where: { $0.id == selectedTabId }),
              let focusedPanelId = tab.focusedPanelId else { return nil }
        tab.clearSplitZoom()
        return newBrowserSplit(
            tabId: selectedTabId,
            fromPanelId: focusedPanelId,
            orientation: direction.orientation,
            insertFirst: direction.insertFirst,
            url: url
        )
    }

    /// Refresh Bonsplit right-side action button tooltips for all workspaces.
    func refreshSplitButtonTooltips() {
        for workspace in tabs {
            workspace.refreshSplitButtonTooltips()
        }
    }

    func refreshTabCloseButtonVisibility() {
        for workspace in tabs {
            workspace.refreshTabCloseButtonVisibility()
        }
    }

    func applySurfaceTabBarButtons(
        _ buttons: [CmuxSurfaceTabBarButton],
        sourcePath: String?,
        globalConfigPath: String,
        terminalCommandSourcePaths: [String: String],
        workspaceCommands: [String: CmuxResolvedCommand]
    ) {
        for workspace in tabs {
            workspace.applySurfaceTabBarButtons(
                buttons,
                sourcePath: sourcePath,
                globalConfigPath: globalConfigPath,
                terminalCommandSourcePaths: terminalCommandSourcePaths,
                workspaceCommands: workspaceCommands
            )
        }
    }

    // MARK: - Pane Focus Navigation

    /// Move focus to an adjacent pane in the specified direction
    func movePaneFocus(direction: NavigationDirection) {
        guard let selectedTabId,
              let tab = tabs.first(where: { $0.id == selectedTabId }) else { return }
        tab.moveFocus(direction: direction)
    }

    // MARK: - Focus History Navigation (CmuxWorkspaceNavigation)

    // The back/forward stack, suppression depth, navigation logic, recording
    // suppression, and the current-entry resolution all live in
    // FocusHistoryModel; these forwarders keep every existing app/test
    // entrypoint (menus, shortcuts, titlebar buttons, socket commands)
    // unchanged. `withFocusHistoryRecordingSuppressed` and
    // `currentFocusHistoryEntry` had no callers outside TabManager, so their
    // few internal uses now call `focusHistoryNavigation` directly and the
    // pass-through forwarders are gone.

    func invalidateFocusHistoryTarget(workspaceId: UUID, panelId: UUID?) {
        focusHistoryNavigation.invalidateFocusHistoryTarget(workspaceId: workspaceId, panelId: panelId)
    }

    // `panelIdForFocusHistorySurface` (the surface->panel translation the
    // focus-surface observer feeds into recording) lives with the other
    // focus-history `tabs` reads in TabManager+FocusHistoryHosting.swift.

    func focusHistoryMenuSnapshot(
        direction: FocusHistoryMenuDirection,
        maxItemCount: Int? = nil
    ) -> FocusHistoryMenuSnapshot {
        focusHistoryNavigation.focusHistoryMenuSnapshot(direction: direction, maxItemCount: maxItemCount)
    }

    @discardableResult
    func navigateToFocusHistoryMenuItem(_ item: FocusHistoryMenuItem) -> Bool {
        focusHistoryNavigation.navigateToFocusHistoryMenuItem(item)
    }

    @discardableResult
    func navigateBack() -> Bool {
        focusHistoryNavigation.navigateBack()
    }

    @discardableResult
    func navigateForward() -> Bool {
        focusHistoryNavigation.navigateForward()
    }

    var canNavigateBack: Bool {
        focusHistoryNavigation.canNavigateBack
    }

    var canNavigateForward: Bool {
        focusHistoryNavigation.canNavigateForward
    }

    // FocusHistoryHosting witnesses that touch private members (the
    // `private(set)` revision counter) or forward into the focused-surface
    // model; the rest of the conformance lives in
    // TabManager+FocusHistoryHosting.swift.

    func focusSelectedWorkspacePanel() {
        focusedSurface.focusSelectedWorkspacePanel(previousWorkspaceId: nil)
    }

    func focusHistoryRevisionDidChange() {
        focusHistoryRevision &+= 1
    }

    // FocusedSurfaceHosting witness; the rest of the conformance lives in
    // TabManager+FocusedSurfaceHosting.swift. Forwards to the relocated
    // `WorkspaceSwitchDebugTracker`, which formats the byte-identical legacy
    // `ws.unfocus.*` trace lines. Release builds make this a no-op exactly as
    // the original `#if DEBUG`-guarded `cmuxDebugLog` calls were.
    func logPendingWorkspaceUnfocusEvent(_ event: PendingWorkspaceUnfocusEvent) {
#if DEBUG
        workspaceSwitchDebug.logPendingWorkspaceUnfocus(event)
#endif
    }

    // WorkspaceHandoffHosting witness; the rest of the conformance lives in
    // TabManager+WorkspaceHandoffHosting.swift. Forwards to the relocated
    // `WorkspaceSwitchDebugTracker`, which formats the byte-identical legacy
    // `ws.mount.reconcile` / `ws.handoff.*` trace lines that `ContentView`
    // used to emit inline; release builds make this a no-op exactly as the
    // original `#if DEBUG`-guarded `cmuxDebugLog` calls were.
    func logWorkspaceHandoffEvent(_ event: WorkspaceHandoffEvent) {
#if DEBUG
        workspaceSwitchDebug.logWorkspaceHandoff(event)
#endif
    }

    // MARK: - Split Operations (Backwards Compatibility)

    /// Create a new split in the specified direction
    /// Returns the new panel's ID (which is also the surface ID for terminals)
    func newSplit(
        tabId: UUID,
        surfaceId: UUID,
        direction: SplitDirection,
        focus: Bool = true,
        workingDirectory: String? = nil,
        initialCommand: String? = nil,
        tmuxStartCommand: String? = nil,
        startupEnvironment: [String: String] = [:],
        initialDividerPosition: CGFloat? = nil,
        remotePTYSessionID: String? = nil
    ) -> UUID? {
        surfaceSplit.newSplit(
            tabId: tabId,
            surfaceId: surfaceId,
            direction: direction,
            focus: focus,
            workingDirectory: workingDirectory,
            initialCommand: initialCommand,
            tmuxStartCommand: tmuxStartCommand,
            startupEnvironment: startupEnvironment,
            initialDividerPosition: initialDividerPosition,
            remotePTYSessionID: remotePTYSessionID
        )
    }

    /// Move focus in the specified direction
    func moveSplitFocus(tabId: UUID, surfaceId: UUID, direction: NavigationDirection) -> Bool {
        surfaceSplit.moveSplitFocus(tabId: tabId, surfaceId: surfaceId, direction: direction)
    }

    /// Resize split - not directly supported by bonsplit, but we can adjust divider positions
    func resizeSplit(tabId: UUID, surfaceId: UUID, direction: ResizeDirection, amount: UInt16) -> Bool {
        surfaceSplit.resizeSplit(tabId: tabId, surfaceId: surfaceId, direction: direction, amount: amount)
    }

    /// Toggle zoom on a panel.
    func toggleSplitZoom(tabId: UUID, surfaceId: UUID) -> Bool {
        surfaceSplit.toggleSplitZoom(tabId: tabId, surfaceId: surfaceId)
    }

    /// Toggle zoom for the currently focused panel in the selected workspace.
    @discardableResult
    func toggleFocusedSplitZoom() -> Bool {
        surfaceSplit.toggleFocusedSplitZoom()
    }

    /// Close a surface/panel
    func closeSurface(tabId: UUID, surfaceId: UUID) -> Bool {
        surfaceSplit.closeSurface(tabId: tabId, surfaceId: surfaceId)
    }

    /// Create a new browser panel in a split. Forwards to the `CmuxBrowser`
    /// ``BrowserOpenCoordinator`` (resolution + availability gate through the
    /// `BrowserOpenHosting` seam this window conforms to).
    func newBrowserSplit(
        tabId: UUID,
        fromPanelId: UUID,
        orientation: SplitOrientation,
        insertFirst: Bool = false,
        url: URL? = nil,
        preferredProfileID: UUID? = nil,
        focus: Bool = true,
        initialDividerPosition: CGFloat? = nil
    ) -> UUID? {
        browserOpen.newBrowserSplit(
            tabId: tabId,
            fromPanelId: fromPanelId,
            orientation: orientation,
            insertFirst: insertFirst,
            url: url,
            preferredProfileID: preferredProfileID,
            focus: focus,
            initialDividerPosition: initialDividerPosition
        )
    }

    /// Create a new browser surface in a pane. Forwards to the `CmuxBrowser`
    /// ``BrowserOpenCoordinator``.
    func newBrowserSurface(
        tabId: UUID,
        inPane paneId: PaneID,
        url: URL? = nil,
        preferredProfileID: UUID? = nil
    ) -> UUID? {
        browserOpen.newBrowserSurface(
            tabId: tabId,
            inPane: paneId,
            url: url,
            preferredProfileID: preferredProfileID
        )
    }

    /// Get a browser panel by ID. Stays here: a pure lookup returning the
    /// app-target `BrowserPanel` reference (which a lower package cannot name),
    /// with no creation orchestration to fold into the coordinator.
    func browserPanel(tabId: UUID, panelId: UUID) -> BrowserPanel? {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return nil }
        return tab.browserPanel(for: panelId)
    }

    /// Open a browser in a specific workspace, optionally preferring a
    /// split-right layout. Forwards to the `CmuxBrowser`
    /// ``BrowserOpenCoordinator``, which owns the reuse/split-source policy and
    /// the default focused-or-first-pane open path; this window supplies the
    /// workspace handle, the selection flow (with its app-side notification-store
    /// dismissal), the focus memory, and the browser-enabled gate.
    @discardableResult
    func openBrowser(
        inWorkspace tabId: UUID,
        url: URL? = nil,
        preferSplitRight: Bool = false,
        preferredProfileID: UUID? = nil,
        insertAtEnd: Bool = false
    ) -> UUID? {
        browserOpen.openBrowser(
            inWorkspace: tabId,
            url: url,
            preferSplitRight: preferSplitRight,
            preferredProfileID: preferredProfileID,
            insertAtEnd: insertAtEnd
        )
    }

    /// Open a browser in the currently focused pane (as a new surface). Forwards
    /// to the `CmuxBrowser` ``BrowserOpenCoordinator``.
    @discardableResult
    func openBrowser(
        url: URL? = nil,
        preferredProfileID: UUID? = nil,
        insertAtEnd: Bool = false
    ) -> UUID? {
        browserOpen.openBrowser(
            url: url,
            preferredProfileID: preferredProfileID,
            insertAtEnd: insertAtEnd
        )
    }

    /// Reopen the most recently closed browser panel (Cmd+Shift+T).
    /// No-op when no browser panel restore snapshot is available.
    @discardableResult
    func reopenMostRecentlyClosedBrowserPanel() -> Bool {
        if reopenMostRecentlyClosedItem() {
            return true
        }

        return reopenMostRecentlyClosedBrowserPanelFromLegacyStack()
    }

    @discardableResult
    func reopenMostRecentlyClosedBrowserPanelFromLegacyStack() -> Bool {
        browserReopen.reopenMostRecentlyClosedBrowserPanelFromLegacyStack()
    }

    func clearRecentlyClosedBrowserPanelHistory() {
        browserReopen.clearRecentlyClosedBrowserPanelHistory()
    }

    func mostRecentLegacyClosedBrowserPanelClosedAt() -> Date? {
        browserReopen.mostRecentLegacyClosedBrowserPanelClosedAt()
    }

    /// Forwards to the per-window ``ClosedItemReopenRouting`` (CmuxWorkspaces);
    /// the routing/ordering lives there, the app effects invert back through
    /// ``ClosedPanelRestoreHosting`` (TabManager+ClosedItemReopenRouting).
    @discardableResult
    func reopenMostRecentlyClosedItem() -> Bool {
        closedItemReopenRouting.reopenMostRecentlyClosedItem()
    }

    @discardableResult
    func reopenClosedHistoryItem(id: UUID) -> Bool {
        closedItemReopenRouting.reopenClosedHistoryItem(id: id)
    }

    @discardableResult
    func restoreClosedPanel(_ entry: ClosedPanelHistoryEntry) -> Bool {
        closedItemReopenRouting.restoreClosedPanel(entry)
    }

    @discardableResult
    func restoreClosedWorkspace(_ entry: ClosedWorkspaceHistoryEntry) -> Bool {
        closedItemReopenRouting.restoreClosedWorkspace(entry)
    }

    /// Flash the currently focused panel so the user can visually confirm focus.
    func triggerFocusFlash() {
        guard let tab = selectedWorkspace,
              let panelId = tab.focusedPanelId else { return }
        tab.triggerFocusFlash(panelId: panelId)
    }

    /// Ensure AppKit first responder matches the currently focused terminal panel.
    /// This keeps real keyboard events (including Ctrl+D) on the same panel as the
    /// bonsplit focus indicator after rapid split topology changes.
    func ensureFocusedTerminalFirstResponder() {
        guard let tab = selectedWorkspace,
              let panelId = tab.focusedPanelId,
              let terminal = tab.terminalPanel(for: panelId) else { return }
        terminal.hostedView.ensureFocus(for: tab.id, surfaceId: panelId)
    }

    /// Reconcile keyboard routing before terminal control shortcuts (e.g. Ctrl+D).
    ///
    /// Source of truth for pane focus is bonsplit's focused pane + selected tab.
    /// Keyboard delivery must converge AppKit first responder to that model state, not mutate
    /// the model from whatever first responder happened to be during reparenting transitions.
    func reconcileFocusedPanelFromFirstResponderForKeyboard() {
        ensureFocusedTerminalFirstResponder()
    }

    /// Get a terminal panel by ID
    func terminalPanel(tabId: UUID, panelId: UUID) -> TerminalPanel? {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return nil }
        return tab.terminalPanel(for: panelId)
    }

    /// Get the panel for a surface ID (terminal panels use surface ID as panel ID)
    func surface(for tabId: UUID, surfaceId: UUID) -> TerminalSurface? {
        terminalPanel(tabId: tabId, panelId: surfaceId)?.surface
    }

#if DEBUG
    @MainActor
    private func waitForWorkspacePanelsCondition(
        tab: Workspace,
        timeoutSeconds: TimeInterval,
        condition: @escaping (Workspace) -> Bool
    ) async -> Bool {
        guard !condition(tab) else { return true }

        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            var resolved = false
            var cancellable: AnyCancellable?

            func finish(_ value: Bool) {
                guard !resolved else { return }
                resolved = true
                cancellable?.cancel()
                cont.resume(returning: value)
            }

            func evaluate() {
                if condition(tab) {
                    finish(true)
                }
            }

            cancellable = tab.panelsPublisher
                .map { _ in () }
                .sink { _ in evaluate() }

            DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSeconds) {
                Task { @MainActor in
                    finish(condition(tab))
                }
            }
            evaluate()
        }
    }

    @MainActor
    private func waitForTerminalPanelCondition(
        tab: Workspace,
        panelId: UUID,
        timeoutSeconds: TimeInterval,
        condition: @escaping (TerminalPanel) -> Bool
    ) async -> Bool {
        if let panel = tab.terminalPanel(for: panelId), condition(panel) {
            return true
        }

        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            var resolved = false
            var panelsCancellable: AnyCancellable?
            var readyObserver: NSObjectProtocol?
            var hostedViewObserver: NSObjectProtocol?

            @MainActor
            func finish(_ value: Bool) {
                guard !resolved else { return }
                resolved = true
                panelsCancellable?.cancel()
                if let readyObserver {
                    NotificationCenter.default.removeObserver(readyObserver)
                }
                if let hostedViewObserver {
                    NotificationCenter.default.removeObserver(hostedViewObserver)
                }
                cont.resume(returning: value)
            }

            @MainActor
            func evaluate() {
                guard let panel = tab.terminalPanel(for: panelId) else {
                    finish(false)
                    return
                }
                panel.surface.requestBackgroundSurfaceStartIfNeeded()
                if condition(panel) {
                    finish(true)
                }
            }

            panelsCancellable = tab.panelsPublisher
                .map { _ in () }
                .sink { _ in
                    Task { @MainActor in
                        evaluate()
                    }
                }
            readyObserver = NotificationCenter.default.addObserver(
                forName: .terminalSurfaceDidBecomeReady,
                object: nil,
                queue: .main
            ) { note in
                guard let readySurfaceId = note.userInfo?["surfaceId"] as? UUID,
                      readySurfaceId == panelId else { return }
                Task { @MainActor in
                    evaluate()
                }
            }
            hostedViewObserver = NotificationCenter.default.addObserver(
                forName: .terminalSurfaceHostedViewDidMoveToWindow,
                object: nil,
                queue: .main
            ) { note in
                guard let hostedSurfaceId = note.userInfo?["surfaceId"] as? UUID,
                      hostedSurfaceId == panelId else { return }
                Task { @MainActor in
                    evaluate()
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSeconds) {
                Task { @MainActor in
                    if let panel = tab.terminalPanel(for: panelId) {
                        finish(condition(panel))
                    } else {
                        finish(false)
                    }
                }
            }
            evaluate()
        }
    }

    @MainActor
    private func waitForTerminalPanelReadyForUITest(
        tab: Workspace,
        panelId: UUID,
        timeoutSeconds: TimeInterval = 6.0
    ) async -> (attached: Bool, hasSurface: Bool, firstResponder: Bool) {
        var attached = false
        var hasSurface = false
        var firstResponder = false

        let _ = await waitForTerminalPanelCondition(
            tab: tab,
            panelId: panelId,
            timeoutSeconds: timeoutSeconds
        ) { panel in
            panel.surface.requestBackgroundSurfaceStartIfNeeded()
            attached = panel.surface.isViewInWindow
            hasSurface = panel.surface.surface != nil
            firstResponder = panel.hostedView.isSurfaceViewFirstResponder()
            return attached && hasSurface
        }

        return (attached, hasSurface, firstResponder)
    }

    /// Build the typed scaffold plan from the process environment and drive any
    /// enabled DEBUG split / child-exit UI-test harness exactly once.
    ///
    /// The env-gating and parameter parsing live in `CmuxTestSupport`
    /// (``UITestSplitScaffoldGate``); this composition root only holds the
    /// once-only guard and forwards to the package's dispatch, with `self`
    /// supplying the live actions via ``UITestScaffoldRunning``.
    private func setupUITestSplitScaffoldsIfNeeded() {
        guard !didSetupUITestSplitScaffolds else { return }
        didSetupUITestSplitScaffolds = true

        let plan = UITestSplitScaffoldGate().plan(from: ProcessInfo.processInfo.environment)
        runEnabledScaffolds(for: plan)
    }

    func installUITestFocusShortcuts() {
        // UI tests can't record arrow keys via the shortcut recorder. Use letter-based shortcuts
        // so tests can reliably drive pane navigation without mouse clicks.
        KeyboardShortcutSettings.setShortcut(
            StoredShortcut(key: "h", command: true, shift: false, option: false, control: true),
            for: .focusLeft
        )
        KeyboardShortcutSettings.setShortcut(
            StoredShortcut(key: "l", command: true, shift: false, option: false, control: true),
            for: .focusRight
        )
        KeyboardShortcutSettings.setShortcut(
            StoredShortcut(key: "k", command: true, shift: false, option: false, control: true),
            for: .focusUp
        )
        KeyboardShortcutSettings.setShortcut(
            StoredShortcut(key: "j", command: true, shift: false, option: false, control: true),
            for: .focusDown
        )
    }

    /// Witness for ``UITestScaffoldRunning``: forwards the split-then-close-right
    /// harness to the lifted ``SplitCloseRightScaffoldRunner``, which owns the
    /// orchestration. `self` supplies the live actions via
    /// ``SplitCloseRightScaffoldDriving``.
    func runSplitCloseRightUITest(_ config: UITestSplitScaffoldPlan.SplitCloseRightConfig) {
        SplitCloseRightScaffoldRunner(driver: self).run(config: config)
    }

	    @MainActor
	    private func runSplitCloseRightVisualRepro(
	        tab: Workspace,
	        topLeftPanelId: UUID,
	        path: String,
	        config: UITestSplitScaffoldPlan.SplitCloseRightConfig
	    ) async {
        // Clamp exactly as the legacy `runSplitCloseRightUITest` caller did
        // before driving the repro; the parsed config carries the raw values.
        let iterations = max(1, min(config.visualIterations, 60))
        let burstFrames = max(0, min(config.burstFrames, 80))
        let closeDelayMs = max(0, min(config.closeDelayMs, 500))
        let pattern = config.pattern

        func sendText(_ panelId: UUID, _ text: String) {
            guard let tp = tab.terminalPanel(for: panelId) else { return }
            tp.sendText(text)
        }

        // Sample a very top strip so the probe remains valid even after vertical expand/collapse.
        // We pin marker text to row 1 before each close sequence.
        let sampleCrop = CGRect(x: 0.04, y: 0.01, width: 0.92, height: 0.08)

        for i in 1...iterations {
            // Reset to a single pane: close everything except the top-left panel.
            tab.focusPanel(topLeftPanelId)
            let toClose = Array(tab.panels.keys).filter { $0 != topLeftPanelId }
            for pid in toClose {
                tab.closePanel(pid, force: true)
            }

            // Create the repro layout. Most patterns use a 2x2 grid, but keep a single-split
            // variant for the exact "close right in a horizontal pair" user report.
            let topLeftId = topLeftPanelId
            let topRight: TerminalPanel
            var bottomLeft: TerminalPanel?
            var bottomRight: TerminalPanel?

            switch pattern {
            case "close_right_single":
                guard let tr = tab.newTerminalSplit(from: topLeftId, orientation: .horizontal) else {
                    writeSplitCloseRightTestData(["setupError": "Failed to split right from top-left (iteration \(i))"], at: path)
                    return
                }
                topRight = tr
            case "close_right_lrtd", "close_right_lrtd_bottom_first", "close_right_bottom_first", "close_right_lrtd_unfocused":
                // User repro: split left/right first, then split top/down in each column.
                guard let tr = tab.newTerminalSplit(from: topLeftId, orientation: .horizontal) else {
                    writeSplitCloseRightTestData(["setupError": "Failed to split right from top-left (iteration \(i))"], at: path)
                    return
                }
                guard let bl = tab.newTerminalSplit(from: topLeftId, orientation: .vertical) else {
                    writeSplitCloseRightTestData(["setupError": "Failed to split down from left (iteration \(i))"], at: path)
                    return
                }
                guard let br = tab.newTerminalSplit(from: tr.id, orientation: .vertical) else {
                    writeSplitCloseRightTestData(["setupError": "Failed to split down from right (iteration \(i))"], at: path)
                    return
                }
                topRight = tr
                bottomLeft = bl
                bottomRight = br
            default:
                // Default: split top/down first, then split left/right in each row.
                guard let bl = tab.newTerminalSplit(from: topLeftId, orientation: .vertical) else {
                    writeSplitCloseRightTestData(["setupError": "Failed to split down from top-left (iteration \(i))"], at: path)
                    return
                }
                guard let br = tab.newTerminalSplit(from: bl.id, orientation: .horizontal) else {
                    writeSplitCloseRightTestData(["setupError": "Failed to split right from bottom-left (iteration \(i))"], at: path)
                    return
                }
                guard let tr = tab.newTerminalSplit(from: topLeftId, orientation: .horizontal) else {
                    writeSplitCloseRightTestData(["setupError": "Failed to split right from top-left (iteration \(i))"], at: path)
                    return
                }
                topRight = tr
                bottomLeft = bl
                bottomRight = br
            }

            // Let newly created surfaces attach before priming content, so sampled panes have
            // stable non-blank text before the close timeline begins.
            try? await Task.sleep(nanoseconds: 180_000_000)

            // Fill left panes with visible content.
            sendText(topLeftId, "printf '\\033[2J\\033[H'; for i in {1..200}; do echo CMUX_SPLIT_TOPLEFT_\(i); done; printf '\\033[HCMUX_MARKER_TOPLEFT\\n'\r")
            sendText(topRight.id, "printf '\\033[2J\\033[H'; for i in {1..200}; do echo CMUX_SPLIT_TOPRIGHT_\(i); done; printf '\\033[HCMUX_MARKER_TOPRIGHT\\n'\r")
            if let bottomLeft {
                sendText(bottomLeft.id, "printf '\\033[2J\\033[H'; for i in {1..200}; do echo CMUX_SPLIT_BOTTOMLEFT_\(i); done; printf '\\033[HCMUX_MARKER_BOTTOMLEFT\\n'\r")
            }
            if let bottomRight {
                sendText(bottomRight.id, "printf '\\033[2J\\033[H'; for i in {1..200}; do echo CMUX_SPLIT_BOTTOMRIGHT_\(i); done; printf '\\033[HCMUX_MARKER_BOTTOMRIGHT\\n'\r")
            }
            // Give shell output a moment to paint before we start the close timeline.
            try? await Task.sleep(nanoseconds: 180_000_000)

            let desiredFrames = max(16, min(burstFrames, 60))
            let closeFrame = min(6, max(1, desiredFrames / 4))
            let delayFrames = max(0, Int((Double(max(0, closeDelayMs)) / 16.6667).rounded(.up)))
            let secondCloseFrame = min(desiredFrames - 1, closeFrame + delayFrames)

            var closeOrder = ""
            let actions: [(frame: Int, action: () -> Void)] = {
                switch pattern {
                case "close_right_single":
                    closeOrder = "TR_ONLY"
                    return [
                        (frame: closeFrame, action: {
                            tab.focusPanel(topRight.id)
                            tab.closePanel(topRight.id, force: true)
                        }),
                    ]
                case "close_bottom":
                    guard let bottomRight, let bottomLeft else { return [] }
                    closeOrder = "BR_THEN_BL"
                    return [
                        (frame: closeFrame, action: {
                            tab.focusPanel(bottomRight.id)
                            tab.closePanel(bottomRight.id, force: true)
                        }),
                        (frame: secondCloseFrame, action: {
                            tab.focusPanel(bottomLeft.id)
                            tab.closePanel(bottomLeft.id, force: true)
                        }),
                    ]
                case "close_right_lrtd_bottom_first", "close_right_bottom_first":
                    guard let bottomRight else { return [] }
                    closeOrder = "BR_THEN_TR"
                    return [
                        (frame: closeFrame, action: {
                            tab.focusPanel(bottomRight.id)
                            tab.closePanel(bottomRight.id, force: true)
                        }),
                        (frame: secondCloseFrame, action: {
                            tab.focusPanel(topRight.id)
                            tab.closePanel(topRight.id, force: true)
                        }),
                    ]
                case "close_right_lrtd_unfocused":
                    guard let bottomRight else { return [] }
                    closeOrder = "TR_THEN_BR_UNFOCUSED"
                    return [
                        (frame: closeFrame, action: {
                            tab.closePanel(topRight.id, force: true)
                        }),
                        (frame: secondCloseFrame, action: {
                            tab.closePanel(bottomRight.id, force: true)
                        }),
                    ]
                default:
                    guard let bottomRight else { return [] }
                    closeOrder = "TR_THEN_BR"
                    return [
                        (frame: closeFrame, action: {
                            tab.focusPanel(topRight.id)
                            tab.closePanel(topRight.id, force: true)
                        }),
                        (frame: secondCloseFrame, action: {
                            tab.focusPanel(bottomRight.id)
                            tab.closePanel(bottomRight.id, force: true)
                        }),
                    ]
                }
            }()

            let targets: [(label: String, view: GhosttySurfaceScrollView)] = {
                switch pattern {
                case "close_right_single":
                    return [
                        ("TL", tab.terminalPanel(for: topLeftId)!.surface.hostedView),
                    ]
                case "close_bottom":
                    return [
                        ("TL", tab.terminalPanel(for: topLeftId)!.surface.hostedView),
                        ("TR", topRight.surface.hostedView),
                    ]
                case "close_right_lrtd_bottom_first", "close_right_bottom_first":
                    return [
                        ("TR", topRight.surface.hostedView),
                        ("TL", tab.terminalPanel(for: topLeftId)!.surface.hostedView),
                    ]
                default:
                    guard let bottomLeft else { return [] }
                    return [
                        ("TL", tab.terminalPanel(for: topLeftId)!.surface.hostedView),
                        ("BL", bottomLeft.surface.hostedView),
                    ]
                }
            }()

            let result = await captureVsyncIOSurfaceTimeline(
                frameCount: desiredFrames,
                closeFrame: closeFrame,
                crop: sampleCrop,
                targets: targets,
                actions: actions
            )

            let paneStateTrace: String = {
                tab.bonsplitController.allPaneIds.map { paneId in
                    let tabs = tab.bonsplitController.tabs(inPane: paneId)
                    let selected = tab.bonsplitController.selectedTab(inPane: paneId)
                    let selectedId = selected.map { String(describing: $0.id) } ?? "nil"
                    let selectedPanelId = selected.flatMap { tab.panelIdFromSurfaceId($0.id) }
                    let selectedPanelLive: String = {
                        guard let selected else { return "0" }
                        return tab.panel(for: selected.id) != nil ? "1" : "0"
                    }()
                    let mappedCount = tabs.filter { tab.panelIdFromSurfaceId($0.id) != nil }.count
                    let selectedPanel = selectedPanelId?.uuidString.prefix(8) ?? "nil"
                    return "pane=\(paneId.id.uuidString.prefix(8)):tabs=\(tabs.count):mapped=\(mappedCount):selected=\(selectedId.prefix(8)):selectedPanel=\(selectedPanel):selectedLive=\(selectedPanelLive)"
                }.joined(separator: ";")
            }()

            writeSplitCloseRightTestData([
                "pattern": pattern,
                "iteration": String(i),
                "closeDelayMs": String(closeDelayMs),
                "closeDelayFrames": String(delayFrames),
                "closeOrder": closeOrder,
                "timelineFrameCount": String(desiredFrames),
                "timelineCloseFrame": String(closeFrame),
                "timelineSecondCloseFrame": String(secondCloseFrame),
                "timelineFirstBlank": result.firstBlank.map { "\($0.label)@\($0.frame)" } ?? "",
                "timelineFirstSizeMismatch": result.firstSizeMismatch.map { "\($0.label)@\($0.frame):ios=\($0.ios):exp=\($0.expected)" } ?? "",
                "timelineTrace": result.trace.joined(separator: "|"),
                "timelinePaneState": paneStateTrace,
                "visualLastIteration": String(i),
            ], at: path)

            if let firstBlank = result.firstBlank {
                writeSplitCloseRightTestData([
                    "blankFrameSeen": "1",
                    "blankObservedIteration": String(i),
                    "blankObservedAt": "\(firstBlank.label)@\(firstBlank.frame)"
                ], at: path)
                return
            }

            if let firstMismatch = result.firstSizeMismatch {
                writeSplitCloseRightTestData([
                    "sizeMismatchSeen": "1",
                    "sizeMismatchObservedIteration": String(i),
                    "sizeMismatchObservedAt": "\(firstMismatch.label)@\(firstMismatch.frame):ios=\(firstMismatch.ios):exp=\(firstMismatch.expected)"
                ], at: path)
                return
            }
        }
	    }

	    @MainActor
	    private func captureVsyncIOSurfaceTimeline(
	        frameCount: Int,
	        closeFrame: Int,
	        crop: CGRect,
	        targets: [(label: String, view: GhosttySurfaceScrollView)],
	        actions: [(frame: Int, action: () -> Void)] = []
	    ) async -> (firstBlank: (label: String, frame: Int)?, firstSizeMismatch: (label: String, frame: Int, ios: String, expected: String)?, trace: [String]) {
	        guard frameCount > 0 else { return (nil, nil, []) }

	        let capture = VsyncIOSurfaceTimelineCapture(frameCount: frameCount, closeFrame: closeFrame)
	        capture.scheduledActions = actions.sorted(by: { $0.frame < $1.frame })
	        capture.nextActionIndex = 0
	        // Map each live GhosttySurfaceScrollView DebugFrameSample to a
	        // VsyncFrameSample here so the package's capture owner never
	        // references an app type or QuartzCore.
	        capture.targets = targets.map { t in
	            { @MainActor in
	                guard let s = t.view.debugSampleIOSurface(normalizedCrop: crop) else { return nil }
	                return VsyncFrameSample(
	                    label: t.label,
	                    isProbablyBlank: s.isProbablyBlank,
	                    iosurfaceWidthPx: s.iosurfaceWidthPx,
	                    iosurfaceHeightPx: s.iosurfaceHeightPx,
	                    expectedWidthPx: s.expectedWidthPx,
	                    expectedHeightPx: s.expectedHeightPx,
	                    layerContentsGravity: s.layerContentsGravity,
	                    isStretchRisk: s.layerContentsGravity == CALayerContentsGravity.resize.rawValue,
	                    layerContentsKey: s.layerContentsKey
	                )
	            }
	        }

	        return await capture.run()
	    }

    private func writeSplitCloseRightTestData(_ updates: [String: String], at path: String) {
        UITestKeyValueCaptureFile(path: path).merge(updates)
    }

    /// Witness for ``UITestScaffoldRunning``: forwards the child-exit split
    /// harness to the lifted ``ChildExitSplitScaffoldRunner``, which owns the
    /// orchestration. `self` supplies the live actions via
    /// ``ChildExitScaffoldDriving``.
    func runChildExitSplitUITest(_ config: UITestSplitScaffoldPlan.ChildExitSplitConfig) {
        ChildExitSplitScaffoldRunner(driver: self).run(config: config)
    }

    /// Witness for ``UITestScaffoldRunning``: forwards the child-exit keyboard
    /// harness to the lifted ``ChildExitKeyboardScaffoldRunner``, which owns the
    /// setup orchestration. `self` supplies the live actions via
    /// ``ChildExitScaffoldDriving``, including the app-side post-`ready`
    /// resolution machinery.
    func runChildExitKeyboardUITest(_ config: UITestSplitScaffoldPlan.ChildExitKeyboardConfig) {
        ChildExitKeyboardScaffoldRunner(driver: self).run(config: config)
    }
#endif
}

#if DEBUG
/// The live-action side of the DEBUG split / child-exit UI-test scaffolds. The
/// env-gating and parameter parsing live in `CmuxTestSupport`; the harness
/// bodies stay here because they drive AppKit / Bonsplit / Ghostty surface state
/// that cannot cross the package boundary.
extension TabManager: UITestScaffoldRunning {}

/// The split-close-right driver seam: the live workspace / Bonsplit / Ghostty /
/// `NSApp` actions that `SplitCloseRightScaffoldRunner` (in `CmuxTestSupport`)
/// sequences. The runner owns the harness orchestration; these witnesses are the
/// irreducible live reads/mutations that cannot cross the package boundary. The
/// CVDisplayLink visual repro stays here per the TabManager decomposition plan.
extension TabManager: SplitCloseRightScaffoldDriving {
    var workspaceIdString: String {
        selectedWorkspace?.id.uuidString ?? ""
    }

    func prepareSplitCloseRight() async -> SplitCloseRightSetup {
        guard let tab = selectedWorkspace else {
            return .failed(captureFields: ["setupError": "Missing selected workspace"])
        }
        guard let topLeftPanelId = tab.focusedPanelId else {
            return .failed(captureFields: ["setupError": "Missing initial focused panel"])
        }
        let initialTerminalReadiness = await waitForTerminalPanelReadyForUITest(
            tab: tab,
            panelId: topLeftPanelId
        )
        guard initialTerminalReadiness.attached,
              initialTerminalReadiness.hasSurface,
              let terminal = tab.terminalPanel(for: topLeftPanelId) else {
            return .failed(captureFields: [
                "preTerminalAttached": initialTerminalReadiness.attached ? "1" : "0",
                "preTerminalSurfaceNil": initialTerminalReadiness.hasSurface ? "0" : "1",
                "setupError": "Initial terminal not ready (not attached or surface nil)"
            ])
        }
        return .ready(
            topLeftPanelId: topLeftPanelId,
            captureFields: [
                "preTerminalAttached": "1",
                "preTerminalSurfaceNil": terminal.surface.surface == nil ? "1" : "0"
            ]
        )
    }

    func splitDown(from panelId: UUID) -> UUID? {
        selectedWorkspace?.newTerminalSplit(from: panelId, orientation: .vertical)?.id
    }

    func splitRight(from panelId: UUID) -> UUID? {
        selectedWorkspace?.newTerminalSplit(from: panelId, orientation: .horizontal)?.id
    }

    func focusPanel(_ panelId: UUID) {
        selectedWorkspace?.focusPanel(panelId)
    }

    func closePanel(_ panelId: UUID) {
        selectedWorkspace?.closePanel(panelId, force: true)
    }

    var paneCount: Int {
        selectedWorkspace?.bonsplitController.allPaneIds.count ?? 0
    }

    var panelCount: Int {
        selectedWorkspace?.panels.count ?? 0
    }

    var bonsplitTabCount: Int {
        selectedWorkspace?.bonsplitController.allTabIds.count ?? 0
    }

    func resetEmptyPanelAppearCount() {
        DebugUIEventCounters.resetEmptyPanelAppearCount()
    }

    var emptyPanelAppearCount: Int {
        DebugUIEventCounters.emptyPanelAppearCount
    }

    func reconcileVisibleTerminalGeometry() {
        guard let tab = selectedWorkspace else { return }
        NSApp.windows.forEach { window in
            window.contentView?.layoutSubtreeIfNeeded()
            window.contentView?.displayIfNeeded()
        }
        for paneId in tab.bonsplitController.allPaneIds {
            guard let selected = tab.bonsplitController.selectedTab(inPane: paneId),
                  let terminal = tab.panel(for: selected.id) as? TerminalPanel else {
                continue
            }
            terminal.hostedView.reconcileGeometryNow()
            terminal.surface.forceRefresh()
        }
    }

    func paneSnapshots() -> [SplitCloseRightPaneSnapshot] {
        guard let tab = selectedWorkspace else { return [] }
        return tab.bonsplitController.allPaneIds.map { paneId in
            guard let selected = tab.bonsplitController.selectedTab(inPane: paneId) else {
                return SplitCloseRightPaneSnapshot(hasSelectedTab: false)
            }
            guard let panel = tab.panel(for: selected.id) else {
                return SplitCloseRightPaneSnapshot(hasSelectedTab: true, hasPanelMapping: false)
            }
            guard let terminal = panel as? TerminalPanel else {
                return SplitCloseRightPaneSnapshot(
                    hasSelectedTab: true,
                    hasPanelMapping: true,
                    isTerminal: false
                )
            }
            let size = terminal.hostedView.bounds.size
            return SplitCloseRightPaneSnapshot(
                hasSelectedTab: true,
                hasPanelMapping: true,
                isTerminal: true,
                isAttached: terminal.surface.isViewInWindow,
                isZeroSize: size.width < 5 || size.height < 5,
                isSurfaceNil: terminal.surface.surface == nil
            )
        }
    }

    func runVisualRepro(
        topLeftPanelId: UUID,
        config: UITestSplitScaffoldPlan.SplitCloseRightConfig
    ) async {
        guard let tab = selectedWorkspace else { return }
        await runSplitCloseRightVisualRepro(
            tab: tab,
            topLeftPanelId: topLeftPanelId,
            path: config.path,
            config: config
        )
    }
}

/// The child-exit driver seam: the live workspace / Bonsplit / Ghostty actions
/// that `ChildExitSplitScaffoldRunner` / `ChildExitKeyboardScaffoldRunner` (in
/// `CmuxTestSupport`) sequence. The runners own the harness orchestration; these
/// witnesses are the irreducible live reads/mutations that cannot cross the
/// package boundary. The keyboard post-`ready` resolution stays here per the
/// TabManager decomposition plan because it owns the live Combine cancellable
/// set, the `@Observable` workspace-list observation, the `DispatchWorkItem`
/// timeout, and the runtime close callback.
extension TabManager: ChildExitScaffoldDriving {
    private var childExitWorkspace: Workspace? { childExitScaffoldPinnedWorkspace }

    func pinSelectedWorkspace() -> UUID? {
        guard let tab = selectedWorkspace else {
            childExitScaffoldPinnedWorkspace = nil
            return nil
        }
        childExitScaffoldPinnedWorkspace = tab
        return tab.id
    }

    var workspaceCount: Int { tabs.count }

    var pinnedWorkspaceIsAlive: Bool {
        guard let tab = childExitWorkspace else { return false }
        return tabs.contains(where: { $0.id == tab.id })
    }

    var pinnedPanelCount: Int { childExitWorkspace?.panels.count ?? 0 }

    var pinnedFocusedPanelId: UUID? { childExitWorkspace?.focusedPanelId }

    var pinnedFirstPanelId: UUID? { childExitWorkspace?.panels.keys.first }

    func pinnedPanelIds(excluding panelId: UUID) -> [UUID] {
        guard let tab = childExitWorkspace else { return [] }
        return tab.panels.keys.filter { $0 != panelId }
    }

    func closePinnedPanel(_ panelId: UUID) {
        childExitWorkspace?.closePanel(panelId, force: true)
    }

    func newRightSplit(from panelId: UUID) -> UUID? {
        childExitWorkspace?.newTerminalSplit(from: panelId, orientation: .horizontal)?.id
    }

    func newDownSplit(from panelId: UUID) -> UUID? {
        childExitWorkspace?.newTerminalSplit(from: panelId, orientation: .vertical)?.id
    }

    func focusPinnedPanel(_ panelId: UUID) {
        childExitWorkspace?.focusPanel(panelId)
    }

    func sendText(_ panelId: UUID, _ text: String) {
        childExitWorkspace?.terminalPanel(for: panelId)?.sendText(text)
    }

    func waitForPanelCount(equals count: Int, timeoutSeconds: TimeInterval) async -> Bool {
        guard let tab = childExitWorkspace else { return false }
        return await waitForWorkspacePanelsCondition(
            tab: tab,
            timeoutSeconds: timeoutSeconds
        ) { workspace in
            workspace.panels.count == count
        }
    }

    func waitForPanelRemoved(_ panelId: UUID, timeoutSeconds: TimeInterval) async -> Bool {
        guard let tab = childExitWorkspace else { return false }
        return await waitForWorkspacePanelsCondition(
            tab: tab,
            timeoutSeconds: timeoutSeconds
        ) { workspace in
            workspace.panels[panelId] == nil
        }
    }

    func waitForPanelAttachedWithSurface(_ panelId: UUID, timeoutSeconds: TimeInterval) async -> Bool {
        guard let tab = childExitWorkspace else { return false }
        return await waitForTerminalPanelCondition(
            tab: tab,
            panelId: panelId,
            timeoutSeconds: timeoutSeconds
        ) { panel in
            panel.surface.isViewInWindow && panel.surface.surface != nil
        }
    }

    func waitForPanelCountToCollapse() async -> Bool {
        guard let tab = childExitWorkspace else { return false }
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            var cancellable: AnyCancellable?
            var resolved = false

            func finish(_ value: Bool) {
                guard !resolved else { return }
                resolved = true
                cancellable?.cancel()
                cont.resume(returning: value)
            }

            cancellable = tab.panelsPublisher
                .map { $0.count }
                .removeDuplicates()
                .sink { count in
                    if count == 1 {
                        finish(true)
                    }
                }

            DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) {
                finish(false)
            }
        }
    }

    func waitForPanelReady(_ panelId: UUID) async -> ChildExitPanelReadiness {
        guard let tab = childExitWorkspace else {
            return ChildExitPanelReadiness(attached: false, hasSurface: false, firstResponder: false)
        }
        let readiness = await waitForTerminalPanelReadyForUITest(tab: tab, panelId: panelId)
        return ChildExitPanelReadiness(
            attached: readiness.attached,
            hasSurface: readiness.hasSurface,
            firstResponder: readiness.firstResponder
        )
    }

    func panelReadinessSnapshot(_ panelId: UUID) -> ChildExitPanelReadiness? {
        guard let panel = childExitWorkspace?.terminalPanel(for: panelId) else { return nil }
        return ChildExitPanelReadiness(
            attached: panel.surface.isViewInWindow,
            hasSurface: panel.surface.surface != nil,
            firstResponder: panel.hostedView.isSurfaceViewFirstResponder()
        )
    }

    var pinnedWorkspaceIdString: String { childExitWorkspace?.id.uuidString ?? "" }

    var pinnedFocusedPanelIdString: String {
        childExitWorkspace?.focusedPanelId?.uuidString ?? ""
    }

    var pinnedFirstResponderTerminalPanelIdString: String {
        guard let tab = childExitWorkspace else { return "" }
        return tab.panels.compactMap { (panelId, panel) -> UUID? in
            guard let terminal = panel as? TerminalPanel else { return nil }
            return terminal.hostedView.isSurfaceViewFirstResponder() ? panelId : nil
        }.first?.uuidString ?? ""
    }

    func runChildExitKeyboardResolution(
        exitPanelId: UUID,
        capturePath: String,
        config: UITestSplitScaffoldPlan.ChildExitKeyboardConfig
    ) {
        guard let tab = childExitWorkspace else { return }
        let autoTrigger = config.autoTrigger
        let strictKeyOnly = config.strictKeyOnly
        let triggerMode = config.triggerMode
        let useEarlyCtrlShiftTrigger = config.useEarlyCtrlShiftTrigger
        let useEarlyCtrlDTrigger = config.useEarlyCtrlDTrigger
        let useEarlyTrigger = config.useEarlyTrigger
        let triggerUsesShift = config.triggerUsesShift
        let expectedPanelsAfter = config.expectedPanelsAfter

        let captureFile = UITestKeyValueCaptureFile(path: capturePath)
        func write(_ updates: [String: String]) {
            captureFile.merge(updates)
        }

        var finished = false
        var timeoutWork: DispatchWorkItem?

        @MainActor
        func finish(_ updates: [String: String]) {
            guard !finished else { return }
            finished = true
            timeoutWork?.cancel()
            write(updates.merging(["done": "1"], uniquingKeysWith: { _, new in new }))
            self.uiTestCancellables.removeAll()
            self.uiTestWorkspacesObservations.forEach { $0.cancel() }
            self.uiTestWorkspacesObservations.removeAll()
        }

        tab.panelsPublisher
            .map { $0.count }
            .removeDuplicates()
            .sink { [weak self, weak tab] count in
                Task { @MainActor in
                    guard let self, let tab else { return }
                    if count == expectedPanelsAfter {
                        // Require the post-exit state to be stable for a short window so
                        // we catch "close looked correct, then workspace vanished" races.
                        try? await Task.sleep(nanoseconds: 1_200_000_000)
                        guard tab.panels.count == expectedPanelsAfter else { return }

                        let firstResponderPanelAfter = tab.panels.compactMap { (panelId, panel) -> UUID? in
                            guard let terminal = panel as? TerminalPanel else { return nil }
                            return terminal.hostedView.isSurfaceViewFirstResponder() ? panelId : nil
                        }.first?.uuidString ?? ""

                        finish([
                            "workspaceCountAfter": String(self.tabs.count),
                            "panelCountAfter": String(tab.panels.count),
                            "closedWorkspace": self.tabs.contains(where: { $0.id == tab.id }) ? "0" : "1",
                            "focusedPanelAfter": tab.focusedPanelId?.uuidString ?? "",
                            "firstResponderPanelAfter": firstResponderPanelAfter,
                        ])
                    }
                }
            }
            .store(in: &uiTestCancellables)

        // Observe the `@Observable` workspace list instead of the retired
        // `tabsPublisher` bridge. The former chain mapped to "tab still
        // alive" and `.removeDuplicates()`, so it only acted on the
        // alive→gone transition; `lastAlive` reproduces that dedup. The
        // bridge's replay delivered the initial `alive=true` (a no-op), so
        // no explicit initial check is needed.
        var lastAlive = self.tabs.contains(where: { $0.id == tab.id })
        uiTestWorkspacesObservations.append(
            workspaces.observeTabs { [weak self, weak tab] in
                guard let self, let tab else { return }
                let alive = self.tabs.contains(where: { $0.id == tab.id })
                guard alive != lastAlive else { return }
                lastAlive = alive
                if !alive {
                    finish([
                        "workspaceCountAfter": "0",
                        "panelCountAfter": "0",
                        "closedWorkspace": "1",
                    ])
                }
            }
        )

        let work = DispatchWorkItem {
            finish([
                "workspaceCountAfter": String(self.tabs.count),
                "panelCountAfter": String(tab.panels.count),
                "closedWorkspace": self.tabs.contains(where: { $0.id == tab.id }) ? "0" : "1",
                "timedOut": "1",
            ])
        }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0, execute: work)

        if autoTrigger {
            Task { @MainActor [weak tab] in
                guard let tab else { return }
                write(["autoTriggerStarted": "1"])

                if triggerMode == "runtime_close_callback" {
                    write(["autoTriggerMode": "runtime_close_callback"])
                    self.closePanelAfterChildExited(tabId: tab.id, surfaceId: exitPanelId)
                    return
                }

                let triggerModifiers: NSEvent.ModifierFlags = triggerUsesShift
                    ? [.control, .shift]
                    : [.control]
                let shouldWaitForSurface = !useEarlyTrigger

                var attachedBeforeTrigger = false
                var hasSurfaceBeforeTrigger = false
                if shouldWaitForSurface {
                    let ready = await self.waitForTerminalPanelCondition(
                        tab: tab,
                        panelId: exitPanelId,
                        timeoutSeconds: 5.0
                    ) { panel in
                        attachedBeforeTrigger = panel.surface.isViewInWindow
                        hasSurfaceBeforeTrigger = panel.surface.surface != nil
                        return attachedBeforeTrigger && hasSurfaceBeforeTrigger
                    }
                    if !ready,
                       tab.terminalPanel(for: exitPanelId) == nil {
                        write(["autoTriggerError": "missingExitPanelBeforeTrigger"])
                        return
                    }
                } else if let panel = tab.terminalPanel(for: exitPanelId) {
                    attachedBeforeTrigger = panel.surface.isViewInWindow
                    hasSurfaceBeforeTrigger = panel.surface.surface != nil
                }
                write([
                    "exitPanelAttachedBeforeTrigger": attachedBeforeTrigger ? "1" : "0",
                    "exitPanelHasSurfaceBeforeTrigger": hasSurfaceBeforeTrigger ? "1" : "0",
                ])
                if shouldWaitForSurface && !(attachedBeforeTrigger && hasSurfaceBeforeTrigger) {
                    write(["autoTriggerError": "exitPanelNotReadyBeforeTrigger"])
                    return
                }

                guard let panel = tab.terminalPanel(for: exitPanelId) else {
                    write(["autoTriggerError": "missingExitPanelAtTrigger"])
                    return
                }
                // Exercise the real key path (ghostty_surface_key for Ctrl+D).
                if panel.hostedView.sendSyntheticCtrlDForUITest(modifierFlags: triggerModifiers) {
                    write(["autoTriggerSentCtrlDKey1": "1"])
                } else {
                    write([
                        "autoTriggerCtrlDKeyUnavailable": "1",
                        "autoTriggerError": "ctrlDKeyUnavailable",
                    ])
                    return
                }

                // In strict mode, never mask routing bugs with fallback writes.
                if strictKeyOnly {
                    let strictModeLabel: String = {
                        if useEarlyCtrlShiftTrigger { return "strict_early_ctrl_shift_d" }
                        if useEarlyCtrlDTrigger { return "strict_early_ctrl_d" }
                        if triggerUsesShift { return "strict_ctrl_shift_d" }
                        return "strict_ctrl_d"
                    }()
                    write(["autoTriggerMode": strictModeLabel])
                    return
                }

                // Non-strict mode keeps one additional Ctrl+D retry for startup timing variance.
                try? await Task.sleep(nanoseconds: 450_000_000)
                if tab.panels[exitPanelId] != nil,
                   panel.hostedView.sendSyntheticCtrlDForUITest(modifierFlags: triggerModifiers) {
                    write(["autoTriggerSentCtrlDKey2": "1"])
                }
            }
        }
    }
}
#endif

extension TabManager {
    /// The session autosave fingerprint for this window.
    ///
    /// The deterministic hashing moved into
    /// `CmuxWorkspaces.SessionFingerprintService`; this thin caller flattens the
    /// live god state into the package's `SessionWorkspaceFingerprintInput` via
    /// the `SessionFingerprintHosting` witness (in
    /// `TabManager+SessionFingerprintHosting.swift`), resolving each panel's
    /// restorable-agent and surface-resume snapshots from the app-target indexes,
    /// then hands the value input to the service. Byte-identical to the legacy
    /// in-file hasher, which the autosave skip-on-unchanged optimization requires.
    func sessionAutosaveFingerprint(
        restorableAgentIndex: RestorableAgentSessionIndex = .empty,
        surfaceResumeBindingIndex: SurfaceResumeBindingIndex = .empty
    ) -> Int {
        let input = makeSessionWorkspaceFingerprintInput(
            resolveRestorableAgent: { workspaceId, panelId in
                Self.fingerprintRestorableAgent(
                    restorableAgentIndex.snapshot(workspaceId: workspaceId, panelId: panelId)
                )
            },
            resolveSurfaceResumeBinding: { workspaceId, panelId in
                guard let workspace = self.tabs.first(where: { $0.id == workspaceId }) else {
                    return nil
                }
                return Self.fingerprintSurfaceResumeBinding(
                    workspace.effectiveSurfaceResumeBinding(
                        panelId: panelId,
                        surfaceResumeBindingIndex: surfaceResumeBindingIndex
                    )
                )
            }
        )
        return Self.sessionFingerprintService.fingerprint(for: input)
    }

    /// The standalone fingerprint of one restorable-agent snapshot, used to
    /// detect resume-relevant changes. Flattens the app snapshot into the package
    /// value and forwards to `CmuxWorkspaces.SessionFingerprintService`.
    /// Byte-identical to the legacy in-file helper.
    nonisolated static func restorableAgentSnapshotFingerprint(
        _ snapshot: SessionRestorableAgentSnapshot?
    ) -> Int {
        sessionFingerprintService.restorableAgentFingerprint(
            for: fingerprintRestorableAgent(snapshot)
        )
    }

    /// The shared, stateless fingerprint service. A value type with no state,
    /// constructed once at the type level and reused by both fingerprint entry
    /// points (no per-window or singleton instance state added).
    nonisolated static let sessionFingerprintService = SessionFingerprintService()

    func sessionSnapshot(
        includeScrollback: Bool,
        restorableAgentIndex: RestorableAgentSessionIndex = .empty,
        surfaceResumeBindingIndex: SurfaceResumeBindingIndex? = nil
    ) -> SessionTabManagerSnapshot {
        // Capture the ordered tabs once so the flattened inputs and the
        // per-workspace snapshot closure index into the same array snapshot.
        let orderedTabs = tabs
        let inputs = orderedTabs.map { tab in
            SessionWorkspaceSnapshotInput(
                id: tab.id,
                groupId: tab.groupId,
                isRestorable: tab.isRestorableInSessionSnapshot
            )
        }
        let plan = sessionSnapshotBuilder.assembleTabManagerSnapshot(
            inputs: inputs,
            selectedTabId: selectedTabId,
            groups: workspaceGroups,
            maxWorkspaces: SessionPersistencePolicy.maxWorkspacesPerWindow,
            groupCoordinator: sessionSnapshotGroups,
            workspaceSnapshot: { index in
                orderedTabs[index].sessionSnapshot(
                    includeScrollback: includeScrollback,
                    restorableAgentIndex: restorableAgentIndex,
                    surfaceResumeBindingIndex: surfaceResumeBindingIndex
                )
            }
        )
        return SessionTabManagerSnapshot(
            selectedWorkspaceIndex: plan.selectedWorkspaceIndex,
            workspaces: plan.workspaceSnapshots,
            workspaceGroups: plan.groupSnapshots
        )
    }

    func sessionSnapshotWorkspaceIds() -> [UUID] {
        let inputs = tabs.map { tab in
            SessionWorkspaceSnapshotInput(
                id: tab.id,
                groupId: tab.groupId,
                isRestorable: tab.isRestorableInSessionSnapshot
            )
        }
        return sessionSnapshotBuilder.restorableWorkspaceIds(
            inputs: inputs,
            maxWorkspaces: SessionPersistencePolicy.maxWorkspacesPerWindow
        )
    }

    private func releaseRestoredAwayWorkspace(_ workspace: Workspace) {
        // Session restore replaces the bootstrap workspace objects with freshly
        // restored ones. Tear the old graph down after the atomic swap so late
        // panel/socket callbacks cannot keep mutating hidden pre-restore state.
        appEnvironment?.notificationStore?.clearNotifications(forTabId: workspace.id)
        workspace.teardownAllPanels()
        workspace.teardownRemoteConnection()
        workspace.owningTabManager = nil
    }

    @discardableResult
    func restoreSessionSnapshot(
        _ snapshot: SessionTabManagerSnapshot,
        remapClosedPanelHistory: Bool = true
    ) -> [[UUID: UUID]] {
        pendingSessionRestoreSnapshot = snapshot
        defer { pendingSessionRestoreSnapshot = nil }
        return sessionSnapshotRestore.restore(
            persistedGroupSnapshots: snapshot.workspaceGroups,
            selectedWorkspaceIndex: snapshot.selectedWorkspaceIndex,
            remapClosedPanelHistory: remapClosedPanelHistory
        )
    }

    // MARK: - SessionSnapshotRestoreHosting witnesses
    // The god-coupled steps of a whole-window session-snapshot restore: the
    // SessionSnapshotRestoreCoordinator (CmuxWorkspaces) owns the ordering and
    // pure decisions; these perform the steps touching the Workspace god type,
    // app-static port-ordinal state, closedItemHistory, and the
    // @Published stored properties that cannot cross the module boundary. Bodies
    // are lifted one-for-one from the former inline restoreSessionSnapshot body.

    func beginSessionSnapshotRestore() {
        isRestoringSessionSnapshot = true
    }

    func endSessionSnapshotRestore() {
        isRestoringSessionSnapshot = false
    }

    func currentWorkspaces() -> [Workspace] {
        tabs
    }

    func resetSubModels(previousTabs: [Workspace]) {
        for tab in previousTabs {
            unwireClosedBrowserTracking(for: tab)
        }
        closedItemHistory.removePanelRecords(
            forWorkspaceIds: Set(previousTabs.map(\.id))
        )
        sidebarGitMetadataService.resetAllWorkspaceGitProbeTracking()

        // Clear non-@Published state without touching tabs/selectedTabId yet.
        // Resets both the remembered-focus map and the deferred-unfocus target
        // (legacy `lastFocusedPanelByTab.removeAll()` + `pendingWorkspaceUnfocusTarget = nil`).
        focusedSurface.reset()
        surfaceMetadata.resetPendingPanelTitleUpdates()
        focusHistoryNavigation.reset()
        focusHistoryRevision &+= 1
        workspaceSelection.resetWorkspaceCycleHotWindow()
        selectionSideEffects.invalidateDeferredSelectionSideEffects()
        browserModel.clearRecentlyClosedBrowserPanels()
    }

    func buildRestoredWorkspaces() -> SessionSnapshotRestoreBuild<Workspace> {
        // The snapshot is set by `restoreSessionSnapshot` for the duration of the
        // synchronous restore turn the coordinator drives.
        let snapshot = pendingSessionRestoreSnapshot
        var newTabs: [Workspace] = []
        var restoredPanelIdsByWorkspaceIndex: [[UUID: UUID]] = []
        var restoredOriginalWorkspaceIds: [UUID?] = []
        let workspaceSnapshots = (snapshot?.workspaces ?? [])
            .prefix(SessionPersistencePolicy.maxWorkspacesPerWindow)
        for workspaceSnapshot in workspaceSnapshots {
            let ordinal = portOrdinalAllocator.next()
            let workspace = Workspace(
                title: workspaceSnapshot.processTitle,
                workingDirectory: workspaceSnapshot.currentDirectory,
                portOrdinal: ordinal
            )
            workspace.owningTabManager = self
            let restoredPanelIds = workspace.restoreSessionSnapshot(workspaceSnapshot)
            wireClosedBrowserTracking(for: workspace)
            newTabs.append(workspace)
            restoredPanelIdsByWorkspaceIndex.append(restoredPanelIds)
            restoredOriginalWorkspaceIds.append(workspaceSnapshot.workspaceId)
        }

        if newTabs.isEmpty {
            let ordinal = portOrdinalAllocator.next()
            let fallback = Workspace(title: "Terminal 1", portOrdinal: ordinal)
            fallback.owningTabManager = self
            wireClosedBrowserTracking(for: fallback)
            newTabs.append(fallback)
        }
        return SessionSnapshotRestoreBuild(
            tabs: newTabs,
            restoredPanelIdsByWorkspaceIndex: restoredPanelIdsByWorkspaceIndex,
            restoredOriginalWorkspaceIds: restoredOriginalWorkspaceIds
        )
    }

    func commitRestoredState(
        tabs newTabs: [Workspace],
        groups: [WorkspaceGroup],
        knownGroupIds: Set<UUID>,
        selectedTabId newSelectedId: UUID?
    ) {
        // Single atomic assignment of @Published properties so SwiftUI observers
        // never see an intermediate state with empty tabs or nil selection.
        tabs = newTabs
        // Clear any group references on restored workspaces that no longer
        // correspond to a known group (older snapshots, manual edits, etc.).
        for workspace in newTabs where workspace.groupId.map({ !knownGroupIds.contains($0) }) ?? false {
            workspace.groupId = nil
        }
        workspaceGroups = groups
        selectedTabId = newSelectedId
    }

    func pruneBackgroundLoadsAndSelection(existingIds: Set<UUID>) {
        pruneBackgroundWorkspaceLoads(existingIds: existingIds)
        sidebarMultiSelection.intersectSelection(with: existingIds)
    }

    func releaseAwayWorkspaces(_ previousTabs: [Workspace]) {
        for workspace in previousTabs {
            releaseRestoredAwayWorkspace(workspace)
        }
    }

    func scheduleInitialGitMetadata(for tabs: [Workspace]) {
        for workspace in tabs {
            let terminalPanels = workspace.panels.values.compactMap { $0 as? TerminalPanel }
            for terminalPanel in terminalPanels {
                scheduleInitialWorkspaceGitMetadataRefreshIfPossible(
                    workspaceId: workspace.id,
                    panelId: terminalPanel.id
                )
            }
        }
    }

    func postDidFocusTab(selectedTabId: UUID) {
        NotificationCenter.default.post(
            name: .ghosttyDidFocusTab,
            object: nil,
            userInfo: [GhosttyNotificationKey.tabId: selectedTabId]
        )
    }

    func remapClosedPanelHistoryAfterSessionRestore(
        originalWorkspaceIds: [UUID?],
        restoredPanelIdsByWorkspaceIndex: [[UUID: UUID]]
    ) {
        let operations = closedPanelHistoryRemapPlanner.planSessionRestoreRemaps(
            originalWorkspaceIds: originalWorkspaceIds,
            restoredWorkspaceIds: tabs.map(\.id),
            panelIdMapsByIndex: restoredPanelIdsByWorkspaceIndex
        )
        applyClosedPanelHistoryRemaps(operations)
    }

    func remapClosedPanelHistoryAfterWindowRestore(
        originalWorkspaceIds: [UUID],
        restoredPanelIdsByWorkspaceIndex: [[UUID: UUID]]
    ) {
        let operations = closedPanelHistoryRemapPlanner.planWindowRestoreRemaps(
            originalWorkspaceIds: originalWorkspaceIds,
            restoredWorkspaceIds: tabs.map(\.id),
            panelIdMapsByIndex: restoredPanelIdsByWorkspaceIndex
        )
        applyClosedPanelHistoryRemaps(operations)
    }

    // Applies the planned closed-panel-history workspace-id remaps to the
    // injected history store and flushes once when any op ran, matching the
    // legacy `didRequestHistoryRemap` gate. `closedItemHistory` is the
    // composition-root-injected instance (no longer the `.shared` global) and
    // stays app-side (`ClosedItemHistoryStore` is an app-target type).
    // Internal (not private) because it is the SessionSnapshotRestoreHosting
    // witness for `applyClosedPanelHistoryRemaps(_:)`.
    func applyClosedPanelHistoryRemaps(
        _ operations: [ClosedPanelHistoryRemapOperation]
    ) {
        guard !operations.isEmpty else { return }
        for operation in operations {
            closedItemHistory.remapPanelWorkspaceIds(
                from: operation.fromWorkspaceId,
                to: operation.toWorkspaceId,
                panelIdMap: operation.panelIdMap
            )
        }
        closedItemHistory.flushPendingSaves()
    }
}

// The hook methods live in the class body (they touch private selection /
// DEBUG state); these extensions only bind the conformances. `WorkspacesHosting`'s
// `Tab` is bound explicitly because its surviving requirements (the selection
// hooks) are keyed by `UUID`, not `Tab`, after the `Tab`-typed `tabs`/
// `workspaceGroups` willSet hooks were retired, so it can no longer be inferred.
extension TabManager: WorkspacesHosting {
    typealias Tab = Workspace
}
extension TabManager: WorkspaceSelectionSideEffectsHosting {}
extension TabManager: WorkspaceGroupHosting {}
extension TabManager: SessionSnapshotRestoreHosting {}
extension TabManager: WorkspaceCloseHosting {}
extension TabManager: SurfaceMetadataTitleHosting {}

// Workspace satisfies the CmuxWorkspaces tab seam with its existing
// id/groupId/isPinned storage; the panel-resolution requirements
// (`panelExists(_:)` / `panelId(forSurfaceId:)`) are already witnessed by
// `Workspace+WorkspaceSurfaceTreeReading.swift`, so this conformance is empty.
extension Workspace: WorkspaceTabRepresenting {}

extension Notification.Name {
    // The sidebar multi-selection sync events moved to CmuxSidebar as typed
    // SidebarMultiSelectionShouldCollapseEvent / DidHideEvent (same names).
    //
    // The command-palette names are owned by CmuxCommandPalette: the open-request
    // names by CommandPaletteRequestKind, the interaction/lifecycle signals by
    // CommandPaletteSignal. These accessors forward to those typed events so each
    // wire string lives in one place (mirrors the browser omnibar/first-responder
    // events below). The resulting Notification.Name strings are byte-identical.
    static let commandPaletteToggleRequested = CommandPaletteSignal.toggle.notificationName
    static let commandPaletteRequested = Notification.Name(CommandPaletteRequestKind.commands.notificationName)
    static let commandPaletteSwitcherRequested = Notification.Name(CommandPaletteRequestKind.switcher.notificationName)
    static let commandPaletteSubmitRequested = CommandPaletteSignal.submit.notificationName
    static let commandPaletteDismissRequested = CommandPaletteSignal.dismiss.notificationName
    static let commandPaletteRenameTabRequested = Notification.Name(CommandPaletteRequestKind.renameTab.notificationName)
    static let commandPaletteRenameWorkspaceRequested = Notification.Name(CommandPaletteRequestKind.renameWorkspace.notificationName)
    static let commandPaletteEditWorkspaceDescriptionRequested = Notification.Name(CommandPaletteRequestKind.editWorkspaceDescription.notificationName)
    static let commandPaletteMoveSelection = CommandPaletteSignal.moveSelection.notificationName
    static let commandPaletteRenameInputInteractionRequested = CommandPaletteSignal.renameInputInteraction.notificationName
    static let commandPaletteRenameInputDeleteBackwardRequested = CommandPaletteSignal.renameInputDeleteBackward.notificationName
    static let feedbackComposerRequested = Notification.Name("cmux.feedbackComposerRequested")
    static let browserDidBecomeFirstResponderWebView = BrowserFirstResponderEvent.notificationName
    static let browserFocusAddressBar = BrowserOmnibarFocusSignal.focusAddressBar.notificationName
    static let browserMoveOmnibarSelection = BrowserOmnibarFocusSignal.moveSelection.notificationName
    static let browserDidExitAddressBar = BrowserOmnibarFocusSignal.didExitAddressBar.notificationName
    static let browserDidFocusAddressBar = BrowserOmnibarFocusSignal.didFocusAddressBar.notificationName
    static let browserDidBlurAddressBar = BrowserOmnibarFocusSignal.didBlurAddressBar.notificationName
    static let browserFocusModeStateDidChange = BrowserPanelSignal.focusModeStateDidChange.notificationName
    static let webViewDidReceiveClick = BrowserPanelSignal.webViewDidReceiveClick.notificationName
    static let terminalPortalVisibilityDidChange = BrowserPortalSignal.terminalPortalVisibilityDidChange.notificationName
    static let browserPortalRegistryDidChange = BrowserPortalSignal.browserPortalRegistryDidChange.notificationName
}

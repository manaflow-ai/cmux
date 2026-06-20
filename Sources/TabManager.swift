import AppKit
import CmuxFoundation
import CmuxTerminalCore
import SwiftUI
import Foundation
import Bonsplit
import CmuxBrowser
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

enum WorkspaceOrderChangeNotificationKey {
    static let movedWorkspaceIds = "movedWorkspaceIds"
}

/// Coalesces repeated main-thread signals into one callback after a short delay.
/// Useful for notification storms where only the latest update matters.
final class NotificationBurstCoalescer {
    private let delay: TimeInterval
    private var isFlushScheduled = false
    private var pendingAction: (() -> Void)?

    init(delay: TimeInterval = 1.0 / 30.0) {
        self.delay = max(0, delay)
    }

    func signal(_ action: @escaping () -> Void) {
        precondition(Thread.isMainThread, "NotificationBurstCoalescer must be used on the main thread")
        pendingAction = action
        scheduleFlushIfNeeded()
    }

    private func scheduleFlushIfNeeded() {
        guard !isFlushScheduled else { return }
        isFlushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.flush()
        }
    }

    private func flush() {
        precondition(Thread.isMainThread, "NotificationBurstCoalescer must be used on the main thread")
        isFlushScheduled = false
        guard let action = pendingAction else { return }
        pendingAction = nil
        action()
        if pendingAction != nil {
            scheduleFlushIfNeeded()
        }
    }
}

#if DEBUG
// Sample the actual IOSurface-backed terminal layer at vsync cadence so UI tests can reliably
// catch a single compositor-frame blank flash and any transient compositor scaling (stretched text).
//
// This is DEBUG-only and used only for UI tests; no polling or display-link loops exist in normal app runtime.
//
// The pure per-frame detection/trace logic lives in CmuxTestSupport's
// VsyncIOSurfaceTimelineAnalyzer (a Sendable-input, AppKit-free value
// transform). This app-side state owns the irreducible seam: the
// CVDisplayLink lifecycle, the NSLock-guarded in-flight/finished
// coordination read from the C callback, and the GhosttySurfaceScrollView /
// QuartzCore live sampling closures. Each frame it samples its targets on the
// main thread, converts them to VsyncFrameSample values, and feeds them to the
// analyzer.
fileprivate final class VsyncIOSurfaceTimelineState {
    struct Target {
        let label: String
        let sample: @MainActor () -> GhosttySurfaceScrollView.DebugFrameSample?
    }

    let analyzer: VsyncIOSurfaceTimelineAnalyzer
    let lock = NSLock()

    var inFlight = false
    var finished = false

    var scheduledActions: [(frame: Int, action: () -> Void)] = []
    var nextActionIndex: Int = 0

    var targets: [Target] = []

    var link: CVDisplayLink?
    var continuation: CheckedContinuation<Void, Never>?

    var frameCount: Int { analyzer.frameCount }
    var framesWritten: Int { analyzer.framesWritten }
    var firstBlank: (label: String, frame: Int)? { analyzer.firstBlank }
    var firstSizeMismatch: (label: String, frame: Int, ios: String, expected: String)? { analyzer.firstSizeMismatch }
    var trace: [String] { analyzer.trace }

    init(frameCount: Int, closeFrame: Int) {
        self.analyzer = VsyncIOSurfaceTimelineAnalyzer(frameCount: frameCount, closeFrame: closeFrame)
    }

    func tryBeginCapture() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if finished { return false }
        if inFlight { return false }
        inFlight = true
        return true
    }

    func endCapture() {
        lock.lock()
        inFlight = false
        lock.unlock()
    }

    func finish() {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume()
    }
}

fileprivate func cmuxVsyncIOSurfaceTimelineCallback(
    _ displayLink: CVDisplayLink,
    _ inNow: UnsafePointer<CVTimeStamp>,
    _ inOutputTime: UnsafePointer<CVTimeStamp>,
    _ flagsIn: CVOptionFlags,
    _ flagsOut: UnsafeMutablePointer<CVOptionFlags>,
    _ ctx: UnsafeMutableRawPointer?
) -> CVReturn {
    guard let ctx else { return kCVReturnSuccess }
    let st = Unmanaged<VsyncIOSurfaceTimelineState>.fromOpaque(ctx).takeUnretainedValue()
    if !st.tryBeginCapture() { return kCVReturnSuccess }

    // Sample on the main thread synchronously so we don't "miss" a single compositor frame.
    // (The previous Task/@MainActor hop could be delayed long enough to skip the blank frame.)
    DispatchQueue.main.sync {
        defer { st.endCapture() }
        guard !st.analyzer.isComplete else { return }

        while st.nextActionIndex < st.scheduledActions.count {
            let next = st.scheduledActions[st.nextActionIndex]
            if next.frame != st.framesWritten { break }
            st.nextActionIndex += 1
            next.action()
        }

        let frameSamples: [VsyncFrameSample] = st.targets.compactMap { t in
            guard let s = t.sample() else { return nil }
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

        st.analyzer.ingest(frameSamples: frameSamples)
    }

    // Stop/resume outside the main-thread sync block to avoid reentrancy issues.
    if st.framesWritten >= st.frameCount, let link = st.link {
        CVDisplayLinkStop(link)
        st.finish()
        Unmanaged<VsyncIOSurfaceTimelineState>.fromOpaque(ctx).release()
    }

    return kCVReturnSuccess
}
#endif

// WorkspaceGroup, WorkspaceReorderPlanItem, WorkspaceBatchReorderError, and
// the pure batch-reorder planning live in CmuxWorkspaces.

@MainActor
class TabManager: ObservableObject {
    /// The window that owns this TabManager. Set by AppDelegate.registerMainWindow().
    /// Used to apply title updates to the correct window instead of NSApp.keyWindow.
    weak var window: NSWindow?
    /// Stable identifier of the owning macOS window. Used only for opt-in title
    /// templates that expose a WM-matchable per-window token.
    var windowId: UUID?

    // Wave-4 sub-model (TabManager decomposition): the workspace list, the
    // sidebar group sections, and the selected-workspace id storage live in
    // WorkspacesModel (CmuxWorkspaces). TabManager stays the per-window
    // composition point: it owns the model, forwards the legacy accessors
    // below, and implements WorkspacesHosting (bottom of this file) to run
    // the legacy @Published property-observer side effects at identical
    // timing (objectWillChange + bridge publishers in willSet, selection
    // side effects in didSet).
    let workspaces = WorkspacesModel<Workspace>()

    /// Window-title + per-surface shell-activity reads/mutations over the
    /// workspace list (CmuxWorkspaces). The PR-refresh half of
    /// `updateSurfaceShellActivity` stays in this composition root because it
    /// routes through `pullRequestProbing`, which CmuxWorkspaces does not import.
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

    /// Legacy Combine bridge for the remaining `tabManager.$tabs`
    /// subscribers. Driven exclusively from `workspaceTabsWillChange(to:)`,
    /// so it emits the new value during willSet and replays the current
    /// value on subscribe — the exact `Published.Publisher` semantics those
    /// call sites were written against. Single seam; delete when the
    /// subscribers move to @Observable observation.
    let tabsPublisher = CurrentValueSubject<[Workspace], Never>([])
    /// Legacy Combine bridge for the remaining `tabManager.$selectedTabId`
    /// subscribers; same contract as `tabsPublisher`.
    let selectedTabIdPublisher = CurrentValueSubject<UUID?, Never>(nil)
    /// Legacy Combine bridge for the remaining `tabManager.$workspaceGroups`
    /// subscribers (e.g. MobileWorkspaceListObserver); same contract as
    /// `tabsPublisher`. Emits during willSet and replays the current value
    /// on subscribe — the `Published.Publisher` semantics those call sites
    /// were written against.
    let workspaceGroupsPublisher = CurrentValueSubject<[WorkspaceGroup], Never>([])
    /// Set by `restoreSessionSnapshot` to suppress side-effects (like auto-
    /// expanding a group on focus) that would mutate restored state mid-restore.
    private var isRestoringSessionSnapshot: Bool = false
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

    /// Global monotonically increasing counter for CMUX_PORT ordinal assignment.
    /// Static so port ranges don't overlap across multiple windows (each window has its own TabManager).
    static var nextPortOrdinal: Int = 0
    var selectedTabId: UUID? {
        get { workspaces.selectedTabId }
        set { workspaces.selectedTabId = newValue }
    }

    // MARK: - WorkspacesHosting hooks (legacy @Published property observers)

    /// Legacy `@Published tabs` willSet: objectWillChange plus the Combine
    /// bridge fire before storage changes, matching @Published timing.
    func workspaceTabsWillChange(to newValue: [Workspace]) {
        objectWillChange.send()
        tabsPublisher.send(newValue)
    }

    /// Legacy `@Published workspaceGroups` willSet.
    func workspaceGroupsWillChange(to newValue: [WorkspaceGroup]) {
        objectWillChange.send()
        workspaceGroupsPublisher.send(newValue)
    }

    /// Legacy `@Published selectedTabId` willSet; `selectedTabId` still
    /// reads the old value here, exactly like the original property observer.
    func selectedWorkspaceIdWillChange(to newValue: UUID?) {
        objectWillChange.send()
        selectedTabIdPublisher.send(newValue)
#if DEBUG
            guard newValue != selectedTabId else {
                debugPendingWorkspaceSwitchTrigger = nil
                debugPendingWorkspaceSwitchTarget = nil
                debugPreparedWorkspaceSwitchTarget = nil
                return
            }

            if debugPreparedWorkspaceSwitchTarget == newValue {
                debugPreparedWorkspaceSwitchTarget = nil
                debugPendingWorkspaceSwitchTrigger = nil
                debugPendingWorkspaceSwitchTarget = nil
            } else {
                let trigger = (debugPendingWorkspaceSwitchTarget == newValue
                    ? debugPendingWorkspaceSwitchTrigger
                    : nil) ?? "direct"
                debugPendingWorkspaceSwitchTrigger = nil
                debugPendingWorkspaceSwitchTarget = nil
                debugBeginWorkspaceSwitch(
                    trigger: trigger,
                    from: selectedTabId,
                    to: newValue
                )
            }
#endif
    }

    /// Legacy `@Published selectedTabId` didSet: the selection side-effect
    /// chain, run synchronously after storage changed.
    func selectedWorkspaceIdDidChange(from oldValue: UUID?) {
            guard selectedTabId != oldValue else { return }
            if !isRestoringSessionSnapshot {
                workspaces.expandWorkspaceGroupForSelectionIfNeeded()
            }
            sentryBreadcrumb("workspace.switch", data: [
                "tabCount": tabs.count
            ])
            let previousTabId = oldValue
            if let previousTabId {
                focusedSurface.recordRememberedFocusForPreviousSelection(previousTabId)
            }
            if shouldRecordFocusHistory {
                if let previousTabId {
                    focusHistoryNavigation.recordFocusInHistory(
                        workspaceId: previousTabId,
                        panelId: focusedPanelId(for: previousTabId),
                        preservingForwardBranch: false
                    )
                }
                if let selectedTabId,
                   tabs.contains(where: { $0.id == selectedTabId }) {
                    let selectedEntry = FocusHistoryEntry(
                        workspaceId: selectedTabId,
                        panelId: focusedSurface.rememberedFocusedPanelId(selectedTabId)
                    )
                    focusHistoryNavigation.recordFocusInHistory(
                        workspaceId: selectedTabId,
                        panelId: focusHistoryNavigation.resolvedFocusHistoryPanelId(for: selectedEntry),
                        preservingForwardBranch: false
                    )
                }
            }
            publishCmuxWorkspaceSelectedChange(from: previousTabId)
            let notificationDismissalContext = notificationDismissal.takePendingSelectionContext() ?? .activeFocus
#if DEBUG
            let switchId = debugWorkspaceSwitchId
            let switchDtMs = debugWorkspaceSwitchStartTime > 0
                ? (CACurrentMediaTime() - debugWorkspaceSwitchStartTime) * 1000
                : 0
            cmuxDebugLog(
                "ws.select.didSet id=\(switchId) from=\(Self.debugShortWorkspaceId(previousTabId)) " +
                "to=\(Self.debugShortWorkspaceId(selectedTabId)) dt=\(Self.debugMsText(switchDtMs))"
            )
#endif
            selectionSideEffectsGeneration &+= 1
            let generation = selectionSideEffectsGeneration
            if !shouldRecordFocusHistory {
                focusHistoryNavigation.markSuppressedSelectionSideEffectGeneration(generation)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let suppressFocusHistory = self.focusHistoryNavigation.consumeSuppressedSelectionSideEffectGeneration(generation)
                guard self.selectionSideEffectsGeneration == generation else { return }
                let applySelectionSideEffects = {
                    self.focusedSurface.focusSelectedWorkspacePanel(previousWorkspaceId: previousTabId)
                    self.updateWindowTitleForSelectedTab()
                    if let selectedTabId = self.selectedTabId {
                        self.dismissFocusedPanelNotificationIfActive(
                            tabId: selectedTabId,
                            context: notificationDismissalContext
                        )
                    }
                }
                if suppressFocusHistory {
                    self.focusHistoryNavigation.withFocusHistoryRecordingSuppressed(applySelectionSideEffects)
                } else {
                    applySelectionSideEffects()
                }
#if DEBUG
                let dtMs = self.debugWorkspaceSwitchStartTime > 0
                    ? (CACurrentMediaTime() - self.debugWorkspaceSwitchStartTime) * 1000
                    : 0
                cmuxDebugLog(
                    "ws.select.asyncDone id=\(self.debugWorkspaceSwitchId) dt=\(Self.debugMsText(dtMs)) " +
                    "selected=\(Self.debugShortWorkspaceId(self.selectedTabId))"
                )
#endif
            }
    }
    private var observers: [NSObjectProtocol] = []
    /// Per-window focused-surface bookkeeping (remembered focused panel per
    /// workspace) + the deferred previous-workspace unfocus state machine
    /// (CmuxWorkspaces). TabManager hosts its seam
    /// (`TabManager+FocusedSurfaceHosting`) and forwards the legacy entry
    /// points below.
    let focusedSurface = FocusedSurfaceModel()
    /// The per-window panel-title coalescer the `SurfaceMetadataCoordinator`
    /// schedules its flush on through `SurfaceMetadataTitleHosting`. The
    /// coalescing batch + flush logic live in the coordinator (CmuxWorkspaces);
    /// this app-target coalescer (shared by other window-chrome call sites)
    /// stays here and is driven via the host seam.
    private let panelTitleUpdateCoalescer = NotificationBurstCoalescer(delay: 1.0 / 30.0)

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
    // Pure planner for the closed-panel-history workspace-id remaps a restore
    // requires (CmuxWorkspaces); the app shell applies each op to the closed-
    // item history store and flushes once.
    let closedPanelHistoryRemapPlanner = ClosedPanelHistoryRemapPlanner()
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
    // (localized strings + confirmClose, in this file's class body).
    let workspaceClosing: WorkspaceCloseCoordinator<Workspace>
    // Pure new-workspace insertion planning over the workspaces model
    // (CmuxWorkspaces): the pre-creation snapshot, its live-order remap, and the
    // placement-driven insertion index. The creation orchestration (Workspace
    // boot, chrome inheritance, port ordinal, lifecycle publish, selection/focus,
    // welcome send) is irreducibly app-coupled and stays in this file, calling
    // these computations.
    let workspaceCreating: WorkspaceCreationCoordinator<Workspace>
    // Selection-navigation flows over the workspaces model + background-load
    // model (CmuxWorkspaces): the next/prev wrap-around order math, select-by-
    // index, select-last, and the cycle-hot window state machine (generation +
    // cooldown task + isWorkspaceCycleHot). The irreducible app-coupled effects
    // (the private selectWorkspaceId mutation chain, the sidebar multi-selection
    // collapse, and DEBUG switch tracing) invert through
    // WorkspaceSelectionHosting (TabManager+WorkspaceSelectionHosting.swift).
    let workspaceSelection: WorkspaceSelectionCoordinator<Workspace>
    private var shouldRecordFocusHistory: Bool {
        focusHistoryNavigation.shouldRecordFocusHistory
    }
    private var selectionSideEffectsGeneration: UInt64 = 0
    var sidebarSelectedWorkspaceIds: Set<UUID> { sidebarMultiSelection.selectedWorkspaceIds }
    private var currentWindowTabBarLeadingInset: CGFloat?
    private var closeConfirmationInFlight = false
    var confirmCloseHandler: ((String, String, Bool) -> Bool)?
    private var agentPIDSweepTimer: DispatchSourceTimer?
#if DEBUG
    private var debugWorkspaceSwitchCounter: UInt64 = 0
    private var debugWorkspaceSwitchId: UInt64 = 0
    private var debugWorkspaceSwitchStartTime: CFTimeInterval = 0
    private var debugPendingWorkspaceSwitchTrigger: String?
    private var debugPendingWorkspaceSwitchTarget: UUID?
    private var debugPreparedWorkspaceSwitchTarget: UUID?
#endif

#if DEBUG
    private var didSetupUITestSplitScaffolds = false
    private var uiTestCancellables = Set<AnyCancellable>()
#endif

    // Process-wide cap on concurrent sidebar git snapshot probes, shared by
    // every window's SidebarGitMetadataService. A static (not a per-instance
    // default) on purpose: the cap is per process, not per window, matching
    // the legacy shared limiter; tests inject their own instance.
    private static let sharedWorkspaceGitProbeLimiter = WorkspaceGitMetadataProbeLimiter(limit: 2)

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
        settings: any SettingsWriting = UserDefaultsSettingsClient(defaults: .standard)
    ) {
        self.settings = settings
        workspaceReordering = WorkspaceReorderCoordinator(model: workspaces)
        workspaceCommands = WorkspaceCommandCoordinator(model: workspaces, reordering: workspaceReordering)
        workspaceGrouping = WorkspaceGroupCoordinator(model: workspaces)
        workspaceClosing = WorkspaceCloseCoordinator(model: workspaces)
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
        surfaceMetadata.attach(titleHost: self)
        // Workspace-list/group/selection storage (CmuxWorkspaces). Attached
        // before the first addWorkspace so the property-observer hooks fire
        // from the very first insertion, matching the legacy @Published
        // observer timing.
        workspaces.attach(host: self)
        workspaceReordering.attach(host: self)
        workspaceCommands.attach(host: self)
        workspaceSelection.attach(host: self)
        workspaceGrouping.attach(host: self)
        workspaceClosing.attach(confirming: self)
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
        addWorkspace(
            title: initialWorkspaceTitle,
            workingDirectory: initialWorkingDirectory,
            initialTerminalInput: initialTerminalInput,
            autoWelcomeIfNeeded: autoWelcomeIfNeeded
        )
        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDidSetTitle,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated { [weak self] in
                guard let self else { return }
                guard let change = GhosttyTitleChange(notification: notification) else { return }
                enqueuePanelTitleUpdate(tabId: change.tabId, panelId: change.surfaceId, title: change.title)
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDidFocusSurface,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated { [weak self] in
                guard let self else { return }
                guard let tabId = notification.userInfo?[GhosttyNotificationKey.tabId] as? UUID else { return }
                guard let surfaceId = notification.userInfo?[GhosttyNotificationKey.surfaceId] as? UUID else { return }
                let explicitFocusIntent = notification.userInfo?[GhosttyNotificationKey.explicitFocusIntent] as? Bool ?? false
                let panelId = panelIdForFocusHistorySurface(surfaceId, workspaceId: tabId)
                if selectedTabId == tabId {
                    if explicitFocusIntent {
                        focusHistoryNavigation.recordFocusInHistory(
                            workspaceId: tabId,
                            panelId: panelId,
                            preservingForwardBranch: false
                        )
                    } else {
                        focusHistoryNavigation.recordImplicitFocusInHistory(workspaceId: tabId, panelId: panelId)
                    }
                }
                dismissPanelNotificationOnFocus(tabId: tabId, panelId: panelId, explicitFocusIntent: explicitFocusIntent)
                focusedSurfaceTitleDidChange(tabId: tabId)
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .workspaceCurrentDirectoryDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated { [weak self] in
                guard let self else { return }
                let workspaceId = notification.userInfo?["workspaceId"] as? UUID
                    ?? (notification.object as? Workspace)?.id
                guard let workspaceId else { return }
                workspaceCurrentDirectoryDidChange(workspaceId: workspaceId)
            }
        })

        startAgentPIDSweepTimer()
        observers.append(NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { [weak self] in
                self?.sidebarMetadataSettingsDidChange()
                self?.refreshTabCloseButtonVisibility()
                self?.refreshWindowTitle()
            }
        })
#if DEBUG
        setupUITestSplitScaffoldsIfNeeded()
#endif
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        // The workspace-cycle cooldown task is owned by `workspaceSelection`
        // (CmuxWorkspaces); it deallocates with this TabManager and its task's
        // `[weak self]` guard no-ops after dealloc, so no explicit cancel is
        // needed from this nonisolated deinit.
        agentPIDSweepTimer?.cancel()
        // The sidebar git/PR services cancel their own poll, probe, snapshot,
        // and refresh tasks in their deinits; they deallocate with this
        // TabManager (the host back-references are weak).
    }

    // MARK: - Agent PID Sweep

    /// Periodically checks agent PIDs associated with status entries.
    /// If a process has exited (SIGKILL, crash, etc.), clears the stale status entry.
    /// This is the safety net for cases where no hook fires (e.g. SIGKILL).
    private func startAgentPIDSweepTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.sweepStaleAgentPIDs()
            }
        }
        timer.resume()
        agentPIDSweepTimer = timer
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


    private func sweepStaleAgentPIDs() {
        for tab in tabs {
            var keysToRemove: [String] = []
            for (key, pid) in tab.agentPIDs {
                guard pid > 0 else {
                    keysToRemove.append(key)
                    continue
                }
                // kill(pid, 0) probes process liveness without sending a signal.
                // ESRCH = process doesn't exist (stale). EPERM = process exists
                // but we lack permission (not stale, keep tracking).
                errno = 0
                if kill(pid, 0) == -1, POSIXErrorCode(rawValue: errno) == .ESRCH {
                    keysToRemove.append(key)
                }
            }
            if !keysToRemove.isEmpty {
                for key in keysToRemove {
                    tab.clearAgentPID(key: key, clearStatus: true, refreshPorts: false)
                }
                let remainingAgentPIDs = Set(tab.agentPIDs.values.compactMap { $0 > 0 ? Int($0) : nil })
                PortScanner.shared.refreshAgentPorts(workspaceId: tab.id, agentPIDs: remainingAgentPIDs)
                // Also clear stale notifications (e.g. "Doing well, thanks!")
                // left behind when Claude was killed without SessionEnd firing.
                AppDelegate.shared?.notificationStore?.clearNotifications(forTabId: tab.id)
            }
        }
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
        let inheritedLeadingInset = currentWindowTabBarLeadingInset
            ?? sourceWorkspace?.bonsplitController.configuration.appearance.tabBarLeadingInset
        guard let inheritedLeadingInset else { return }
        applyTabBarLeadingInset(inheritedLeadingInset, to: newWorkspace)
    }

    func syncWorkspaceTabBarLeadingInset(_ inset: CGFloat) {
        let normalizedInset = max(0, inset)
        currentWindowTabBarLeadingInset = normalizedInset
        for tab in tabs {
            applyTabBarLeadingInset(normalizedInset, to: tab)
        }
    }

    private func applyTabBarLeadingInset(_ inset: CGFloat, to workspace: Workspace) {
        if workspace.bonsplitController.configuration.appearance.tabBarLeadingInset != inset {
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
        let panels = workspace.panels
        var candidates: [TerminalPanel] = []
        var seen: Set<UUID> = []

        func appendCandidate(_ panel: TerminalPanel?) {
            guard let panel, seen.insert(panel.id).inserted else { return }
            candidates.append(panel)
        }

        appendCandidate(workspace.lastRememberedTerminalPanelForConfigInheritance())
        for terminalPanel in panels.values
            .compactMap({ $0 as? TerminalPanel })
            .sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            appendCandidate(terminalPanel)
        }

        if let livePanel = candidates.first(where: { $0.surface.hasLiveSurface && $0.surface.surface != nil }) {
            return livePanel
        }
        return candidates.first
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
        return withExtendedLifetime(workspace) {
            guard let fontPoints = workspace.lastRememberedTerminalFontPointsForConfigInheritance(),
                  fontPoints > 0 else {
                return nil
            }
            return fontPoints
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

    func preferredWorkingDirectoryForNewTab(
        workspace: Workspace?
    ) -> String? {
        guard let workspace else {
            return nil
        }
        // Use cached directory state only; avoiding live focus traversal keeps workspace
        // creation resilient when Bonsplit is in the middle of a rapid Cmd+N churn.
        if let currentDirectory = normalizedWorkingDirectory(workspace.currentDirectory) {
            return currentDirectory
        }

        return workspace.panelDirectories.values.lazy.compactMap { directory in
            self.normalizedWorkingDirectory(directory)
        }.first
    }

    func implicitWorkingDirectoryForNewWorkspace(from sourceWorkspace: Workspace?) -> String? {
        guard settings.value(for: settingsCatalog.app.workspaceInheritWorkingDirectory) else {
            return nil
        }
        return preferredWorkingDirectoryForNewTab(workspace: sourceWorkspace)
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
            name: .workspaceOrderDidChange,
            object: self,
            userInfo: [WorkspaceOrderChangeNotificationKey.movedWorkspaceIds: movedWorkspaceIds]
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
            AppDelegate.shared?.remoteTmuxController.handleMirrorWorkspaceRenamed(
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
        guard !closeConfirmationInFlight else { return }
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
        guard !closeConfirmationInFlight else { return }
        guard let plan = closeOtherTabsInFocusedPanePlan() else { return }

        if CloseTabWarningStore(defaults: .standard).shouldConfirmClose(requiresConfirmation: true, source: .shortcut) {
            let prompt = CloseOtherTabsConfirmationPrompt(titles: plan.titles)
            guard confirmClose(
                title: prompt.title,
                message: prompt.message,
                acceptCmdD: false
            ) else { return }
        }

        for panelId in plan.panelIds {
            plan.workspace.markCloseHistoryEligible(panelId: panelId)
            _ = plan.workspace.closePanel(panelId, force: true)
        }
    }

    func closeCurrentWorkspaceWithConfirmation() {
#if DEBUG
        UITestRecorder.incrementInt("closeTabInvocations")
#endif
        guard !closeConfirmationInFlight else { return }
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

    @discardableResult
    func closeWorkspaceWithConfirmation(_ workspace: Workspace) -> Bool {
        if workspace.isPinned {
            guard confirmPinnedWorkspaceClose(source: .workspace) else { return false }
            closeWorkspaceIfRunningProcess(workspace, requiresConfirmation: false)
            return true
        }
        closeWorkspaceIfRunningProcess(workspace)
        return true
    }

    @discardableResult
    func closeWorkspaceFromCloseTabGesture(_ workspace: Workspace) -> Bool {
        if workspace.isPinned {
            guard confirmPinnedWorkspaceClose(source: .tabClose) else { return false }
            closeWorkspaceIfRunningProcess(workspace, requiresConfirmation: false)
            return true
        }
        closeWorkspaceIfRunningProcess(workspace, source: .tabClose)
        return true
    }

    @discardableResult
    func closeWorkspaceFromTabCloseButton(_ workspace: Workspace) -> Bool {
        if workspace.isPinned {
            guard confirmPinnedWorkspaceClose(source: .tabCloseButton) else { return false }
            closeWorkspaceIfRunningProcess(workspace, requiresConfirmation: false)
            return true
        }
        closeWorkspaceIfRunningProcess(workspace, source: .tabCloseButton)
        return true
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

    /// Marks the window's pending close as a tab/session close so a remote-tmux
    /// mirror among `workspaces` is KILLED (synced with tmux) on the close commit
    /// rather than detached. The single decision point for every close path that
    /// closes the whole window directly — the last-workspace branch of
    /// ``closeWorkspaceIfRunningProcess`` and the batch/anchor paths in
    /// ``closeWorkspacesWithConfirmation`` — so every explicit tab-close intent kills
    /// consistently. ``AppDelegate``'s `shouldClose`/`onClose` consume or clear the
    /// marker (veto vs commit).
    private func markRemoteTmuxKillOnWindowCloseIfNeeded(for workspaces: [Workspace]) {
        guard workspaces.contains(where: { $0.isRemoteTmuxMirror }),
              let windowId = AppDelegate.shared?.windowId(for: self) else { return }
        AppDelegate.shared?.remoteTmuxController.markKillSessionsOnWindowClose(windowId: windowId)
    }

    func closeWorkspacesWithConfirmation(_ workspaceIds: [UUID], allowPinned: Bool) {
        let workspaces = workspaceClosing.orderedClosableWorkspaces(workspaceIds, allowPinned: allowPinned)
        guard !workspaces.isEmpty else { return }
        guard workspaces.count > 1 else {
            closeWorkspaceFromCloseTabGesture(workspaces[0])
            return
        }

        guard let plan = workspaceClosing.closeWorkspacesPlan(for: workspaces) else { return }
        if workspaceClosing.shouldConfirmClose(requiresConfirmation: true, source: .tabClose) {
            guard confirmClose(
                title: plan.title,
                message: plan.message,
                acceptCmdD: plan.acceptCmdD
            ) else { return }
        }

        if workspaces.count == tabs.count,
           let firstWorkspace = workspaces.first {
            // Closing every tab is still an explicit tab/session close: kill the
            // remote-tmux session(s) on commit, not detach.
            markRemoteTmuxKillOnWindowCloseIfNeeded(for: workspaces)
            if let window {
                window.performClose(nil)
                return
            }
            if AppDelegate.shared != nil {
                AppDelegate.shared?.closeMainWindowContainingTabId(firstWorkspace.id)
                return
            }
        }

        for workspace in workspaces {
            guard tabs.contains(where: { $0.id == workspace.id }) else { continue }
            // Anchor-close confirms inside closeWorkspaceIfRunningProcess.
            // If the user cancels that dialog during a batch, abort the
            // whole batch — otherwise the loop keeps closing later items
            // even though the user said "no" to the dialog that was up.
            if let groupId = workspace.groupId,
               let group = workspaceGroups.first(where: { $0.id == groupId }),
               group.anchorWorkspaceId == workspace.id,
               !settings.value(for: settingsCatalog.workspaceGroups.anchorCloseSuppressed) {
                let otherMemberCount = tabs.reduce(0) { partial, tab in
                    tab.groupId == groupId && tab.id != workspace.id ? partial + 1 : partial
                }
                if !confirmAnchorWorkspaceClose(groupName: group.name, otherMemberCount: otherMemberCount) {
                    return
                }
                // Anchor confirmed (or suppressed); skip the inner re-prompt
                // by closing without going through closeWorkspaceIfRunningProcess.
                if tabs.count <= 1 {
                    // Still a tab/session close → kill the remote session on commit.
                    markRemoteTmuxKillOnWindowCloseIfNeeded(for: [workspace])
                    if let window {
                        window.performClose(nil)
                    } else {
                        AppDelegate.shared?.closeMainWindowContainingTabId(workspace.id)
                    }
                } else {
                    closeWorkspace(workspace)
                }
                continue
            }
            closeWorkspaceIfRunningProcess(workspace, requiresConfirmation: false)
        }
    }

    func selectWorkspace(_ workspace: Workspace) {
#if DEBUG
        debugPrimeWorkspaceSwitchTrigger("select", to: workspace.id)
#endif
        selectWorkspaceId(workspace.id, notificationDismissalContext: .explicitWorkspaceResume)
    }

    // Keep selectTab as convenience alias
    func selectTab(_ tab: Workspace) { selectWorkspace(tab) }

    var isCloseConfirmationInFlight: Bool { closeConfirmationInFlight }

    func beginCloseConfirmationSession() -> Bool {
        guard !closeConfirmationInFlight else { return false }
        closeConfirmationInFlight = true
        return true
    }

    func endCloseConfirmationSession() {
        DispatchQueue.main.async { [weak self] in
            self?.closeConfirmationInFlight = false
        }
    }

    func confirmClose(title: String, message: String, acceptCmdD: Bool) -> Bool {
        guard beginCloseConfirmationSession() else { return false }
        defer { endCloseConfirmationSession() }

        if let confirmCloseHandler {
            return confirmCloseHandler(title, message, acceptCmdD)
        }
        _ = acceptCmdD

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "dialog.closeTab.close", defaultValue: "Close"))
        alert.addButton(withTitle: String(localized: "dialog.closeTab.cancel", defaultValue: "Cancel"))

        if let closeButton = alert.buttons.first {
            closeButton.keyEquivalent = "\r"
            closeButton.keyEquivalentModifierMask = []
            alert.window.defaultButtonCell = closeButton.cell as? NSButtonCell
            alert.window.initialFirstResponder = closeButton
        }
        if let cancelButton = alert.buttons.dropFirst().first {
            cancelButton.keyEquivalent = "\u{1b}"
        }

        #if DEBUG
        UITestRecorder.record([
            "closeConfirmationTitle": title,
            "closeConfirmationMessage": message,
        ])
        #endif

        return runCloseConfirmationAlert(alert) == .alertFirstButtonReturn
    }

    // MARK: - CloseConfirming (WorkspaceCloseCoordinator's app-side seam)
    //
    // The localized confirmation strings stay in the app bundle: a
    // `String(localized:)` resolved inside CmuxWorkspaces would bind to the
    // package bundle (which lacks these keys) and silently drop non-English
    // translations. The coordinator computes the plan shape; these witnesses
    // supply the catalog strings, lifted verbatim from the legacy
    // `closeWorkspacesPlan(for:)` / `closeWorkspaceDisplayTitle(_:)` bodies.

    func closeWorkspacesTitle(willCloseWindow: Bool) -> String {
        willCloseWindow
            ? String(localized: "dialog.closeWindow.title", defaultValue: "Close window?")
            : String(localized: "dialog.closeWorkspaces.title", defaultValue: "Close workspaces?")
    }

    func closeWorkspacesMessage(
        willCloseWindow: Bool,
        workspaceCount: Int,
        bulletedTitles: String
    ) -> String {
        let format = willCloseWindow
            ? String(
                localized: "dialog.closeWorkspacesWindow.message",
                defaultValue: "This will close the current window, its %1$lld workspaces, and all of their panels:\n%2$@"
            )
            : String(
                localized: "dialog.closeWorkspaces.message",
                defaultValue: "This will close %1$lld workspaces and all of their panels:\n%2$@"
            )
        return String(format: format, locale: .current, Int64(workspaceCount), bulletedTitles)
    }

    var workspaceDisplayTitleFallback: String {
        String(localized: "workspace.displayName.fallback", defaultValue: "Workspace")
    }

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
        AppDelegate.shared?.remoteTmuxController.handleWorkspaceClosed(workspaceId: tab.id)
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
        ClosedItemHistoryStore.shared.push(.workspace(ClosedWorkspaceHistoryEntry(
            workspaceId: tab.id,
            windowId: AppDelegate.shared?.windowId(for: self),
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
        AppDelegate.shared?.notificationStore?.clearNotifications(forTabId: workspaceId)
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

    func defaultWorkspaceTitle(initialSurface: NewWorkspaceInitialSurface, tabNumber: Int) -> String {
        switch initialSurface {
        case .terminal:
            return "Terminal \(tabNumber)"
        case .browser:
            // Match the browser surface's blank new-tab title; the
            // single-panel title sync keeps the workspace title following
            // the page title once the user navigates.
            return String(localized: "browser.newTab", defaultValue: "New tab")
        }
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
        let ordinal = Self.nextPortOrdinal
        Self.nextPortOrdinal += 1
        return ordinal
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

    private func runCloseConfirmationAlert(_ alert: NSAlert) -> NSApplication.ModalResponse {
        // Presentation (activate + sheet-on-main-window, else app-modal) is
        // shared with every other cmux dialog via `runCmuxModalAlert`. This
        // wrapper only adds the close-confirmation-specific UITest telemetry,
        // recorded from the presenter's actual path so the label can never
        // disagree with how the alert was really shown.
        return runCmuxModalAlert(
            alert,
            presentingWindow: closeConfirmationPresentingWindow()
        ) { presentation in
            #if DEBUG
            switch presentation {
            case .sheet(let hostWindow):
                // The sheet attaches after this hook returns, so read the
                // attachment on the next runloop turn (during the modal loop).
                DispatchQueue.main.async {
                    UITestRecorder.record([
                        "closeConfirmationPresentation": "sheet",
                        "closeConfirmationAttachedSheet": hostWindow.attachedSheet == nil ? "0" : "1",
                    ])
                }
            case .appModal(let hostWindowHadAttachedSheet):
                UITestRecorder.record([
                    "closeConfirmationPresentation": "appModal",
                    "closeConfirmationAttachedSheet": hostWindowHadAttachedSheet ? "1" : "0",
                ])
            }
            #endif
        }
    }

    private func closeConfirmationPresentingWindow() -> NSWindow? {
        cmuxMainWindowForModalPresentation(preferring: window)
    }

    private struct CloseOtherTabsInFocusedPanePlan {
        let workspace: Workspace
        let panelIds: [UUID]
        let titles: [String]
    }

    private func closeOtherTabsInFocusedPanePlan() -> CloseOtherTabsInFocusedPanePlan? {
        guard let workspace = selectedWorkspace else { return nil }
        guard let paneId = workspace.bonsplitController.focusedPaneId ?? workspace.bonsplitController.allPaneIds.first else {
            return nil
        }

        let tabsInPane = workspace.bonsplitController.tabs(inPane: paneId)
        guard !tabsInPane.isEmpty else { return nil }
        guard let selectedTabId = workspace.bonsplitController.selectedTab(inPane: paneId)?.id ?? tabsInPane.first?.id else {
            return nil
        }

        var targetPanelIds: [UUID] = []
        var targetTitles: [String] = []
        for tab in tabsInPane where tab.id != selectedTabId {
            guard let panelId = workspace.panelIdFromSurfaceId(tab.id) else { continue }
            if workspace.isPanelPinned(panelId) {
                continue
            }
            targetPanelIds.append(panelId)
            targetTitles.append(CloseOtherTabsConfirmationPrompt.displayTitle(workspace.panelTitle(panelId: panelId)))
        }

        guard !targetPanelIds.isEmpty else { return nil }
        return CloseOtherTabsInFocusedPanePlan(
            workspace: workspace,
            panelIds: targetPanelIds,
            titles: targetTitles
        )
    }

    private func closeWorkspaceIfRunningProcess(
        _ workspace: Workspace,
        requiresConfirmation: Bool = true,
        source: CloseConfirmationSource = .workspace
    ) {
        // Anchor-close ALWAYS prompts (subject to its own
        // workspaceGroups.anchorCloseSuppressed flag), regardless of
        // requiresConfirmation. Batch-close paths set requiresConfirmation=false
        // after their own generic prompt, but that generic prompt doesn't
        // mention group dissolution — silently ungrouping members during a
        // multi-close would be surprising. The "Don't ask again" toggle on
        // the anchor dialog is the user's opt-out.
        if let groupId = workspace.groupId,
           let group = workspaceGroups.first(where: { $0.id == groupId }),
           group.anchorWorkspaceId == workspace.id {
            let otherMemberCount = tabs.reduce(0) { partial, tab in
                tab.groupId == groupId && tab.id != workspace.id ? partial + 1 : partial
            }
            if !confirmAnchorWorkspaceClose(groupName: group.name, otherMemberCount: otherMemberCount) {
                return
            }
        }
        let willCloseWindow = tabs.count <= 1
        let needsCloseConfirmation = workspaceNeedsConfirmClose(workspace)
        if requiresConfirmation,
           workspaceClosing.shouldConfirmClose(requiresConfirmation: needsCloseConfirmation, source: source),
           !confirmClose(
               title: String(localized: "dialog.closeWorkspace.title", defaultValue: "Close workspace?"),
               message: String(localized: "dialog.closeWorkspace.message", defaultValue: "This will close the workspace and all of its panels."),
               acceptCmdD: willCloseWindow
           ) {
            return
        }
        if tabs.count <= 1 {
            // Last workspace in this window closes via the window-close path, but it
            // is still an explicit TAB/session close: for a remote-tmux mirror, mark
            // the close to KILL the session on commit (synced with tmux), even though
            // it also closes the app window. The marker is consumed on the (non-vetoed)
            // close commit, or cleared if the close is vetoed (single-window quit
            // warning) so a cancelled close never kills. A plain window/quit close
            // never sets it, so it detaches. Non-last workspaces kill via closeWorkspace.
            markRemoteTmuxKillOnWindowCloseIfNeeded(for: [workspace])
            if let window {
                window.performClose(nil)
            } else {
                AppDelegate.shared?.closeMainWindowContainingTabId(workspace.id)
            }
        } else {
            closeWorkspace(workspace)
        }
    }

    /// Confirm before closing a workspace that is its group's anchor. Closing
    /// the anchor dissolves the group (other members survive ungrouped).
    /// "Don't ask again" sets the `workspaceGroups.anchorCloseSuppressed` flag.
    private func confirmAnchorWorkspaceClose(groupName: String, otherMemberCount: Int) -> Bool {
        if settings.value(for: settingsCatalog.workspaceGroups.anchorCloseSuppressed) {
            return true
        }
        // Do NOT acquire beginCloseConfirmationSession here. The standard
        // close confirmation path that runs immediately after (confirmClose())
        // gates itself with the same flag, and endCloseConfirmationSession
        // releases the flag asynchronously on the next main-queue turn — so
        // wrapping this dialog with begin/end would leave the flag set when
        // the inner confirmClose runs, causing it to return false and silently
        // refuse the close even after the user accepted both prompts.
        let title = String(
            localized: "dialog.closeAnchor.title",
            defaultValue: "Close this workspace?"
        )
        // Use printf-style format specifiers and String(format:) so the
        // catalog entry can substitute the group name and member count at
        // runtime. Embedding Swift `\(groupName)` interpolation in the
        // catalog `value` would render literal `\(groupName)` on lookup.
        let message: String
        if otherMemberCount == 0 {
            let format = String(
                localized: "dialog.closeAnchor.message.lone",
                defaultValue: "Closing this workspace will remove the group \u{201C}%@\u{201D}."
            )
            message = String.localizedStringWithFormat(format, groupName)
        } else if otherMemberCount == 1 {
            let format = String(
                localized: "dialog.closeAnchor.message.one",
                defaultValue: "Closing this workspace will ungroup \u{201C}%@\u{201D} and release 1 other workspace."
            )
            message = String.localizedStringWithFormat(format, groupName)
        } else {
            let format = String(
                localized: "dialog.closeAnchor.message.many",
                defaultValue: "Closing this workspace will ungroup \u{201C}%1$@\u{201D} and release %2$lld other workspaces."
            )
            message = String.localizedStringWithFormat(format, groupName, otherMemberCount)
        }

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "dialog.closeTab.close", defaultValue: "Close"))
        alert.addButton(withTitle: String(localized: "dialog.closeTab.cancel", defaultValue: "Cancel"))
        let suppressionButton = NSButton(
            checkboxWithTitle: String(
                localized: "dialog.dontAskAgain",
                defaultValue: "Don\u{2019}t ask again"
            ),
            target: nil,
            action: nil
        )
        suppressionButton.state = .off
        alert.accessoryView = suppressionButton
        if let closeButton = alert.buttons.first {
            closeButton.keyEquivalent = "\r"
            closeButton.keyEquivalentModifierMask = []
            alert.window.defaultButtonCell = closeButton.cell as? NSButtonCell
            alert.window.initialFirstResponder = closeButton
        }
        if let cancelButton = alert.buttons.dropFirst().first {
            cancelButton.keyEquivalent = "\u{1b}"
        }

        let response = runCloseConfirmationAlert(alert)
        guard response == .alertFirstButtonReturn else { return false }
        if suppressionButton.state == .on {
            settings.set(true, for: settingsCatalog.workspaceGroups.anchorCloseSuppressed)
        }
        return true
    }

    private func confirmPinnedWorkspaceClose(source: CloseConfirmationSource) -> Bool {
        guard workspaceClosing.shouldConfirmClose(requiresConfirmation: true, source: source) else { return true }
        return confirmClose(
            title: String(localized: "dialog.closePinnedWorkspace.title", defaultValue: "Close pinned workspace?"),
            message: String(
                localized: "dialog.closePinnedWorkspace.message",
                defaultValue: "This workspace is pinned. Closing it will close the workspace and all of its panels."
            ),
            acceptCmdD: tabs.count <= 1
        )
    }

    private func shouldCloseWorkspaceOnLastSurfaceShortcut(_ workspace: Workspace, panelId: UUID) -> Bool {
        // Stored under the legacy closeWorkspaceOnLastSurfaceShortcut key:
        // true means the Close shortcut closes the workspace on its last surface.
        settings.value(for: settingsCatalog.app.keepWorkspaceOpenWhenClosingLastSurface) &&
            workspace.panels.count <= 1 &&
            workspace.panels[panelId] != nil
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
        if let focusedPanelId = workspace.focusedPanelId,
           workspace.panels[focusedPanelId] != nil {
            return focusedPanelId
        }

        if workspace.panels.count == 1 {
            return workspace.panels.keys.first
        }

        let candidatePane = workspace.bonsplitController.focusedPaneId ?? workspace.bonsplitController.allPaneIds.first
        if let candidatePane,
           let selectedTabId = workspace.bonsplitController.selectedTab(inPane: candidatePane)?.id
                ?? workspace.bonsplitController.tabs(inPane: candidatePane).first?.id,
           let panelId = workspace.panelIdFromSurfaceId(selectedTabId),
           workspace.panels[panelId] != nil {
            return panelId
        }

        return nil
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
            guard confirmClose(
                title: String(localized: "dialog.closeTab.title", defaultValue: "Close tab?"),
                message: String(localized: "dialog.closeTab.message", defaultValue: "This will close the current tab."),
                acceptCmdD: false
            ) else { return }
        }

        _ = tab.closePanel(surfaceId, force: true)
        AppDelegate.shared?.notificationStore?.clearNotifications(forTabId: tab.id, surfaceId: surfaceId)
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
        AppDelegate.shared?.notificationStore?.clearNotifications(forTabId: tab.id, surfaceId: surfaceId)
    }

    /// Close a panel because its child process exited (e.g. the user hit Ctrl+D).
    ///
    /// This should never prompt: the process is already gone, and Ghostty emits the
    /// `SHOW_CHILD_EXITED` action specifically so the host app can decide what to do.
    func closePanelAfterChildExited(tabId: UUID, surfaceId: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return }
        guard tab.panels[surfaceId] != nil else { return }
        let keepsPersistentRemoteSurfaceOpen =
            tab.shouldKeepPersistentRemoteSurfaceOpenAfterChildExit(surfaceId)
        if !keepsPersistentRemoteSurfaceOpen,
           tab.shouldDemoteWorkspaceAfterChildExit(surfaceId: surfaceId) {
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
        let handlesRemoteExitThroughWorkspace =
            tab.panels.count <= 1 && tab.shouldDemoteWorkspaceAfterChildExit(surfaceId: surfaceId)

#if DEBUG
        cmuxDebugLog(
            "surface.close.childExited tab=\(tabId.uuidString.prefix(5)) " +
            "surface=\(surfaceId.uuidString.prefix(5)) panels=\(tab.panels.count) workspaces=\(tabs.count) " +
            "remoteWorkspace=\(tab.isRemoteWorkspace ? 1 : 0) keepRemote=\(handlesRemoteExitThroughWorkspace ? 1 : 0) " +
            "keepPersistentRemote=\(keepsPersistentRemoteSurfaceOpen ? 1 : 0)"
        )
#endif

        // A persistent SSH workspace must never silently replace a failed remote attach with
        // a local login shell. Keep the exited surface visible so the user can see the error
        // and retry instead of making a detached remote workspace look local after relaunch.
        if keepsPersistentRemoteSurfaceOpen {
            tab.markPersistentRemotePTYAttachFailed(surfaceId: surfaceId)
            return
        }

        // Route the last remote child exit through Workspace close handling so remote teardown
        // and replacement-panel logic run before TabManager considers removing the workspace.
        if handlesRemoteExitThroughWorkspace {
            closeRuntimeSurface(tabId: tabId, surfaceId: surfaceId)
            return
        }

        // Child-exit on the last panel should collapse the workspace, matching explicit close
        // semantics (and close the window when it was the last workspace).
        if tab.panels.count <= 1 {
            if tabs.count <= 1 {
                if let app = AppDelegate.shared {
                    app.notificationStore?.clearNotifications(forTabId: tabId)
                    app.closeMainWindowContainingTabId(tabId, recordHistory: false)
                } else {
                    // Headless/test fallback when no AppDelegate window context exists.
                    closeRuntimeSurface(tabId: tabId, surfaceId: surfaceId)
                }
            } else {
                closeWorkspace(tab, recordHistory: false)
            }
            return
        }

        closeRuntimeSurface(tabId: tabId, surfaceId: surfaceId)
    }

    private func workspaceNeedsConfirmClose(_ workspace: Workspace) -> Bool {
#if DEBUG
        if ProcessInfo.processInfo.environment["CMUX_UI_TEST_FORCE_CONFIRM_CLOSE_WORKSPACE"] == "1" {
            return true
        }
#endif
        return workspace.needsConfirmClose()
    }

    func titleForTab(_ tabId: UUID) -> String? {
        surfaceMetadata.titleForTab(tabId)
    }

    // MARK: - Panel/Surface ID Access

    /// Returns the focused panel ID for a tab (replaces focusedSurfaceId)
    func focusedPanelId(for tabId: UUID) -> UUID? {
        tabs.first(where: { $0.id == tabId })?.focusedPanelId
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

    // MARK: SurfaceMetadataTitleHosting (panel-title coalescing app effects)
    // Witnesses live here in the class body because they touch the `private`
    // panel-title coalescer and the DEBUG id/title formatters; the conformance
    // is bound by the extension below.

    func surfaceMetadataScheduleTitleFlush(_ flush: @escaping () -> Void) {
        panelTitleUpdateCoalescer.signal(flush)
    }

    func surfaceMetadataUpdateWindowTitleIfSelected(workspaceId: UUID) {
        guard selectedTabId == workspaceId,
              let tab = tabs.first(where: { $0.id == workspaceId }) else { return }
        updateWindowTitle(for: tab)
    }

    func surfaceMetadataLogPanelTitleEnqueue(workspaceId: UUID, panelId: UUID, title: String) {
#if DEBUG
        cmuxDebugLog(
            "workspace.title.enqueue workspace=\(Self.debugShortWorkspaceId(workspaceId)) " +
            "panel=\(panelId.uuidString.prefix(5)) title=\"\(Self.debugTitlePreview(title))\""
        )
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
        if workspace.panels[surfaceOrPanelId] != nil {
            return surfaceOrPanelId
        }
        return workspace.panelIdFromSurfaceId(TabID(uuid: surfaceOrPanelId))
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
        debugPrepareWorkspaceSwitch(trigger, from: from, to: to)
#endif
    }

    func debugLogWorkspaceCycleHotOn(generation: UInt64) {
#if DEBUG
        cmuxDebugLog(
            "ws.hot.on id=\(debugWorkspaceSwitchId) gen=\(generation) dt=\(Self.debugMsText(debugWorkspaceCycleSwitchDtMs))"
        )
#endif
    }

    func debugLogWorkspaceCycleHotCancelPrevious(generation: UInt64) {
#if DEBUG
        cmuxDebugLog(
            "ws.hot.cancelPrev id=\(debugWorkspaceSwitchId) gen=\(generation) dt=\(Self.debugMsText(debugWorkspaceCycleSwitchDtMs))"
        )
#endif
    }

    func debugLogWorkspaceCycleHotCooldownCanceled(generation: UInt64) {
#if DEBUG
        cmuxDebugLog(
            "ws.hot.cooldownCanceled id=\(debugWorkspaceSwitchId) gen=\(generation) dt=\(Self.debugMsText(debugWorkspaceCycleSwitchDtMs))"
        )
#endif
    }

    func debugLogWorkspaceCycleHotOff(generation: UInt64) {
#if DEBUG
        cmuxDebugLog(
            "ws.hot.off id=\(debugWorkspaceSwitchId) gen=\(generation) dt=\(Self.debugMsText(debugWorkspaceCycleSwitchDtMs))"
        )
#endif
    }

#if DEBUG
    /// Elapsed ms since the current DEBUG workspace switch started, or 0 when no
    /// switch is timed — the `dt=` field the cycle-hot trace lines report.
    private var debugWorkspaceCycleSwitchDtMs: Double {
        debugWorkspaceSwitchStartTime > 0
            ? (CACurrentMediaTime() - debugWorkspaceSwitchStartTime) * 1000
            : 0
    }

    func debugCurrentWorkspaceSwitchSnapshot() -> (id: UInt64, startedAt: CFTimeInterval)? {
        guard debugWorkspaceSwitchId > 0, debugWorkspaceSwitchStartTime > 0 else { return nil }
        return (debugWorkspaceSwitchId, debugWorkspaceSwitchStartTime)
    }

    func debugPrimeWorkspaceSwitchTrigger(_ trigger: String, to target: UUID?) {
        guard selectedTabId != target else {
            debugPendingWorkspaceSwitchTrigger = nil
            debugPendingWorkspaceSwitchTarget = nil
            return
        }
        debugPendingWorkspaceSwitchTrigger = trigger
        debugPendingWorkspaceSwitchTarget = target
    }

    private func debugPrepareWorkspaceSwitch(_ trigger: String, from: UUID?, to: UUID?) {
        guard from != to else {
            debugPendingWorkspaceSwitchTrigger = nil
            debugPendingWorkspaceSwitchTarget = nil
            debugPreparedWorkspaceSwitchTarget = nil
            return
        }
        debugPendingWorkspaceSwitchTrigger = nil
        debugPendingWorkspaceSwitchTarget = nil
        debugBeginWorkspaceSwitch(trigger: trigger, from: from, to: to)
        debugPreparedWorkspaceSwitchTarget = to
    }

    private func debugBeginWorkspaceSwitch(trigger: String, from: UUID?, to: UUID?) {
        debugWorkspaceSwitchCounter &+= 1
        debugWorkspaceSwitchId = debugWorkspaceSwitchCounter
        debugWorkspaceSwitchStartTime = CACurrentMediaTime()
        cmuxDebugLog(
            "ws.switch.begin id=\(debugWorkspaceSwitchId) trigger=\(trigger) " +
            "from=\(Self.debugShortWorkspaceId(from)) to=\(Self.debugShortWorkspaceId(to)) " +
            "hot=\(isWorkspaceCycleHot ? 1 : 0) tabs=\(tabs.count)"
        )
    }

    private static func debugShortWorkspaceId(_ id: UUID?) -> String {
        guard let id else { return "nil" }
        return String(id.uuidString.prefix(5))
    }

    private static func debugTitlePreview(_ title: String, limit: Int = 120) -> String {
        let escaped = title
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
            .replacingOccurrences(of: "\"", with: "\\\"")
        guard escaped.count > limit else { return escaped }
        return "\(escaped.prefix(limit))..."
    }

    private static func debugMsText(_ ms: Double) -> String {
        String(format: "%.2fms", ms)
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
        selectedWorkspace?.selectNextSurface()
    }

    /// Select the previous surface in the currently focused pane of the selected workspace
    func selectPreviousSurface() {
        selectedWorkspace?.selectPreviousSurface()
    }

    /// Select a surface by index in the currently focused pane of the selected workspace
    func selectSurface(at index: Int) {
        selectedWorkspace?.selectSurface(at: index)
    }

    /// Select the last surface in the currently focused pane of the selected workspace
    func selectLastSurface() {
        selectedWorkspace?.selectLastSurface()
    }

    /// Create a new terminal surface in the focused pane of the selected workspace
    func newSurface() {
        // Cmd+T should always focus the newly created surface.
        selectedWorkspace?.clearSplitZoom()
        selectedWorkspace?.newTerminalSurfaceInFocusedPane(focus: true)
    }

    func newSurface(initialInput: String) {
        selectedWorkspace?.clearSplitZoom()
        selectedWorkspace?.newTerminalSurfaceInFocusedPane(focus: true, initialInput: initialInput)
    }

    // MARK: - Split Creation

    /// Create a new split in the current tab
    @discardableResult
    func createSplit(direction: SplitDirection) -> UUID? {
        guard let selectedTabId,
              let tab = tabs.first(where: { $0.id == selectedTabId }),
              let focusedPanelId = tab.focusedPanelId else { return nil }
        return createSplit(tabId: selectedTabId, surfaceId: focusedPanelId, direction: direction)
    }

    /// Create a new split from an explicit source panel.
    @discardableResult
    func createSplit(tabId: UUID, surfaceId: UUID, direction: SplitDirection, focus: Bool = true) -> UUID? {
        guard let tab = tabs.first(where: { $0.id == tabId }),
              tab.panels[surfaceId] != nil else { return nil }
        tab.clearSplitZoom()
        sentryBreadcrumb("split.create", data: ["direction": String(describing: direction)])
        return newSplit(tabId: tabId, surfaceId: surfaceId, direction: direction, focus: focus)
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

    private func panelIdForFocusHistorySurface(_ surfaceId: UUID, workspaceId: UUID) -> UUID {
        tabs.first(where: { $0.id == workspaceId })?.panelIdFromSurfaceId(TabID(uuid: surfaceId)) ?? surfaceId
    }

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

    // FocusedSurfaceHosting witness that touches `private` DEBUG members
    // (`debugCurrentWorkspaceSwitchSnapshot`, `debugShortWorkspaceId`,
    // `debugMsText`, `cmuxDebugLog`); the rest of the conformance lives in
    // TabManager+FocusedSurfaceHosting.swift. Formats the byte-identical legacy
    // `ws.unfocus.*` trace lines; release builds make this a no-op exactly as
    // the original `#if DEBUG`-guarded `cmuxDebugLog` calls were.
    func logPendingWorkspaceUnfocusEvent(_ event: PendingWorkspaceUnfocusEvent) {
#if DEBUG
        switch event {
        case let .deferred(workspaceId, panelId):
            if let snapshot = debugCurrentWorkspaceSwitchSnapshot() {
                let dtMs = (CACurrentMediaTime() - snapshot.startedAt) * 1000
                cmuxDebugLog(
                    "ws.unfocus.defer id=\(snapshot.id) dt=\(Self.debugMsText(dtMs)) " +
                    "tab=\(Self.debugShortWorkspaceId(workspaceId)) panel=\(String(panelId.uuidString.prefix(5)))"
                )
            } else {
                cmuxDebugLog(
                    "ws.unfocus.defer id=none tab=\(Self.debugShortWorkspaceId(workspaceId)) panel=\(String(panelId.uuidString.prefix(5)))"
                )
            }
        case let .flushedOnReplace(workspaceId, panelId):
            cmuxDebugLog(
                "ws.unfocus.flush tab=\(Self.debugShortWorkspaceId(workspaceId)) panel=\(String(panelId.uuidString.prefix(5))) reason=replaced"
            )
        case let .droppedOnReplaceSelected(workspaceId, panelId):
            cmuxDebugLog(
                "ws.unfocus.drop tab=\(Self.debugShortWorkspaceId(workspaceId)) panel=\(String(panelId.uuidString.prefix(5))) reason=replaced_selected"
            )
        case let .droppedSelectedAgain(workspaceId, panelId):
            cmuxDebugLog(
                "ws.unfocus.drop tab=\(Self.debugShortWorkspaceId(workspaceId)) panel=\(String(panelId.uuidString.prefix(5))) reason=selected_again"
            )
        case let .completed(workspaceId, panelId, reason):
            if let snapshot = debugCurrentWorkspaceSwitchSnapshot() {
                let dtMs = (CACurrentMediaTime() - snapshot.startedAt) * 1000
                cmuxDebugLog(
                    "ws.unfocus.complete id=\(snapshot.id) dt=\(Self.debugMsText(dtMs)) " +
                    "tab=\(Self.debugShortWorkspaceId(workspaceId)) panel=\(String(panelId.uuidString.prefix(5))) reason=\(reason)"
                )
            } else {
                cmuxDebugLog(
                    "ws.unfocus.complete id=none tab=\(Self.debugShortWorkspaceId(workspaceId)) " +
                    "panel=\(String(panelId.uuidString.prefix(5))) reason=\(reason)"
                )
            }
        }
#endif
    }

    // WorkspaceHandoffHosting witness that touches `private` DEBUG members
    // (`debugCurrentWorkspaceSwitchSnapshot`, `debugShortWorkspaceId`,
    // `debugMsText`); the rest of the conformance lives in
    // TabManager+WorkspaceHandoffHosting.swift. Formats the byte-identical
    // legacy `ws.mount.reconcile` / `ws.handoff.*` trace lines that
    // `ContentView` used to emit inline; release builds make this a no-op
    // exactly as the original `#if DEBUG`-guarded `cmuxDebugLog` calls were.
    func logWorkspaceHandoffEvent(_ event: WorkspaceHandoffEvent) {
#if DEBUG
        switch event {
        case let .mountReconciled(isCycleHot, selectedWorkspaceId, mountedWorkspaceIds, addedWorkspaceIds, removedWorkspaceIds):
            if let snapshot = debugCurrentWorkspaceSwitchSnapshot() {
                let dtMs = (CACurrentMediaTime() - snapshot.startedAt) * 1000
                cmuxDebugLog(
                    "ws.mount.reconcile id=\(snapshot.id) dt=\(Self.debugMsText(dtMs)) hot=\(isCycleHot ? 1 : 0) " +
                    "selected=\(Self.debugShortWorkspaceId(selectedWorkspaceId)) " +
                    "mounted=\(Self.debugShortWorkspaceIds(mountedWorkspaceIds)) " +
                    "added=\(Self.debugShortWorkspaceIds(addedWorkspaceIds)) removed=\(Self.debugShortWorkspaceIds(removedWorkspaceIds))"
                )
            } else {
                cmuxDebugLog(
                    "ws.mount.reconcile id=none hot=\(isCycleHot ? 1 : 0) selected=\(Self.debugShortWorkspaceId(selectedWorkspaceId)) " +
                    "mounted=\(Self.debugShortWorkspaceIds(mountedWorkspaceIds))"
                )
            }
        case let .handoffStarted(oldSelectedWorkspaceId, newSelectedWorkspaceId):
            if let snapshot = debugCurrentWorkspaceSwitchSnapshot() {
                let dtMs = (CACurrentMediaTime() - snapshot.startedAt) * 1000
                cmuxDebugLog(
                    "ws.handoff.start id=\(snapshot.id) dt=\(Self.debugMsText(dtMs)) old=\(Self.debugShortWorkspaceId(oldSelectedWorkspaceId)) " +
                    "new=\(Self.debugShortWorkspaceId(newSelectedWorkspaceId))"
                )
            } else {
                cmuxDebugLog(
                    "ws.handoff.start id=none old=\(Self.debugShortWorkspaceId(oldSelectedWorkspaceId)) new=\(Self.debugShortWorkspaceId(newSelectedWorkspaceId))"
                )
            }
        case let .handoffFastReady(selectedWorkspaceId):
            if let snapshot = debugCurrentWorkspaceSwitchSnapshot() {
                let dtMs = (CACurrentMediaTime() - snapshot.startedAt) * 1000
                cmuxDebugLog(
                    "ws.handoff.fastReady id=\(snapshot.id) dt=\(Self.debugMsText(dtMs)) selected=\(Self.debugShortWorkspaceId(selectedWorkspaceId))"
                )
            } else {
                cmuxDebugLog("ws.handoff.fastReady id=none selected=\(Self.debugShortWorkspaceId(selectedWorkspaceId))")
            }
        case let .handoffCompleted(reason, retiringWorkspaceId):
            if let snapshot = debugCurrentWorkspaceSwitchSnapshot() {
                let dtMs = (CACurrentMediaTime() - snapshot.startedAt) * 1000
                cmuxDebugLog(
                    "ws.handoff.complete id=\(snapshot.id) dt=\(Self.debugMsText(dtMs)) reason=\(reason) retiring=\(Self.debugShortWorkspaceId(retiringWorkspaceId))"
                )
            } else {
                cmuxDebugLog("ws.handoff.complete id=none reason=\(reason) retiring=\(Self.debugShortWorkspaceId(retiringWorkspaceId))")
            }
        }
#endif
    }

#if DEBUG
    private static func debugShortWorkspaceIds(_ ids: [UUID]) -> String {
        if ids.isEmpty { return "[]" }
        return "[" + ids.map { String($0.uuidString.prefix(5)) }.joined(separator: ",") + "]"
    }
#endif

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
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return nil }
        return tab.newTerminalSplit(
            from: surfaceId,
            orientation: direction.orientation,
            insertFirst: direction.insertFirst,
            focus: focus,
            workingDirectory: workingDirectory,
            initialCommand: initialCommand,
            tmuxStartCommand: tmuxStartCommand,
            startupEnvironment: startupEnvironment,
            initialDividerPosition: initialDividerPosition,
            remotePTYSessionID: remotePTYSessionID
        )?.id
    }

    /// Move focus in the specified direction
    func moveSplitFocus(tabId: UUID, surfaceId: UUID, direction: NavigationDirection) -> Bool {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return false }
        tab.moveFocus(direction: direction)
        return true
    }

    /// Resize split - not directly supported by bonsplit, but we can adjust divider positions
    func resizeSplit(tabId: UUID, surfaceId: UUID, direction: ResizeDirection, amount: UInt16) -> Bool {
        guard amount > 0,
              let tab = tabs.first(where: { $0.id == tabId }),
              let paneId = tab.paneId(forPanelId: surfaceId) else { return false }

        let paneUUID = paneId.id
        guard tab.bonsplitController.allPaneIds.contains(where: { $0.id == paneUUID }) else {
            return false
        }

        return paneLayout.resizeSplit(
            in: tab.bonsplitController.treeSnapshot(),
            targetPaneId: paneUUID.uuidString,
            direction: direction,
            amountPixels: amount,
            controller: tab.bonsplitController
        )
    }

    /// Toggle zoom on a panel.
    func toggleSplitZoom(tabId: UUID, surfaceId: UUID) -> Bool {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return false }
        return tab.toggleSplitZoom(panelId: surfaceId)
    }

    /// Toggle zoom for the currently focused panel in the selected workspace.
    @discardableResult
    func toggleFocusedSplitZoom() -> Bool {
        guard let tab = selectedWorkspace,
              let focusedPanelId = tab.focusedPanelId else { return false }
        return tab.toggleSplitZoom(panelId: focusedPanelId)
    }

    /// Close a surface/panel
    func closeSurface(tabId: UUID, surfaceId: UUID) -> Bool {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return false }
        // Guard against stale close callbacks (e.g. child-exit can trigger multiple actions).
        // A stale callback must never affect unrelated panels/workspaces.
        guard tab.panels[surfaceId] != nil,
              tab.surfaceIdFromPanelId(surfaceId) != nil else { return false }
        tab.closePanel(surfaceId)
        AppDelegate.shared?.notificationStore?.clearNotifications(forTabId: tabId, surfaceId: surfaceId)
        return true
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
        guard BrowserAvailabilitySettings.isEnabled() else { return false }

        while let snapshot = browserModel.popMostRecentlyClosedBrowserPanel() {
            // The legacy stack must restore into the workspace that originally owned the
            // browser. If that workspace is gone, the snapshot is stale and we drop it
            // instead of barging into whatever workspace happens to be selected now
            // (which surfaced yesterday's browser inside today's unrelated workspaces).
            guard let targetWorkspace = tabs.first(where: { $0.id == snapshot.workspaceId }) else {
                continue
            }
            let preReopenFocusedPanelId = focusedPanelId(for: targetWorkspace.id)

            if selectedTabId != targetWorkspace.id {
                selectWorkspaceId(
                    targetWorkspace.id,
                    notificationDismissalContext: .explicitWorkspaceResume
                )
            }

            if let reopenedPanelId = reopenClosedBrowserPanel(snapshot, in: targetWorkspace) {
                enforceReopenedBrowserFocus(
                    tabId: targetWorkspace.id,
                    reopenedPanelId: reopenedPanelId,
                    preReopenFocusedPanelId: preReopenFocusedPanelId
                )
                return true
            }
        }

        return false
    }

    func clearRecentlyClosedBrowserPanelHistory() {
        browserModel.clearRecentlyClosedBrowserPanels()
    }

    func mostRecentLegacyClosedBrowserPanelClosedAt() -> Date? {
        browserModel.mostRecentClosedBrowserPanelClosedAt
    }

    @discardableResult
    func reopenMostRecentlyClosedItem() -> Bool {
        if let appDelegate = AppDelegate.shared {
            return appDelegate.reopenMostRecentlyClosedItem(preferredTabManager: self)
        }

        if ClosedItemHistoryStore.shared.restoreFirstRestorable(using: { entry in
            switch entry {
            case .panel(let panelEntry):
                return restoreClosedPanel(panelEntry)
            case .workspace(let workspaceEntry):
                return restoreClosedWorkspace(workspaceEntry)
            case .window:
                return false
            }
        }) {
            return true
        }

        return false
    }

    @discardableResult
    func reopenClosedHistoryItem(id: UUID) -> Bool {
        if let appDelegate = AppDelegate.shared {
            return appDelegate.reopenClosedHistoryItem(id: id, preferredTabManager: self)
        }

        guard let removed = ClosedItemHistoryStore.shared.removeRecord(id: id) else {
            return false
        }

        let didRestore: Bool
        switch removed.record.entry {
        case .panel(let panelEntry):
            didRestore = restoreClosedPanel(panelEntry)
        case .workspace(let workspaceEntry):
            didRestore = restoreClosedWorkspace(workspaceEntry)
        case .window:
            didRestore = false
        }

        if !didRestore {
            ClosedItemHistoryStore.shared.insert(removed.record, at: removed.index)
        }
        return didRestore
    }

    @discardableResult
    func restoreClosedPanel(_ entry: ClosedPanelHistoryEntry) -> Bool {
        guard let workspace = tabs.first(where: { $0.id == entry.workspaceId }) else {
            return false
        }

        let preRestoreFocus = focusHistoryNavigation.currentFocusHistoryEntry
        let panelId = focusHistoryNavigation.withFocusHistoryRecordingSuppressed {
            workspace.restoreClosedPanel(entry)
        }

        guard let panelId else { return false }
        ClosedItemHistoryStore.shared.remapPanelAnchorIds(from: entry.snapshot.id, to: panelId)
        focusHistoryNavigation.withFocusHistoryRecordingSuppressed {
            if selectedTabId != workspace.id {
                selectedTabId = workspace.id
            }
        }
        focusHistoryNavigation.recordFocusInHistory(preRestoreFocus, preservingForwardBranch: true)
        rememberFocusedSurface(tabId: workspace.id, surfaceId: panelId)
        focusHistoryNavigation.recordFocusInHistory(workspaceId: workspace.id, panelId: panelId, preservingForwardBranch: true)
        return true
    }

    @discardableResult
    func restoreClosedWorkspace(_ entry: ClosedWorkspaceHistoryEntry) -> Bool {
        let preRestoreFocus = focusHistoryNavigation.currentFocusHistoryEntry
        let workspace = addWorkspace(
            title: entry.snapshot.customTitle ?? entry.snapshot.processTitle,
            workingDirectory: entry.snapshot.currentDirectory,
            select: false,
            autoWelcomeIfNeeded: false
        )
        let restoredPanelIds = workspace.restoreSessionSnapshot(entry.snapshot)
        guard !entry.snapshot.hasRestorablePanels || !restoredPanelIds.isEmpty else {
            closeWorkspace(workspace, recordHistory: false)
            return false
        }
        guard !workspace.panels.isEmpty else {
            closeWorkspace(workspace, recordHistory: false)
            return false
        }
        // The snapshot may carry a groupId for a group that no longer exists
        // in this TabManager (e.g. the group was dissolved between close and
        // reopen). Drop those stale references so the restored workspace
        // doesn't render as an orphaned indented row under no header.
        if let groupId = workspace.groupId,
           !workspaceGroups.contains(where: { $0.id == groupId }) {
            workspace.groupId = nil
        }
        // When the group DOES still exist, the workspace is about to be
        // reinserted at its old absolute index, which may now sit inside a
        // different group section after intervening reorders. Renormalize
        // so the restored member lands beside its group.
        let needsNormalize = workspace.groupId != nil && !workspaceGroups.isEmpty
        ClosedItemHistoryStore.shared.remapPanelWorkspaceIds(
            from: entry.workspaceId,
            to: workspace.id,
            panelIdMap: restoredPanelIds
        )

        if let currentIndex = tabs.firstIndex(where: { $0.id == workspace.id }) {
            let removed = tabs.remove(at: currentIndex)
            let insertIndex = min(max(entry.workspaceIndex, 0), tabs.count)
            tabs.insert(removed, at: insertIndex)
        }
        if needsNormalize {
            workspaces.normalizeWorkspaceGroupContiguity()
        }

        focusHistoryNavigation.withFocusHistoryRecordingSuppressed {
            selectedTabId = workspace.id
        }
        focusHistoryNavigation.recordFocusInHistory(preRestoreFocus, preservingForwardBranch: true)
        if let focusedPanelId = workspace.focusedPanelId {
            rememberFocusedSurface(tabId: workspace.id, surfaceId: focusedPanelId)
            workspace.triggerFocusFlash(panelId: focusedPanelId)
            focusHistoryNavigation.recordFocusInHistory(workspaceId: workspace.id, panelId: focusedPanelId, preservingForwardBranch: true)
        } else {
            focusHistoryNavigation.recordFocusInHistory(workspaceId: workspace.id, panelId: nil, preservingForwardBranch: true)
        }
        return true
    }

    private func enforceReopenedBrowserFocus(
        tabId: UUID,
        reopenedPanelId: UUID,
        preReopenFocusedPanelId: UUID?
    ) {
        // Keep workspace-switch restoration pinned to the reopened browser panel.
        rememberFocusedSurface(tabId: tabId, surfaceId: reopenedPanelId)
        enforceReopenedBrowserFocusIfNeeded(
            tabId: tabId,
            reopenedPanelId: reopenedPanelId,
            preReopenFocusedPanelId: preReopenFocusedPanelId
        )

        // Some stale focus callbacks can land one runloop turn later. Re-assert focus in two
        // consecutive turns, but only when focus drifted back to the pre-reopen panel.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.enforceReopenedBrowserFocusIfNeeded(
                tabId: tabId,
                reopenedPanelId: reopenedPanelId,
                preReopenFocusedPanelId: preReopenFocusedPanelId
            )
            DispatchQueue.main.async { [weak self] in
                self?.enforceReopenedBrowserFocusIfNeeded(
                    tabId: tabId,
                    reopenedPanelId: reopenedPanelId,
                    preReopenFocusedPanelId: preReopenFocusedPanelId
                )
            }
        }
    }

    private func enforceReopenedBrowserFocusIfNeeded(
        tabId: UUID,
        reopenedPanelId: UUID,
        preReopenFocusedPanelId: UUID?
    ) {
        guard selectedTabId == tabId,
              let tab = tabs.first(where: { $0.id == tabId }),
              tab.panels[reopenedPanelId] != nil else {
            return
        }

        rememberFocusedSurface(tabId: tabId, surfaceId: reopenedPanelId)

        guard tab.focusedPanelId != reopenedPanelId else { return }

        if let focusedPanelId = tab.focusedPanelId,
           let preReopenFocusedPanelId,
           focusedPanelId != preReopenFocusedPanelId {
            return
        }

        tab.focusPanel(reopenedPanelId)
    }

    private func reopenClosedBrowserPanel(
        _ snapshot: ClosedBrowserPanelRestoreSnapshot,
        in workspace: Workspace
    ) -> UUID? {
        if let originalPane = workspace.bonsplitController.allPaneIds.first(where: { $0.id == snapshot.originalPaneId }),
           let browserPanel = workspace.newBrowserSurface(
               inPane: originalPane,
               url: snapshot.url,
               focus: true,
               preferredProfileID: snapshot.profileID
           ) {
            let tabCount = workspace.bonsplitController.tabs(inPane: originalPane).count
            let maxIndex = max(0, tabCount - 1)
            let targetIndex = min(max(snapshot.originalTabIndex, 0), maxIndex)
            _ = workspace.reorderSurface(panelId: browserPanel.id, toIndex: targetIndex)
            return browserPanel.id
        }

        if let orientation = snapshot.fallbackSplitOrientation,
           let fallbackAnchorPaneId = snapshot.fallbackAnchorPaneId,
           let anchorPane = workspace.bonsplitController.allPaneIds.first(where: { $0.id == fallbackAnchorPaneId }),
           let anchorTab = workspace.bonsplitController.selectedTab(inPane: anchorPane) ?? workspace.bonsplitController.tabs(inPane: anchorPane).first,
           let anchorPanelId = workspace.panelIdFromSurfaceId(anchorTab.id),
           let browserPanelId = workspace.newBrowserSplit(
               from: anchorPanelId,
               orientation: orientation,
               insertFirst: snapshot.fallbackSplitInsertFirst,
               url: snapshot.url,
               preferredProfileID: snapshot.profileID
           )?.id {
            return browserPanelId
        }

        guard let focusedPane = workspace.bonsplitController.focusedPaneId ?? workspace.bonsplitController.allPaneIds.first else {
            return nil
        }
        return workspace.newBrowserSurface(
            inPane: focusedPane,
            url: snapshot.url,
            focus: true,
            preferredProfileID: snapshot.profileID
        )?.id
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

    func runSplitCloseRightUITest(_ config: UITestSplitScaffoldPlan.SplitCloseRightConfig) {
        let path = config.path
        let visualMode = config.visualMode
        let shotsDir = config.shotsDir
        let visualIterations = config.visualIterations
        let burstFrames = config.burstFrames
        let closeDelayMs = config.closeDelayMs
        let pattern = config.pattern

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let tab = self.selectedWorkspace else {
                    self.writeSplitCloseRightTestData(["setupError": "Missing selected workspace"], at: path)
                    return
                }

                guard let topLeftPanelId = tab.focusedPanelId else {
                    self.writeSplitCloseRightTestData(["setupError": "Missing initial focused panel"], at: path)
                    return
                }
                let initialTerminalReadiness = await self.waitForTerminalPanelReadyForUITest(
                    tab: tab,
                    panelId: topLeftPanelId
                )

                guard initialTerminalReadiness.attached,
                      initialTerminalReadiness.hasSurface,
                      let terminal = tab.terminalPanel(for: topLeftPanelId) else {
                    self.writeSplitCloseRightTestData([
                        "preTerminalAttached": initialTerminalReadiness.attached ? "1" : "0",
                        "preTerminalSurfaceNil": initialTerminalReadiness.hasSurface ? "0" : "1",
                        "setupError": "Initial terminal not ready (not attached or surface nil)"
                    ], at: path)
                    return
                }

                self.writeSplitCloseRightTestData([
                    "preTerminalAttached": "1",
                    "preTerminalSurfaceNil": terminal.surface.surface == nil ? "1" : "0"
                ], at: path)

                if visualMode {
                    // Visual repro mode: repeat the split/close sequence many times and write
                    // screenshots to `shotsDir`. This avoids relying on XCUITest to click hover-only
                    // close buttons, while still exercising the "close unfocused right tabs" path.
                    self.writeSplitCloseRightTestData([
                        "visualMode": "1",
                        "visualIterations": String(visualIterations),
                        "visualDone": "0"
                    ], at: path)

                    await self.runSplitCloseRightVisualRepro(
                        tab: tab,
                        topLeftPanelId: topLeftPanelId,
                        path: path,
                        shotsDir: shotsDir,
                        iterations: max(1, min(visualIterations, 60)),
                        burstFrames: max(0, min(burstFrames, 80)),
                        closeDelayMs: max(0, min(closeDelayMs, 500)),
                        pattern: pattern
                    )

                    self.writeSplitCloseRightTestData(["visualDone": "1"], at: path)
                    return
                }

                // Layout goal: 2x2 grid (2 top, 2 bottom), then close both right panels.
                // Order matters: split down first, then split right in each row (matches UI shortcut repro).
                guard let bottomLeft = tab.newTerminalSplit(from: topLeftPanelId, orientation: .vertical) else {
                    self.writeSplitCloseRightTestData(["setupError": "Failed to create bottom-left split"], at: path)
                    return
                }
                guard let bottomRight = tab.newTerminalSplit(from: bottomLeft.id, orientation: .horizontal) else {
                    self.writeSplitCloseRightTestData(["setupError": "Failed to create bottom-right split"], at: path)
                    return
                }
                tab.focusPanel(topLeftPanelId)
                guard let topRight = tab.newTerminalSplit(from: topLeftPanelId, orientation: .horizontal) else {
                    self.writeSplitCloseRightTestData(["setupError": "Failed to create top-right split"], at: path)
                    return
                }

                self.writeSplitCloseRightTestData([
                    "tabId": tab.id.uuidString,
                    "topLeftPanelId": topLeftPanelId.uuidString,
                    "bottomLeftPanelId": bottomLeft.id.uuidString,
                    "topRightPanelId": topRight.id.uuidString,
                    "bottomRightPanelId": bottomRight.id.uuidString,
                    "createdPaneCount": String(tab.bonsplitController.allPaneIds.count),
                    "createdPanelCount": String(tab.panels.count)
                ], at: path)

                DebugUIEventCounters.resetEmptyPanelAppearCount()

                // Close the two right panes via the same path as the Close Tab shortcut.
                tab.focusPanel(topRight.id)
                tab.closePanel(topRight.id, force: true)
                tab.focusPanel(bottomRight.id)
                tab.closePanel(bottomRight.id, force: true)


                // Capture final state after Bonsplit/AppKit/Ghostty geometry reconciliation.
                // We avoid sleep-based timing and converge over a few main-actor turns.
                 @MainActor func collectSplitCloseRightState() -> (data: [String: String], settled: Bool) {
                    let paneIds = tab.bonsplitController.allPaneIds
                    let bonsplitTabCount = tab.bonsplitController.allTabIds.count
                    let panelCount = tab.panels.count

                    var missingSelectedTabCount = 0
                    var missingPanelMappingCount = 0
                    var selectedTerminalCount = 0
                    var selectedTerminalAttachedCount = 0
                    var selectedTerminalZeroSizeCount = 0
                    var selectedTerminalSurfaceNilCount = 0

                    for paneId in paneIds {
                        guard let selected = tab.bonsplitController.selectedTab(inPane: paneId) else {
                            missingSelectedTabCount += 1
                            continue
                        }
                        guard let panel = tab.panel(for: selected.id) else {
                            missingPanelMappingCount += 1
                            continue
                        }
                        if let terminal = panel as? TerminalPanel {
                            selectedTerminalCount += 1
                            if terminal.surface.isViewInWindow {
                                selectedTerminalAttachedCount += 1
                            }
                            let size = terminal.hostedView.bounds.size
                            if size.width < 5 || size.height < 5 {
                                selectedTerminalZeroSizeCount += 1
                            }
                            if terminal.surface.surface == nil {
                                selectedTerminalSurfaceNilCount += 1
                            }
                        }
                    }

                    let settled =
                        paneIds.count == 2 &&
                        missingSelectedTabCount == 0 &&
                        missingPanelMappingCount == 0 &&
                        DebugUIEventCounters.emptyPanelAppearCount == 0 &&
                        selectedTerminalCount == 2 &&
                        selectedTerminalAttachedCount == 2 &&
                        selectedTerminalZeroSizeCount == 0 &&
                        selectedTerminalSurfaceNilCount == 0

                    return (
                        data: [
                            "finalPaneCount": String(paneIds.count),
                            "finalBonsplitTabCount": String(bonsplitTabCount),
                            "finalPanelCount": String(panelCount),
                            "missingSelectedTabCount": String(missingSelectedTabCount),
                            "missingPanelMappingCount": String(missingPanelMappingCount),
                            "emptyPanelAppearCount": String(DebugUIEventCounters.emptyPanelAppearCount),
                            "selectedTerminalCount": String(selectedTerminalCount),
                            "selectedTerminalAttachedCount": String(selectedTerminalAttachedCount),
                            "selectedTerminalZeroSizeCount": String(selectedTerminalZeroSizeCount),
                            "selectedTerminalSurfaceNilCount": String(selectedTerminalSurfaceNilCount),
                        ],
                        settled: settled
                    )
                }
                 @MainActor func reconcileVisibleTerminalGeometry() {
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

                var finalState = collectSplitCloseRightState()
                for attempt in 1...8 {
                    reconcileVisibleTerminalGeometry()
                    await Task.yield()
                    finalState = collectSplitCloseRightState()
                    var payload = finalState.data
                    payload["finalAttempt"] = String(attempt)
                    self.writeSplitCloseRightTestData(payload, at: path)
                    if finalState.settled {
                        break
                    }
                }
            }
        }
    }

	    @MainActor
	    private func runSplitCloseRightVisualRepro(
	        tab: Workspace,
	        topLeftPanelId: UUID,
	        path: String,
	        shotsDir: String,
	        iterations: Int,
	        burstFrames: Int,
	        closeDelayMs: Int,
	        pattern: String
	    ) async {
        _ = shotsDir // legacy: screenshots removed in favor of IOSurface sampling

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

	        let st = VsyncIOSurfaceTimelineState(frameCount: frameCount, closeFrame: closeFrame)
	        st.scheduledActions = actions.sorted(by: { $0.frame < $1.frame })
	        st.nextActionIndex = 0
	        st.targets = targets.map { t in
	            VsyncIOSurfaceTimelineState.Target(label: t.label, sample: { @MainActor in
	                t.view.debugSampleIOSurface(normalizedCrop: crop)
	            })
	        }

	        let unmanaged = Unmanaged.passRetained(st)
	        let ctx = unmanaged.toOpaque()

	        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
	            st.continuation = cont
	            var link: CVDisplayLink?
	            CVDisplayLinkCreateWithActiveCGDisplays(&link)
	            guard let link else {
	                st.finish()
	                Unmanaged<VsyncIOSurfaceTimelineState>.fromOpaque(ctx).release()
	                return
	            }
	            st.link = link

	            CVDisplayLinkSetOutputCallback(link, cmuxVsyncIOSurfaceTimelineCallback, ctx)
	            CVDisplayLinkStart(link)
	        }

	        return (st.firstBlank, st.firstSizeMismatch, st.trace)
	    }

    private func writeSplitCloseRightTestData(_ updates: [String: String], at path: String) {
        UITestKeyValueCaptureFile(path: path).merge(updates)
    }

    func runChildExitSplitUITest(_ config: UITestSplitScaffoldPlan.ChildExitSplitConfig) {
        let path = config.path
        let requestedIterations = config.requestedIterations
        let iterations = config.iterations

        let captureFile = UITestKeyValueCaptureFile(path: path)
        func write(_ updates: [String: String]) {
            captureFile.merge(updates)
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            // Small delay so the initial window/panel has completed first layout.
            try? await Task.sleep(nanoseconds: 200_000_000)

            guard let tab = self.selectedWorkspace else {
                write(["setupError": "Missing selected workspace", "done": "1"])
                return
            }
            write([
                "requestedIterations": String(requestedIterations),
                "iterations": String(iterations),
                "workspaceCountBefore": String(self.tabs.count),
                "panelCountBefore": String(tab.panels.count),
                "done": "0",
            ])

            var completedIterations = 0
            var timedOut = false
            var closedWorkspace = false

            for i in 1...iterations {
                guard self.tabs.contains(where: { $0.id == tab.id }) else {
                    closedWorkspace = true
                    break
                }

                guard let leftPanelId = tab.focusedPanelId ?? tab.panels.keys.first else {
                    write(["setupError": "Missing focused panel before iteration \(i)", "done": "1"])
                    return
                }

                // Start each iteration from a deterministic 1x1 workspace.
                if tab.panels.count > 1 {
                    for panelId in tab.panels.keys where panelId != leftPanelId {
                        tab.closePanel(panelId, force: true)
                    }
                    let collapsed = await self.waitForWorkspacePanelsCondition(
                        tab: tab,
                        timeoutSeconds: 2.0
                    ) { workspace in
                        workspace.panels.count == 1
                    }
                    if !collapsed {
                        write(["setupError": "Timed out collapsing workspace before iteration \(i)", "done": "1"])
                        return
                    }
                }

                guard let rightPanel = tab.newTerminalSplit(from: leftPanelId, orientation: .horizontal) else {
                    write(["setupError": "Failed to create right split at iteration \(i)", "done": "1"])
                    return
                }

                write([
                    "iteration": String(i),
                    "leftPanelId": leftPanelId.uuidString,
                    "rightPanelId": rightPanel.id.uuidString,
                ])

                tab.focusPanel(rightPanel.id)
                // Wait for the split terminal surface to be attached before sending exit.
                // Without this, very early writes can be dropped during initial surface creation.
                _ = await self.waitForTerminalPanelCondition(
                    tab: tab,
                    panelId: rightPanel.id,
                    timeoutSeconds: 2.0
                ) { panel in
                    panel.surface.isViewInWindow && panel.surface.surface != nil
                }
                // Use an explicit shell exit command for deterministic child-exit behavior across
                // startup timing variance; this still exercises the same SHOW_CHILD_EXITED path.
                rightPanel.sendText("exit\r")

                // Wait for the right panel to close.
                let closed = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
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

                if !closed {
                    timedOut = true
                    write(["timedOutIteration": String(i)])
                    break
                }

                if !self.tabs.contains(where: { $0.id == tab.id }) {
                    closedWorkspace = true
                    write(["closedWorkspaceIteration": String(i)])
                    break
                }

                completedIterations = i
            }

            let workspaceStillOpen = self.tabs.contains(where: { $0.id == tab.id })
            let effectiveClosedWorkspace = closedWorkspace || !workspaceStillOpen

            write([
                "workspaceCountAfter": String(self.tabs.count),
                "panelCountAfter": String(tab.panels.count),
                "workspaceStillOpen": workspaceStillOpen ? "1" : "0",
                "closedWorkspace": effectiveClosedWorkspace ? "1" : "0",
                "timedOut": timedOut ? "1" : "0",
                "completedIterations": String(completedIterations),
                "done": "1",
            ])
        }
    }

    func runChildExitKeyboardUITest(_ config: UITestSplitScaffoldPlan.ChildExitKeyboardConfig) {
        let path = config.path
        let autoTrigger = config.autoTrigger
        let strictKeyOnly = config.strictKeyOnly
        let triggerMode = config.triggerMode
        let useEarlyCtrlShiftTrigger = config.useEarlyCtrlShiftTrigger
        let useEarlyCtrlDTrigger = config.useEarlyCtrlDTrigger
        let useEarlyTrigger = config.useEarlyTrigger
        let triggerUsesShift = config.triggerUsesShift
        let layout = config.layout
        let expectedPanelsAfter = config.expectedPanelsAfter

        let captureFile = UITestKeyValueCaptureFile(path: path)
        func write(_ updates: [String: String]) {
            captureFile.merge(updates)
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 200_000_000)

            guard let tab = self.selectedWorkspace else {
                write(["setupError": "Missing selected workspace", "done": "1"])
                return
            }
            guard let leftPanelId = tab.focusedPanelId else {
                write(["setupError": "Missing initial focused panel", "done": "1"])
                return
            }
            guard let rightPanel = tab.newTerminalSplit(from: leftPanelId, orientation: .horizontal) else {
                write(["setupError": "Failed to create right split", "done": "1"])
                return
            }

            var bottomLeftPanelId = ""
            let topRightPanelId = rightPanel.id.uuidString
            var bottomRightPanelId = ""
            var exitPanelId = rightPanel.id

            if layout == "lr_left_vertical" {
                guard let bottomLeft = tab.newTerminalSplit(from: leftPanelId, orientation: .vertical) else {
                    write(["setupError": "Failed to create bottom-left split", "done": "1"])
                    return
                }
                bottomLeftPanelId = bottomLeft.id.uuidString
            } else if layout == "lrtd_close_right_then_exit_top_left" {
                guard let bottomLeft = tab.newTerminalSplit(from: leftPanelId, orientation: .vertical) else {
                    write(["setupError": "Failed to create bottom-left split", "done": "1"])
                    return
                }
                guard let bottomRight = tab.newTerminalSplit(from: rightPanel.id, orientation: .vertical) else {
                    write(["setupError": "Failed to create bottom-right split", "done": "1"])
                    return
                }
                bottomLeftPanelId = bottomLeft.id.uuidString
                bottomRightPanelId = bottomRight.id.uuidString

                // Repro flow: with a 2x2 (left/right then top/down), close both right panes,
                // then trigger Ctrl+D in top-left.
                tab.focusPanel(rightPanel.id)
                tab.closePanel(rightPanel.id, force: true)
                tab.focusPanel(bottomRight.id)
                tab.closePanel(bottomRight.id, force: true)
                exitPanelId = leftPanelId

                let collapsed = await self.waitForWorkspacePanelsCondition(
                    tab: tab,
                    timeoutSeconds: 2.0
                ) { workspace in
                    workspace.panels.count == 2
                }
                if !collapsed {
                    write([
                        "setupError": "Expected 2 panels after closing right column, got \(tab.panels.count)",
                        "done": "1",
                    ])
                    return
                }
            } else if layout == "tdlr_close_bottom_then_exit_top_left" {
                // Alternate repro flow:
                // 1) split top/down
                // 2) split left/right for each row (2x2)
                // 3) close both bottom panes
                // 4) trigger Ctrl+D in top-left
                guard let bottomLeft = tab.newTerminalSplit(from: leftPanelId, orientation: .vertical) else {
                    write(["setupError": "Failed to create bottom-left split", "done": "1"])
                    return
                }
                guard let topRight = tab.newTerminalSplit(from: leftPanelId, orientation: .horizontal) else {
                    write(["setupError": "Failed to create top-right split", "done": "1"])
                    return
                }
                guard let bottomRight = tab.newTerminalSplit(from: bottomLeft.id, orientation: .horizontal) else {
                    write(["setupError": "Failed to create bottom-right split", "done": "1"])
                    return
                }
                bottomLeftPanelId = bottomLeft.id.uuidString
                bottomRightPanelId = bottomRight.id.uuidString

                // Close every pane except the top row; do it one-by-one and wait for model convergence.
                let keepPanels: Set<UUID> = [leftPanelId, topRight.id]
                for panelId in Array(tab.panels.keys) where !keepPanels.contains(panelId) {
                    tab.focusPanel(panelId)
                    tab.closePanel(panelId, force: true)
                    let closed = await self.waitForWorkspacePanelsCondition(
                        tab: tab,
                        timeoutSeconds: 1.0
                    ) { workspace in
                        workspace.panels[panelId] == nil
                    }
                    if !closed {
                        write([
                            "setupError": "Failed to close bottom pane \(panelId.uuidString)",
                            "done": "1",
                        ])
                        return
                    }
                }
                exitPanelId = leftPanelId

                let collapsed = await self.waitForWorkspacePanelsCondition(
                    tab: tab,
                    timeoutSeconds: 2.0
                ) { workspace in
                    workspace.panels.count == 2
                }
                if !collapsed {
                    write([
                        "setupError": "Expected 2 panels after closing bottom row, got \(tab.panels.count)",
                        "done": "1",
                    ])
                    return
                }
            }

            tab.focusPanel(exitPanelId)
            // Keep child-exit keyboard tests deterministic across user shell configs.
            // `exec cat` exits on a single Ctrl+D and avoids ignore-eof shell settings.
            if let exitPanel = tab.terminalPanel(for: exitPanelId) {
                exitPanel.sendText("exec cat\r")
            }

            var exitPanelAttachedBeforeCtrlD = false
            var exitPanelHasSurfaceBeforeCtrlD = false
            if !useEarlyTrigger {
                let readiness = await self.waitForTerminalPanelReadyForUITest(
                    tab: tab,
                    panelId: exitPanelId
                )
                exitPanelAttachedBeforeCtrlD = readiness.attached
                exitPanelHasSurfaceBeforeCtrlD = readiness.hasSurface
                if !(readiness.attached && readiness.hasSurface) {
                    write([
                        "exitPanelAttachedBeforeCtrlD": readiness.attached ? "1" : "0",
                        "exitPanelHasSurfaceBeforeCtrlD": readiness.hasSurface ? "1" : "0",
                        "setupError": "Exit panel not ready for Ctrl+D (not attached or surface nil)",
                        "done": "1",
                    ])
                    return
                }
                self.ensureFocusedTerminalFirstResponder()
            } else if let exitPanel = tab.terminalPanel(for: exitPanelId) {
                exitPanelAttachedBeforeCtrlD = exitPanel.surface.isViewInWindow
                exitPanelHasSurfaceBeforeCtrlD = exitPanel.surface.surface != nil
            }

            let focusedPanelBefore = tab.focusedPanelId?.uuidString ?? ""
            let firstResponderPanelBefore = tab.panels.compactMap { (panelId, panel) -> UUID? in
                guard let terminal = panel as? TerminalPanel else { return nil }
                return terminal.hostedView.isSurfaceViewFirstResponder() ? panelId : nil
            }.first?.uuidString ?? ""

            write([
                "workspaceId": tab.id.uuidString,
                "leftPanelId": leftPanelId.uuidString,
                "rightPanelId": rightPanel.id.uuidString,
                "topRightPanelId": topRightPanelId,
                "bottomLeftPanelId": bottomLeftPanelId,
                "bottomRightPanelId": bottomRightPanelId,
                "exitPanelId": exitPanelId.uuidString,
                "panelCountBeforeCtrlD": String(tab.panels.count),
                "layout": layout,
                "expectedPanelsAfter": String(expectedPanelsAfter),
                "focusedPanelBefore": focusedPanelBefore,
                "firstResponderPanelBefore": firstResponderPanelBefore,
                "exitPanelAttachedBeforeCtrlD": exitPanelAttachedBeforeCtrlD ? "1" : "0",
                "exitPanelHasSurfaceBeforeCtrlD": exitPanelHasSurfaceBeforeCtrlD ? "1" : "0",
                "ready": "1",
                "done": "0",
            ])

            var finished = false
            var timeoutWork: DispatchWorkItem?

            @MainActor
            func finish(_ updates: [String: String]) {
                guard !finished else { return }
                finished = true
                timeoutWork?.cancel()
                write(updates.merging(["done": "1"], uniquingKeysWith: { _, new in new }))
                self.uiTestCancellables.removeAll()
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

            tabsPublisher
                .map { $0.contains(where: { $0.id == tab.id }) }
                .removeDuplicates()
                .sink { alive in
                    Task { @MainActor in
                        if !alive {
                            finish([
                                "workspaceCountAfter": "0",
                                "panelCountAfter": "0",
                                "closedWorkspace": "1",
                            ])
                        }
                    }
                }
                .store(in: &uiTestCancellables)

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
}

#if DEBUG
/// The live-action side of the DEBUG split / child-exit UI-test scaffolds. The
/// env-gating and parameter parsing live in `CmuxTestSupport`; the harness
/// bodies stay here because they drive AppKit / Bonsplit / Ghostty surface state
/// that cannot cross the package boundary.
extension TabManager: UITestScaffoldRunning {}
#endif

extension TabManager {
    func sessionAutosaveFingerprint(
        restorableAgentIndex: RestorableAgentSessionIndex = .empty,
        surfaceResumeBindingIndex: SurfaceResumeBindingIndex = .empty
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(selectedTabId)
        hasher.combine(tabs.count)
        let notificationStore = AppDelegate.shared?.notificationStore

        // Workspace groups participate in the session snapshot, so changes
        // that only touch group metadata (rename / collapse / pin a group,
        // or move a workspace between groups without reordering tabs) must
        // bump the fingerprint or the autosave timer skips the write.
        hasher.combine(workspaceGroups.count)
        for group in workspaceGroups {
            hasher.combine(group.id)
            hasher.combine(group.name)
            hasher.combine(group.isCollapsed)
            hasher.combine(group.isPinned)
            hasher.combine(group.anchorWorkspaceId)
            hasher.combine(group.customColor ?? "")
            hasher.combine(group.iconSymbol ?? "")
        }
        for workspace in tabs.prefix(SessionPersistencePolicy.maxWorkspacesPerWindow) {
            hasher.combine(workspace.id)
            hasher.combine(workspace.groupId)
            hasher.combine(workspace.focusedPanelId)
            hasher.combine(workspace.currentDirectory)
            hasher.combine(workspace.customTitle ?? "")
            hasher.combine(workspace.customDescription ?? "")
            hasher.combine(workspace.customColor ?? "")
            hasher.combine(workspace.isPinned)
            hasher.combine(workspace.panels.count)
            hasher.combine(workspace.statusEntries.count)
            hasher.combine(workspace.metadataBlocks.count)
            hasher.combine(workspace.logEntries.count)
            hasher.combine(workspace.panelDirectories.count)
            hasher.combine(workspace.panelTitles.count)
            hasher.combine(workspace.panelPullRequests.count)
            hasher.combine(workspace.panelGitBranches.count)
            hasher.combine(workspace.surfaceListeningPorts.count)
            hasher.combine(notificationStore?.hasManualUnread(forTabId: workspace.id) ?? false)
            hasher.combine(notificationStore?.workspaceIsUnread(forTabId: workspace.id) ?? false)
            Self.hashNotifications(
                notificationStore?.notifications(forTabId: workspace.id, surfaceId: nil) ?? [],
                into: &hasher
            )

            let panelIds = workspace.panels.keys.sorted { $0.uuidString < $1.uuidString }
            hasher.combine(panelIds.count)
            for panelId in panelIds {
                hasher.combine(panelId)
                hasher.combine(workspace.manualUnreadPanelIds.contains(panelId))
                hasher.combine(workspace.restoredUnreadPanelIds.contains(panelId))
                hasher.combine(workspace.restoredUnreadIndicatorContributesToWorkspace(panelId: panelId))
                hasher.combine(
                    notificationStore?.hasVisibleNotificationIndicator(
                        forTabId: workspace.id,
                        surfaceId: panelId
                    ) ?? false
                )
                Self.hashNotifications(
                    notificationStore?.notifications(forTabId: workspace.id, surfaceId: panelId) ?? [],
                    into: &hasher
                )
                Self.hashRestorableAgentSnapshot(
                    restorableAgentIndex.snapshot(
                        workspaceId: workspace.id,
                        panelId: panelId
                    ),
                    into: &hasher
                )
                Self.hashAgentHibernationPanelState(
                    (workspace.panels[panelId] as? TerminalPanel)?.agentHibernationState,
                    into: &hasher
                )
                Self.hashSurfaceResumeBindingSnapshot(
                    workspace.effectiveSurfaceResumeBinding(
                        panelId: panelId,
                        surfaceResumeBindingIndex: surfaceResumeBindingIndex
                    ),
                    into: &hasher
                )
                if let terminalPanel = workspace.terminalPanel(for: panelId) {
                    Self.hashTextBoxDraftSnapshot(
                        terminalPanel.sessionTextBoxDraftSnapshot(),
                        into: &hasher
                    )
                } else {
                    hasher.combine(false)
                }
            }

            if let progress = workspace.progress {
                hasher.combine(Int((progress.value * 1000).rounded()))
                hasher.combine(progress.label)
            } else {
                hasher.combine(-1)
            }

            if let gitBranch = workspace.gitBranch {
                hasher.combine(gitBranch.branch)
                hasher.combine(gitBranch.isDirty)
            } else {
                hasher.combine("")
                hasher.combine(false)
            }
        }

        return hasher.finalize()
    }

    nonisolated static func restorableAgentSnapshotFingerprint(
        _ snapshot: SessionRestorableAgentSnapshot?
    ) -> Int {
        var hasher = Hasher()
        hashRestorableAgentSnapshot(snapshot, into: &hasher)
        return hasher.finalize()
    }

    nonisolated private static func hashRestorableAgentSnapshot(
        _ snapshot: SessionRestorableAgentSnapshot?,
        into hasher: inout Hasher
    ) {
        guard let snapshot else {
            hasher.combine(false)
            return
        }

        hasher.combine(true)
        hasher.combine(snapshot.kind.rawValue)
        hasher.combine(snapshot.sessionId)
        hashOptionalString(snapshot.workingDirectory, into: &hasher)
        hashAgentLaunchCommand(snapshot.launchCommand, into: &hasher)
    }

    nonisolated private static func hashAgentLaunchCommand(
        _ launchCommand: AgentLaunchCommandSnapshot?,
        into hasher: inout Hasher
    ) {
        guard let launchCommand else {
            hasher.combine(false)
            return
        }

        hasher.combine(true)
        hashOptionalString(launchCommand.launcher, into: &hasher)
        hashOptionalString(launchCommand.executablePath, into: &hasher)
        hasher.combine(launchCommand.arguments)
        hashOptionalString(launchCommand.workingDirectory, into: &hasher)
        if let environment = launchCommand.environment {
            hasher.combine(true)
            hasher.combine(environment.count)
            for key in environment.keys.sorted() {
                hasher.combine(key)
                hasher.combine(environment[key])
            }
        } else {
            hasher.combine(false)
        }
        hashOptionalDouble(launchCommand.capturedAt, into: &hasher)
        hashOptionalString(launchCommand.source, into: &hasher)
    }

    private static func hashAgentHibernationPanelState(
        _ state: AgentHibernationPanelState?,
        into hasher: inout Hasher
    ) {
        guard let state else {
            hasher.combine(false)
            return
        }

        hasher.combine(true)
        hashRestorableAgentSnapshot(state.agent, into: &hasher)
        hasher.combine(state.hibernatedAt.timeIntervalSince1970)
        hasher.combine(state.lastActivityAt.timeIntervalSince1970)
    }

    nonisolated private static func hashSurfaceResumeBindingSnapshot(
        _ snapshot: SurfaceResumeBindingSnapshot?,
        into hasher: inout Hasher
    ) {
        guard let snapshot else {
            hasher.combine(false)
            return
        }

        hasher.combine(true)
        hashOptionalString(snapshot.name, into: &hasher)
        hashOptionalString(snapshot.kind, into: &hasher)
        hasher.combine(snapshot.command)
        hashOptionalString(snapshot.cwd, into: &hasher)
        hashOptionalString(snapshot.checkpointId, into: &hasher)
        hashOptionalString(snapshot.source, into: &hasher)
        hashStringMap(snapshot.environment, into: &hasher)
        hasher.combine(snapshot.allowsAutomaticResume)
        if snapshot.isProcessDetected {
            hasher.combine(false)
        } else {
            hashOptionalDouble(snapshot.updatedAt, into: &hasher)
        }
    }

    nonisolated private static func hashTextBoxDraftSnapshot(
        _ snapshot: SessionTextBoxInputDraftSnapshot?,
        into hasher: inout Hasher
    ) {
        guard let snapshot else {
            hasher.combine(false)
            return
        }

        hasher.combine(true)
        hasher.combine(snapshot.isActive)
        hasher.combine(snapshot.parts.count)
        for part in snapshot.parts {
            hasher.combine(part.kind.rawValue)
            hashOptionalString(part.text, into: &hasher)
            hashTextBoxAttachmentSnapshot(part.attachment, into: &hasher)
        }
    }

    nonisolated private static func hashTextBoxAttachmentSnapshot(
        _ snapshot: SessionTextBoxInputAttachmentSnapshot?,
        into hasher: inout Hasher
    ) {
        guard let snapshot else {
            hasher.combine(false)
            return
        }

        hasher.combine(true)
        hasher.combine(snapshot.displayName)
        hasher.combine(snapshot.submissionText)
        hasher.combine(snapshot.submissionPath)
        hashOptionalString(snapshot.localPath, into: &hasher)
        hasher.combine(snapshot.cleanupLocalPathWhenDisposed)
    }

    nonisolated private static func hashNotifications(
        _ notifications: [TerminalNotification],
        into hasher: inout Hasher
    ) {
        hasher.combine(notifications.count)
        for notification in notifications.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            hasher.combine(notification.id)
            hasher.combine(notification.title)
            hasher.combine(notification.subtitle)
            hasher.combine(notification.body)
            hasher.combine(notification.createdAt.timeIntervalSince1970)
            hasher.combine(notification.isRead)
            hasher.combine(notification.paneFlash)
            hasher.combine(notification.panelId)
            hasher.combine(notification.clickAction)
        }
    }

    nonisolated private static func hashOptionalString(_ value: String?, into hasher: inout Hasher) {
        if let value {
            hasher.combine(true)
            hasher.combine(value)
        } else {
            hasher.combine(false)
        }
    }

    nonisolated private static func hashOptionalDouble(_ value: Double?, into hasher: inout Hasher) {
        if let value {
            hasher.combine(true)
            hasher.combine(value)
        } else {
            hasher.combine(false)
        }
    }

    nonisolated private static func hashStringMap(_ value: [String: String]?, into hasher: inout Hasher) {
        guard let value, !value.isEmpty else {
            hasher.combine(false)
            return
        }
        hasher.combine(true)
        let keys = value.keys.sorted()
        hasher.combine(keys.count)
        for key in keys {
            hasher.combine(key)
            hasher.combine(value[key] ?? "")
        }
    }

    func sessionSnapshot(
        includeScrollback: Bool,
        restorableAgentIndex: RestorableAgentSessionIndex = .empty,
        surfaceResumeBindingIndex: SurfaceResumeBindingIndex? = nil
    ) -> SessionTabManagerSnapshot {
        let restorableTabs = tabs
            .filter(\.isRestorableInSessionSnapshot)
            .prefix(SessionPersistencePolicy.maxWorkspacesPerWindow)
        let workspaceSnapshots = restorableTabs
            .map {
                $0.sessionSnapshot(
                    includeScrollback: includeScrollback,
                    restorableAgentIndex: restorableAgentIndex,
                    surfaceResumeBindingIndex: surfaceResumeBindingIndex
                )
            }
        let selectedWorkspaceIndex = selectedTabId.flatMap { selectedTabId in
            restorableTabs.firstIndex(where: { $0.id == selectedTabId })
        }
        let occupiedGroupIds = Set(restorableTabs.compactMap(\.groupId))
        // Build a per-group ordered list of restorable member IDs so we can
        // record the anchor's index (restore-stable across UUID rotation).
        let restorableMembersByGroupId: [UUID: [UUID]] = {
            var map: [UUID: [UUID]] = [:]
            for tab in restorableTabs {
                if let gid = tab.groupId {
                    map[gid, default: []].append(tab.id)
                }
            }
            return map
        }()
        let groupSnapshots = sessionSnapshotGroups.assembleGroupSnapshots(
            groups: workspaceGroups,
            occupiedGroupIds: occupiedGroupIds,
            restorableMemberIdsByGroupId: restorableMembersByGroupId
        )
        return SessionTabManagerSnapshot(
            selectedWorkspaceIndex: selectedWorkspaceIndex,
            workspaces: workspaceSnapshots,
            workspaceGroups: groupSnapshots
        )
    }

    func sessionSnapshotWorkspaceIds() -> [UUID] {
        Array(
            tabs
                .filter(\.isRestorableInSessionSnapshot)
                .prefix(SessionPersistencePolicy.maxWorkspacesPerWindow)
                .map(\.id)
        )
    }

    private func releaseRestoredAwayWorkspace(_ workspace: Workspace) {
        // Session restore replaces the bootstrap workspace objects with freshly
        // restored ones. Tear the old graph down after the atomic swap so late
        // panel/socket callbacks cannot keep mutating hidden pre-restore state.
        AppDelegate.shared?.notificationStore?.clearNotifications(forTabId: workspace.id)
        workspace.teardownAllPanels()
        workspace.teardownRemoteConnection()
        workspace.owningTabManager = nil
    }

    @discardableResult
    func restoreSessionSnapshot(
        _ snapshot: SessionTabManagerSnapshot,
        remapClosedPanelHistory: Bool = true
    ) -> [[UUID: UUID]] {
        isRestoringSessionSnapshot = true
        defer { isRestoringSessionSnapshot = false }
        let previousTabs = tabs
        for tab in previousTabs {
            unwireClosedBrowserTracking(for: tab)
        }
        ClosedItemHistoryStore.shared.removePanelRecords(
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
        selectionSideEffectsGeneration &+= 1
        browserModel.clearRecentlyClosedBrowserPanels()

        // Build the new workspace list locally to avoid intermediate @Published
        // emissions (empty tabs, nil selectedTabId) that can leave SwiftUI's
        // mountedWorkspaceIds empty and cause a frozen blank launch state (#399).
        var newTabs: [Workspace] = []
        var restoredPanelIdsByWorkspaceIndex: [[UUID: UUID]] = []
        let workspaceSnapshots = snapshot.workspaces
            .prefix(SessionPersistencePolicy.maxWorkspacesPerWindow)
        var restoredOriginalWorkspaceIds: [UUID?] = []
        for workspaceSnapshot in workspaceSnapshots {
            let ordinal = Self.nextPortOrdinal
            Self.nextPortOrdinal += 1
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
            let ordinal = Self.nextPortOrdinal
            Self.nextPortOrdinal += 1
            let fallback = Workspace(title: "Terminal 1", portOrdinal: ordinal)
            fallback.owningTabManager = self
            wireClosedBrowserTracking(for: fallback)
            newTabs.append(fallback)
        }

        // Determine selection before mutating @Published properties.
        let newSelectedId: UUID?
        if let selectedWorkspaceIndex = snapshot.selectedWorkspaceIndex,
           newTabs.indices.contains(selectedWorkspaceIndex) {
            newSelectedId = newTabs[selectedWorkspaceIndex].id
        } else {
            newSelectedId = newTabs.first?.id
        }

        // Single atomic assignment of @Published properties so SwiftUI observers
        // never see an intermediate state with empty tabs or nil selection.
        tabs = newTabs
        let workspaceIdsByGroupId: [UUID: [UUID]] = {
            var map: [UUID: [UUID]] = [:]
            for workspace in newTabs {
                if let gid = workspace.groupId {
                    map[gid, default: []].append(workspace.id)
                }
            }
            return map
        }()
        let restoredGroups = sessionSnapshotGroups.restoreGroups(
            groupSnapshots: snapshot.workspaceGroups,
            memberIdsByGroupId: workspaceIdsByGroupId
        )
        // Clear any group references on restored workspaces that no longer correspond
        // to a known group (older snapshots, manual edits, etc.).
        let knownGroupIds = Set(restoredGroups.map(\.id))
        for workspace in newTabs where workspace.groupId.map({ !knownGroupIds.contains($0) }) ?? false {
            workspace.groupId = nil
        }
        workspaceGroups = restoredGroups
        selectedTabId = newSelectedId
        let existingIds = Set(newTabs.map(\.id))
        pruneBackgroundWorkspaceLoads(existingIds: existingIds)
        sidebarMultiSelection.intersectSelection(with: existingIds)
        for workspace in previousTabs {
            releaseRestoredAwayWorkspace(workspace)
        }
        for workspace in newTabs {
            let terminalPanels = workspace.panels.values.compactMap { $0 as? TerminalPanel }
            for terminalPanel in terminalPanels {
                scheduleInitialWorkspaceGitMetadataRefreshIfPossible(
                    workspaceId: workspace.id,
                    panelId: terminalPanel.id
                )
            }
        }
        if remapClosedPanelHistory {
            remapClosedPanelHistoryAfterSessionRestore(
                originalWorkspaceIds: restoredOriginalWorkspaceIds,
                restoredPanelIdsByWorkspaceIndex: restoredPanelIdsByWorkspaceIndex
            )
        }

        if let selectedTabId {
            NotificationCenter.default.post(
                name: .ghosttyDidFocusTab,
                object: nil,
                userInfo: [GhosttyNotificationKey.tabId: selectedTabId]
            )
        }
        return restoredPanelIdsByWorkspaceIndex
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
    // shared history store and flushes once when any op ran, matching the
    // legacy `didRequestHistoryRemap` gate. `ClosedItemHistoryStore.shared`
    // stays app-side; its de-singletonization is deferred to a later slice.
    private func applyClosedPanelHistoryRemaps(
        _ operations: [ClosedPanelHistoryRemapOperation]
    ) {
        guard !operations.isEmpty else { return }
        for operation in operations {
            ClosedItemHistoryStore.shared.remapPanelWorkspaceIds(
                from: operation.fromWorkspaceId,
                to: operation.toWorkspaceId,
                panelIdMap: operation.panelIdMap
            )
        }
        ClosedItemHistoryStore.shared.flushPendingSaves()
    }
}

// The hook methods live in the class body (they touch private selection /
// DEBUG state); these extensions only bind the conformances.
extension TabManager: WorkspacesHosting {}
extension TabManager: WorkspaceGroupHosting {}
extension TabManager: CloseConfirming {}
extension TabManager: WorkspaceCloseHosting {}
extension TabManager: SurfaceMetadataTitleHosting {}

// Workspace satisfies the CmuxWorkspaces tab seam with its existing
// id/groupId/isPinned storage.
extension Workspace: WorkspaceTabRepresenting {}

extension Notification.Name {
    // The sidebar multi-selection sync events moved to CmuxSidebar as typed
    // SidebarMultiSelectionShouldCollapseEvent / DidHideEvent (same names).
    static let commandPaletteToggleRequested = Notification.Name("cmux.commandPaletteToggleRequested")
    static let commandPaletteRequested = Notification.Name("cmux.commandPaletteRequested")
    static let commandPaletteSwitcherRequested = Notification.Name("cmux.commandPaletteSwitcherRequested")
    static let commandPaletteSubmitRequested = Notification.Name("cmux.commandPaletteSubmitRequested")
    static let commandPaletteDismissRequested = Notification.Name("cmux.commandPaletteDismissRequested")
    static let commandPaletteRenameTabRequested = Notification.Name("cmux.commandPaletteRenameTabRequested")
    static let commandPaletteRenameWorkspaceRequested = Notification.Name("cmux.commandPaletteRenameWorkspaceRequested")
    static let commandPaletteEditWorkspaceDescriptionRequested = Notification.Name("cmux.commandPaletteEditWorkspaceDescriptionRequested")
    static let commandPaletteMoveSelection = Notification.Name("cmux.commandPaletteMoveSelection")
    static let commandPaletteRenameInputInteractionRequested = Notification.Name("cmux.commandPaletteRenameInputInteractionRequested")
    static let commandPaletteRenameInputDeleteBackwardRequested = Notification.Name("cmux.commandPaletteRenameInputDeleteBackwardRequested")
    static let feedbackComposerRequested = Notification.Name("cmux.feedbackComposerRequested")
    static let ghosttyDidSetTitle = Notification.Name("ghosttyDidSetTitle")
    static let ghosttyDidFocusTab = Notification.Name("ghosttyDidFocusTab")
    static let ghosttyDidFocusSurface = Notification.Name("ghosttyDidFocusSurface")
    static let ghosttyDidBecomeFirstResponderSurface = Notification.Name("ghosttyDidBecomeFirstResponderSurface")
    static let browserDidBecomeFirstResponderWebView = Notification.Name("browserDidBecomeFirstResponderWebView")
    static let browserFocusAddressBar = Notification.Name("browserFocusAddressBar")
    static let browserMoveOmnibarSelection = Notification.Name("browserMoveOmnibarSelection")
    static let browserDidExitAddressBar = Notification.Name("browserDidExitAddressBar")
    static let browserDidFocusAddressBar = Notification.Name("browserDidFocusAddressBar")
    static let browserDidBlurAddressBar = Notification.Name("browserDidBlurAddressBar")
    static let browserFocusModeStateDidChange = Notification.Name("cmux.browserFocusModeStateDidChange")
    static let webViewDidReceiveClick = Notification.Name("webViewDidReceiveClick")
    static let terminalPortalVisibilityDidChange = Notification.Name("cmux.terminalPortalVisibilityDidChange")
    static let browserPortalRegistryDidChange = Notification.Name("cmux.browserPortalRegistryDidChange")
    static let workspaceOrderDidChange = Notification.Name("cmux.workspaceOrderDidChange")
    /// Posted when an existing workspace group's `name` changes (rename). The
    /// imperatively-cached window-chrome surfaces (custom title bar in
    /// `ContentView`, toolbar command label in `WindowToolbarController`) read
    /// a grouped anchor's displayed name from `group.name` and refresh on this.
    static let workspaceGroupNameDidChange = Notification.Name("cmux.workspaceGroupNameDidChange")
    static let workspaceCurrentDirectoryDidChange = Notification.Name("cmux.workspaceCurrentDirectoryDidChange")
    static let tabManagerFocusHistoryRevisionDidChange = Notification.Name("cmux.tabManagerFocusHistoryRevisionDidChange")
}

enum BrowserFirstResponderNotificationUserInfoKey {
    static let pointerInitiated = "pointerInitiated"
}

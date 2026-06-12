import AppKit
import SwiftUI
import Foundation
import Bonsplit
import CmuxBrowser
import CmuxFileWatch
import CmuxGit
import CmuxNotifications
import CmuxPanes
import CmuxProcess
import CmuxSettings
import CmuxSidebar
import CmuxSidebarGit
import CmuxWorkspaceNavigation
import CmuxWorkspaces
import CoreVideo
import Combine
import CoreServices
import Darwin
import OSLog

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
fileprivate final class VsyncIOSurfaceTimelineState {
    struct Target {
        let label: String
        let sample: @MainActor () -> GhosttySurfaceScrollView.DebugFrameSample?
    }

    let frameCount: Int
    let closeFrame: Int
    let lock = NSLock()

    var framesWritten = 0
    var inFlight = false
    var finished = false

    var scheduledActions: [(frame: Int, action: () -> Void)] = []
    var nextActionIndex: Int = 0

    var targets: [Target] = []

    // Results
    var firstBlank: (label: String, frame: Int)?
    var firstSizeMismatch: (label: String, frame: Int, ios: String, expected: String)?
    var trace: [String] = []

    var link: CVDisplayLink?
    var continuation: CheckedContinuation<Void, Never>?

    init(frameCount: Int, closeFrame: Int) {
        self.frameCount = frameCount
        self.closeFrame = closeFrame
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
        guard st.framesWritten < st.frameCount else { return }

        while st.nextActionIndex < st.scheduledActions.count {
            let next = st.scheduledActions[st.nextActionIndex]
            if next.frame != st.framesWritten { break }
            st.nextActionIndex += 1
            next.action()
        }

        for t in st.targets {
            guard let s = t.sample() else { continue }

            let iosW = s.iosurfaceWidthPx
            let iosH = s.iosurfaceHeightPx
            let expW = s.expectedWidthPx
            let expH = s.expectedHeightPx
            let gravity = s.layerContentsGravity
            let hasDimensions = iosW > 0 && iosH > 0 && expW > 0 && expH > 0
            let dw = hasDimensions ? abs(iosW - expW) : 0
            let dh = hasDimensions ? abs(iosH - expH) : 0
            let hasSizeMismatch = hasDimensions && (dw > 2 || dh > 2)
            let stretchRisk = (gravity == CALayerContentsGravity.resize.rawValue)

            // Ignore setup/warmup frames before the close action. We only care about
            // regressions that happen at/after the close mutation.
            if st.firstBlank == nil, st.framesWritten >= st.closeFrame, s.isProbablyBlank {
                st.firstBlank = (label: t.label, frame: st.framesWritten)
            }

            if st.firstSizeMismatch == nil,
               st.framesWritten >= st.closeFrame,
               stretchRisk,
               hasSizeMismatch {
                st.firstSizeMismatch = (
                    label: t.label,
                    frame: st.framesWritten,
                    ios: "\(iosW)x\(iosH)",
                    expected: "\(expW)x\(expH)"
                )
            }

            if st.trace.count < 200 {
                st.trace.append("\(st.framesWritten):\(t.label):blank=\(s.isProbablyBlank ? 1 : 0):ios=\(iosW)x\(iosH):exp=\(expW)x\(expH):gravity=\(gravity):key=\(s.layerContentsKey)")
            }
        }

        st.framesWritten += 1
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

    // Wave-4 sub-model (TabManager decomposition): the workspace list, the
    // sidebar group sections, and the selected-workspace id storage live in
    // WorkspacesModel (CmuxWorkspaces). TabManager stays the per-window
    // composition point: it owns the model, forwards the legacy accessors
    // below, and implements WorkspacesHosting (bottom of this file) to run
    // the legacy @Published property-observer side effects at identical
    // timing (objectWillChange + bridge publishers in willSet, selection
    // side effects in didSet).
    let workspaces = WorkspacesModel<Workspace>()

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
    /// Set by `restoreSessionSnapshot` to suppress side-effects (like auto-
    /// expanding a group on focus) that would mutate restored state mid-restore.
    private var isRestoringSessionSnapshot: Bool = false
    @Published private(set) var isWorkspaceCycleHot: Bool = false
    @Published private(set) var pendingBackgroundWorkspaceLoadIds: Set<UUID> = []
    @Published private(set) var mountedBackgroundWorkspaceLoadIds: Set<UUID> = []
    @Published private(set) var debugPinnedWorkspaceLoadIds: Set<UUID> = []

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
                expandWorkspaceGroupForSelectionIfNeeded()
            }
            sentryBreadcrumb("workspace.switch", data: [
                "tabCount": tabs.count
            ])
            let previousTabId = oldValue
            if let previousTabId,
               let previousPanelId = focusedPanelId(for: previousTabId) {
                lastFocusedPanelByTab[previousTabId] = previousPanelId
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
                        panelId: lastFocusedPanelByTab[selectedTabId]
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
                    self.focusSelectedTabPanel(previousTabId: previousTabId)
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
    private var lastFocusedPanelByTab: [UUID: UUID] = [:]
    private struct PanelTitleUpdateKey: Hashable {
        let tabId: UUID
        let panelId: UUID
    }
    private var pendingPanelTitleUpdates: [PanelTitleUpdateKey: String] = [:]
    private let panelTitleUpdateCoalescer = NotificationBurstCoalescer(delay: 1.0 / 30.0)

    // Wave-3 sub-models (TabManager decomposition): TabManager is the
    // per-window composition point. It owns the concrete sub-models, hosts
    // their seams, and forwards its legacy entry points.
    /// Per-panel notification-dismissal flow (CmuxNotifications).
    let notificationDismissal: any NotificationDismissing = NotificationDismissalModel()
    /// Recently-closed browser panel history (CmuxBrowser).
    let browserModel = BrowserModel<ClosedBrowserPanelRestoreSnapshot>()
    /// Sidebar multi-selection state + sync events (CmuxSidebar).
    let sidebarMultiSelection = SidebarMultiSelectionModel()
    /// Typed synchronous settings access (CmuxSettings).
    private let settings: any SettingsWriting
    private let settingsCatalog = SettingCatalog()

    @Published private(set) var focusHistoryRevision: UInt64 = 0 {
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
    // Pure batch-reorder planning (CmuxWorkspaces); applying the plan to
    // tabs[] and renormalizing groups stays here.
    let workspaceReorder = WorkspaceReorderPlanner()
    private var shouldRecordFocusHistory: Bool {
        focusHistoryNavigation.shouldRecordFocusHistory
    }
    private var selectionSideEffectsGeneration: UInt64 = 0
    private var workspaceCycleGeneration: UInt64 = 0
    private var workspaceCycleCooldownTask: Task<Void, Never>?
    private var pendingWorkspaceUnfocusTarget: (tabId: UUID, panelId: UUID)?
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
    private var didSetupSplitCloseRightUITest = false
    private var didSetupUITestFocusShortcuts = false
    private var didSetupChildExitSplitUITest = false
    private var didSetupChildExitKeyboardUITest = false
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
        // Workspace-list/group/selection storage (CmuxWorkspaces). Attached
        // before the first addWorkspace so the property-observer hooks fire
        // from the very first insertion, matching the legacy @Published
        // observer timing.
        workspaces.attach(host: self)
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
                guard let tabId = notification.userInfo?[GhosttyNotificationKey.tabId] as? UUID else { return }
                guard let surfaceId = notification.userInfo?[GhosttyNotificationKey.surfaceId] as? UUID else { return }
                guard let title = notification.userInfo?[GhosttyNotificationKey.title] as? String else { return }
                enqueuePanelTitleUpdate(tabId: tabId, panelId: surfaceId, title: title)
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

        startAgentPIDSweepTimer()
        observers.append(NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { [weak self] in
                self?.sidebarMetadataSettingsDidChange()
                self?.refreshTabCloseButtonVisibility()
            }
        })
#if DEBUG
        setupUITestFocusShortcutsIfNeeded()
        setupSplitCloseRightUITestIfNeeded()
        setupChildExitSplitUITestIfNeeded()
        setupChildExitKeyboardUITestIfNeeded()
#endif
    }

    deinit {
        workspaceCycleCooldownTask?.cancel()
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

    func gitProbeDirectory(for workspace: Workspace, panelId: UUID) -> String? {
        // Match the sidebar directory fallback chain so hidden/background panels can
        // still probe git metadata before OSC 7 has reported a live cwd.
        let rawDirectory = workspace.panelDirectories[panelId]
            ?? workspace.terminalPanel(for: panelId)?.requestedWorkingDirectory
            ?? (workspace.focusedPanelId == panelId ? workspace.currentDirectory : nil)
        return rawDirectory.flatMap(normalizedWorkingDirectory)
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

    var isFindVisible: Bool {
        selectedTerminalPanel?.searchState != nil || focusedBrowserPanel?.searchState != nil
    }

    var canUseSelectionForFind: Bool {
        selectedTerminalPanel?.hasSelection() == true
    }

    @discardableResult
    func startSearch() -> Bool {
        if let panel = selectedTerminalPanel {
            let hadExistingSearch = panel.searchState != nil
            panel.hostedView.preparePanelFocusIntentForActivation(.findField)
            let recoveredNeedle = hadExistingSearch ? "" : panel.surface.lastSearchNeedle
            let handled = startOrFocusTerminalSearch(panel.surface, initialNeedle: recoveredNeedle) { surface in
                NotificationCenter.default.post(
                    name: .ghosttySearchFocus,
                    object: surface,
                    userInfo: [FindFocusNotificationKey.selectAll: !hadExistingSearch && !recoveredNeedle.isEmpty]
                )
            }
#if DEBUG
            cmuxDebugLog(
                "find.startSearch workspace=\(panel.workspaceId.uuidString.prefix(5)) " +
                "panel=\(panel.id.uuidString.prefix(5)) existing=\(hadExistingSearch ? "yes" : "no") " +
                "handled=\(handled ? 1 : 0) " +
                "firstResponder=\(String(describing: panel.surface.uiWindow?.firstResponder))"
            )
#endif
            return handled
        }
        guard let browserPanel = focusedBrowserPanel else { return false }
        browserPanel.startFind()
        return browserPanel.searchState != nil
    }

    func searchSelection() {
        guard let panel = selectedTerminalPanel else { return }
        if panel.searchState == nil {
            panel.searchState = TerminalSurface.SearchState()
        }
#if DEBUG
        cmuxDebugLog(
            "find.searchSelection workspace=\(panel.workspaceId.uuidString.prefix(5)) " +
            "panel=\(panel.id.uuidString.prefix(5))"
        )
#endif
        NotificationCenter.default.post(name: .ghosttySearchFocus, object: panel.surface)
        _ = panel.performBindingAction("search_selection")
    }

    func findNext() {
        if let panel = selectedTerminalPanel {
            _ = panel.performBindingAction("search:next")
            return
        }

        focusedBrowserPanel?.findNext()
    }

    func findPrevious() {
        if let panel = selectedTerminalPanel {
            _ = panel.performBindingAction("search:previous")
            return
        }

        focusedBrowserPanel?.findPrevious()
    }

    @discardableResult
    func toggleFocusedTerminalCopyMode() -> Bool {
        guard let panel = selectedTerminalPanel else { return false }
        return panel.surface.toggleKeyboardCopyMode()
    }

    /// Forwards a single Ctrl-F (`^F`) key press to the focused terminal surface,
    /// faithfully encoded through Ghostty so it matches whatever the running TUI
    /// would receive from a real keystroke.
    ///
    /// This is the non-keyboard escape hatch for control chords that a focused TUI
    /// reads off the raw tty. The motivating case is Claude Code's force-stop, which
    /// is only exposed as "press Ctrl-F twice"; invoke this action twice to deliver
    /// it. Delivery bypasses cmux's shortcut/menu/responder layers entirely.
    ///
    /// - Returns: `true` when the chord was sent or queued for the focused terminal,
    ///   `false` when no terminal panel is focused.
    @discardableResult
    func sendCtrlFToFocusedTerminal() -> Bool {
        guard let panel = selectedTerminalPanel else { return false }
        let result = panel.sendNamedKeyResult("ctrl-f")
        if result == .sent {
            panel.surface.forceRefresh(reason: "tabManager.sendCtrlFToFocusedTerminal")
        }
#if DEBUG
        cmuxDebugLog(
            "terminal.sendCtrlF workspace=\(panel.workspaceId.uuidString.prefix(5)) " +
            "panel=\(panel.id.uuidString.prefix(5)) result=\(result)"
        )
#endif
        return result.accepted
    }

    @discardableResult
    func toggleFocusedTerminalTextBox() -> Bool {
        guard let panel = selectedTerminalPanel else { return false }
        return panel.toggleTextBoxInput()
    }

    @discardableResult
    func focusFocusedTerminalTextBoxInputOrTerminal() -> Bool {
        guard let panel = selectedTerminalPanel else { return false }
        return panel.focusTextBoxInputOrTerminal()
    }

    @discardableResult
    func attachFileToFocusedTerminalTextBoxInput() -> Bool {
        guard let panel = selectedTerminalPanel else { return false }
        return panel.attachFileToTextBoxInput()
    }

    @discardableResult
    func consumeFocusedTerminalTextBoxHideEscapeIfArmed(in window: NSWindow?) -> Bool {
        guard let focusedPanel = selectedTerminalPanel else {
            clearFocusedTerminalTextBoxHideEscapeArm()
            return false
        }
        let consumed = focusedPanel.consumeTextBoxHideEscapeIfArmed(in: window)
        guard !consumed else { return true }
        for panel in selectedWorkspaceTerminalPanels {
            if panel === focusedPanel { continue }
            panel.clearTextBoxHideEscapeArm()
        }
        return false
    }

    func clearFocusedTerminalTextBoxHideEscapeArm() {
        for panel in selectedWorkspaceTerminalPanels {
            panel.clearTextBoxHideEscapeArm()
        }
    }

    func hideFind() {
        if let panel = selectedTerminalPanel {
            panel.searchState = nil
            return
        }

        focusedBrowserPanel?.hideFind()
    }

    func makeWorkspaceForCreation(
        title: String,
        workingDirectory: String?,
        portOrdinal: Int,
        configTemplate: CmuxSurfaceConfigTemplate?,
        initialTerminalCommand: String?,
        initialTerminalInput: String? = nil,
        initialTerminalEnvironment: [String: String]
    ) -> Workspace {
        Workspace(
            title: title,
            workingDirectory: workingDirectory,
            portOrdinal: portOrdinal,
            configTemplate: configTemplate,
            initialTerminalCommand: initialTerminalCommand,
            initialTerminalInput: initialTerminalInput,
            initialTerminalEnvironment: initialTerminalEnvironment
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

    @discardableResult
    func addWorkspace(
        title: String? = nil,
        workingDirectory overrideWorkingDirectory: String? = nil,
        initialTerminalCommand: String? = nil,
        initialTerminalInput: String? = nil,
        initialTerminalEnvironment: [String: String] = [:],
        inheritWorkingDirectory: Bool = true,
        select: Bool = true,
        eagerLoadTerminal: Bool = false,
        placementOverride: WorkspacePlacement? = nil,
        autoWelcomeIfNeeded: Bool = true,
        autoRefreshMetadata: Bool = true,
        normalizeWorkspaceGroupsAfterInsert: Bool = true
    ) -> Workspace {
        let sourceWorkspace = selectedWorkspace
        let capturedTabs = tabs
        // Snapshot the selected tab from the pinned workspace instead of rereading the
        // @Published selectedTabId storage after the inheritance helpers. The arm64 Nightly
        // Cmd+N crash is in PublishedSubject.value.getter on that second getter read.
        let capturedSelectedTabId = sourceWorkspace?.id
        // Keep both the source workspace and the pre-creation workspace array alive for the
        // entire creation path. Release ARC can otherwise drop retains early across the
        // helper/insertion chain, which reintroduces use-after-free crashes in optimized builds.
        return withExtendedLifetime((capturedTabs, sourceWorkspace)) {
            let dir = inheritWorkingDirectory
                ? implicitWorkingDirectoryForNewWorkspace(from: sourceWorkspace)
                : nil
            let font = inheritedTerminalFontPointsForNewWorkspace(workspace: sourceWorkspace)
            let snapshot = workspaceCreationSnapshotLite(
                currentTabs: capturedTabs,
                currentSelectedTabId: capturedSelectedTabId,
                preferredWorkingDirectory: dir,
                inheritedTerminalFontPoints: font
            )
            didCaptureWorkspaceCreationSnapshot()
#if DEBUG
            maybeMutateSelectionDuringWorkspaceCreationForDev(snapshot: snapshot)
#endif
            let nextTabCount = snapshot.tabs.count + 1
            sentryBreadcrumb("workspace.create", data: ["tabCount": nextTabCount])
            let explicitWorkingDirectory = normalizedWorkingDirectory(overrideWorkingDirectory)
            let workingDirectory = explicitWorkingDirectory ?? snapshot.preferredWorkingDirectory
            let inheritedConfig = workspaceCreationConfigTemplate(
                inheritedTerminalFontPoints: snapshot.inheritedTerminalFontPoints
            )
            // Resolve placement against the pre-creation snapshot before Workspace init
            // boots terminal state. The ssh/new-workspace path can otherwise crash while
            // reading @Published placement state from existing workspaces mid-creation.
            let insertIndex = newTabInsertIndex(snapshot: snapshot, placementOverride: placementOverride)
            let ordinal = Self.nextPortOrdinal
            Self.nextPortOrdinal += 1
            let newWorkspace = makeWorkspaceForCreation(
                title: title ?? "Terminal \(nextTabCount)",
                workingDirectory: workingDirectory,
                portOrdinal: ordinal,
                configTemplate: inheritedConfig,
                initialTerminalCommand: initialTerminalCommand,
                initialTerminalInput: initialTerminalInput,
                initialTerminalEnvironment: initialTerminalEnvironment
            )
            applyCreationChromeInheritance(
                to: newWorkspace,
                from: sourceWorkspace ?? capturedTabs.first
            )
            newWorkspace.owningTabManager = self
            if title != nil {
                newWorkspace.setCustomTitle(title)
            }
            wireClosedBrowserTracking(for: newWorkspace)
            if eagerLoadTerminal && !select {
                requestBackgroundWorkspaceLoad(for: newWorkspace.id)
            }
            // Apply insertion to the current live array so post-snapshot closes/reorders
            // are preserved instead of reintroducing stale workspace instances.
            var updatedTabs = tabs
            if insertIndex >= 0 && insertIndex <= updatedTabs.count {
                updatedTabs.insert(newWorkspace, at: insertIndex)
            } else {
                updatedTabs.append(newWorkspace)
            }
            tabs = updatedTabs
            // The global insertion-index rules don't know about group sections.
            // Re-run the group-aware normalize so a freshly-added workspace
            // can't land inside another group's contiguous section.
            if normalizeWorkspaceGroupsAfterInsert, !workspaceGroups.isEmpty {
                normalizeWorkspaceGroupContiguity()
            }
            if autoRefreshMetadata, let terminalPanel = newWorkspace.focusedTerminalPanel {
                scheduleInitialWorkspaceGitMetadataRefreshIfPossible(
                    workspaceId: newWorkspace.id,
                    panelId: terminalPanel.id
                )
            }
            if eagerLoadTerminal {
                if select {
                    newWorkspace.focusedTerminalPanel?.surface.requestBackgroundSurfaceStartIfNeeded()
                }
            }
            publishCmuxWorkspaceCreated(newWorkspace, selected: select)
            publishCmuxInitialSurfaceCreated(newWorkspace, selected: select)
            if select {
#if DEBUG
                debugPrimeWorkspaceSwitchTrigger("create", to: newWorkspace.id)
#endif
                selectedTabId = newWorkspace.id
                NotificationCenter.default.post(
                    name: .ghosttyDidFocusTab,
                    object: nil,
                    userInfo: [GhosttyNotificationKey.tabId: newWorkspace.id]
                )
            }
#if DEBUG
            UITestRecorder.incrementInt("addTabInvocations")
            UITestRecorder.record([
                "tabCount": String(updatedTabs.count),
                "selectedTabId": select ? newWorkspace.id.uuidString : (snapshot.selectedTabId?.uuidString ?? "")
            ])
#endif
            if autoWelcomeIfNeeded && select && !UserDefaults.standard.bool(forKey: WelcomeSettings.shownKey) {
                if let appDelegate = AppDelegate.shared {
                    appDelegate.sendWelcomeCommandWhenReady(to: newWorkspace, markShownOnSend: true)
                } else {
                    sendWelcomeWhenReady(to: newWorkspace)
                }
            }
            return newWorkspace
        }
    }

    @MainActor
    private func sendWelcomeWhenReady(to workspace: Workspace) {
        if let terminalPanel = workspace.focusedTerminalPanel,
           terminalPanel.surface.surface != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                UserDefaults.standard.set(true, forKey: WelcomeSettings.shownKey)
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
                UserDefaults.standard.set(true, forKey: WelcomeSettings.shownKey)
                terminalPanel.sendText("cmux welcome\n")
            }
        }

        panelsCancellable = workspace.$panels
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
        pendingBackgroundWorkspaceLoadIds = updated
    }

    func completeBackgroundWorkspaceLoad(for workspaceId: UUID) {
        guard pendingBackgroundWorkspaceLoadIds.contains(workspaceId) else { return }
        var updated = pendingBackgroundWorkspaceLoadIds
        updated.remove(workspaceId)
        pendingBackgroundWorkspaceLoadIds = updated
        releaseBackgroundWorkspaceMount(for: workspaceId)
    }

    func retainBackgroundWorkspaceMount(for workspaceId: UUID) {
        guard !mountedBackgroundWorkspaceLoadIds.contains(workspaceId) else { return }
        var updated = mountedBackgroundWorkspaceLoadIds
        updated.insert(workspaceId)
        mountedBackgroundWorkspaceLoadIds = updated
    }

    func releaseBackgroundWorkspaceMount(for workspaceId: UUID) {
        guard mountedBackgroundWorkspaceLoadIds.contains(workspaceId) else { return }
        var updated = mountedBackgroundWorkspaceLoadIds
        updated.remove(workspaceId)
        mountedBackgroundWorkspaceLoadIds = updated
    }

    func retainDebugWorkspaceLoads(for workspaceIds: Set<UUID>) {
        guard !workspaceIds.isEmpty else { return }
        var updated = debugPinnedWorkspaceLoadIds
        updated.formUnion(workspaceIds)
        guard updated != debugPinnedWorkspaceLoadIds else { return }
        debugPinnedWorkspaceLoadIds = updated
    }

    func releaseDebugWorkspaceLoads(for workspaceIds: Set<UUID>) {
        guard !workspaceIds.isEmpty else { return }
        var updated = debugPinnedWorkspaceLoadIds
        updated.subtract(workspaceIds)
        guard updated != debugPinnedWorkspaceLoadIds else { return }
        debugPinnedWorkspaceLoadIds = updated
    }

    func pruneBackgroundWorkspaceLoads(existingIds: Set<UUID>) {
        let pruned = pendingBackgroundWorkspaceLoadIds.intersection(existingIds)
        if pruned != pendingBackgroundWorkspaceLoadIds {
            pendingBackgroundWorkspaceLoadIds = pruned
        }
        let mounted = mountedBackgroundWorkspaceLoadIds.intersection(existingIds)
        if mounted != mountedBackgroundWorkspaceLoadIds {
            mountedBackgroundWorkspaceLoadIds = mounted
        }
        let retained = debugPinnedWorkspaceLoadIds.intersection(existingIds)
        if retained != debugPinnedWorkspaceLoadIds {
            debugPinnedWorkspaceLoadIds = retained
        }
    }

    // Keep addTab as convenience alias
    @discardableResult
    func addTab(select: Bool = true, eagerLoadTerminal: Bool = false) -> Workspace {
        addWorkspace(select: select, eagerLoadTerminal: eagerLoadTerminal)
    }

    func terminalPanelForWorkspaceConfigInheritanceSource() -> TerminalPanel? {
        terminalPanelForWorkspaceConfigInheritanceSource(workspace: selectedWorkspace)
    }

    /// Build a snapshot using pre-extracted value-type data. The caller is responsible
    /// for obtaining `preferredWorkingDirectory` and `inheritedTerminalFontPoints` through
    /// `self` (where `self.tabs` keeps all Workspace objects alive) so that no local
    /// Workspace references are needed here.
    func workspaceCreationSnapshotLite(
        currentTabs: [Workspace],
        currentSelectedTabId: UUID?,
        preferredWorkingDirectory: String?,
        inheritedTerminalFontPoints: Float?
    ) -> WorkspaceCreationSnapshot {
        var tabSnapshots: [WorkspaceCreationTabSnapshot] = []
        tabSnapshots.reserveCapacity(currentTabs.count)
        for workspace in currentTabs {
            // Keep each Workspace alive while copying the tiny value snapshot out of it.
            // The optimized arm64 Nightly build can otherwise over-release during
            // Collection.map, crashing here in swift_release / snapshot creation.
            let snapshot = withExtendedLifetime(workspace) {
                WorkspaceCreationTabSnapshot(workspace: workspace)
            }
            tabSnapshots.append(snapshot)
        }
        let selectedTabSnapshot = currentSelectedTabId.flatMap { selectedTabId in
            tabSnapshots.first(where: { $0.id == selectedTabId })
        }

        return WorkspaceCreationSnapshot(
            tabs: tabSnapshots,
            selectedTabId: currentSelectedTabId,
            selectedTabWasPinned: selectedTabSnapshot?.isPinned ?? false,
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

    private func orderedLiveWorkspaceCreationTabs(
        from snapshot: WorkspaceCreationSnapshot
    ) -> [WorkspaceCreationTabSnapshot]? {
        let currentTabs = tabs
        let snapshotTabsById = Dictionary(uniqueKeysWithValues: snapshot.tabs.map { ($0.id, $0) })
        var orderedTabs: [WorkspaceCreationTabSnapshot] = []
        orderedTabs.reserveCapacity(currentTabs.count)

        for workspace in currentTabs {
            guard let tabSnapshot = snapshotTabsById[workspace.id] else {
#if DEBUG
                cmuxDebugLog(
                    "workspace.create.reentrantSnapshotFallback " +
                    "snapshotCount=\(snapshot.tabs.count) liveCount=\(currentTabs.count)"
                )
#endif
                return nil
            }
            orderedTabs.append(tabSnapshot)
        }

        return orderedTabs
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

    func workspaceCreationConfigTemplate(
        inheritedTerminalFontPoints: Float?
    ) -> CmuxSurfaceConfigTemplate? {
        guard let inheritedTerminalFontPoints, inheritedTerminalFontPoints > 0 else {
            return nil
        }
        // Rebuild a clean Swift-owned template instead of carrying over any pointer-backed
        // inherited config state from the source workspace.
        var config = CmuxSurfaceConfigTemplate()
        config.fontSize = inheritedTerminalFontPoints
        return config
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

    func newTabInsertIndex(
        snapshot: WorkspaceCreationSnapshot,
        placementOverride: WorkspacePlacement? = nil
    ) -> Int {
        let placement = WorkspacePlacement.effectivePlacement(
            placementOverride: placementOverride,
            settings: settings,
            catalog: settingsCatalog
        )
        let liveTabs = orderedLiveWorkspaceCreationTabs(from: snapshot) ?? snapshot.tabs
        let pinnedCount = liveTabs.reduce(into: 0) { partial, tab in
            if tab.isPinned {
                partial += 1
            }
        }

        switch placement {
        case .top:
            return pinnedCount
        case .end:
            return liveTabs.count
        case .afterCurrent:
            if let selectedTabId = snapshot.selectedTabId,
               let selectedIndex = liveTabs.firstIndex(where: { $0.id == selectedTabId }) {
                return placement.insertionIndex(
                    selectedIndex: selectedIndex,
                    selectedIsPinned: snapshot.selectedTabWasPinned,
                    pinnedCount: pinnedCount,
                    totalCount: liveTabs.count
                )
            }
            return snapshot.selectedTabWasPinned ? pinnedCount : liveTabs.count
        }
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

    func moveTabToTop(_ tabId: UUID) {
        moveTabsToTop([tabId])
    }

    func moveTabsToTop(_ tabIds: Set<UUID>) {
        guard !tabIds.isEmpty else { return }
        let selectedTabs = tabs.filter { tabIds.contains($0.id) }
        guard !selectedTabs.isEmpty else { return }
        let previousOrder = tabs.map(\.id)

        if !workspaceGroups.isEmpty {
            moveWorkspaceGroupMembersAfterAnchors(workspaceIds: selectedTabs.map(\.id))
            let topLevelIds = sidebarTopLevelWorkspaceIds()
            let selectedTopLevelIds = topLevelWorkspaceIds(for: selectedTabs)
            let selectedTopLevelIdSet = Set(selectedTopLevelIds)
            let pinnedTopLevelIds = sidebarTopLevelPinnedWorkspaceIds()
            let desiredTopLevelIds =
                selectedTopLevelIds.filter { pinnedTopLevelIds.contains($0) } +
                topLevelIds.filter { pinnedTopLevelIds.contains($0) && !selectedTopLevelIdSet.contains($0) } +
                selectedTopLevelIds.filter { !pinnedTopLevelIds.contains($0) } +
                topLevelIds.filter { !pinnedTopLevelIds.contains($0) && !selectedTopLevelIdSet.contains($0) }
            normalizeWorkspaceGroupRunsPreservingOrder(desiredTopLevelIds)
            syncWorkspaceGroupsOrderToAnchorOrder()
        } else {
            let remainingTabs = tabs.filter { !tabIds.contains($0.id) }
            let selectedPinned = selectedTabs.filter { $0.isPinned }
            let selectedUnpinned = selectedTabs.filter { !$0.isPinned }
            let remainingPinned = remainingTabs.filter { $0.isPinned }
            let remainingUnpinned = remainingTabs.filter { !$0.isPinned }
            tabs = selectedPinned + remainingPinned + selectedUnpinned + remainingUnpinned
        }
        if tabs.map(\.id) != previousOrder {
            postWorkspaceOrderDidChange(movedWorkspaceIds: selectedTabs.map(\.id))
        }
    }

    func moveTabToTopForNotification(_ tabId: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return }
        let previousOrder = tabs.map(\.id)

        if !workspaceGroups.isEmpty {
            guard let topLevelId = topLevelWorkspaceIds(for: [tab]).first else { return }
            let pinnedTopLevelIds = sidebarTopLevelPinnedWorkspaceIds()
            guard !pinnedTopLevelIds.contains(topLevelId) else { return }
            moveWorkspaceGroupMembersAfterAnchors(workspaceIds: [tabId])
            var desiredTopLevelIds = sidebarTopLevelWorkspaceIds()
            guard let fromIndex = desiredTopLevelIds.firstIndex(of: topLevelId) else { return }
            let pinnedCount = desiredTopLevelIds.reduce(into: 0) { count, id in
                if pinnedTopLevelIds.contains(id) {
                    count += 1
                }
            }
            if fromIndex != pinnedCount {
                let movedId = desiredTopLevelIds.remove(at: fromIndex)
                desiredTopLevelIds.insert(movedId, at: min(pinnedCount, desiredTopLevelIds.count))
            }
            normalizeWorkspaceGroupRunsPreservingOrder(desiredTopLevelIds)
            syncWorkspaceGroupsOrderToAnchorOrder()
        } else {
            guard let index = tabs.firstIndex(where: { $0.id == tabId }) else { return }
            let pinnedCount = tabs.filter { $0.isPinned }.count
            guard index != pinnedCount else { return }
            let tab = tabs[index]
            guard !tab.isPinned else { return }
            tabs.remove(at: index)
            tabs.insert(tab, at: pinnedCount)
        }
        if tabs.map(\.id) != previousOrder {
            postWorkspaceOrderDidChange(movedWorkspaceIds: [tabId])
        }
    }

    @discardableResult
    func reorderWorkspace(tabId: UUID, toIndex targetIndex: Int, isDragOperation: Bool = false) -> Bool {
        guard let plan = workspaceReorderPlan(tabId: tabId, toIndex: targetIndex) else { return false }
        // No-op reorders (single workspace, clamped to current index, etc.)
        // must not run group inference. Otherwise socket calls like
        // `workspace.action move_down` on the last ungrouped row would
        // silently absorb it into the group above just because the request
        // resolved to "stay put."
        if tabs.count <= 1 || plan.fromIndex == plan.toIndex {
            return true
        }

        let workspace = tabs.remove(at: plan.fromIndex)
        tabs.insert(workspace, at: plan.toIndex)
        if isDragOperation {
            applyDragInferredGroupMembership(workspaceId: tabId)
        } else if !workspaceGroups.isEmpty {
            if workspaceGroups.contains(where: { $0.anchorWorkspaceId == tabId }) {
                syncWorkspaceGroupsOrderToAnchorOrder()
            }
            normalizeWorkspaceGroupContiguity()
        }
        postWorkspaceOrderDidChange(movedWorkspaceIds: [tabId])
        return true
    }

    func sidebarReorderWorkspaceIds(
        forDraggedWorkspaceId draggedWorkspaceId: UUID?,
        targetWorkspaceId: UUID? = nil,
        usesTopLevelRows: Bool = false
    ) -> [UUID] {
        guard usesTopLevelRows || sidebarReorderUsesTopLevelRows(
            forDraggedWorkspaceId: draggedWorkspaceId,
            targetWorkspaceId: targetWorkspaceId
        ) else {
            return tabs.map(\.id)
        }
        return sidebarTopLevelWorkspaceIds(promotingWorkspaceId: draggedWorkspaceId)
    }

    func sidebarReorderPinnedWorkspaceIds(
        forDraggedWorkspaceId draggedWorkspaceId: UUID?,
        targetWorkspaceId: UUID? = nil,
        usesTopLevelRows: Bool = false
    ) -> Set<UUID> {
        guard usesTopLevelRows || sidebarReorderUsesTopLevelRows(
            forDraggedWorkspaceId: draggedWorkspaceId,
            targetWorkspaceId: targetWorkspaceId
        ) else {
            return Set(tabs.filter { $0.groupId == nil && $0.isPinned }.map(\.id))
        }
        return sidebarTopLevelPinnedWorkspaceIds()
    }

    func sidebarReorderLegalInsertionRange(
        forDraggedWorkspaceId draggedWorkspaceId: UUID?,
        targetWorkspaceId: UUID? = nil,
        usesTopLevelRows: Bool = false
    ) -> ClosedRange<Int>? {
        guard !usesTopLevelRows,
              !sidebarReorderUsesTopLevelRows(
                  forDraggedWorkspaceId: draggedWorkspaceId,
                  targetWorkspaceId: targetWorkspaceId
              ),
              let draggedWorkspaceId,
              let draggedWorkspace = tabs.first(where: { $0.id == draggedWorkspaceId }),
              let groupId = draggedWorkspace.groupId,
              let group = workspaceGroups.first(where: { $0.id == groupId }),
              draggedWorkspace.id != group.anchorWorkspaceId else {
            return nil
        }
        let memberIndices = tabs.indices.filter { tabs[$0].groupId == groupId }
        guard let firstIndex = memberIndices.first,
              let lastIndex = memberIndices.last else {
            return nil
        }
        let pinnedMemberCount = memberIndices.reduce(into: 0) { count, index in
            let member = tabs[index]
            if member.id != group.anchorWorkspaceId, member.isPinned {
                count += 1
            }
        }
        if draggedWorkspace.isPinned {
            let lower = min(firstIndex + 1, tabs.count)
            let upper = min(firstIndex + 1 + pinnedMemberCount, tabs.count)
            return lower...max(lower, upper)
        }
        let lower = min(firstIndex + 1 + pinnedMemberCount, tabs.count)
        let upper = min(lastIndex + 1, tabs.count)
        return min(lower, upper)...max(lower, upper)
    }

    @discardableResult
    func reorderSidebarWorkspace(
        tabId: UUID,
        toIndex targetIndex: Int,
        isDragOperation: Bool = false,
        usesTopLevelRows: Bool = false
    ) -> Bool {
        if usesTopLevelRows || isWorkspaceGroupAnchor(tabId) {
            return reorderTopLevelWorkspaceItem(
                tabId: tabId,
                toIndex: targetIndex,
                promotesGroupedWorkspace: usesTopLevelRows
            )
        }
        return reorderWorkspace(tabId: tabId, toIndex: targetIndex, isDragOperation: isDragOperation)
    }

    @discardableResult
    private func reorderTopLevelWorkspaceItem(
        tabId: UUID,
        toIndex targetIndex: Int,
        promotesGroupedWorkspace: Bool = false
    ) -> Bool {
        let topLevelIds = sidebarTopLevelWorkspaceIds(
            promotingWorkspaceId: promotesGroupedWorkspace ? tabId : nil
        )
        guard let fromIndex = topLevelIds.firstIndex(of: tabId) else { return false }
        let clampedTarget = clampedTopLevelReorderIndex(
            forWorkspaceId: tabId,
            targetIndex: targetIndex,
            topLevelIds: topLevelIds
        )
        guard fromIndex != clampedTarget else { return false }

        var desiredTopLevelIds = topLevelIds
        let movedId = desiredTopLevelIds.remove(at: fromIndex)
        desiredTopLevelIds.insert(movedId, at: clampedTarget)
        if promotesGroupedWorkspace,
           let tab = tabs.first(where: { $0.id == tabId }),
           tab.groupId != nil,
           !isWorkspaceGroupAnchor(tabId) {
            assignGroup(workspaceId: tabId, groupId: nil)
        }
        normalizeWorkspaceGroupRunsPreservingOrder(desiredTopLevelIds)
        syncWorkspaceGroupsOrderToAnchorOrder()

        let movedWorkspaceIds: [UUID]
        if let group = workspaceGroups.first(where: { $0.anchorWorkspaceId == tabId }) {
            movedWorkspaceIds = tabs.filter { $0.groupId == group.id }.map(\.id)
        } else {
            movedWorkspaceIds = [tabId]
        }
        postWorkspaceOrderDidChange(movedWorkspaceIds: movedWorkspaceIds)
        return true
    }

    func sidebarReorderUsesTopLevelRows(
        forDraggedWorkspaceId draggedWorkspaceId: UUID?,
        targetWorkspaceId: UUID?
    ) -> Bool {
        sidebarReorderUsesTopLevelRows(
            forDraggedWorkspaceId: draggedWorkspaceId,
            targetWorkspaceId: targetWorkspaceId,
            workspaceGroupIdByWorkspaceId: Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0.groupId) })
        )
    }

    func sidebarReorderUsesTopLevelRows(
        forDraggedWorkspaceId draggedWorkspaceId: UUID?,
        targetWorkspaceId: UUID?,
        workspaceGroupIdByWorkspaceId: [UUID: UUID?]
    ) -> Bool {
        guard let draggedWorkspaceId else { return false }
        if isWorkspaceGroupAnchor(draggedWorkspaceId) ||
            targetWorkspaceId.map(isWorkspaceGroupAnchor) == true {
            return true
        }
        guard let draggedWorkspaceGroupId = workspaceGroupIdByWorkspaceId[draggedWorkspaceId],
              draggedWorkspaceGroupId != nil else {
            return false
        }
        // A grouped child dragged over top-level space is leaving the group;
        // plan in top-level rows so the promotion is explicit and ordered.
        guard let targetWorkspaceId else { return true }
        guard let targetWorkspaceGroupId = workspaceGroupIdByWorkspaceId[targetWorkspaceId] else {
            return false
        }
        return targetWorkspaceGroupId == nil
    }

    /// After a drag-driven reorder, infer the dragged workspace's group
    /// membership from its new neighbors in `tabs[]`:
    /// - If both neighbors share a non-nil groupId, join that group.
    /// - If only one neighbor is in a group, join that neighbor's group when
    ///   that group's anchor is the neighbor or another existing member
    ///   (i.e. the dragged workspace sits "inside" the section).
    /// - Otherwise, clear groupId.
    /// Pinned workspaces may join a group when the same neighbor-based rules
    /// place them inside that group's section.
    /// Anchors keep their group: their lifecycle is gated by group existence.
    private func applyDragInferredGroupMembership(workspaceId: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == workspaceId }) else { return }
        let tab = tabs[index]
        let isAnchor = workspaceGroups.contains(where: { $0.anchorWorkspaceId == workspaceId })
        if isAnchor {
            // Anchors don't change group membership via drag (their group
            // identity owns them), but moving an anchor in `tabs[]` IS how
            // the user reorders the whole group. Resync `workspaceGroups`
            // order to the new anchor positions in tabs[] before normalize
            // rebuilds the section list.
            syncWorkspaceGroupsOrderToAnchorOrder()
            normalizeWorkspaceGroupContiguity()
            return
        }
        let before: Workspace? = index > 0 ? tabs[index - 1] : nil
        let after: Workspace? = (index + 1) < tabs.count ? tabs[index + 1] : nil
        let beforeGroup = before?.groupId
        let afterGroup = after?.groupId
        let currentGroup = tab.groupId
        // Three cases:
        //  A. Both neighbors share the same value (incl. both nil): land in
        //     that membership state. Sandwiched inside a group → join it.
        //     Sandwiched in the ungrouped section → clear membership.
        //  B. Otherwise (one neighbor differs from the other) — preserve
        //     current membership. This is the ambiguous edge case: dragging
        //     to the LAST slot of currentGroup and the FIRST slot just
        //     beyond currentGroup look identical via neighbor inspection,
        //     so we bias toward "user is reordering within their group"
        //     since `normalizeWorkspaceGroupContiguity()` will keep the
        //     row in the group's contiguous section anyway. To drag a
        //     workspace out of its group, the user must drop it with BOTH
        //     neighbors outside the group (case A with
        //     `beforeGroup == afterGroup != currentGroup`) or use the
        //     right-click → Remove From Group action.
        let inferred: UUID?
        if beforeGroup == afterGroup {
            inferred = beforeGroup
        } else {
            inferred = currentGroup
        }
        if tab.groupId != inferred {
            tab.groupId = inferred
            // Renormalize after group change to keep tiers contiguous.
            normalizeWorkspaceGroupContiguity()
        } else if inferred != nil {
            // Same-group drag: membership unchanged, but the drop may have
            // placed a non-anchor before the anchor in tabs[]. Renormalize
            // so the anchor stays at the section's leading edge (matches
            // the visible header position).
            normalizeWorkspaceGroupContiguity()
        }
    }

    func workspaceReorderPlan(tabId: UUID, toIndex targetIndex: Int) -> WorkspaceReorderPlanItem? {
        guard let currentIndex = tabs.firstIndex(where: { $0.id == tabId }) else { return nil }
        if tabs.count <= 1 {
            return WorkspaceReorderPlanItem(workspaceId: tabId, fromIndex: currentIndex, toIndex: currentIndex)
        }

        let workspace = tabs[currentIndex]
        let clamped = clampedReorderIndex(for: workspace, targetIndex: targetIndex)
        return WorkspaceReorderPlanItem(workspaceId: tabId, fromIndex: currentIndex, toIndex: clamped)
    }

    private func postWorkspaceOrderDidChange(movedWorkspaceIds: [UUID]) {
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
        guard let plan = workspaceReorderPlan(tabId: tabId, before: beforeId, after: afterId) else { return false }
        return reorderWorkspace(tabId: tabId, toIndex: plan.toIndex, isDragOperation: isDragOperation)
    }

    func workspaceReorderPlan(tabId: UUID, before beforeId: UUID? = nil, after afterId: UUID? = nil) -> WorkspaceReorderPlanItem? {
        guard tabs.contains(where: { $0.id == tabId }) else { return nil }
        if let beforeId {
            guard let idx = tabs.firstIndex(where: { $0.id == beforeId }) else { return nil }
            return workspaceReorderPlan(tabId: tabId, toIndex: idx)
        }
        if let afterId {
            guard let idx = tabs.firstIndex(where: { $0.id == afterId }) else { return nil }
            return workspaceReorderPlan(tabId: tabId, toIndex: idx + 1)
        }
        return nil
    }

    func workspaceBatchReorderPlan(
        orderedWorkspaceIds: [UUID]
    ) -> Result<[WorkspaceReorderPlanItem], WorkspaceBatchReorderError> {
        workspaceReorder.batchReorderPlan(
            orderedWorkspaceIds: orderedWorkspaceIds,
            current: workspaceOrderSnapshots()
        )
    }

    @discardableResult
    func reorderWorkspaces(
        orderedWorkspaceIds: [UUID],
        dryRun: Bool = false
    ) -> Result<[WorkspaceReorderPlanItem], WorkspaceBatchReorderError> {
        let result = workspaceBatchReorderPlan(orderedWorkspaceIds: orderedWorkspaceIds)
        guard case .success(let plan) = result else { return result }
        guard !dryRun else { return result }

        let movedWorkspaceIds = plan
            .filter { $0.fromIndex != $0.toIndex }
            .map(\.workspaceId)
        guard !movedWorkspaceIds.isEmpty else { return result }

        let workspacesById = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        let finalIds = batchWorkspaceReorderFinalIds(orderedWorkspaceIds: orderedWorkspaceIds)
        tabs = finalIds.compactMap { workspacesById[$0] }
        // Batch reorder rebuilds tabs from scratch, ignoring group section
        // ordering — that can split a group across the array or land a
        // non-anchor in front of its anchor. Renormalize so the contiguous
        // section + anchor-first invariants hold for socket
        // workspace.reorder_many / `cmux reorder-workspaces`.
        if !workspaceGroups.isEmpty {
            // Resync workspaceGroups order to wherever the anchors landed
            // in the rebuilt tabs[] so later group-slot moves use the same
            // order the user sees.
            syncWorkspaceGroupsOrderToAnchorOrder()
            normalizeWorkspaceGroupContiguity()
        }
        postWorkspaceOrderDidChange(movedWorkspaceIds: movedWorkspaceIds)
        return result
    }

    private func batchWorkspaceReorderFinalIds(orderedWorkspaceIds: [UUID]) -> [UUID] {
        workspaceReorder.batchReorderFinalIds(
            orderedWorkspaceIds: orderedWorkspaceIds,
            current: workspaceOrderSnapshots()
        )
    }

    private func workspaceOrderSnapshots() -> [WorkspaceOrderSnapshot] {
        tabs.map { WorkspaceOrderSnapshot(id: $0.id, isPinned: $0.isPinned) }
    }

    func setCustomTitle(tabId: UUID, title: String?) {
        guard let index = tabs.firstIndex(where: { $0.id == tabId }) else { return }
        tabs[index].setCustomTitle(title)
        if selectedTabId == tabId {
            updateWindowTitle(for: tabs[index])
        }
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
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return }
        tab.setCustomColor(color)
    }

    func applyWorkspaceColor(_ color: String?, toWorkspaceIds workspaceIds: [UUID]) {
        guard !workspaceIds.isEmpty else { return }
        if workspaceIds.count == 1, let workspaceId = workspaceIds.first {
            setTabColor(tabId: workspaceId, color: color)
            return
        }

        let targetIds = Set(workspaceIds)
        for tab in tabs where targetIds.contains(tab.id) {
            tab.setCustomColor(color)
        }
    }

    func applyWorkspacePaletteColor(named name: String, toWorkspaceIds workspaceIds: [UUID]) {
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
        guard let index = tabs.firstIndex(where: { $0.id == tabId }) else { return }
        let tab = tabs[index]
        setPinned(tab, pinned: !tab.isPinned)
    }

    func setPinned(_ tab: Workspace, pinned: Bool) {
        guard tab.isPinned != pinned else { return }
        tab.isPinned = pinned
        reorderTabForPinnedState(tab)
        postWorkspaceOrderDidChange(movedWorkspaceIds: [tab.id])
    }

    @discardableResult
    func setPinned(workspaceIds: [UUID], pinned: Bool) -> [UUID] {
        guard !workspaceIds.isEmpty else { return [] }
        if workspaceIds.count == 1,
           let workspaceId = workspaceIds.first,
           let tab = tabs.first(where: { $0.id == workspaceId }) {
            let changed = tab.isPinned != pinned
            setPinned(tab, pinned: pinned)
            return changed ? [workspaceId] : []
        }

        var seen = Set<UUID>()
        let orderedTargetIds = workspaceIds.filter { seen.insert($0).inserted }
        let targetIds = Set(orderedTargetIds)
        var workspacesById: [UUID: Workspace] = [:]
        var changedIdSet = Set<UUID>()

        for workspace in tabs {
            workspacesById[workspace.id] = workspace
            guard targetIds.contains(workspace.id), workspace.isPinned != pinned else { continue }
            workspace.isPinned = pinned
            changedIdSet.insert(workspace.id)
        }

        guard !changedIdSet.isEmpty else { return [] }
        let changedIds = orderedTargetIds.filter { changedIdSet.contains($0) }

        if !workspaceGroups.isEmpty {
            for id in changedIds {
                if let workspace = workspacesById[id] {
                    reorderTabForPinnedState(workspace)
                }
            }
            postWorkspaceOrderDidChange(movedWorkspaceIds: changedIds)
            return changedIds
        }

        let changedWorkspaces: [Workspace]
        if pinned {
            changedWorkspaces = changedIds.compactMap { workspacesById[$0] }
        } else {
            // Keep parity with reorderTabForPinnedState: each unpinned item
            // is inserted at the front of the unpinned segment, so rebuilding a
            // batch in one pass must reverse the changed input order.
            changedWorkspaces = changedIds.reversed().compactMap { workspacesById[$0] }
        }
        let remainingPinned = tabs.filter { $0.isPinned && !changedIdSet.contains($0.id) }
        let remainingUnpinned = tabs.filter { !$0.isPinned && !changedIdSet.contains($0.id) }
        tabs = remainingPinned + changedWorkspaces + remainingUnpinned
        postWorkspaceOrderDidChange(movedWorkspaceIds: changedIds)
        return changedIds
    }

    private func reorderTabForPinnedState(_ tab: Workspace) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        if tab.groupId != nil {
            normalizeWorkspaceGroupContiguity()
            return
        }
        tabs.remove(at: index)
        let pinnedCount = leadingGlobalPinnedRowCount()
        let insertIndex = min(pinnedCount, tabs.count)
        tabs.insert(tab, at: insertIndex)
    }

    // MARK: - Workspace Groups

    /// Create a new group, inserting a fresh anchor workspace above the given
    /// child workspaces. Returns the new group id.
    ///
    /// The anchor is always brand new (never promoted from an existing
    /// workspace). Its cwd defaults to `anchorWorkingDirectory`, or the first
    /// eligible child's cwd, or whatever `addWorkspace` resolves on its own.
    @discardableResult
    func createWorkspaceGroup(
        name: String,
        childWorkspaceIds: [UUID] = [],
        anchorWorkingDirectory: String? = nil,
        selectAnchor: Bool = true,
        collapseSidebarSelection: Bool = true
    ) -> UUID? {
        // Eligible children: not currently an anchor of a different group.
        // Pulling an anchor into a new group would orphan the
        // source group (its anchorWorkspaceId would no longer match), so we
        // reject those silently and let the user explicitly ungroup first.
        let existingAnchorIds = Set(workspaceGroups.map(\.anchorWorkspaceId))
        let eligibleChildren = childWorkspaceIds.compactMap { id -> UUID? in
            guard tabs.contains(where: { $0.id == id }),
                  !existingAnchorIds.contains(id) else { return nil }
            return id
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = trimmedName.isEmpty
            ? nextAutoWorkspaceGroupName()
            : trimmedName

        let firstChildTab = eligibleChildren.first.flatMap { firstId in
            tabs.first(where: { $0.id == firstId })
        }
        let inferredCwd: String? = anchorWorkingDirectory
            ?? firstChildTab?.currentDirectory
        let originalTabOrder = tabs.map(\.id)

        let anchor = addWorkspace(
            title: resolvedName,
            workingDirectory: inferredCwd,
            inheritWorkingDirectory: inferredCwd == nil,
            select: selectAnchor,
            placementOverride: .top,
            autoWelcomeIfNeeded: false,
            normalizeWorkspaceGroupsAfterInsert: false
        )

        let group = WorkspaceGroup(
            id: UUID(),
            name: resolvedName,
            isCollapsed: false,
            isPinned: false,
            anchorWorkspaceId: anchor.id,
            customColor: nil,
            iconSymbol: nil
        )
        workspaceGroups.append(group)
        anchor.groupId = group.id
        for id in eligibleChildren {
            assignGroup(workspaceId: id, groupId: group.id)
        }
        placeNewWorkspaceGroupAtCreationPosition(
            groupId: group.id,
            anchorId: anchor.id,
            childWorkspaceIds: eligibleChildren,
            originalTabOrder: originalTabOrder
        )
        // Collapse the sidebar multi-selection so a second ⌘⇧G press doesn't
        // immediately reuse the same child ids and create a duplicate group
        // around them. The new anchor is the only sensible "current"
        // selection at this point. Posts the hide notification so the
        // SwiftUI sidebar binding follows.
        //
        // Skipped for the non-focus socket/CLI path (caller passes
        // collapseSidebarSelection: false): per the socket focus policy in
        // CLAUDE.md, those entrypoints must not mutate the user's active
        // sidebar selection.
        if collapseSidebarSelection,
           !sidebarSelectedWorkspaceIds.isDisjoint(with: Set(eligibleChildren)) || sidebarSelectedWorkspaceIds.count > 1 {
            let hiddenIds = sidebarSelectedWorkspaceIds
            sidebarMultiSelection.replaceSelection(with: [anchor.id])
            sidebarMultiSelection.postDidHide(hiddenWorkspaceIds: hiddenIds, focusedWorkspaceId: anchor.id)
        }
        postWorkspaceOrderDidChange(movedWorkspaceIds: [anchor.id] + eligibleChildren)
        return group.id
    }

    /// Create a brand-new workspace inheriting the anchor's cwd, attach it
    /// to the group, and position it within the group's tabs[] range per
    /// `placement`. Returns the new workspace.
    @discardableResult
    func createWorkspaceInGroup(
        groupId: UUID,
        placement explicitPlacement: WorkspaceGroupNewPlacement? = nil,
        referenceWorkspaceId: UUID? = nil,
        select: Bool = true
    ) -> Workspace? {
        // nil resolves to the stored global default at call time, matching
        // the legacy default-argument read of the
        // workspaceGroups.newWorkspacePlacement setting.
        let placement = explicitPlacement
            ?? settings.value(for: settingsCatalog.workspaceGroups.newWorkspacePlacement)
        guard let group = workspaceGroups.first(where: { $0.id == groupId }) else { return nil }
        let cwd = tabs.first(where: { $0.id == group.anchorWorkspaceId })?.currentDirectory
        let newWorkspace = addWorkspace(
            workingDirectory: cwd,
            inheritWorkingDirectory: cwd == nil,
            select: select,
            autoWelcomeIfNeeded: false
        )
        assignGroup(workspaceId: newWorkspace.id, groupId: groupId)
        placeWithinGroup(
            workspaceId: newWorkspace.id,
            groupId: groupId,
            placement: placement,
            referenceWorkspaceId: referenceWorkspaceId
        )
        // Expand the group when the new workspace is being focused. The
        // selectedTabId auto-expand hook fires inside `addWorkspace` BEFORE
        // assignGroup, so it can't see the new workspace's membership. Without
        // this, clicking `+` on a collapsed group selects a workspace that's
        // visually hidden in the sidebar.
        if select,
           let idx = workspaceGroups.firstIndex(where: { $0.id == groupId }),
           workspaceGroups[idx].isCollapsed {
            workspaceGroups[idx].isCollapsed = false
        }
        normalizeWorkspaceGroupContiguity()
        postWorkspaceOrderDidChange(movedWorkspaceIds: [newWorkspace.id])
        return newWorkspace
    }

    /// Move an existing group member to the requested in-group slot. Called
    /// after `createWorkspaceInGroup` and any other path that needs to
    /// pin the new member relative to the group's members.
    private func placeWithinGroup(
        workspaceId: UUID,
        groupId: UUID,
        placement: WorkspaceGroupNewPlacement,
        referenceWorkspaceId: UUID? = nil
    ) {
        guard let group = workspaceGroups.first(where: { $0.id == groupId }),
              let currentIndex = tabs.firstIndex(where: { $0.id == workspaceId }) else { return }
        let memberIndices = tabs.indices.filter { tabs[$0].groupId == groupId && tabs[$0].id != workspaceId }
        func logMissingPlacementAnchor(_ placementName: String) {
            tabManagerLogger.info(
                "workspaceGroup.placeWithinGroup missing placement anchor group=\(groupId.uuidString, privacy: .public) workspace=\(workspaceId.uuidString, privacy: .public) placement=\(placementName, privacy: .public)"
            )
        }
        let targetIndex: Int
        switch placement {
        case .afterCurrent:
            if let referenceWorkspaceId,
               referenceWorkspaceId != workspaceId,
               let referenceIndex = tabs.firstIndex(where: { $0.id == referenceWorkspaceId && $0.groupId == groupId }) {
                targetIndex = referenceIndex + 1
            } else if let anchorIndex = tabs.firstIndex(where: { $0.id == group.anchorWorkspaceId }) {
                targetIndex = anchorIndex + 1
            } else if let firstMember = memberIndices.first {
                targetIndex = firstMember
            } else {
                logMissingPlacementAnchor("afterCurrent")
                return
            }
        case .top:
            if let anchorIndex = tabs.firstIndex(where: { $0.id == group.anchorWorkspaceId }) {
                // Right after the anchor; the anchor stays first via
                // `normalizeWorkspaceGroupContiguity`'s anchorFirst pass.
                targetIndex = anchorIndex + 1
            } else if let firstMember = memberIndices.first {
                targetIndex = firstMember
            } else {
                logMissingPlacementAnchor("top")
                return
            }
        case .end:
            if let lastMember = memberIndices.last {
                targetIndex = lastMember + 1
            } else {
                // Only the anchor and the new workspace exist; treat as top.
                if let anchorIndex = tabs.firstIndex(where: { $0.id == group.anchorWorkspaceId }) {
                    targetIndex = anchorIndex + 1
                } else {
                    logMissingPlacementAnchor("end")
                    return
                }
            }
        }
        guard currentIndex != targetIndex else { return }
        let workspace = tabs.remove(at: currentIndex)
        let insertAt = currentIndex < targetIndex ? targetIndex - 1 : targetIndex
        tabs.insert(workspace, at: max(0, min(insertAt, tabs.count)))
    }

    /// Add an existing workspace to an existing group as a non-anchor member.
    /// No-op for workspaces that are the anchor of a different group (those
    /// must be ungrouped first to avoid orphaning the
    /// source group). If the workspace is the currently selected one and the
    /// target group is collapsed, the group auto-expands so the focused
    /// workspace stays visible.
    func addWorkspaceToGroup(
        workspaceId: UUID,
        groupId: UUID,
        placement: WorkspaceGroupNewPlacement? = nil,
        referenceWorkspaceId: UUID? = nil
    ) {
        guard let tab = tabs.first(where: { $0.id == workspaceId }) else { return }
        guard workspaceGroups.contains(where: { $0.id == groupId }) else { return }
        guard tab.groupId != groupId else { return }
        let isAnchorOfOtherGroup = workspaceGroups.contains { group in
            group.id != groupId && group.anchorWorkspaceId == workspaceId
        }
        if isAnchorOfOtherGroup { return }
        let originalTopLevelIds = sidebarTopLevelWorkspaceIds()
        assignGroup(workspaceId: workspaceId, groupId: groupId)
        // selectedTabId may not change here (the workspace was already
        // selected), so the existing didSet hook won't fire. Expand manually
        // when the added workspace is the focused one so it doesn't end up
        // hidden inside a collapsed section.
        if selectedTabId == workspaceId,
           let groupIndex = workspaceGroups.firstIndex(where: { $0.id == groupId }),
           workspaceGroups[groupIndex].isCollapsed {
            workspaceGroups[groupIndex].isCollapsed = false
        }
        normalizeWorkspaceGroupContiguity(
            preservingTopLevelIds: originalTopLevelIds.filter { $0 != workspaceId }
        )
        if let placement {
            placeWithinGroup(
                workspaceId: workspaceId,
                groupId: groupId,
                placement: placement,
                referenceWorkspaceId: referenceWorkspaceId
            )
        }
        postWorkspaceOrderDidChange(movedWorkspaceIds: [workspaceId])
    }

    /// Remove a non-anchor workspace from its group. If the workspace is its
    /// group's anchor, the group is dissolved instead (other members survive
    /// as ungrouped workspaces).
    func removeWorkspaceFromGroup(workspaceId: UUID) {
        guard let tab = tabs.first(where: { $0.id == workspaceId }),
              let groupId = tab.groupId else { return }
        if let group = workspaceGroups.first(where: { $0.id == groupId }),
           group.anchorWorkspaceId == workspaceId {
            ungroupWorkspaceGroup(groupId: groupId)
            return
        }
        assignGroup(workspaceId: workspaceId, groupId: nil)
        normalizeWorkspaceGroupContiguity()
        postWorkspaceOrderDidChange(movedWorkspaceIds: [workspaceId])
    }

    /// Dissolve a group while preserving every member workspace (including its
    /// anchor) as a regular ungrouped workspace. Nothing is closed. The
    /// former members KEEP their `tabs[]` positions so the anchor — which
    /// was previously rendered exclusively as the group header — appears as
    /// a workspace row at the same vertical spot the header occupied, with
    /// the rest of the members staying right below it in their existing
    /// relative order. We deliberately do not re-normalize here: that would
    /// push the now-ungrouped members down into the "ungrouped tier at the
    /// bottom" slot, which makes Ungroup feel like a destructive move
    /// instead of a flatten-in-place.
    func ungroupWorkspaceGroup(groupId: UUID) {
        let memberIds = tabs.filter { $0.groupId == groupId }.map(\.id)
        guard !memberIds.isEmpty || workspaceGroups.contains(where: { $0.id == groupId }) else { return }
        for id in memberIds {
            assignGroup(workspaceId: id, groupId: nil)
        }
        workspaceGroups.removeAll { $0.id == groupId }
        postWorkspaceOrderDidChange(movedWorkspaceIds: memberIds)
    }

    /// Delete a group and close every workspace inside it (anchor + all
    /// members). This is the destructive sibling of
    /// `ungroupWorkspaceGroup`: ungroup keeps the workspaces, delete throws
    /// them away. Callers that need confirmation must prompt before calling
    /// this; the method itself is unconditional so socket/CLI paths can opt
    /// out of the prompt cleanly.
    @discardableResult
    func deleteWorkspaceGroup(groupId: UUID, recordHistory: Bool = true) -> Int {
        guard workspaceGroups.contains(where: { $0.id == groupId }) else { return 0 }
        let members = tabs.filter { $0.groupId == groupId }
        var closed = 0
        for tab in members {
            // closeWorkspace short-circuits when tabs.count <= 1, so the last
            // remaining workspace would be left alive with a stale groupId.
            // Convert the holdout into a regular workspace (clear groupId)
            // instead, and let the caller's surrounding flow decide whether
            // to close the window. We still report it in the count of items
            // "removed from the group" so the response is accurate.
            if tabs.count <= 1 {
                assignGroup(workspaceId: tab.id, groupId: nil)
                continue
            }
            let countBefore = tabs.count
            closeWorkspace(tab, recordHistory: recordHistory)
            if tabs.count < countBefore { closed += 1 }
        }
        // closeWorkspace's dissolveGroupsAnchoredBy already removes the group
        // when the anchor is among the closed members, but if every member
        // was non-anchor (callers can construct that shape via socket
        // workspace.group.set_anchor races) the group survives — clean up.
        workspaceGroups.removeAll { $0.id == groupId }
        return closed
    }

    /// Rename a group. Whitespace-only names are ignored.
    func renameWorkspaceGroup(groupId: UUID, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let index = workspaceGroups.firstIndex(where: { $0.id == groupId }) else { return }
        guard workspaceGroups[index].name != trimmed else { return }
        workspaceGroups[index].name = trimmed
        // The group's name is the single source of truth for its anchor's
        // displayed title (see `resolvedWorkspaceDisplayTitle(for:)`). The
        // sidebar re-reads `group.name` via the @Published array, but the
        // imperatively-cached window-chrome surfaces (custom title bar,
        // toolbar command label) need an explicit nudge, and NSWindow.title
        // is refreshed inline here.
        updateWindowTitleForSelectedTab()
        NotificationCenter.default.post(name: .workspaceGroupNameDidChange, object: self)
    }

    /// UI-only collapse toggle: also moves focus to the anchor if the
    /// currently-selected workspace is a non-anchor child that would be
    /// hidden by the collapse. The pure-data variant
    /// `setWorkspaceGroupCollapsed` is the right call for socket/CLI paths
    /// that must preserve focus (the socket focus policy in CLAUDE.md).
    func toggleWorkspaceGroupCollapsed(groupId: UUID) {
        guard let index = workspaceGroups.firstIndex(where: { $0.id == groupId }) else { return }
        let nextCollapsed = !workspaceGroups[index].isCollapsed
        if nextCollapsed {
            let anchorId = workspaceGroups[index].anchorWorkspaceId
            if let selectedTabId,
               selectedTabId != anchorId,
               let selectedTab = tabs.first(where: { $0.id == selectedTabId }),
               selectedTab.groupId == groupId,
               let anchor = tabs.first(where: { $0.id == anchorId }) {
                selectWorkspace(anchor)
            }
            // Strip any sidebar multi-selection entries that point at
            // now-hidden non-anchor children of this group. Without this, a
            // close/group shortcut fired after the collapse would still act
            // on workspaces the user can no longer see.
            let hiddenMemberIds: Set<UUID> = Set(
                tabs
                    .filter { $0.groupId == groupId && $0.id != anchorId }
                    .map(\.id)
            )
            if !hiddenMemberIds.isEmpty,
               !sidebarSelectedWorkspaceIds.isDisjoint(with: hiddenMemberIds) {
                sidebarMultiSelection.subtractSelection(hiddenMemberIds)
                // Use the "did hide" event (not collapse-to-one) so the
                // SwiftUI sidebar only strips the hidden ids and keeps any
                // visible multi-selection entries that sit outside the group.
                // focusedWorkspaceId rides along only when focus moved.
                let focusedWorkspaceId: UUID? = (selectedTabId == anchorId) ? anchorId : nil
                sidebarMultiSelection.postDidHide(
                    hiddenWorkspaceIds: hiddenMemberIds,
                    focusedWorkspaceId: focusedWorkspaceId
                )
            }
        }
        setWorkspaceGroupCollapsed(groupId: groupId, isCollapsed: nextCollapsed)
    }

    /// Pure data mutation — flips the collapse flag without touching
    /// selection. Use this from socket/CLI handlers so a non-focus-intent
    /// command never steals the user's active workspace.
    func setWorkspaceGroupCollapsed(groupId: UUID, isCollapsed: Bool) {
        guard let index = workspaceGroups.firstIndex(where: { $0.id == groupId }) else { return }
        guard workspaceGroups[index].isCollapsed != isCollapsed else { return }
        workspaceGroups[index].isCollapsed = isCollapsed
    }

    /// Toggle the pinned state of a whole group. Pinned groups float above
    /// unpinned groups in the sidebar. Independent of per-workspace pin.
    func toggleWorkspaceGroupPinned(groupId: UUID) {
        setWorkspaceGroupPinned(groupId: groupId, isPinned: !(workspaceGroups.first(where: { $0.id == groupId })?.isPinned ?? false))
    }

    func setWorkspaceGroupPinned(groupId: UUID, isPinned: Bool) {
        guard let index = workspaceGroups.firstIndex(where: { $0.id == groupId }) else { return }
        guard workspaceGroups[index].isPinned != isPinned else { return }
        workspaceGroups[index].isPinned = isPinned
        normalizeWorkspaceGroupContiguity()
        let memberIds = tabs.filter { $0.groupId == groupId }.map(\.id)
        postWorkspaceOrderDidChange(movedWorkspaceIds: memberIds)
    }

    func setWorkspaceGroupColor(groupId: UUID, hex: String?) {
        guard let index = workspaceGroups.firstIndex(where: { $0.id == groupId }) else { return }
        guard workspaceGroups[index].customColor != hex else { return }
        workspaceGroups[index].customColor = hex
    }

    @discardableResult
    func setWorkspaceGroupIcon(groupId: UUID, symbol: String?) -> String? {
        let normalized = RenderableSystemSymbol.normalized(symbol)
        guard let index = workspaceGroups.firstIndex(where: { $0.id == groupId }) else { return nil }
        guard workspaceGroups[index].iconSymbol != normalized else { return normalized }
        workspaceGroups[index].iconSymbol = normalized
        return normalized
    }

    /// Reassign which member workspace serves as the group's anchor.
    /// `workspaceId` must already be a member of the group.
    func setWorkspaceGroupAnchor(groupId: UUID, workspaceId: UUID) {
        guard let groupIndex = workspaceGroups.firstIndex(where: { $0.id == groupId }) else { return }
        guard let tab = tabs.first(where: { $0.id == workspaceId }), tab.groupId == groupId else { return }
        guard workspaceGroups[groupIndex].anchorWorkspaceId != workspaceId else { return }
        workspaceGroups[groupIndex].anchorWorkspaceId = workspaceId
        // Hoist the new anchor to the front of its members in tabs[] so the
        // sidebar header is rendered at the anchor's position. Without this,
        // the header would still draw at the (former) first member but the
        // shortcut digit / focus target would point at the new anchor lower
        // down, breaking workspace-number navigation.
        normalizeWorkspaceGroupContiguity()
        // Publish the order change so CmuxEventBus subscribers and any
        // notification observers see the new anchor position immediately
        // (other group-mutation paths post; this one was a hole).
        let memberIds = tabs.filter { $0.groupId == groupId }.map(\.id)
        postWorkspaceOrderDidChange(movedWorkspaceIds: memberIds.isEmpty ? [workspaceId] : memberIds)
        _ = tab
    }

    /// Move a group to a new group-slot position. `targetIndex` is interpreted
    /// as the FINAL position the group should end up at in `workspaceGroups`
    /// (post-move). It is clamped to the range occupied by groups in the same
    /// pin tier as the source. Ungrouped top-level workspace rows keep their
    /// slots; the reordered group anchors are projected back into the existing
    /// group slots.
    func moveWorkspaceGroup(groupId: UUID, toIndex targetIndex: Int) {
        guard moveWorkspaceGroupSlot(groupId: groupId, toIndex: targetIndex) else { return }
        applyWorkspaceGroupSlotOrderToTabs()
        let memberIds = tabs.filter { $0.groupId == groupId }.map(\.id)
        postWorkspaceOrderDidChange(movedWorkspaceIds: memberIds)
    }

    @discardableResult
    private func moveWorkspaceGroupSlot(groupId: UUID, toIndex targetIndex: Int) -> Bool {
        guard let currentIndex = workspaceGroups.firstIndex(where: { $0.id == groupId }) else { return false }
        let isPinned = workspaceGroups[currentIndex].isPinned
        let sameTierIndices = workspaceGroups.indices.filter { workspaceGroups[$0].isPinned == isPinned }
        guard let firstSameTier = sameTierIndices.first,
              let lastSameTier = sameTierIndices.last else { return false }
        let clampedTarget = max(firstSameTier, min(targetIndex, lastSameTier))
        guard clampedTarget != currentIndex else { return false }
        let group = workspaceGroups.remove(at: currentIndex)
        // Insert at clampedTarget directly — the source's removal already
        // shifted subsequent indices down, so for a desired final position
        // of N: if N < currentIndex, indices to the left didn't move (insert
        // at N); if N > currentIndex, the source's removal shifted N's old
        // contents left by one, but we want our group AT position N in the
        // final array, which means inserting after that element — index N
        // works because we're inserting into a shorter array.
        workspaceGroups.insert(group, at: max(0, min(clampedTarget, workspaceGroups.count)))
        return true
    }

    private func applyWorkspaceGroupSlotOrderToTabs() {
        let groupsByAnchorId = Dictionary(uniqueKeysWithValues: workspaceGroups.map { ($0.anchorWorkspaceId, $0) })
        let topLevelIds = sidebarTopLevelWorkspaceIds()
        let tabsById = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })

        var pinnedTopLevelIds: [UUID] = []
        var unpinnedTopLevelIds: [UUID] = []
        pinnedTopLevelIds.reserveCapacity(topLevelIds.count)
        unpinnedTopLevelIds.reserveCapacity(topLevelIds.count)
        for id in topLevelIds {
            let isPinned = groupsByAnchorId[id]?.isPinned ?? (tabsById[id]?.isPinned == true)
            if isPinned {
                pinnedTopLevelIds.append(id)
            } else {
                unpinnedTopLevelIds.append(id)
            }
        }
        let tieredTopLevelIds = pinnedTopLevelIds + unpinnedTopLevelIds

        var pinnedAnchors: [UUID] = []
        var unpinnedAnchors: [UUID] = []
        pinnedAnchors.reserveCapacity(workspaceGroups.count)
        unpinnedAnchors.reserveCapacity(workspaceGroups.count)
        for group in workspaceGroups {
            if group.isPinned {
                pinnedAnchors.append(group.anchorWorkspaceId)
            } else {
                unpinnedAnchors.append(group.anchorWorkspaceId)
            }
        }
        var pinnedAnchorIndex = 0
        var unpinnedAnchorIndex = 0
        let desiredIds = tieredTopLevelIds.map { id -> UUID in
            guard let group = groupsByAnchorId[id] else { return id }
            if group.isPinned, pinnedAnchorIndex < pinnedAnchors.count {
                defer { pinnedAnchorIndex += 1 }
                return pinnedAnchors[pinnedAnchorIndex]
            }
            if !group.isPinned, unpinnedAnchorIndex < unpinnedAnchors.count {
                defer { unpinnedAnchorIndex += 1 }
                return unpinnedAnchors[unpinnedAnchorIndex]
            }
            return id
        }
        normalizeWorkspaceGroupRunsPreservingOrder(desiredIds)
        syncWorkspaceGroupsOrderToAnchorOrder()
    }

    /// Pick the next "Group N" name that doesn't collide with an existing
    /// group. Used when the user creates a group without naming it.
    private func nextAutoWorkspaceGroupName() -> String {
        let used = Set(workspaceGroups.map(\.name))
        var n = workspaceGroups.count + 1
        while true {
            let format = String(
                localized: "workspaceGroup.autoName.numbered",
                defaultValue: "Group %lld"
            )
            let candidate = String.localizedStringWithFormat(format, n)
            if !used.contains(candidate) { return candidate }
            n += 1
        }
    }

    private func assignGroup(workspaceId: UUID, groupId: UUID?) {
        guard let tab = tabs.first(where: { $0.id == workspaceId }) else { return }
        guard tab.groupId != groupId else { return }
        tab.groupId = groupId
    }

    /// Place a freshly-created group where its first child already was.
    /// This keeps "New Group from Selection" visually stable while still
    /// making every affected group contiguous and anchor-first. It
    /// intentionally preserves top-level order because changing that outer
    /// position is the jump this creation path is avoiding.
    private func placeNewWorkspaceGroupAtCreationPosition(
        groupId: UUID,
        anchorId: UUID,
        childWorkspaceIds: [UUID],
        originalTabOrder: [UUID]
    ) {
        let childIdSet = Set(childWorkspaceIds)
        let orderedChildIds = originalTabOrder.filter { childIdSet.contains($0) }
        guard let insertionIndex = originalTabOrder.firstIndex(where: { childIdSet.contains($0) }),
              !orderedChildIds.isEmpty else {
            normalizeWorkspaceGroupContiguity()
            return
        }

        var desiredIds: [UUID] = []
        desiredIds.reserveCapacity(tabs.count)
        for (index, id) in originalTabOrder.enumerated() {
            if index == insertionIndex {
                desiredIds.append(anchorId)
                desiredIds.append(contentsOf: orderedChildIds)
            }
            if !childIdSet.contains(id) {
                desiredIds.append(id)
            }
        }
        normalizeWorkspaceGroupContiguity(
            preservingTopLevelIds: topLevelWorkspaceIdsPreservingOrder(desiredIds)
        )
        if workspaceGroups.contains(where: { $0.id == groupId }) {
            syncWorkspaceGroupsOrderToAnchorOrder()
        }
    }

    /// Rebuild `tabs` by walking a desired top-level workspace order and
    /// emitting each workspace group as one contiguous run at its first
    /// encountered member.
    private func normalizeWorkspaceGroupRunsPreservingOrder(_ desiredIds: [UUID]) {
        let groupsById = Dictionary(uniqueKeysWithValues: workspaceGroups.map { ($0.id, $0) })
        let knownGroupIds = Set(groupsById.keys)
        for tab in tabs where tab.groupId.map({ !knownGroupIds.contains($0) }) ?? false {
            tab.groupId = nil
        }

        var groupedByGroupId: [UUID: [Workspace]] = [:]
        let tabsById = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        for tab in tabs {
            if let groupId = tab.groupId {
                groupedByGroupId[groupId, default: []].append(tab)
            }
        }

        var emittedWorkspaceIds = Set<UUID>()
        var emittedGroupIds = Set<UUID>()
        var reordered: [Workspace] = []
        reordered.reserveCapacity(tabs.count)

        func appendWorkspaceOrGroup(for id: UUID) {
            guard let tab = tabsById[id] else { return }
            if let groupId = tab.groupId,
               let group = groupsById[groupId],
               emittedGroupIds.insert(groupId).inserted {
                let members = anchorFirst(groupedByGroupId[groupId] ?? [], anchorId: group.anchorWorkspaceId)
                for member in members where emittedWorkspaceIds.insert(member.id).inserted {
                    reordered.append(member)
                }
            } else if tab.groupId == nil,
                      emittedWorkspaceIds.insert(tab.id).inserted {
                reordered.append(tab)
            }
        }

        for id in desiredIds {
            appendWorkspaceOrGroup(for: id)
        }
        for tab in tabs where !emittedWorkspaceIds.contains(tab.id) {
            appendWorkspaceOrGroup(for: tab.id)
        }

        tabs = reordered
    }

    /// Reorder `tabs` so each group stays contiguous and anchor-first while
    /// preserving top-level row order inside the pinned and unpinned tiers:
    /// 1. Pinned top-level rows (pinned workspaces and pinned groups).
    /// 2. Unpinned top-level rows (workspaces and groups).
    ///
    /// Within each group, members keep their relative order. A group anchor is
    /// the group's top-level row for ordering purposes.
    private func normalizeWorkspaceGroupContiguity(
        preservingTopLevelIds preferredTopLevelIds: [UUID]? = nil
    ) {
        guard !tabs.isEmpty else { return }
        let knownGroupIds = Set(workspaceGroups.map(\.id))
        for tab in tabs where tab.groupId.map({ !knownGroupIds.contains($0) }) ?? false {
            tab.groupId = nil
        }
        let topLevelIds = preferredTopLevelIds ?? sidebarTopLevelWorkspaceIds()
        let pinnedTopLevelIds = sidebarTopLevelPinnedWorkspaceIds()
        let desiredIds = topLevelIds.filter { pinnedTopLevelIds.contains($0) }
            + topLevelIds.filter { !pinnedTopLevelIds.contains($0) }
        // Always reassign so SwiftUI consumers re-evaluate row modifiers that
        // depend on `Workspace.groupId` even when the array contents are
        // unchanged.
        normalizeWorkspaceGroupRunsPreservingOrder(desiredIds)
        syncWorkspaceGroupsOrderToAnchorOrder()
    }

    /// Ensure the group containing the newly-selected workspace is expanded, so the
    /// selected row is actually visible in the sidebar. Called from `selectedTabId`'s
    /// didSet. No-op when the workspace is ungrouped or its group is already expanded.
    private func expandWorkspaceGroupForSelectionIfNeeded() {
        guard let selectedTabId,
              let groupId = tabs.first(where: { $0.id == selectedTabId })?.groupId,
              let index = workspaceGroups.firstIndex(where: { $0.id == groupId }),
              workspaceGroups[index].isCollapsed else {
            return
        }
        // The anchor is the group header's visible representation, so
        // focusing it doesn't hide it. Skip auto-expand when the focused
        // workspace IS the group's anchor — that lets users work in the
        // anchor while keeping the rest of the group folded away.
        guard workspaceGroups[index].anchorWorkspaceId != selectedTabId else { return }
        workspaceGroups[index].isCollapsed = false
    }

    /// Reorder `workspaceGroups` so each group's relative position matches
    /// the order its anchor occupies in `tabs[]`. Call this after an anchor
    /// reorder so later group-slot commands observe the same order the user
    /// sees in the sidebar.
    private func syncWorkspaceGroupsOrderToAnchorOrder() {
        let anchorIndex: [UUID: Int] = Dictionary(uniqueKeysWithValues: tabs.enumerated().map { ($1.id, $0) })
        workspaceGroups.sort { lhs, rhs in
            let l = anchorIndex[lhs.anchorWorkspaceId] ?? Int.max
            let r = anchorIndex[rhs.anchorWorkspaceId] ?? Int.max
            return l < r
        }
    }

    private func isWorkspaceGroupAnchor(_ workspaceId: UUID) -> Bool {
        workspaceGroups.contains { $0.anchorWorkspaceId == workspaceId }
    }

    private func topLevelWorkspaceIds(for workspaces: [Workspace]) -> [UUID] {
        let groupsById = Dictionary(uniqueKeysWithValues: workspaceGroups.map { ($0.id, $0) })
        var emittedIds = Set<UUID>()
        var ids: [UUID] = []
        ids.reserveCapacity(workspaces.count)
        for workspace in workspaces {
            let topLevelId: UUID
            if let groupId = workspace.groupId,
               let group = groupsById[groupId] {
                topLevelId = group.anchorWorkspaceId
            } else {
                topLevelId = workspace.id
            }
            if emittedIds.insert(topLevelId).inserted {
                ids.append(topLevelId)
            }
        }
        return ids
    }

    private func moveWorkspaceGroupMembersAfterAnchors(workspaceIds: [UUID]) {
        let groupsById = Dictionary(uniqueKeysWithValues: workspaceGroups.map { ($0.id, $0) })
        let tabsById = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        var promotedIdsByGroupId: [UUID: [UUID]] = [:]
        for workspaceId in workspaceIds {
            guard let tab = tabsById[workspaceId],
                  let groupId = tab.groupId,
                  let group = groupsById[groupId],
                  tab.id != group.anchorWorkspaceId else {
                continue
            }
            promotedIdsByGroupId[groupId, default: []].append(workspaceId)
        }
        guard !promotedIdsByGroupId.isEmpty else { return }

        var replacementMembersByGroupId: [UUID: [Workspace]] = [:]
        for (groupId, promotedIds) in promotedIdsByGroupId {
            guard let group = groupsById[groupId] else { continue }
            let orderedMembers = anchorFirst(
                tabs.filter { $0.groupId == groupId },
                anchorId: group.anchorWorkspaceId
            )
            guard let anchor = orderedMembers.first(where: { $0.id == group.anchorWorkspaceId }) else { continue }
            var emittedPromotedIds = Set<UUID>()
            let promotedMembers = promotedIds.compactMap { id -> Workspace? in
                guard emittedPromotedIds.insert(id).inserted else { return nil }
                return tabsById[id]
            }
            let promotedIdSet = Set(promotedMembers.map(\.id))
            let remainingMembers = orderedMembers.filter {
                $0.id != group.anchorWorkspaceId && !promotedIdSet.contains($0.id)
            }
            replacementMembersByGroupId[groupId] = [anchor] + promotedMembers + remainingMembers
        }
        guard !replacementMembersByGroupId.isEmpty else { return }

        var emittedGroupIds = Set<UUID>()
        var reordered: [Workspace] = []
        reordered.reserveCapacity(tabs.count)
        for tab in tabs {
            if let groupId = tab.groupId,
               let replacementMembers = replacementMembersByGroupId[groupId] {
                if emittedGroupIds.insert(groupId).inserted {
                    reordered.append(contentsOf: replacementMembers)
                }
            } else {
                reordered.append(tab)
            }
        }
        tabs = reordered
    }

    private func sidebarTopLevelWorkspaceIds(promotingWorkspaceId promotedWorkspaceId: UUID? = nil) -> [UUID] {
        let groupsById = Dictionary(uniqueKeysWithValues: workspaceGroups.map { ($0.id, $0) })
        var emittedGroupIds = Set<UUID>()
        var ids: [UUID] = []
        ids.reserveCapacity(tabs.count)
        for tab in tabs {
            if let groupId = tab.groupId,
               let group = groupsById[groupId] {
                if emittedGroupIds.insert(groupId).inserted {
                    ids.append(group.anchorWorkspaceId)
                }
            } else {
                ids.append(tab.id)
            }
        }
        if let promotedWorkspaceId,
           !ids.contains(promotedWorkspaceId),
           let tab = tabs.first(where: { $0.id == promotedWorkspaceId }),
           let groupId = tab.groupId,
           let group = groupsById[groupId],
           let groupIndex = ids.firstIndex(of: group.anchorWorkspaceId) {
            ids.insert(promotedWorkspaceId, at: min(groupIndex + 1, ids.count))
        }
        return ids
    }

    private func topLevelWorkspaceIdsPreservingOrder(_ desiredIds: [UUID]) -> [UUID] {
        let groupsById = Dictionary(uniqueKeysWithValues: workspaceGroups.map { ($0.id, $0) })
        let tabsById = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        var emittedWorkspaceIds = Set<UUID>()
        var emittedGroupIds = Set<UUID>()
        var ids: [UUID] = []
        ids.reserveCapacity(tabs.count)

        func appendTopLevelId(for id: UUID) {
            guard let tab = tabsById[id],
                  emittedWorkspaceIds.insert(tab.id).inserted else { return }
            if let groupId = tab.groupId,
               let group = groupsById[groupId] {
                if emittedGroupIds.insert(groupId).inserted {
                    ids.append(group.anchorWorkspaceId)
                }
            } else {
                ids.append(tab.id)
            }
        }

        for id in desiredIds {
            appendTopLevelId(for: id)
        }
        for tab in tabs where !emittedWorkspaceIds.contains(tab.id) {
            appendTopLevelId(for: tab.id)
        }
        return ids
    }

    private func sidebarTopLevelPinnedWorkspaceIds() -> Set<UUID> {
        let groupsByAnchorId = Dictionary(uniqueKeysWithValues: workspaceGroups.map { ($0.anchorWorkspaceId, $0) })
        let tabsById = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        return Set(sidebarTopLevelWorkspaceIds().filter { id in
            if let group = groupsByAnchorId[id] {
                return group.isPinned
            }
            return tabsById[id]?.isPinned == true
        })
    }

    private func clampedTopLevelReorderIndex(
        forWorkspaceId workspaceId: UUID,
        targetIndex: Int,
        topLevelIds: [UUID]
    ) -> Int {
        let clamped = max(0, min(targetIndex, max(0, topLevelIds.count - 1)))
        let pinnedIds = sidebarTopLevelPinnedWorkspaceIds()
        let pinnedCount = topLevelIds.reduce(into: 0) { count, id in
            if pinnedIds.contains(id) {
                count += 1
            }
        }
        if pinnedIds.contains(workspaceId) {
            return min(clamped, max(0, pinnedCount - 1))
        }
        return max(clamped, pinnedCount)
    }

    /// Helper for `normalizeWorkspaceGroupContiguity`: hoist the anchor to
    /// the front of its group's member list, then keep pinned member
    /// workspaces above unpinned member workspaces while preserving relative
    /// order inside each tier. No-op when the anchor isn't actually in the
    /// list (anchor lifecycle elsewhere ensures it always should be).
    private func anchorFirst(_ members: [Workspace], anchorId: UUID) -> [Workspace] {
        guard let anchorIndex = members.firstIndex(where: { $0.id == anchorId }) else {
            return members
        }
        let anchor = members[anchorIndex]
        let nonAnchors = members.filter { $0.id != anchorId }
        return [anchor] + nonAnchors.filter(\.isPinned) + nonAnchors.filter { !$0.isPinned }
    }

    /// Compatibility shim. With anchor-bound group lifecycle, "empty" groups
    /// are no longer possible — a group exists iff its anchor exists in
    /// `tabs[]`. The cleanup is now performed inside the `tabs` didSet.
    func pruneEmptyWorkspaceGroups() {}

    private func clampedReorderIndex(for workspace: Workspace, targetIndex: Int) -> Int {
        let clamped = max(0, min(targetIndex, tabs.count - 1))
        if let groupClamp = clampedGroupedMemberReorderIndex(
            for: workspace,
            clampedTargetIndex: clamped
        ) {
            return groupClamp
        }
        let pinnedCount = leadingGlobalPinnedRowCount()
        if workspace.isPinned {
            return min(clamped, max(0, pinnedCount - 1))
        }
        return max(clamped, pinnedCount)
    }

    private func clampedGroupedMemberReorderIndex(
        for workspace: Workspace,
        clampedTargetIndex: Int
    ) -> Int? {
        guard let groupId = workspace.groupId,
              let group = workspaceGroups.first(where: { $0.id == groupId }),
              workspace.id != group.anchorWorkspaceId else {
            return nil
        }
        let memberIndices = tabs.indices.filter { tabs[$0].groupId == groupId }
        guard let firstIndex = memberIndices.first,
              let lastIndex = memberIndices.last else {
            return nil
        }
        let pinnedMemberCount = memberIndices.reduce(into: 0) { count, index in
            let member = tabs[index]
            if member.id != group.anchorWorkspaceId, member.isPinned {
                count += 1
            }
        }
        let lowerBound = workspace.isPinned
            ? min(firstIndex + 1, lastIndex)
            : min(firstIndex + 1 + pinnedMemberCount, lastIndex)
        let upperBound = workspace.isPinned
            ? max(firstIndex + pinnedMemberCount, lowerBound)
            : lastIndex
        return min(max(clampedTargetIndex, lowerBound), upperBound)
    }

    private func leadingGlobalPinnedRowCount() -> Int {
        var count = 0
        for tab in tabs {
            guard isGlobalPinnedRow(tab) else { break }
            count += 1
        }
        return count
    }

    private func isGlobalPinnedRow(_ tab: Workspace) -> Bool {
        if let groupId = tab.groupId,
           let group = workspaceGroups.first(where: { $0.id == groupId }) {
            return group.isPinned
        }
        return tab.isPinned
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
        state: Workspace.PanelShellActivityState
    ) {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return }
        tab.updatePanelShellActivityState(panelId: surfaceId, state: state)
        if state == .promptIdle {
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
        guard tabs.count > 1 else { return }
        sentryBreadcrumb("workspace.close", data: ["tabCount": tabs.count - 1])
        if recordHistory,
           workspace.isRestorableInSessionSnapshot,
           let index = tabs.firstIndex(where: { $0.id == workspace.id }) {
            // Prefer the warm cached agent index over a synchronous
            // RestorableAgentSessionIndex.load() (sysctl-per-record + disk) so closing a
            // workspace does not freeze the main thread; fall back to a fresh load only
            // while the cache has not loaded yet. See closedPanelHistoryEntry.
            let snapshot = workspace.sessionSnapshot(
                includeScrollback: true,
                restorableAgentIndex: SharedLiveAgentIndex.shared.currentIndexSchedulingRefresh()
                    ?? RestorableAgentSessionIndex.load()
            )
            ClosedItemHistoryStore.shared.push(.workspace(ClosedWorkspaceHistoryEntry(
                workspaceId: workspace.id,
                windowId: AppDelegate.shared?.windowId(for: self),
                workspaceIndex: index,
                snapshot: snapshot
            )))
        }
        sidebarGitMetadataService.clearWorkspaceGitProbes(workspaceId: workspace.id)
        pullRequestProbing.clearWorkspacePullRequestTracking(workspaceId: workspace.id)
        sidebarMultiSelection.removeFromSelection(workspace.id)
        invalidateFocusHistoryTarget(workspaceId: workspace.id, panelId: nil)

        AppDelegate.shared?.notificationStore?.clearNotifications(forTabId: workspace.id)
        workspace.withClosedPanelHistorySuppressed {
            workspace.teardownAllPanels()
        }
        workspace.teardownRemoteConnection()
        unwireClosedBrowserTracking(for: workspace)
        browserModel.removeClosedBrowserPanels(forWorkspaceId: workspace.id)
        workspace.owningTabManager = nil

        if let index = tabs.firstIndex(where: { $0.id == workspace.id }) {
            tabs.remove(at: index)
            // Real-close path: if the closed workspace anchored a group, the
            // group dissolves now and its remaining members survive as
            // ungrouped workspaces. This lives at the explicit close site (not
            // in the tabs didSet) so transient remove/insert reorders never
            // trigger dissolve.
            dissolveGroupsAnchoredBy(closedWorkspaceId: workspace.id)

            if selectedTabId == workspace.id {
                // Keep the "focused index" stable when possible:
                // - If we closed workspace i and there is still a workspace at index i, focus it (the one that moved up).
                // - Otherwise (we closed the last workspace), focus the new last workspace (i-1).
                let newIndex = min(index, max(0, tabs.count - 1))
                selectedTabId = tabs[newIndex].id
            }
        }
        publishCmuxWorkspaceClosed(workspace)
    }

    /// If `closedWorkspaceId` was the anchor of any group, dissolve that group:
    /// remaining members lose their `groupId` and stay in `tabs` as ungrouped
    /// workspaces. Caller is responsible for having already removed the closed
    /// workspace from `tabs`.
    private func dissolveGroupsAnchoredBy(closedWorkspaceId: UUID) {
        let dissolvedGroupIds = workspaceGroups
            .filter { $0.anchorWorkspaceId == closedWorkspaceId }
            .map(\.id)
        guard !dissolvedGroupIds.isEmpty else { return }
        for gid in dissolvedGroupIds {
            for tab in tabs where tab.groupId == gid {
                tab.groupId = nil
            }
        }
        workspaceGroups.removeAll { dissolvedGroupIds.contains($0.id) }
        // Newly-ungrouped members may be sitting above other groups, which
        // violates the renderer's pinned-solo / pinned-groups / unpinned-
        // groups / ungrouped-unpinned ordering invariant. Renormalize so
        // they slide into the ungrouped tier at the bottom.
        normalizeWorkspaceGroupContiguity()
    }

    /// Detach a workspace from this window without closing its panels.
    /// Used by the socket API for cross-window moves.
    @discardableResult
    func detachWorkspace(tabId: UUID) -> Workspace? {
        guard let index = tabs.firstIndex(where: { $0.id == tabId }) else { return nil }
        sidebarGitMetadataService.clearWorkspaceGitProbes(workspaceId: tabId)
        sidebarMultiSelection.removeFromSelection(tabId)
        invalidateFocusHistoryTarget(workspaceId: tabId, panelId: nil)

        let removed = tabs.remove(at: index)
        // Same anchor-close lifecycle as closeWorkspace: detaching a group's
        // anchor dissolves the group; non-anchor members stay in tabs as
        // ungrouped workspaces.
        dissolveGroupsAnchoredBy(closedWorkspaceId: removed.id)
        // Clear the detached workspace's own group membership so the
        // destination window — which has no matching WorkspaceGroup — doesn't
        // render it as an orphaned indented row with stale grouping state.
        removed.groupId = nil
        unwireClosedBrowserTracking(for: removed)
        browserModel.removeClosedBrowserPanels(forWorkspaceId: removed.id)
        removed.owningTabManager = nil
        lastFocusedPanelByTab.removeValue(forKey: removed.id)

        if tabs.isEmpty {
            // The UI assumes each window always has at least one workspace.
            _ = addWorkspace()
            return removed
        }

        if selectedTabId == removed.id {
            let nextIndex = min(index, max(0, tabs.count - 1))
            selectedTabId = tabs[nextIndex].id
        }

        return removed
    }

    /// Attach an existing workspace to this window.
    func attachWorkspace(_ workspace: Workspace, at index: Int? = nil, select: Bool = true) {
        workspace.owningTabManager = self
        wireClosedBrowserTracking(for: workspace)
        let insertIndex: Int = {
            guard let index else { return tabs.count }
            return max(0, min(index, tabs.count))
        }()
        tabs.insert(workspace, at: insertIndex)
        // A workspace moved in from another window arrives ungrouped (detach
        // clears `groupId`) and may be pinned, so an arbitrary insert index can
        // split a destination group's contiguous run or drop a pinned workspace
        // below unpinned ones. Re-run the same normalization every insertion
        // path uses so the destination's sidebar invariants — leading pinned
        // segment, contiguous group runs — hold regardless of the drop index.
        normalizeWorkspaceGroupContiguity()
        if select {
            selectedTabId = workspace.id
        }
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

        if CloseTabConfirmationPolicy.shouldConfirm(requiresConfirmation: true, source: .shortcut) {
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
        let sidebarSelectionIds = orderedSidebarSelectedWorkspaceIds()
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

    func closeWorkspacesWithConfirmation(_ workspaceIds: [UUID], allowPinned: Bool) {
        let workspaces = orderedClosableWorkspaces(workspaceIds, allowPinned: allowPinned)
        guard !workspaces.isEmpty else { return }
        guard workspaces.count > 1 else {
            closeWorkspaceFromCloseTabGesture(workspaces[0])
            return
        }

        let plan = closeWorkspacesPlan(for: workspaces)
        if shouldConfirmClose(requiresConfirmation: true, source: .tabClose) {
            guard confirmClose(
                title: plan.title,
                message: plan.message,
                acceptCmdD: plan.acceptCmdD
            ) else { return }
        }

        if plan.workspaces.count == tabs.count,
           let firstWorkspace = plan.workspaces.first {
            if let window {
                window.performClose(nil)
                return
            }
            if AppDelegate.shared != nil {
                AppDelegate.shared?.closeMainWindowContainingTabId(firstWorkspace.id)
                return
            }
        }

        for workspace in plan.workspaces {
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

    private struct CloseWorkspacesPlan {
        let workspaces: [Workspace]
        let title: String
        let message: String
        let acceptCmdD: Bool
    }

    private enum CloseConfirmationSource {
        case workspace
        case tabClose
        case tabCloseButton
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

    private func orderedClosableWorkspaces(_ workspaceIds: [UUID], allowPinned: Bool) -> [Workspace] {
        let targetIds = Set(workspaceIds)
        return tabs.compactMap { workspace in
            guard targetIds.contains(workspace.id) else { return nil }
            guard allowPinned || !workspace.isPinned else { return nil }
            return workspace
        }
    }

    private func orderedSidebarSelectedWorkspaceIds() -> [UUID] {
        tabs.compactMap { workspace in
            sidebarSelectedWorkspaceIds.contains(workspace.id) ? workspace.id : nil
        }
    }

    private func closeWorkspacesPlan(for workspaces: [Workspace]) -> CloseWorkspacesPlan {
        let willCloseWindow = workspaces.count == tabs.count
        let title = willCloseWindow
            ? String(localized: "dialog.closeWindow.title", defaultValue: "Close window?")
            : String(localized: "dialog.closeWorkspaces.title", defaultValue: "Close workspaces?")
        let titleLines = workspaces
            .map { "• \(closeWorkspaceDisplayTitle($0.title))" }
            .joined(separator: "\n")
        let format = willCloseWindow
            ? String(
                localized: "dialog.closeWorkspacesWindow.message",
                defaultValue: "This will close the current window, its %1$lld workspaces, and all of their panels:\n%2$@"
            )
            : String(
                localized: "dialog.closeWorkspaces.message",
                defaultValue: "This will close %1$lld workspaces and all of their panels:\n%2$@"
            )
        let message = String(format: format, locale: .current, Int64(workspaces.count), titleLines)
        return CloseWorkspacesPlan(
            workspaces: workspaces,
            title: title,
            message: message,
            acceptCmdD: willCloseWindow
        )
    }

    private func closeWorkspaceDisplayTitle(_ title: String?) -> String {
        let collapsed = title?
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let collapsed, !collapsed.isEmpty {
            return collapsed
        }
        return String(localized: "workspace.displayName.fallback", defaultValue: "Workspace")
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
           shouldConfirmClose(requiresConfirmation: needsCloseConfirmation, source: source),
           !confirmClose(
               title: String(localized: "dialog.closeWorkspace.title", defaultValue: "Close workspace?"),
               message: String(localized: "dialog.closeWorkspace.message", defaultValue: "This will close the workspace and all of its panels."),
               acceptCmdD: willCloseWindow
           ) {
            return
        }
        if tabs.count <= 1 {
            // Last workspace in this window: match Close Workspace shortcut behavior.
            if let window {
                window.performClose(nil)
            } else {
                AppDelegate.shared?.closeMainWindowContainingTabId(workspace.id)
            }
        } else {
            closeWorkspace(workspace)
        }
    }

    private func shouldConfirmClose(requiresConfirmation: Bool, source: CloseConfirmationSource) -> Bool {
        switch source {
        case .workspace:
            return requiresConfirmation
        case .tabClose:
            return CloseTabConfirmationPolicy.shouldConfirm(
                requiresConfirmation: requiresConfirmation,
                source: .shortcut
            )
        case .tabCloseButton:
            return CloseTabConfirmationPolicy.shouldConfirm(
                requiresConfirmation: requiresConfirmation,
                source: .tabCloseButton
            )
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
        guard shouldConfirmClose(requiresConfirmation: true, source: source) else { return true }
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

        if CloseTabConfirmationPolicy.shouldConfirm(
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

        // Exiting the last non-persistent SSH surface should demote the workspace back to a
        // local one. Route through Workspace close handling so remote teardown and replacement
        // panel logic run before TabManager considers removing the workspace itself.
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
        tabs.first(where: { $0.id == tabId })?.title
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

    @discardableResult
    func zoomInFocusedBrowser() -> Bool {
        focusedBrowserPanel?.zoomIn() ?? false
    }

    @discardableResult
    func zoomOutFocusedBrowser() -> Bool {
        focusedBrowserPanel?.zoomOut() ?? false
    }

    @discardableResult
    func resetZoomFocusedBrowser() -> Bool {
        focusedBrowserPanel?.resetZoom() ?? false
    }

    var canToggleBrowserFocusModeForFocusedBrowser: Bool {
        focusedBrowserPanel?.canToggleBrowserFocusMode == true
    }

    @discardableResult
    func toggleBrowserFocusModeForFocusedBrowser(reason: String) -> Bool {
        guard let browserPanel = focusedBrowserPanel else { return false }
        return browserPanel.toggleBrowserFocusMode(reason: reason, focusWebView: true)
    }

    @discardableResult
    func setFocusedBrowserFocusModeActive(_ active: Bool, reason: String) -> Bool {
        guard let browserPanel = focusedBrowserPanel else { return false }
        return browserPanel.setBrowserFocusModeActive(active, reason: reason, focusWebView: active)
    }

    @discardableResult
    func zoomInFocusedMarkdown() -> Bool {
        focusedMarkdownPanel?.zoomIn() ?? false
    }

    @discardableResult
    func zoomOutFocusedMarkdown() -> Bool {
        focusedMarkdownPanel?.zoomOut() ?? false
    }

    @discardableResult
    func resetZoomFocusedMarkdown() -> Bool {
        focusedMarkdownPanel?.resetZoom() ?? false
    }

    @discardableResult
    func toggleDeveloperToolsFocusedBrowser() -> Bool {
        focusedBrowserPanel?.toggleDeveloperTools() ?? false
    }

    @discardableResult
    func showJavaScriptConsoleFocusedBrowser() -> Bool {
        focusedBrowserPanel?.showDeveloperToolsConsole() ?? false
    }

    @discardableResult
    func toggleOmnibarFocusedBrowser() -> Bool {
        guard let panel = focusedBrowserPanel else { return false }
        panel.toggleOmnibarVisibility()
        return true
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
    @discardableResult
    func toggleReactGrab(
        in workspace: Workspace,
        browserSurfaceId: UUID?,
        returnTerminalSurfaceId: UUID?
    ) -> UUID? {
        let snapshots = workspace.panels.values.map { panel in
            ReactGrabShortcutPanelSnapshot(
                id: panel.id,
                panelType: panel.panelType,
                isFocused: panel.id == workspace.focusedPanelId
            )
        }
        let route = resolveReactGrabShortcutRoute(panels: snapshots)

        // Browser target: an explicit surface is authoritative (it must be a browser, no
        // fallback to a different browser); otherwise resolve the route's browser from focus.
        let browserPanelId: UUID?
        if let explicit = browserSurfaceId {
            guard workspace.browserPanel(for: explicit) != nil else { return nil }
            browserPanelId = explicit
        } else {
            browserPanelId = route?.browserPanelId
        }
        guard let browserPanelId else { return nil }

        // Return terminal: an explicit return surface is authoritative (must be a terminal in
        // this workspace, no fallback) so pasteback never silently goes to the wrong terminal.
        // With no explicit return, adopt the route's terminal only when the browser also came
        // from the route (matching shortcut semantics).
        let returnTerminalPanelId: UUID?
        if let explicit = returnTerminalSurfaceId {
            guard workspace.panels[explicit]?.panelType == .terminal else { return nil }
            returnTerminalPanelId = explicit
        } else if browserSurfaceId == nil {
            returnTerminalPanelId = route?.returnTerminalPanelId
        } else {
            returnTerminalPanelId = nil
        }

        let didToggle = performReactGrabToggle(
            in: workspace,
            browserPanelId: browserPanelId,
            returnTerminalPanelId: returnTerminalPanelId
        )
        return didToggle ? browserPanelId : nil
    }

    @discardableResult
    private func performReactGrabToggle(
        in workspace: Workspace,
        browserPanelId: UUID,
        returnTerminalPanelId: UUID?
    ) -> Bool {
        guard let browserPanel = workspace.browserPanel(for: browserPanelId) else { return false }

        if let returnTerminalPanelId {
            browserPanel.armReactGrabRoundTrip(returnTo: returnTerminalPanelId)
        } else {
            browserPanel.clearReactGrabRoundTrip(reason: "shortcut.noReturnTarget")
        }

        if workspace.focusedPanelId != browserPanel.id {
            workspace.clearSplitZoom()
            workspace.focusPanel(browserPanel.id)
        }

        let didRequestExplicitWebViewFocus = browserPanel.requestExplicitWebViewFocus()
#if DEBUG
        cmuxDebugLog(
            "reactGrab.pasteback h1.focusRequestResult " +
            "workspace=\(workspace.id.uuidString.prefix(5)) " +
            "browser=\(browserPanel.id.uuidString.prefix(5)) " +
            "return=\(returnTerminalPanelId.map { String($0.uuidString.prefix(5)) } ?? "nil") " +
            "success=\(didRequestExplicitWebViewFocus ? 1 : 0)"
        )
#endif

        Task { @MainActor [weak browserPanel] in
            guard let browserPanel else { return }
            if returnTerminalPanelId != nil {
                await browserPanel.ensureReactGrabActive()
            } else {
                await browserPanel.toggleOrInjectReactGrab()
            }
            if !didRequestExplicitWebViewFocus {
                _ = browserPanel.requestExplicitWebViewFocus()
            }
        }
        return true
    }

    /// Backwards compatibility: returns the focused surface ID
    func focusedSurfaceId(for tabId: UUID) -> UUID? {
        focusedPanelId(for: tabId)
    }

    func rememberFocusedSurface(tabId: UUID, surfaceId: UUID) {
        lastFocusedPanelByTab[tabId] = surfaceId
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

    private func focusSelectedTabPanel(previousTabId: UUID?) {
        guard let selectedTabId,
              let tab = tabs.first(where: { $0.id == selectedTabId }) else { return }

        let panelId: UUID
        if let restoredPanelId = lastFocusedPanelByTab[selectedTabId],
           tab.panels[restoredPanelId] != nil {
            panelId = restoredPanelId
        } else if let focusedPanelId = tab.focusedPanelId,
                  tab.panels[focusedPanelId] != nil {
            panelId = focusedPanelId
        } else {
            return
        }

        // Defer unfocusing the previous workspace's panel until ContentView confirms handoff
        // completion (new workspace has focus or timeout fallback), to avoid a visible freeze gap.
        if let previousTabId,
           let previousTab = tabs.first(where: { $0.id == previousTabId }),
           let previousPanelId = previousTab.focusedPanelId,
           previousTab.panels[previousPanelId] != nil {
            replacePendingWorkspaceUnfocusTarget(
                with: (tabId: previousTabId, panelId: previousPanelId)
            )
        }

        // Route workspace reactivation through the normal focus machinery so panel-local
        // activation intents like browser find-field focus are restored on return.
        tab.focusPanel(panelId)
    }

    func completePendingWorkspaceUnfocus(reason: String) {
        guard let pending = pendingWorkspaceUnfocusTarget else { return }
        // If this tab became selected again before handoff completion, drop the stale
        // pending entry so it cannot be flushed later and deactivate the selected workspace.
        guard Self.shouldUnfocusPendingWorkspace(
            pendingTabId: pending.tabId,
            selectedTabId: selectedTabId
        ) else {
            pendingWorkspaceUnfocusTarget = nil
#if DEBUG
            cmuxDebugLog(
                "ws.unfocus.drop tab=\(Self.debugShortWorkspaceId(pending.tabId)) panel=\(String(pending.panelId.uuidString.prefix(5))) reason=selected_again"
            )
#endif
            return
        }
        pendingWorkspaceUnfocusTarget = nil
        unfocusWorkspacePanel(tabId: pending.tabId, panelId: pending.panelId)
#if DEBUG
        if let snapshot = debugCurrentWorkspaceSwitchSnapshot() {
            let dtMs = (CACurrentMediaTime() - snapshot.startedAt) * 1000
            cmuxDebugLog(
                "ws.unfocus.complete id=\(snapshot.id) dt=\(Self.debugMsText(dtMs)) " +
                "tab=\(Self.debugShortWorkspaceId(pending.tabId)) panel=\(String(pending.panelId.uuidString.prefix(5))) reason=\(reason)"
            )
        } else {
            cmuxDebugLog(
                "ws.unfocus.complete id=none tab=\(Self.debugShortWorkspaceId(pending.tabId)) " +
                "panel=\(String(pending.panelId.uuidString.prefix(5))) reason=\(reason)"
            )
        }
#endif
    }

    private func replacePendingWorkspaceUnfocusTarget(with next: (tabId: UUID, panelId: UUID)) {
        if let current = pendingWorkspaceUnfocusTarget,
           current.tabId == next.tabId,
           current.panelId == next.panelId {
            return
        }

        if let current = pendingWorkspaceUnfocusTarget {
            // Never unfocus the currently selected workspace when replacing stale pending state.
            if Self.shouldUnfocusPendingWorkspace(
                pendingTabId: current.tabId,
                selectedTabId: selectedTabId
            ) {
                unfocusWorkspacePanel(tabId: current.tabId, panelId: current.panelId)
#if DEBUG
                cmuxDebugLog(
                    "ws.unfocus.flush tab=\(Self.debugShortWorkspaceId(current.tabId)) panel=\(String(current.panelId.uuidString.prefix(5))) reason=replaced"
                )
#endif
            } else {
#if DEBUG
                cmuxDebugLog(
                    "ws.unfocus.drop tab=\(Self.debugShortWorkspaceId(current.tabId)) panel=\(String(current.panelId.uuidString.prefix(5))) reason=replaced_selected"
                )
#endif
            }
        }

        pendingWorkspaceUnfocusTarget = next
#if DEBUG
        if let snapshot = debugCurrentWorkspaceSwitchSnapshot() {
            let dtMs = (CACurrentMediaTime() - snapshot.startedAt) * 1000
            cmuxDebugLog(
                "ws.unfocus.defer id=\(snapshot.id) dt=\(Self.debugMsText(dtMs)) " +
                "tab=\(Self.debugShortWorkspaceId(next.tabId)) panel=\(String(next.panelId.uuidString.prefix(5)))"
            )
        } else {
            cmuxDebugLog(
                "ws.unfocus.defer id=none tab=\(Self.debugShortWorkspaceId(next.tabId)) panel=\(String(next.panelId.uuidString.prefix(5)))"
            )
        }
#endif
    }

    private func unfocusWorkspacePanel(tabId: UUID, panelId: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabId }),
              let panel = tab.panels[panelId] else { return }
        panel.unfocus()
    }

    static func shouldUnfocusPendingWorkspace(pendingTabId: UUID, selectedTabId: UUID?) -> Bool {
        selectedTabId != pendingTabId
    }

    // MARK: Notification dismissal (CmuxNotifications)
    //
    // The dismissal decision flow lives in NotificationDismissalModel;
    // TabManager hosts its seam (TabManager+NotificationDismissalHosting)
    // and forwards the legacy entry points below.

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
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
#if DEBUG
        cmuxDebugLog(
            "workspace.title.enqueue workspace=\(Self.debugShortWorkspaceId(tabId)) " +
            "panel=\(panelId.uuidString.prefix(5)) title=\"\(Self.debugTitlePreview(trimmed))\""
        )
#endif
        let key = PanelTitleUpdateKey(tabId: tabId, panelId: panelId)
        pendingPanelTitleUpdates[key] = trimmed
        panelTitleUpdateCoalescer.signal { [weak self] in
            self?.flushPendingPanelTitleUpdates()
        }
    }

    private func flushPendingPanelTitleUpdates() {
        guard !pendingPanelTitleUpdates.isEmpty else { return }
        let updates = pendingPanelTitleUpdates
        pendingPanelTitleUpdates.removeAll(keepingCapacity: true)
        for (key, title) in updates {
            updatePanelTitle(tabId: key.tabId, panelId: key.panelId, title: title)
        }
    }

    private func updatePanelTitle(tabId: UUID, panelId: UUID, title: String) {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return }
        _ = tab.updatePanelTitle(panelId: panelId, title: title)

        if tab.focusedPanelId == panelId {
            tab.applyProcessTitle(title)
            if selectedTabId == tabId {
                updateWindowTitle(for: tab)
            }
        }
    }

    func focusedSurfaceTitleDidChange(tabId: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabId }),
              let focusedPanelId = tab.focusedPanelId,
              let title = tab.panelTitles[focusedPanelId] else { return }
        tab.applyProcessTitle(title)
        if selectedTabId == tabId {
            updateWindowTitle(for: tab)
        }
    }

    private func updateWindowTitleForSelectedTab() {
        guard let selectedTabId,
              let tab = tabs.first(where: { $0.id == selectedTabId }) else {
            updateWindowTitle(for: nil)
            return
        }
        updateWindowTitle(for: tab)
    }

    private func updateWindowTitle(for tab: Workspace?) {
        let title = windowTitle(for: tab)
        guard let targetWindow = window else { return }
        targetWindow.title = title
    }

    /// The name to display for `tab` across window chrome — the custom title
    /// bar, `NSWindow.title`, and the toolbar command label.
    ///
    /// A workspace group's anchor is represented everywhere by the group itself
    /// (the sidebar draws only the group header, never a separate anchor row,
    /// per `SidebarWorkspaceRenderItem`), so for an anchor the single source of
    /// truth for the displayed name is the group's `name`. The anchor's own
    /// `title` is merely seeded equal to the group name at creation and would
    /// otherwise drift when the group is renamed.
    func resolvedWorkspaceDisplayTitle(for tab: Workspace) -> String {
        if let group = workspaceGroups.first(where: { $0.anchorWorkspaceId == tab.id }) {
            return group.name
        }
        return tab.title
    }

    private func windowTitle(for tab: Workspace?) -> String {
        guard let tab else { return "cmux" }
        let trimmedTitle = resolvedWorkspaceDisplayTitle(for: tab)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty {
            return trimmedTitle
        }
        let trimmedDirectory = tab.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedDirectory.isEmpty ? "cmux" : trimmedDirectory
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
            lastFocusedPanelByTab[tabId] = targetPanelId
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
        if let surfaceId, tab.panels[surfaceId] == nil {
#if DEBUG
            cmuxDebugLog(
                "notification.focus.fail tab=\(tabId.uuidString.prefix(5)) " +
                "panel=\(surfaceId.uuidString.prefix(5)) reason=missingPanel"
            )
#endif
            return false
        }
        let desiredPanelId = surfaceId ?? tab.focusedPanelId
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
        guard let currentId = selectedTabId,
              let currentIndex = tabs.firstIndex(where: { $0.id == currentId }) else { return }
        let nextIndex = (currentIndex + 1) % tabs.count
#if DEBUG
        let nextId = tabs[nextIndex].id
        debugPrepareWorkspaceSwitch("next", from: currentId, to: nextId)
#endif
        activateWorkspaceCycleHotWindow()
        selectWorkspaceId(
            tabs[nextIndex].id,
            notificationDismissalContext: .explicitWorkspaceResume
        )
        // Keyboard nav is an explicit "focus one workspace" gesture, so drop
        // any stale sidebar multi-selection (Shift-click range) so subsequent
        // batch actions don't operate on workspaces the user thought they
        // had unselected by moving on.
        clearSidebarMultiSelection(except: tabs[nextIndex].id)
    }

    func selectPreviousTab() {
        guard let currentId = selectedTabId,
              let currentIndex = tabs.firstIndex(where: { $0.id == currentId }) else { return }
        let prevIndex = (currentIndex - 1 + tabs.count) % tabs.count
#if DEBUG
        let prevId = tabs[prevIndex].id
        debugPrepareWorkspaceSwitch("prev", from: currentId, to: prevId)
#endif
        activateWorkspaceCycleHotWindow()
        selectWorkspaceId(
            tabs[prevIndex].id,
            notificationDismissalContext: .explicitWorkspaceResume
        )
        clearSidebarMultiSelection(except: tabs[prevIndex].id)
    }

    /// Reduce sidebar multi-selection to a single workspace (or clear if
    /// `except` isn't a known tab). Called from keyboard-nav paths so a
    /// stale Shift-click range doesn't survive after the user moves focus.
    /// Posts the should-collapse event so the SwiftUI binding
    /// in ContentView (a @State Set<UUID> separate from this tab manager)
    /// can collapse to the focused workspace too.
    private func clearSidebarMultiSelection(except workspaceId: UUID) {
        sidebarMultiSelection.collapseSelection(
            to: workspaceId,
            isKnownWorkspace: tabs.contains(where: { $0.id == workspaceId })
        )
    }

    private func activateWorkspaceCycleHotWindow() {
        workspaceCycleGeneration &+= 1
        let generation = workspaceCycleGeneration
#if DEBUG
        let switchId = debugWorkspaceSwitchId
        let switchDtMs = debugWorkspaceSwitchStartTime > 0
            ? (CACurrentMediaTime() - debugWorkspaceSwitchStartTime) * 1000
            : 0
#endif
        if !isWorkspaceCycleHot {
            isWorkspaceCycleHot = true
#if DEBUG
            cmuxDebugLog(
                "ws.hot.on id=\(switchId) gen=\(generation) dt=\(Self.debugMsText(switchDtMs))"
            )
#endif
        }

        let hadPendingCooldown = workspaceCycleCooldownTask != nil
        workspaceCycleCooldownTask?.cancel()
#if DEBUG
        if hadPendingCooldown {
            cmuxDebugLog(
                "ws.hot.cancelPrev id=\(switchId) gen=\(generation) dt=\(Self.debugMsText(switchDtMs))"
            )
        }
#endif
        workspaceCycleCooldownTask = Task { [weak self, generation] in
            do {
                try await Task.sleep(nanoseconds: 220_000_000)
            } catch {
#if DEBUG
                await MainActor.run {
                    guard let self else { return }
                    let dtMs = self.debugWorkspaceSwitchStartTime > 0
                        ? (CACurrentMediaTime() - self.debugWorkspaceSwitchStartTime) * 1000
                        : 0
                    cmuxDebugLog(
                        "ws.hot.cooldownCanceled id=\(self.debugWorkspaceSwitchId) gen=\(generation) dt=\(Self.debugMsText(dtMs))"
                    )
                }
#endif
                return
            }
            await MainActor.run {
                guard let self else { return }
                guard self.workspaceCycleGeneration == generation else { return }
#if DEBUG
                let dtMs = self.debugWorkspaceSwitchStartTime > 0
                    ? (CACurrentMediaTime() - self.debugWorkspaceSwitchStartTime) * 1000
                    : 0
                cmuxDebugLog(
                    "ws.hot.off id=\(self.debugWorkspaceSwitchId) gen=\(generation) dt=\(Self.debugMsText(dtMs))"
                )
#endif
                self.isWorkspaceCycleHot = false
                self.workspaceCycleCooldownTask = nil
            }
        }
    }

#if DEBUG
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
        guard index >= 0 && index < tabs.count else { return }
#if DEBUG
        debugPrimeWorkspaceSwitchTrigger("select_index", to: tabs[index].id)
#endif
        selectWorkspaceId(tabs[index].id, notificationDismissalContext: .explicitWorkspaceResume)
    }

    func selectLastTab() {
        guard let lastTab = tabs.last else { return }
        selectWorkspaceId(lastTab.id, notificationDismissalContext: .explicitWorkspaceResume)
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

    // The back/forward stack, suppression depth, and navigation logic live
    // in FocusHistoryModel; these forwarders keep every existing entrypoint
    // (menus, shortcuts, titlebar buttons, socket commands) unchanged.

    @discardableResult
    func withFocusHistoryRecordingSuppressed<Result>(_ body: () throws -> Result) rethrows -> Result {
        try focusHistoryNavigation.withFocusHistoryRecordingSuppressed(body)
    }

    func invalidateFocusHistoryTarget(workspaceId: UUID, panelId: UUID?) {
        focusHistoryNavigation.invalidateFocusHistoryTarget(workspaceId: workspaceId, panelId: panelId)
    }

    private func panelIdForFocusHistorySurface(_ surfaceId: UUID, workspaceId: UUID) -> UUID {
        tabs.first(where: { $0.id == workspaceId })?.panelIdFromSurfaceId(TabID(uuid: surfaceId)) ?? surfaceId
    }

    var currentFocusHistoryEntry: FocusHistoryEntry? {
        focusHistoryNavigation.currentFocusHistoryEntry
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

    // FocusHistoryHosting witnesses that touch private members
    // (`focusSelectedTabPanel`, the `private(set)` revision counter); the
    // rest of the conformance lives in TabManager+FocusHistoryHosting.swift.

    func focusSelectedWorkspacePanel() {
        focusSelectedTabPanel(previousTabId: nil)
    }

    func focusHistoryRevisionDidChange() {
        focusHistoryRevision &+= 1
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

    /// Create a new browser panel in a split
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
        guard BrowserAvailabilitySettings.isEnabled() else { return nil }
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return nil }
        return tab.newBrowserSplit(
            from: fromPanelId,
            orientation: orientation,
            insertFirst: insertFirst,
            url: url,
            preferredProfileID: preferredProfileID,
            focus: focus,
            initialDividerPosition: initialDividerPosition
        )?.id
    }

    /// Create a new browser surface in a pane
    func newBrowserSurface(
        tabId: UUID,
        inPane paneId: PaneID,
        url: URL? = nil,
        preferredProfileID: UUID? = nil
    ) -> UUID? {
        guard BrowserAvailabilitySettings.isEnabled() else { return nil }
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return nil }
        return tab.newBrowserSurface(
            inPane: paneId,
            url: url,
            preferredProfileID: preferredProfileID
        )?.id
    }

    /// Get a browser panel by ID
    func browserPanel(tabId: UUID, panelId: UUID) -> BrowserPanel? {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return nil }
        return tab.browserPanel(for: panelId)
    }

    /// Open a browser in a specific workspace, optionally preferring a split-right layout.
    @discardableResult
    func openBrowser(
        inWorkspace tabId: UUID,
        url: URL? = nil,
        preferSplitRight: Bool = false,
        preferredProfileID: UUID? = nil,
        insertAtEnd: Bool = false
    ) -> UUID? {
        guard BrowserAvailabilitySettings.isEnabled() else { return nil }
        guard let workspace = tabs.first(where: { $0.id == tabId }) else { return nil }
        if selectedTabId != tabId {
            selectWorkspaceId(tabId, notificationDismissalContext: .explicitWorkspaceResume)
        }

        if preferSplitRight {
            if let targetPaneId = workspace.topRightBrowserReusePane(),
               let browserPanel = workspace.newBrowserSurface(
                   inPane: targetPaneId,
                   url: url,
                   focus: true,
                   insertAtEnd: insertAtEnd,
                   preferredProfileID: preferredProfileID
               ) {
                rememberFocusedSurface(tabId: tabId, surfaceId: browserPanel.id)
                return browserPanel.id
            }

            let splitSourcePanelId: UUID? = {
                if let focusedPanelId = workspace.focusedPanelId,
                   workspace.panels[focusedPanelId] != nil {
                    return focusedPanelId
                }
                if let rememberedPanelId = lastFocusedPanelByTab[tabId],
                   workspace.panels[rememberedPanelId] != nil {
                    return rememberedPanelId
                }
                if let orderedPanelId = workspace.sidebarOrderedPanelIds().first(where: { workspace.panels[$0] != nil }) {
                    return orderedPanelId
                }
                return workspace.panels.keys.sorted { $0.uuidString < $1.uuidString }.first
            }()

            if let splitSourcePanelId,
               let browserPanel = workspace.newBrowserSplit(
                   from: splitSourcePanelId,
                   orientation: .horizontal,
                   url: url,
                   preferredProfileID: preferredProfileID,
                   focus: true
               ) {
                rememberFocusedSurface(tabId: tabId, surfaceId: browserPanel.id)
                return browserPanel.id
            }
        }

        guard let paneId = workspace.bonsplitController.focusedPaneId ?? workspace.bonsplitController.allPaneIds.first,
              let browserPanel = workspace.newBrowserSurface(
                  inPane: paneId,
                  url: url,
                  focus: true,
                  insertAtEnd: insertAtEnd,
                  preferredProfileID: preferredProfileID
              ) else {
            return nil
        }
        rememberFocusedSurface(tabId: tabId, surfaceId: browserPanel.id)
        return browserPanel.id
    }

    /// Open a browser in the currently focused pane (as a new surface)
    @discardableResult
    func openBrowser(
        url: URL? = nil,
        preferredProfileID: UUID? = nil,
        insertAtEnd: Bool = false
    ) -> UUID? {
        guard let tabId = selectedTabId else { return nil }
        return openBrowser(
            inWorkspace: tabId,
            url: url,
            preferSplitRight: false,
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

        let preRestoreFocus = currentFocusHistoryEntry
        let panelId = withFocusHistoryRecordingSuppressed {
            workspace.restoreClosedPanel(entry)
        }

        guard let panelId else { return false }
        ClosedItemHistoryStore.shared.remapPanelAnchorIds(from: entry.snapshot.id, to: panelId)
        withFocusHistoryRecordingSuppressed {
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
        let preRestoreFocus = currentFocusHistoryEntry
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
            normalizeWorkspaceGroupContiguity()
        }

        withFocusHistoryRecordingSuppressed {
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

            cancellable = tab.$panels
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

            panelsCancellable = tab.$panels
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

    private func setupUITestFocusShortcutsIfNeeded() {
        guard !didSetupUITestFocusShortcuts else { return }
        didSetupUITestFocusShortcuts = true

        let env = ProcessInfo.processInfo.environment
        guard env["CMUX_UI_TEST_FOCUS_SHORTCUTS"] == "1" else { return }

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

    private func setupSplitCloseRightUITestIfNeeded() {
        guard !didSetupSplitCloseRightUITest else { return }
        didSetupSplitCloseRightUITest = true

        let env = ProcessInfo.processInfo.environment
        guard env["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_SETUP"] == "1" else { return }
        guard let path = env["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_PATH"], !path.isEmpty else { return }
        let visualMode = env["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_VISUAL"] == "1"
        let shotsDir = (env["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_SHOTS_DIR"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let visualIterations = Int((env["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_ITERATIONS"] ?? "20").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 20
        let burstFrames = Int((env["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_BURST_FRAMES"] ?? "6").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 6
        let closeDelayMs = Int((env["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_CLOSE_DELAY_MS"] ?? "70").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 70
        let pattern = (env["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_PATTERN"] ?? "close_right")
            .trimmingCharacters(in: .whitespacesAndNewlines)

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
        var payload = loadSplitCloseRightTestData(at: path)
        for (key, value) in updates {
            payload[key] = value
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private func loadSplitCloseRightTestData(at path: String) -> [String: String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return object
    }

    private func setupChildExitSplitUITestIfNeeded() {
        guard !didSetupChildExitSplitUITest else { return }
        didSetupChildExitSplitUITest = true

        let env = ProcessInfo.processInfo.environment
        guard env["CMUX_UI_TEST_CHILD_EXIT_SPLIT_SETUP"] == "1" else { return }
        guard let path = env["CMUX_UI_TEST_CHILD_EXIT_SPLIT_PATH"], !path.isEmpty else { return }
        let requestedIterations = Int(env["CMUX_UI_TEST_CHILD_EXIT_SPLIT_ITERATIONS"] ?? "1") ?? 1
        let iterations = max(1, min(requestedIterations, 20))

        func write(_ updates: [String: String]) {
            var payload: [String: String] = {
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
                    return [:]
                }
                return obj
            }()
            for (k, v) in updates { payload[k] = v }
            guard let out = try? JSONSerialization.data(withJSONObject: payload) else { return }
            try? out.write(to: URL(fileURLWithPath: path), options: .atomic)
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

                    cancellable = tab.$panels
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

    private func setupChildExitKeyboardUITestIfNeeded() {
        guard !didSetupChildExitKeyboardUITest else { return }
        didSetupChildExitKeyboardUITest = true

        let env = ProcessInfo.processInfo.environment
        guard env["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_SETUP"] == "1" else { return }
        guard let path = env["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_PATH"], !path.isEmpty else { return }
        let autoTrigger = env["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_AUTO_TRIGGER"] == "1"
        let strictKeyOnly = env["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_STRICT"] == "1"
        let triggerMode = (env["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_TRIGGER_MODE"] ?? "shell_input")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let useEarlyCtrlShiftTrigger = triggerMode == "early_ctrl_shift_d"
        let useEarlyCtrlDTrigger = triggerMode == "early_ctrl_d"
        let useEarlyTrigger = useEarlyCtrlShiftTrigger || useEarlyCtrlDTrigger
        let triggerUsesShift = triggerMode == "ctrl_shift_d" || useEarlyCtrlShiftTrigger
        let layout = (env["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_LAYOUT"] ?? "lr")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let expectedPanelsAfter = max(
            1,
            Int((env["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_EXPECTED_PANELS_AFTER"] ?? "1")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            ) ?? 1
        )

        func write(_ updates: [String: String]) {
            var payload: [String: String] = {
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
                    return [:]
                }
                return obj
            }()
            for (k, v) in updates { payload[k] = v }
            guard let out = try? JSONSerialization.data(withJSONObject: payload) else { return }
            try? out.write(to: URL(fileURLWithPath: path), options: .atomic)
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

            tab.$panels
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
        let groupSnapshots: [SessionWorkspaceGroupSnapshot]? = {
            let snapshots = workspaceGroups
                .filter { occupiedGroupIds.contains($0.id) }
                .map { group in
                    let memberIds = restorableMembersByGroupId[group.id] ?? []
                    let anchorIndex = memberIds.firstIndex(of: group.anchorWorkspaceId)
                    return SessionWorkspaceGroupSnapshot(
                        id: group.id,
                        name: group.name,
                        isCollapsed: group.isCollapsed,
                        anchorWorkspaceId: group.anchorWorkspaceId,
                        anchorMemberIndex: anchorIndex,
                        isPinned: group.isPinned,
                        customColor: group.customColor,
                        iconSymbol: group.iconSymbol
                    )
                }
            return snapshots.isEmpty ? nil : snapshots
        }()
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
        lastFocusedPanelByTab.removeAll()
        pendingPanelTitleUpdates.removeAll()
        focusHistoryNavigation.reset()
        focusHistoryRevision &+= 1
        pendingWorkspaceUnfocusTarget = nil
        workspaceCycleCooldownTask?.cancel()
        workspaceCycleCooldownTask = nil
        isWorkspaceCycleHot = false
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
        let restoredGroups: [WorkspaceGroup] = {
            guard let groupSnapshots = snapshot.workspaceGroups else { return [] }
            let workspaceIdsByGroupId: [UUID: [UUID]] = {
                var map: [UUID: [UUID]] = [:]
                for workspace in newTabs {
                    if let gid = workspace.groupId {
                        map[gid, default: []].append(workspace.id)
                    }
                }
                return map
            }()
            var seen: Set<UUID> = []
            return groupSnapshots.compactMap { groupSnapshot in
                guard let members = workspaceIdsByGroupId[groupSnapshot.id], !members.isEmpty,
                      seen.insert(groupSnapshot.id).inserted else { return nil }
                // Resolve anchor: prefer the restore-stable index (since each
                // restored workspace gets a fresh UUID, the old
                // anchorWorkspaceId rarely matches). Fall back to the in-process
                // UUID hint, then to "first member by tab order" for very old
                // snapshots that pre-date both fields.
                let anchorId: UUID = {
                    if let index = groupSnapshot.anchorMemberIndex,
                       members.indices.contains(index) {
                        return members[index]
                    }
                    if let stored = groupSnapshot.anchorWorkspaceId, members.contains(stored) {
                        return stored
                    }
                    return members[0]
                }()
                return WorkspaceGroup(
                    id: groupSnapshot.id,
                    name: groupSnapshot.name,
                    isCollapsed: groupSnapshot.isCollapsed,
                    isPinned: groupSnapshot.isPinned ?? false,
                    anchorWorkspaceId: anchorId,
                    customColor: groupSnapshot.customColor,
                    iconSymbol: groupSnapshot.iconSymbol
                )
            }
        }()
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
        let count = min(originalWorkspaceIds.count, tabs.count)
        guard count > 0 else { return }
        var didRequestHistoryRemap = false
        for index in 0..<count {
            guard let originalWorkspaceId = originalWorkspaceIds[index],
                  originalWorkspaceId != tabs[index].id else {
                continue
            }
            didRequestHistoryRemap = true
            let panelIdMap = restoredPanelIdsByWorkspaceIndex.indices.contains(index)
                ? restoredPanelIdsByWorkspaceIndex[index]
                : [:]
            ClosedItemHistoryStore.shared.remapPanelWorkspaceIds(
                from: originalWorkspaceId,
                to: tabs[index].id,
                panelIdMap: panelIdMap
            )
        }
        if didRequestHistoryRemap {
            ClosedItemHistoryStore.shared.flushPendingSaves()
        }
    }

    func remapClosedPanelHistoryAfterWindowRestore(
        originalWorkspaceIds: [UUID],
        restoredPanelIdsByWorkspaceIndex: [[UUID: UUID]]
    ) {
        guard !originalWorkspaceIds.isEmpty else { return }
        let count = min(originalWorkspaceIds.count, tabs.count)
        guard count > 0 else { return }
        var didRequestHistoryRemap = false
        for index in 0..<count {
            didRequestHistoryRemap = true
            let panelIdMap = restoredPanelIdsByWorkspaceIndex.indices.contains(index)
                ? restoredPanelIdsByWorkspaceIndex[index]
                : [:]
            ClosedItemHistoryStore.shared.remapPanelWorkspaceIds(
                from: originalWorkspaceIds[index],
                to: tabs[index].id,
                panelIdMap: panelIdMap
            )
        }
        if didRequestHistoryRemap {
            ClosedItemHistoryStore.shared.flushPendingSaves()
        }
    }
}

// The hook methods live in the class body (they touch private selection /
// DEBUG state); this extension only binds the conformance.
extension TabManager: WorkspacesHosting {}

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

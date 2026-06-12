import AppKit
import SwiftUI
import Foundation
import Bonsplit
import CmuxFileWatch
import CmuxGit
import CmuxProcess
import CoreVideo
import Combine
import CoreServices
import Darwin
import Observation
import OSLog

// MARK: - Tab Type Alias for Backwards Compatibility
// The old Tab class is replaced by Workspace
typealias Tab = Workspace

let tabManagerLogger = Logger(subsystem: "com.cmuxterm.app", category: "TabManager")

@MainActor
@Observable
class TabManager {
    enum WorkspacePullRequestSnapshot: Equatable {
        case deferred
        case unsupportedRepository
        case notFound
        case resolved(SidebarPullRequestState)
        case transientFailure
    }

    struct InitialWorkspaceGitMetadataSnapshot: Equatable {
        let isRepository: Bool
        let branch: String?
        let isDirty: Bool
        let indexSignature: String?
        let indexContentSignature: String?
        let headSignature: String?
        let pullRequest: WorkspacePullRequestSnapshot
    }

    struct WorkspaceGitMetadataWatcherDescriptorRequest: Equatable, Sendable {
        let generation: UInt64
        let directory: String
    }

    struct WorkspaceGitProbeKey: Hashable, Sendable {
        let workspaceId: UUID
        let panelId: UUID
    }

    struct WorkspaceGitSnapshotProbeRequest: Sendable {
        let probeKey: WorkspaceGitProbeKey
        let isLastAttempt: Bool
    }

    enum WorkspaceGitProbeState: Equatable {
        case idle
        case inFlight(rerunPending: Bool)
    }

    /// The window that owns this TabManager. Set by AppDelegate.registerMainWindow().
    /// Used to apply title updates to the correct window instead of NSApp.keyWindow.
    weak var window: NSWindow?

    var tabs: [Workspace] = [] {
        didSet { tabsSubject.send(tabs) }
    }
    /// Named groupings of workspaces shown as collapsible sections in the sidebar.
    /// Group order in this array defines section order in the sidebar.
    /// Each member workspace stores its `groupId` on the `Workspace` model.
    var workspaceGroups: [WorkspaceGroup] = []
    /// Set by `restoreSessionSnapshot` to suppress side-effects (like auto-
    /// expanding a group on focus) that would mutate restored state mid-restore.
    var isRestoringSessionSnapshot: Bool = false
    var isWorkspaceCycleHot: Bool = false
    var pendingBackgroundWorkspaceLoadIds: Set<UUID> = [] {
        didSet { pendingBackgroundWorkspaceLoadIdsSubject.send(pendingBackgroundWorkspaceLoadIds) }
    }
    var mountedBackgroundWorkspaceLoadIds: Set<UUID> = [] {
        didSet { mountedBackgroundWorkspaceLoadIdsSubject.send(mountedBackgroundWorkspaceLoadIds) }
    }
    var debugPinnedWorkspaceLoadIds: Set<UUID> = [] {
        didSet { debugPinnedWorkspaceLoadIdsSubject.send(debugPinnedWorkspaceLoadIds) }
    }

    // MARK: Combine mirrors of the former `@Published` projections
    //
    // `@Observable` has no `$property` Combine projections. These
    // `CurrentValueSubject`s mirror the properties that still have Combine
    // subscribers (fed from each property's `didSet`) and replay the current
    // value on subscribe, matching the former `$property` initial emission.
    // Timing note: `@Published` emitted on `willSet`; these emit on `didSet`,
    // so subscribers observe the already-updated TabManager state. Like
    // `@Published`, they emit on every assignment (no equality filtering).
    @ObservationIgnored private let tabsSubject = CurrentValueSubject<[Workspace], Never>([])
    @ObservationIgnored private let selectedTabIdSubject = CurrentValueSubject<UUID?, Never>(nil)
    @ObservationIgnored private let pendingBackgroundWorkspaceLoadIdsSubject = CurrentValueSubject<Set<UUID>, Never>([])
    @ObservationIgnored private let mountedBackgroundWorkspaceLoadIdsSubject = CurrentValueSubject<Set<UUID>, Never>([])
    @ObservationIgnored private let debugPinnedWorkspaceLoadIdsSubject = CurrentValueSubject<Set<UUID>, Never>([])

    var tabsPublisher: AnyPublisher<[Workspace], Never> {
        tabsSubject.eraseToAnyPublisher()
    }
    var selectedTabIdPublisher: AnyPublisher<UUID?, Never> {
        selectedTabIdSubject.eraseToAnyPublisher()
    }
    var pendingBackgroundWorkspaceLoadIdsPublisher: AnyPublisher<Set<UUID>, Never> {
        pendingBackgroundWorkspaceLoadIdsSubject.eraseToAnyPublisher()
    }
    var mountedBackgroundWorkspaceLoadIdsPublisher: AnyPublisher<Set<UUID>, Never> {
        mountedBackgroundWorkspaceLoadIdsSubject.eraseToAnyPublisher()
    }
    var debugPinnedWorkspaceLoadIdsPublisher: AnyPublisher<Set<UUID>, Never> {
        debugPinnedWorkspaceLoadIdsSubject.eraseToAnyPublisher()
    }

    /// Global monotonically increasing counter for CMUX_PORT ordinal assignment.
    /// Static so port ranges don't overlap across multiple windows (each window has its own TabManager).
    static var nextPortOrdinal: Int = 0
    nonisolated static let initialWorkspaceGitProbeDelays: [TimeInterval] = [0, 0.5, 1.5, 3.0, 6.0, 10.0]
    nonisolated static let workspaceGitMetadataFallbackRefreshInterval: TimeInterval = 5 * 60
    nonisolated static let backgroundPollInterval: TimeInterval = 60
    nonisolated static let selectedPollInterval: TimeInterval = 10
    nonisolated static let workspacePullRequestRepoCachePruneLifetime: TimeInterval = 60
    nonisolated static let workspacePullRequestPollJitterFraction = 0.10
    nonisolated static let workspacePullRequestRefreshBatchLimit = 3
    nonisolated static let mobileHostBackgroundWorkDeferralInterval: TimeInterval = 2.0
    nonisolated static let mobileHostBackgroundWorkQuietInterval: TimeInterval = 60.0
    var selectedTabId: UUID? {
        willSet {
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
        didSet {
            // Mirror every assignment (including same-value re-assignments,
            // which the guard below filters out for side effects) so the
            // Combine bridge matches the former `$selectedTabId` projection.
            selectedTabIdSubject.send(selectedTabId)
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
                    recordFocusInHistory(workspaceId: previousTabId, panelId: focusedPanelId(for: previousTabId))
                }
                if let selectedTabId,
                   let selectedWorkspace = tabs.first(where: { $0.id == selectedTabId }) {
                    let selectedEntry = FocusHistoryEntry(
                        workspaceId: selectedTabId,
                        panelId: lastFocusedPanelByTab[selectedTabId]
                    )
                    recordFocusInHistory(
                        workspaceId: selectedTabId,
                        panelId: resolvedFocusHistoryPanelId(for: selectedEntry, in: selectedWorkspace)
                    )
                }
            }
            publishCmuxWorkspaceSelectedChange(from: previousTabId)
            let notificationDismissalContext = pendingSelectedTabNotificationDismissContext ?? .activeFocus
            pendingSelectedTabNotificationDismissContext = nil
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
                focusHistorySuppressedSelectionSideEffectGenerations.insert(generation)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let suppressFocusHistory = self.focusHistorySuppressedSelectionSideEffectGenerations.remove(generation) != nil
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
                    self.withFocusHistoryRecordingSuppressed(applySelectionSideEffects)
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
    }
    var observers: [NSObjectProtocol] = []
    var suppressFocusFlash = false
    var pendingSelectedTabNotificationDismissContext: NotificationDismissalContext?
    var lastFocusedPanelByTab: [UUID: UUID] = [:]
    struct PanelTitleUpdateKey: Hashable {
        let tabId: UUID
        let panelId: UUID
    }
    var pendingPanelTitleUpdates: [PanelTitleUpdateKey: String] = [:]
    let panelTitleUpdateCoalescer = NotificationBurstCoalescer(delay: 1.0 / 30.0)
    var recentlyClosedBrowsers = RecentlyClosedBrowserStack(capacity: 20)
    var workspaceGitProbeStateByKey: [WorkspaceGitProbeKey: WorkspaceGitProbeState] = [:]
    // Task/timer bookkeeping accessed from `deinit` stays `@ObservationIgnored`:
    // the nonisolated deinit may only touch stored properties, and the
    // `@Observable` macro would otherwise rewrite these into tracked computed
    // properties. None of them feed SwiftUI, so ignoring them preserves the
    // pre-migration (non-`@Published`) behavior exactly.
    @ObservationIgnored var workspaceGitProbeTasksByKey: [WorkspaceGitProbeKey: Task<Void, Never>] = [:]
    var workspaceGitTrackedDirectoryByKey: [WorkspaceGitProbeKey: String] = [:]
    var workspaceGitCleanIndexSignatureByKey: [WorkspaceGitProbeKey: String] = [:]
    var workspaceGitCleanIndexContentSignatureByKey: [WorkspaceGitProbeKey: String] = [:]
    var workspaceGitHeadSignatureByKey: [WorkspaceGitProbeKey: String] = [:]
    var workspaceGitMetadataWatchersByKey: [WorkspaceGitProbeKey: RecursivePathWatcher] = [:]
    var workspaceGitMetadataWatcherRefreshTasksByKey: [WorkspaceGitProbeKey: Task<Void, Never>] = [:]
    var workspaceGitMetadataWatcherSourceDirectoryByKey: [WorkspaceGitProbeKey: String] = [:]
    var workspaceGitMetadataWatcherDescriptorRequestsByKey: [WorkspaceGitProbeKey: WorkspaceGitMetadataWatcherDescriptorRequest] = [:]
    var workspaceGitMetadataWatcherDescriptorGeneration: UInt64 = 0
    var workspaceGitSnapshotRequestsByDirectory: [String: [WorkspaceGitSnapshotProbeRequest]] = [:]
    @ObservationIgnored var workspaceGitSnapshotTasksByDirectory: [String: Task<Void, Never>] = [:]
    var workspaceGitSnapshotDirectoryByProbeKey: [WorkspaceGitProbeKey: String] = [:]
    @ObservationIgnored var workspaceGitMetadataFallbackTask: Task<Void, Never>?
    var lastSidebarGitMetadataWatchEnabled = SidebarWorkspaceDetailDefaults.watchGitStatusValue(defaults: .standard)
    var lastSidebarPullRequestPollingEnabled = SidebarWorkspaceDetailDefaults.pullRequestPollingEnabled(defaults: .standard)
    var workspacePullRequestProbeStateByKey: [WorkspaceGitProbeKey: WorkspaceGitProbeState] = [:]
    var workspacePullRequestNextPollAtByKey: [WorkspaceGitProbeKey: Date] = [:]
    var workspacePullRequestLastTerminalStateRefreshAtByKey: [WorkspaceGitProbeKey: Date] = [:]
    var workspacePullRequestTransientFailureCountByKey: [WorkspaceGitProbeKey: Int] = [:]
    var workspacePullRequestRepoCacheBySlug: [String: WorkspacePullRequestRepoCacheEntry] = [:]
    @ObservationIgnored var workspacePullRequestPollTask: Task<Void, Never>?
    @ObservationIgnored var workspacePullRequestRefreshTask: Task<Void, Never>?
    var workspacePullRequestFollowUpShouldBypassRepoCache = false

    var focusHistoryRevision: UInt64 = 0 {
        didSet {
            guard focusHistoryRevision != oldValue else { return }
            NotificationCenter.default.post(name: .tabManagerFocusHistoryRevisionDidChange, object: self)
        }
    }
    // Recent focus history for back/forward navigation across workspaces and panes.
    var focusHistory: [FocusHistoryRecord] = []
    var historyIndex: Int = -1
    var focusHistoryRecordingSuppressionDepth = 0
    var focusHistorySuppressedSelectionSideEffectGenerations: Set<UInt64> = []
    var shouldRecordFocusHistory: Bool {
        focusHistoryRecordingSuppressionDepth == 0
    }
    let maxHistorySize = 50
    var selectionSideEffectsGeneration: UInt64 = 0
    var workspaceCycleGeneration: UInt64 = 0
    @ObservationIgnored var workspaceCycleCooldownTask: Task<Void, Never>?
    var pendingWorkspaceUnfocusTarget: (tabId: UUID, panelId: UUID)?
    var sidebarSelectedWorkspaceIds: Set<UUID> = []
    var currentWindowTabBarLeadingInset: CGFloat?
    var closeConfirmationInFlight = false
    var confirmCloseHandler: ((String, String, Bool) -> Bool)?
    @ObservationIgnored var agentPIDSweepTimer: DispatchSourceTimer?
#if DEBUG
    var debugWorkspaceSwitchCounter: UInt64 = 0
    var debugWorkspaceSwitchId: UInt64 = 0
    var debugWorkspaceSwitchStartTime: CFTimeInterval = 0
    var debugPendingWorkspaceSwitchTrigger: String?
    var debugPendingWorkspaceSwitchTarget: UUID?
    var debugPreparedWorkspaceSwitchTarget: UUID?
#endif

#if DEBUG
    var didSetupSplitCloseRightUITest = false
    var didSetupUITestFocusShortcuts = false
    var didSetupChildExitSplitUITest = false
    var didSetupChildExitKeyboardUITest = false
    var uiTestCancellables = Set<AnyCancellable>()
#endif

    // Reads on-disk git metadata (branch, dirty state, watched paths, remote
    // slugs) off the main actor. Stateless; the reads are pure functions of the
    // directory argument.
    let gitMetadataService: GitMetadataService
    let workspaceGitMetadataReader: any WorkspaceGitMetadataReading

    // Resolves GitHub PR badges (slug resolution, REST fetch, candidate
    // matching). Stateless; the repo cache stays here in
    // workspacePullRequestRepoCacheBySlug and is passed per refresh.
    let pullRequestProbeService: PullRequestProbeService

    // Drives the git/PR polling delays (probe retry gaps, fallback loop, PR
    // poll deadline). Injected so tests can use virtual time.
    let gitPollClock: any GitPollClock

    init(
        initialWorkspaceTitle: String? = nil,
        initialWorkingDirectory: String? = nil,
        initialTerminalInput: String? = nil,
        autoWelcomeIfNeeded: Bool = true,
        commandRunner: any CommandRunning = CommandRunner(),
        gitMetadataService: GitMetadataService = GitMetadataService(),
        workspaceGitMetadataReader: (any WorkspaceGitMetadataReading)? = nil,
        gitPollClock: any GitPollClock = SystemGitPollClock()
    ) {
        self.gitMetadataService = gitMetadataService
        self.workspaceGitMetadataReader = workspaceGitMetadataReader ?? gitMetadataService
        self.gitPollClock = gitPollClock
#if DEBUG
        self.pullRequestProbeService = PullRequestProbeService(
            commandRunner: commandRunner,
            debugLog: { cmuxDebugLog($0) }
        )
#else
        self.pullRequestProbeService = PullRequestProbeService(commandRunner: commandRunner)
#endif
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
                        recordFocusInHistory(workspaceId: tabId, panelId: panelId)
                    } else {
                        recordImplicitFocusInHistory(workspaceId: tabId, panelId: panelId)
                    }
                }
                dismissPanelNotificationOnFocus(tabId: tabId, panelId: panelId, explicitFocusIntent: explicitFocusIntent)
                focusedSurfaceTitleDidChange(tabId: tabId)
            }
        })

        startAgentPIDSweepTimer()
        updateWorkspacePullRequestPollTimer()
        updateWorkspaceGitMetadataFallbackTimer()
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
        workspacePullRequestPollTask?.cancel()
        workspaceGitMetadataFallbackTask?.cancel()
        for task in workspaceGitProbeTasksByKey.values {
            task.cancel()
        }
        for task in workspaceGitSnapshotTasksByDirectory.values {
            task.cancel()
        }
        workspacePullRequestRefreshTask?.cancel()
    }

    // MARK: - Agent PID Sweep

    var selectedWorkspace: Workspace? {
        guard let selectedTabId else { return nil }
        return tabs.first(where: { $0.id == selectedTabId })
    }

    // MARK: - Surface/Panel Compatibility Layer

    /// Returns the focused panel's terminal panel (if it is a terminal)
    var selectedTerminalPanel: TerminalPanel? {
        selectedWorkspace?.focusedTerminalPanel
    }

    var selectedWorkspaceTerminalPanels: [TerminalPanel] {
        selectedWorkspace?.panels.values.compactMap { $0 as? TerminalPanel } ?? []
    }

#if DEBUG
    /// Test seam: invoked when an initial workspace git-metadata refresh is
    /// scheduled, so tests can observe scheduling without the network probe.
    func didScheduleInitialWorkspaceGitMetadataRefreshForTesting(
        workspaceId: UUID,
        panelId: UUID,
        reason: String
    ) {}
#endif


    // MARK: - Workspace-creation seams (overridden by tests; must live in the class body)
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


    /// Test seam for mutating live workspace state after the creation snapshot is captured.
    func didCaptureWorkspaceCreationSnapshot() {}


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
}


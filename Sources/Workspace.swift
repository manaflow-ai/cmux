import Foundation
import SwiftUI
import AppKit
import Bonsplit
import CMUXAgentLaunch
import CmuxSocketControl
import Combine
import CryptoKit
import Darwin
import Network
import Observation
import CoreText

#if DEBUG
func debugWorkspaceDescriptionPreview(_ text: String?, limit: Int = 120) -> String {
    guard let text else { return "nil" }
    let escaped = text
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\r")
        .replacingOccurrences(of: "\t", with: "\\t")
    if escaped.count <= limit {
        return escaped
    }
    return "\(escaped.prefix(limit))..."
}
#endif

extension Workspace {
}

// MARK: - cmux.json custom layout

/// Workspace represents a sidebar tab.
/// Each workspace contains one BonsplitController that manages split panes and nested surfaces.
@MainActor
@Observable
final class Workspace: Identifiable {
    enum BrowserPanelCreationPolicy {
        case userInitiated
        case automationPreload
        case restoration

        var permitsCreationWhenBrowserDisabled: Bool {
            self == .restoration
        }

        var preloadsInitialNavigationInBackground: Bool {
            self == .automationPreload
        }
    }

    static let terminalScrollBarHiddenDidChangeNotification = Notification.Name(
        "cmux.workspaceTerminalScrollBarHiddenDidChange"
    )

    let id: UUID
    var title: String {
        didSet { titleSubject.send(title) }
    }
    var customTitle: String?
    var customDescription: String? {
        didSet { customDescriptionSubject.send(customDescription) }
    }
    var isPinned: Bool = false {
        didSet { isPinnedSubject.send(isPinned) }
    }
    /// Identifier of the WorkspaceGroup this workspace belongs to, or nil if ungrouped.
    /// The group entity itself lives in `TabManager.workspaceGroups`.
    var groupId: UUID?
    var customColor: String? {  // hex string, e.g. "#C0392B"
        didSet { customColorSubject.send(customColor) }
    }
    // Legacy in-memory state for old helpers/tests. Product UI, rendering, and
    // session persistence no longer honor per-workspace scrollbar overrides.
    var terminalScrollBarHidden: Bool = false
    var currentDirectory: String {
        didSet {
            currentDirectorySubject.send(currentDirectory)
            let oldDirectory = oldValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let newDirectory = currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            guard oldDirectory != newDirectory else { return }
            scheduleExtensionSidebarProjectRootRefresh(for: currentDirectory)
            // Notify the sidebar so anchor-cwd-driven group config (color,
            // icon, context menu, newWorkspacePlacement) refreshes even
            // when the anchor isn't the visible/selected workspace. Group
            // headers are the anchor's only sidebar surface, so a
            // TabItemView-style observation isn't mounted for them.
            NotificationCenter.default.post(
                name: .workspaceCurrentDirectoryDidChange,
                object: self,
                userInfo: ["workspaceId": id]
            )
        }
    }
    var extensionSidebarProjectRootPath: String? {
        didSet { extensionSidebarProjectRootPathSubject.send(extensionSidebarProjectRootPath) }
    }
    var extensionSidebarProjectRootRefreshID: UInt64 = 0
    var surfaceTabBarDirectory: String? {
        didSet { surfaceTabBarDirectorySubject.send(surfaceTabBarDirectory) }
    }
    var preferredBrowserProfileID: UUID?

    /// Ordinal for CMUX_PORT range assignment (monotonically increasing per app session)
    var portOrdinal: Int = 0

    /// The bonsplit controller managing the split panes for this workspace
    let bonsplitController: BonsplitController
    struct SurfaceTabBarExecutableButton {
        let button: CmuxSurfaceTabBarButton
        let builtInAction: CmuxSurfaceTabBarBuiltInAction?
        let workspaceCommand: CmuxResolvedCommand?
        let terminalCommandSourcePath: String?
    }

    var surfaceTabBarCommandButtons: [String: SurfaceTabBarExecutableButton] = [:]
    var surfaceTabBarButtonSourcePath: String?
    var surfaceTabBarButtonGlobalConfigPath: String?

    /// Mapping from bonsplit TabID to our Panel instances
    var panels: [UUID: any Panel] = [:] {
        didSet { panelsSubject.send(panels) }
    }

    /// Monotonic counter bumped only when the spatial (left-to-right, top-to-bottom)
    /// order of panels changes without the panel *set* changing — i.e. a pure
    /// drag-reorder of tabs within or across panes. Membership changes already
    /// fire the `panels` observation/bridge; pure reorders mutate only
    /// `bonsplitController` state, which is not observable, so observers (e.g. the
    /// mobile workspace-list observer) would otherwise never learn about a reorder.
    /// We gate the bump on an actual change of `orderedPanelIds` so that divider
    /// drags and selection-only events (which also flow through
    /// `didChangeGeometry`) do not invalidate observers needlessly.
    var paneLayoutVersion: Int = 0 {
        didSet { paneLayoutVersionSubject.send(paneLayoutVersion) }
    }

    /// Snapshot of `orderedPanelIds` from the last geometry notification, used to
    /// gate `paneLayoutVersion` bumps to genuine reorder events.
    var lastOrderedPanelIds: [UUID] = []

    /// Subscriptions for panel updates (e.g., browser title changes)
    var panelSubscriptions: [UUID: AnyCancellable] = [:]
    var agentSessionPanelCallbackIds: Set<UUID> = []

    /// When true, suppresses auto-creation in didSplitPane (programmatic splits handle their own panels)
    var isProgrammaticSplit = false
    var debugStressPreloadSelectionDepth = 0

    /// Last terminal panel used as an inheritance source (typically last focused terminal).
    var lastTerminalConfigInheritancePanelId: UUID?
    /// Last known terminal font points from inheritance sources. Used as fallback when
    /// no live terminal surface is currently available.
    var lastTerminalConfigInheritanceFontPoints: Float?
    /// Per-panel inherited zoom lineage. Descendants reuse this root value unless
    /// a panel is explicitly re-zoomed by the user.
    var terminalInheritanceFontPointsByPanelId: [UUID: Float] = [:]

    /// Callback used by TabManager to capture recently closed browser panels for Cmd+Shift+T restore.
    var onClosedBrowserPanel: ((ClosedBrowserPanelRestoreSnapshot) -> Void)?
    weak var owningTabManager: TabManager?

    // Closing tabs mutates split layout immediately; terminal views handle their own AppKit
    // layout/size synchronization.

    /// Published directory for each panel
    var panelDirectories: [UUID: String] = [:] {
        didSet { panelDirectoriesSubject.send(panelDirectories) }
    }
    var panelTitles: [UUID: String] = [:] {
        didSet { panelTitlesSubject.send(panelTitles) }
    }
    var panelCustomTitles: [UUID: String] = [:] {
        didSet { panelCustomTitlesSubject.send(panelCustomTitles) }
    }
    var pinnedPanelIds: Set<UUID> = []
    var manualUnreadPanelIds: Set<UUID> = [] {
        didSet {
            guard manualUnreadPanelIds != oldValue else { return }
            syncPanelDerivedWorkspaceUnread()
        }
    }
    var restoredUnreadPanelIndicators: [UUID: RestoredPanelUnreadIndicator] = [:] {
        didSet {
            guard restoredUnreadPanelIndicators != oldValue else { return }
            syncPanelDerivedWorkspaceUnread()
        }
    }
    var restoredUnreadPanelIds: Set<UUID> {
        Set(restoredUnreadPanelIndicators.keys)
    }
    var tmuxLayoutSnapshot: LayoutSnapshot?
    var tmuxWorkspaceFlashPanelId: UUID?
    var tmuxWorkspaceFlashReason: WorkspaceAttentionFlashReason?
    var tmuxWorkspaceFlashToken: UInt64 = 0
    var manualUnreadMarkedAt: [UUID: Date] = [:]
    var statusEntries: [String: SidebarStatusEntry] = [:] {
        didSet { statusEntriesSubject.send(statusEntries) }
    }
    var metadataBlocks: [String: SidebarMetadataBlock] = [:] {
        didSet { metadataBlocksSubject.send(metadataBlocks) }
    }
    var latestConversationMessage: String? {
        didSet { latestConversationMessageSubject.send(latestConversationMessage) }
    }
    var latestSubmittedMessage: String? {
        didSet { latestSubmittedMessageSubject.send(latestSubmittedMessage) }
    }
    var latestSubmittedAt: Date? {
        didSet { latestSubmittedAtSubject.send(latestSubmittedAt) }
    }
    var logEntries: [SidebarLogEntry] = [] {
        didSet { logEntriesSubject.send(logEntries) }
    }
    var progress: SidebarProgressState? {
        didSet { progressSubject.send(progress) }
    }
    var gitBranch: SidebarGitBranchState? {
        didSet { gitBranchSubject.send(gitBranch) }
    }
    var panelGitBranches: [UUID: SidebarGitBranchState] = [:] {
        didSet { panelGitBranchesSubject.send(panelGitBranches) }
    }
    var pullRequest: SidebarPullRequestState? {
        didSet { pullRequestSubject.send(pullRequest) }
    }
    var panelPullRequests: [UUID: SidebarPullRequestState] = [:] {
        didSet { panelPullRequestsSubject.send(panelPullRequests) }
    }
    var surfaceListeningPorts: [UUID: [Int]] = [:]
    var agentListeningPorts: [Int] = []
    var remoteConfiguration: WorkspaceRemoteConfiguration? {
        didSet { remoteConfigurationSubject.send(remoteConfiguration) }
    }
    var remoteConnectionState: WorkspaceRemoteConnectionState = .disconnected {
        didSet { remoteConnectionStateSubject.send(remoteConnectionState) }
    }
    var remoteConnectionDetail: String? {
        didSet { remoteConnectionDetailSubject.send(remoteConnectionDetail) }
    }
    var remoteDaemonStatus: WorkspaceRemoteDaemonStatus = WorkspaceRemoteDaemonStatus() {
        didSet { remoteDaemonStatusSubject.send(remoteDaemonStatus) }
    }
    var remoteDetectedPorts: [Int] = []
    var remoteForwardedPorts: [Int] = []
    var remotePortConflicts: [Int] = []
    var remoteProxyEndpoint: BrowserProxyEndpoint?
    var remoteHeartbeatCount: Int = 0
    var remoteLastHeartbeatAt: Date?
    var listeningPorts: [Int] = [] {
        didSet { listeningPortsSubject.send(listeningPorts) }
    }
    var activeRemoteTerminalSessionCount: Int = 0 {
        didSet { activeRemoteTerminalSessionCountSubject.send(activeRemoteTerminalSessionCount) }
    }
    var surfaceTTYNames: [UUID: String] = [:]
    // Accessed from `deinit`, so this must stay stored (`@ObservationIgnored`):
    // the Observable macro would otherwise turn it into a MainActor-isolated
    // computed property that a nonisolated deinit cannot touch. It is internal
    // session bookkeeping that was never `@Published`.
    @ObservationIgnored var remoteSessionController: WorkspaceRemoteSessionController?
    var pendingRemoteForegroundAuthToken: String?
    // Stored (not macro-computed) because deinit clears it; see note above.
    @ObservationIgnored var activeRemoteSessionControllerID: UUID?
    var remoteLastErrorFingerprint: String?
    var remoteLastDaemonErrorFingerprint: String?
    var remoteLastPortConflictFingerprint: String?
    var remoteDetectedSurfaceIds: Set<UUID> = []
    var activeRemoteTerminalSurfaceIds: Set<UUID> = []
    var endedPersistentRemotePTYAttachSurfaceIds: Set<UUID> = []
    var remotePTYSessionIDsByPanelId: [UUID: String] = [:]
    var remoteRelayWorkspaceIDAliases: [UUID: UUID] = [:]
    var remoteRelaySurfaceIDAliases: [UUID: UUID] = [:]
    var suppressRemoteTerminalStartupForSessionRestoreScaffold = false
    var pendingRemoteTerminalChildExitSurfaceIds: Set<UUID> = []
    /// Display target of the remote workspace that just disconnected. Set right before
    /// `createReplacementTerminalPanel()` so the replacement shell can print a banner
    /// explaining that ssh ended (instead of the user seeing an unexplained local prompt
    /// that looks identical to a healthy workspace).
    var pendingReplacementBannerRemoteTarget: String?

    static let remoteErrorStatusKey = "remote.error"
    static let remotePortConflictStatusKey = "remote.port_conflicts"
    static let remoteNotificationCooldown: TimeInterval = 5 * 60
    static let sshControlMasterCleanupQueue = DispatchQueue(
        label: "com.cmux.remote-ssh.control-master-cleanup",
        qos: .utility
    )
    static let remoteHeartbeatDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    nonisolated(unsafe) static var runSSHControlMasterCommandOverrideForTesting: (([String]) -> Void)?
    var panelShellActivityStates: [UUID: PanelShellActivityState] = [:]
    /// PIDs associated with agent status entries (e.g. claude_code), keyed by status key.
    /// Used for stale-session detection: if the PID is dead, the status entry is cleared.
    var agentPIDs: [String: pid_t] = [:]
    var agentPIDPanelIdsByKey: [String: UUID] = [:]
    var agentPIDKeysByPanelId: [UUID: Set<String>] = [:]
    var agentLifecycleStatesByPanelId: [UUID: [String: AgentHibernationLifecycleState]] = [:]
    var restoredTerminalScrollbackByPanelId: [UUID: String] = [:]
#if DEBUG
    var debugSessionSnapshotScrollbackFallbackPanelIds: Set<UUID> = []
    var debugSessionSnapshotSyntheticScrollbackByPanelId: [UUID: String] = [:]
#endif
    var restoredAgentSnapshotsByPanelId: [UUID: SessionRestorableAgentSnapshot] = [:]
    var surfaceResumeBindingsByPanelId: [UUID: SurfaceResumeBindingSnapshot] = [:]
    var restoredGuardedWorkingDirectoriesByPanelId: [UUID: String] = [:]
    enum RestoredAgentResumeState: Equatable {
        case manualResumeAvailable
        case awaitingAutoResumeCommand
        case autoResumeCommandRunning
        case observedAgentCommandRunning
    }
    var restoredAgentResumeStatesByPanelId: [UUID: RestoredAgentResumeState] = [:]
    var invalidatedRestoredAgentFingerprintsByPanelId: [UUID: Int] = [:]
    // Accessed from `deinit` (observer teardown), so this must stay stored
    // (`@ObservationIgnored`): the Observable macro would otherwise turn it
    // into a MainActor-isolated computed property that a nonisolated deinit
    // cannot touch. It was never `@Published`.
    @ObservationIgnored var pendingTerminalInputObserversByPanelId: [UUID: [WorkspacePendingTerminalInputObserver]] = [:]

    // MARK: Combine mirrors of the former `@Published` projections
    //
    // `@Observable` has no `$property` Combine projections. These
    // `CurrentValueSubject`s mirror the properties that still have Combine
    // subscribers (fed from each property's `didSet`, plus a one-shot
    // `syncCombineBridgeSubjects()` at the end of `init` because property
    // observers do not fire for assignments made directly inside the
    // initializer) and replay the current value on subscribe, matching the
    // former `$property` initial emission. Timing note: `@Published` emitted
    // on `willSet`; these emit on `didSet`, so subscribers observe the
    // already-updated Workspace state. Like `@Published`, they emit on every
    // assignment (no equality filtering); the sidebar observation publishers
    // below keep their `.dropFirst()`/`.removeDuplicates()` downstream exactly
    // as before.
    @ObservationIgnored private let titleSubject = CurrentValueSubject<String, Never>("")
    @ObservationIgnored private let customDescriptionSubject = CurrentValueSubject<String?, Never>(nil)
    @ObservationIgnored private let isPinnedSubject = CurrentValueSubject<Bool, Never>(false)
    @ObservationIgnored private let customColorSubject = CurrentValueSubject<String?, Never>(nil)
    @ObservationIgnored private let latestConversationMessageSubject = CurrentValueSubject<String?, Never>(nil)
    @ObservationIgnored private let latestSubmittedMessageSubject = CurrentValueSubject<String?, Never>(nil)
    @ObservationIgnored private let latestSubmittedAtSubject = CurrentValueSubject<Date?, Never>(nil)
    @ObservationIgnored private let currentDirectorySubject = CurrentValueSubject<String, Never>("")
    @ObservationIgnored private let extensionSidebarProjectRootPathSubject = CurrentValueSubject<String?, Never>(nil)
    @ObservationIgnored private let panelsSubject = CurrentValueSubject<[UUID: any Panel], Never>([:])
    @ObservationIgnored private let panelDirectoriesSubject = CurrentValueSubject<[UUID: String], Never>([:])
    @ObservationIgnored private let panelTitlesSubject = CurrentValueSubject<[UUID: String], Never>([:])
    @ObservationIgnored private let panelCustomTitlesSubject = CurrentValueSubject<[UUID: String], Never>([:])
    @ObservationIgnored private let paneLayoutVersionSubject = CurrentValueSubject<Int, Never>(0)
    @ObservationIgnored private let surfaceTabBarDirectorySubject = CurrentValueSubject<String?, Never>(nil)
    @ObservationIgnored private let statusEntriesSubject = CurrentValueSubject<[String: SidebarStatusEntry], Never>([:])
    @ObservationIgnored private let metadataBlocksSubject = CurrentValueSubject<[String: SidebarMetadataBlock], Never>([:])
    @ObservationIgnored private let logEntriesSubject = CurrentValueSubject<[SidebarLogEntry], Never>([])
    @ObservationIgnored private let progressSubject = CurrentValueSubject<SidebarProgressState?, Never>(nil)
    @ObservationIgnored private let gitBranchSubject = CurrentValueSubject<SidebarGitBranchState?, Never>(nil)
    @ObservationIgnored private let panelGitBranchesSubject = CurrentValueSubject<[UUID: SidebarGitBranchState], Never>([:])
    @ObservationIgnored private let pullRequestSubject = CurrentValueSubject<SidebarPullRequestState?, Never>(nil)
    @ObservationIgnored private let panelPullRequestsSubject = CurrentValueSubject<[UUID: SidebarPullRequestState], Never>([:])
    @ObservationIgnored private let remoteConfigurationSubject = CurrentValueSubject<WorkspaceRemoteConfiguration?, Never>(nil)
    @ObservationIgnored private let remoteConnectionStateSubject = CurrentValueSubject<WorkspaceRemoteConnectionState, Never>(.disconnected)
    @ObservationIgnored private let remoteConnectionDetailSubject = CurrentValueSubject<String?, Never>(nil)
    @ObservationIgnored private let remoteDaemonStatusSubject = CurrentValueSubject<WorkspaceRemoteDaemonStatus, Never>(WorkspaceRemoteDaemonStatus())
    @ObservationIgnored private let activeRemoteTerminalSessionCountSubject = CurrentValueSubject<Int, Never>(0)
    @ObservationIgnored private let listeningPortsSubject = CurrentValueSubject<[Int], Never>([])

    var panelsPublisher: AnyPublisher<[UUID: any Panel], Never> {
        panelsSubject.eraseToAnyPublisher()
    }
    var titlePublisher: AnyPublisher<String, Never> {
        titleSubject.eraseToAnyPublisher()
    }
    var isPinnedPublisher: AnyPublisher<Bool, Never> {
        isPinnedSubject.eraseToAnyPublisher()
    }
    var currentDirectoryPublisher: AnyPublisher<String, Never> {
        currentDirectorySubject.eraseToAnyPublisher()
    }
    var panelDirectoriesPublisher: AnyPublisher<[UUID: String], Never> {
        panelDirectoriesSubject.eraseToAnyPublisher()
    }
    var panelTitlesPublisher: AnyPublisher<[UUID: String], Never> {
        panelTitlesSubject.eraseToAnyPublisher()
    }
    var panelCustomTitlesPublisher: AnyPublisher<[UUID: String], Never> {
        panelCustomTitlesSubject.eraseToAnyPublisher()
    }
    var paneLayoutVersionPublisher: AnyPublisher<Int, Never> {
        paneLayoutVersionSubject.eraseToAnyPublisher()
    }
    var surfaceTabBarDirectoryPublisher: AnyPublisher<String?, Never> {
        surfaceTabBarDirectorySubject.eraseToAnyPublisher()
    }
    var remoteConfigurationPublisher: AnyPublisher<WorkspaceRemoteConfiguration?, Never> {
        remoteConfigurationSubject.eraseToAnyPublisher()
    }
    var remoteConnectionStatePublisher: AnyPublisher<WorkspaceRemoteConnectionState, Never> {
        remoteConnectionStateSubject.eraseToAnyPublisher()
    }
    var remoteConnectionDetailPublisher: AnyPublisher<String?, Never> {
        remoteConnectionDetailSubject.eraseToAnyPublisher()
    }
    var remoteDaemonStatusPublisher: AnyPublisher<WorkspaceRemoteDaemonStatus, Never> {
        remoteDaemonStatusSubject.eraseToAnyPublisher()
    }

    /// Property observers do not fire for assignments made directly inside
    /// `init`, so the bridge subjects are synced once at the end of `init`.
    /// No external subscriber can exist before `init` returns, so this never
    /// produces a visible duplicate emission.
    private func syncCombineBridgeSubjects() {
        titleSubject.send(title)
        customDescriptionSubject.send(customDescription)
        isPinnedSubject.send(isPinned)
        customColorSubject.send(customColor)
        latestConversationMessageSubject.send(latestConversationMessage)
        latestSubmittedMessageSubject.send(latestSubmittedMessage)
        latestSubmittedAtSubject.send(latestSubmittedAt)
        currentDirectorySubject.send(currentDirectory)
        extensionSidebarProjectRootPathSubject.send(extensionSidebarProjectRootPath)
        panelsSubject.send(panels)
        panelDirectoriesSubject.send(panelDirectories)
        panelTitlesSubject.send(panelTitles)
        panelCustomTitlesSubject.send(panelCustomTitles)
        paneLayoutVersionSubject.send(paneLayoutVersion)
        surfaceTabBarDirectorySubject.send(surfaceTabBarDirectory)
        statusEntriesSubject.send(statusEntries)
        metadataBlocksSubject.send(metadataBlocks)
        logEntriesSubject.send(logEntries)
        progressSubject.send(progress)
        gitBranchSubject.send(gitBranch)
        panelGitBranchesSubject.send(panelGitBranches)
        pullRequestSubject.send(pullRequest)
        panelPullRequestsSubject.send(panelPullRequests)
        remoteConfigurationSubject.send(remoteConfiguration)
        remoteConnectionStateSubject.send(remoteConnectionState)
        remoteConnectionDetailSubject.send(remoteConnectionDetail)
        remoteDaemonStatusSubject.send(remoteDaemonStatus)
        activeRemoteTerminalSessionCountSubject.send(activeRemoteTerminalSessionCount)
        listeningPortsSubject.send(listeningPorts)
    }

    private func sidebarObservationSignal<Value: Equatable>(
        _ subject: CurrentValueSubject<Value, Never>
    ) -> AnyPublisher<Void, Never> {
        subject
            .dropFirst()
            .removeDuplicates()
            .map { _ in () }
            .eraseToAnyPublisher()
    }

    @ObservationIgnored
    lazy var sidebarImmediateObservationPublisher: AnyPublisher<Void, Never> = {
        let publishers: [AnyPublisher<Void, Never>] = [
            sidebarObservationSignal(titleSubject),
            sidebarObservationSignal(customDescriptionSubject),
            sidebarObservationSignal(isPinnedSubject),
            sidebarObservationSignal(customColorSubject),
            sidebarObservationSignal(latestConversationMessageSubject),
            sidebarObservationSignal(latestSubmittedMessageSubject),
            sidebarObservationSignal(latestSubmittedAtSubject),
        ]

        return Publishers.MergeMany(publishers).eraseToAnyPublisher()
    }()

    @ObservationIgnored
    lazy var sidebarObservationPublisher: AnyPublisher<Void, Never> = {
        let publishers: [AnyPublisher<Void, Never>] = [
            sidebarObservationSignal(currentDirectorySubject),
            sidebarObservationSignal(extensionSidebarProjectRootPathSubject),
            panelsSubject
                .map(SidebarPanelObservationState.init)
                .dropFirst()
                .removeDuplicates()
                .map { _ in () }
                .eraseToAnyPublisher(),
            sidebarObservationSignal(panelDirectoriesSubject),
            sidebarObservationSignal(statusEntriesSubject),
            sidebarObservationSignal(metadataBlocksSubject),
            sidebarObservationSignal(logEntriesSubject),
            sidebarObservationSignal(progressSubject),
            sidebarObservationSignal(gitBranchSubject),
            sidebarObservationSignal(panelGitBranchesSubject),
            sidebarObservationSignal(pullRequestSubject),
            sidebarObservationSignal(panelPullRequestsSubject),
            sidebarObservationSignal(remoteConfigurationSubject),
            sidebarObservationSignal(remoteConnectionStateSubject),
            sidebarObservationSignal(remoteConnectionDetailSubject),
            sidebarObservationSignal(activeRemoteTerminalSessionCountSubject),
            sidebarObservationSignal(listeningPortsSubject),
        ]

        return Publishers.MergeMany(publishers).eraseToAnyPublisher()
    }()

    var processTitle: String

    init(
        title: String = "Terminal",
        workingDirectory: String? = nil,
        portOrdinal: Int = 0,
        configTemplate: CmuxSurfaceConfigTemplate? = nil,
        initialTerminalCommand: String? = nil,
        initialTerminalInput: String? = nil,
        initialTerminalEnvironment: [String: String] = [:], initialDetachedSurface: DetachedSurfaceTransfer? = nil
    ) {
        self.id = UUID()
        self.portOrdinal = portOrdinal
        self.processTitle = title
        self.title = title
        self.customTitle = nil
        self.customDescription = nil

        let trimmedWorkingDirectory = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasWorkingDirectory = !trimmedWorkingDirectory.isEmpty
        let initialDirectory = hasWorkingDirectory
            ? trimmedWorkingDirectory
            : FileManager.default.homeDirectoryForCurrentUser.path
        self.currentDirectory = hasWorkingDirectory
            ? trimmedWorkingDirectory
            : FileManager.default.homeDirectoryForCurrentUser.path
        self.surfaceTabBarDirectory = initialDirectory

        // Configure bonsplit with keepAllAlive to preserve terminal state
        // and keep split entry instantaneous.
        // Use the cached Ghostty config so new workspaces inherit tab-strip sizing
        // without paying repeated parse costs on the workspace-creation hot path.
        let initialSurfaceTabBarFontSize = GhosttyConfig.load().surfaceTabBarFontSize
        let appearance = Self.bonsplitAppearance(
            from: GhosttyApp.shared.defaultBackgroundColor,
            backgroundOpacity: GhosttyApp.shared.defaultBackgroundOpacity,
            tabTitleFontSize: initialSurfaceTabBarFontSize
        )
        let config = BonsplitConfiguration(
            allowSplits: true,
            allowCloseTabs: !CloseTabWarningSettings.hidesTabCloseButton(),
            allowCloseLastPane: false,
            allowTabReordering: true,
            allowCrossPaneTabMove: true,
            autoCloseEmptyPanes: true,
            contentViewLifecycle: .keepAllAlive,
            newTabPosition: .current,
            appearance: appearance
        )
        self.bonsplitController = BonsplitController(configuration: config)
        bonsplitController.contextMenuShortcuts = Self.buildContextMenuShortcuts()

        // Remove the default "Welcome" tab that bonsplit creates
        let welcomeTabIds = bonsplitController.allTabIds

        // When the workspace boots with an explicit initial command (`cmux ssh` /
        // `cmux vm new` both funnel their ssh startup script through this path),
        // hold the PTY open after that command exits. Without this Ghostty
        // silently respawns a local login shell and the user can't tell a dead
        // VM apart from a healthy local prompt.
        var resolvedConfigTemplate = configTemplate
        if let trimmedCommand = initialTerminalCommand?.trimmingCharacters(in: .whitespacesAndNewlines),
           !trimmedCommand.isEmpty {
            var template = resolvedConfigTemplate ?? CmuxSurfaceConfigTemplate()
            template.waitAfterCommand = true
            resolvedConfigTemplate = template
        }

        var initialTabId: TabID?
        if let initialDetachedSurface {
            if let initialPaneId = bonsplitController.allPaneIds.first,
               attachDetachedSurface(initialDetachedSurface, inPane: initialPaneId, focus: false) != nil {
                initialTabId = surfaceIdFromPanelId(initialDetachedSurface.panelId)
            }
        } else {
            // Create initial terminal panel
            let terminalPanel = TerminalPanel(
                workspaceId: id,
                context: GHOSTTY_SURFACE_CONTEXT_TAB,
                configTemplate: resolvedConfigTemplate,
                workingDirectory: hasWorkingDirectory ? trimmedWorkingDirectory : nil,
                portOrdinal: portOrdinal,
                initialCommand: initialTerminalCommand,
                initialInput: initialTerminalInput,
                initialEnvironmentOverrides: initialTerminalEnvironment
            )
            configureNewTerminalPanel(terminalPanel)
            panels[terminalPanel.id] = terminalPanel
            panelTitles[terminalPanel.id] = terminalPanel.displayTitle
            seedTerminalInheritanceFontPoints(panelId: terminalPanel.id, configTemplate: configTemplate)

            // Create initial tab in bonsplit and store the mapping
            if let tabId = bonsplitController.createTab(
                title: title,
                icon: "terminal.fill",
                kind: SurfaceKind.terminal,
                isDirty: false,
                isPinned: false
            ) {
                surfaceIdToPanelId[tabId] = terminalPanel.id
                initialTabId = tabId
            }
        }

        // Close the default Welcome tab(s)
        for welcomeTabId in welcomeTabIds {
            bonsplitController.closeTab(welcomeTabId)
        }

        bonsplitController.onExternalTabDrop = { [weak self] request in
            self?.handleExternalTabDrop(request) ?? false
        }
        bonsplitController.onExternalFileDrop = { [weak self] request in
            self?.handleExternalFileDrop(request) ?? false
        }
        bonsplitController.tabContextMoveDestinationsProvider = { [weak self] tabId, _ in
            self?.bonsplitTabMoveDestinations(for: tabId) ?? []
        }
        bonsplitController.tabContextForkConversationAvailabilityProvider = { [weak self] tabId, _ in
            guard let self,
                  let panelId = self.panelIdFromSurfaceId(tabId) else { return false }
            return self.canForkAgentConversationFromPanel(panelId)
        }
        bonsplitController.tabContextForkConversationDefaultActionProvider = { _, _ in
            AgentConversationForkDefaultSettings.current().tabContextAction
        }
        bonsplitController.onTabCloseRequest = { [weak self] tabId, _, source in
            switch source {
            case .closeButton:
                self?.markTabCloseButtonClose(surfaceId: tabId)
            case .middleClick:
                self?.markExplicitClose(surfaceId: tabId)
            }
        }
        bonsplitController.onTabZoomToggleRequest = { [weak self] tabId, _ in
            guard let self,
                  let panelId = self.panelIdFromSurfaceId(tabId) else { return false }
            return self.toggleSplitZoom(panelId: panelId)
        }

        // Set ourselves as delegate
        bonsplitController.delegate = self

        // Ensure bonsplit has a focused pane and our didSelectTab handler runs for the
        // initial terminal. bonsplit's createTab selects internally but does not emit
        // didSelectTab, and focusedPaneId can otherwise be nil until user interaction.
        if let initialTabId, initialDetachedSurface == nil {
            // Focus the pane containing the initial tab (or the first pane as fallback).
            let paneToFocus: PaneID? = {
                for paneId in bonsplitController.allPaneIds {
                    if bonsplitController.tabs(inPane: paneId).contains(where: { $0.id == initialTabId }) {
                        return paneId
                    }
                }
                return bonsplitController.allPaneIds.first
            }()
            if let paneToFocus {
                bonsplitController.focusPane(paneToFocus)
            }
            bonsplitController.selectTab(initialTabId)
        }
        tmuxLayoutSnapshot = bonsplitController.layoutSnapshot()
        scheduleExtensionSidebarProjectRootRefresh(for: currentDirectory)

        // Property observers do not fire for assignments made directly inside
        // this initializer, so bring the Combine bridge subjects in line with
        // the just-initialized property values.
        syncCombineBridgeSubjects()

        // Forward shared agent-index refreshes into `sharedAgentIndexRevision` so the
        // bonsplit tab-bar re-evaluates the Fork Conversation availability the moment a
        // background refresh lands. `indexDidChange` is the index's explicit did-set
        // subject. Workspace itself is `@Observable` (no `objectWillChange` to forward
        // into), so `WorkspaceContentView` reads the tracked revision in its body and
        // re-renders when it bumps. `indexDidChange` only fires from MainActor-isolated
        // didSet, so `assumeIsolated` is safe here.
        sharedLiveAgentIndexCancellable = SharedLiveAgentIndex.shared.indexDidChange.sink { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sharedAgentIndexRevision &+= 1
            }
        }
    }

    @ObservationIgnored private var sharedLiveAgentIndexCancellable: AnyCancellable?

    /// Bumped when the process-wide `SharedLiveAgentIndex` lands a refresh. Replaces
    /// the former `objectWillChange.send()` forward: `WorkspaceContentView` reads this
    /// tracked counter so SwiftUI re-renders it (and bonsplit's TabBarView re-evaluates
    /// Fork Conversation availability) when the shared index refreshes.
    private(set) var sharedAgentIndexRevision: Int = 0

    deinit {
        for registrations in pendingTerminalInputObserversByPanelId.values {
            for registration in registrations {
                if let observer = registration.observer {
                    NotificationCenter.default.removeObserver(observer)
                }
            }
        }
        activeRemoteSessionControllerID = nil
        remoteSessionController?.stop()
    }

    /// Mapping from bonsplit TabID (surface ID) to panel UUID
    var surfaceIdToPanelId: [TabID: UUID] = [:]

    /// Tab IDs that are allowed to close even if they would normally require confirmation.
    /// This is used by app-level confirmation prompts (for example, Close Tab) so the
    /// Bonsplit delegate doesn't block the close after the user already confirmed.
    var forceCloseTabIds: Set<TabID> = []

    /// Tab IDs that are currently showing (or about to show) a close confirmation prompt.
    /// Prevents repeated close gestures (e.g., middle-click spam) from stacking dialogs.
    var pendingCloseConfirmTabIds: Set<TabID> = []

    /// Tab IDs whose next close attempt should be treated as an explicit
    /// workspace-close gesture from the user (the tab-strip X button, or the Close Tab
    /// shortcut when the shortcut preference is set to close the workspace on the last surface),
    /// rather than an internal close/move flow.
    var explicitUserCloseTabIds: Set<TabID> = []
    var closeHistoryEligibleTabIds: Set<TabID> = []
    var closeHistoryEligiblePanelIds: Set<UUID> = []
    var suppressClosedPanelHistory = false
    var tabCloseButtonCloseTabIds: Set<TabID> = []

    /// Deterministic tab selection to apply after a tab closes.
    /// Keyed by the closing tab ID, value is the tab ID we want to select next.
    var postCloseSelectTabId: [TabID: TabID] = [:]
    var postCloseClearSplitZoomTabIds: Set<TabID> = []
    /// Panel IDs that were in a pane when a pane-close operation was approved.
    /// Bonsplit pane-close does not emit per-tab didClose callbacks.
    var pendingPaneClosePanelIds: [UUID: [UUID]] = [:]
    var pendingPaneCloseHistoryEntries: [UUID: [ClosedPanelHistoryEntry]] = [:]
    var pendingClosedBrowserRestoreSnapshots: [TabID: ClosedBrowserPanelRestoreSnapshot] = [:]
    var isApplyingTabSelection = false
    struct PendingTabSelectionRequest {
        let tabId: TabID
        let pane: PaneID
        let reassertAppKitFocus: Bool
        let focusIntent: PanelFocusIntent?
        let resumeHibernatedAgent: Bool?
        let previousTerminalHostedView: GhosttySurfaceScrollView?
    }
    var pendingTabSelection: PendingTabSelectionRequest?
    var isReconcilingFocusState = false
    var focusReconcileScheduled = false
#if DEBUG
    var debugFocusReconcileScheduledDuringDetachCount: Int = 0
    var debugLastDidMoveTabTimestamp: TimeInterval = 0
    var debugDidMoveTabEventCount: UInt64 = 0
#endif
    var layoutFollowUpObservers: [NSObjectProtocol] = []
    var layoutFollowUpPanelsCancellable: AnyCancellable?
    var layoutFollowUpTimeoutWorkItem: DispatchWorkItem?
    var layoutFollowUpReason: String?
    var layoutFollowUpTerminalFocusPanelId: UUID?
    var layoutFollowUpBrowserPanelId: UUID?
    var layoutFollowUpBrowserExitFocusPanelId: UUID?
    var layoutFollowUpNeedsGeometryPass = false
    var layoutFollowUpAttemptScheduled = false
    var layoutFollowUpAttemptVersion: Int = 0
    var layoutFollowUpStalledAttemptCount = 0
    var pendingReparentFocusSuppressionViews: [ObjectIdentifier: GhosttySurfaceScrollView] = [:]
    var portalRenderingEnabled = true
    var agentHibernationAutoResumePresentationVisible = true
    var isAttemptingLayoutFollowUp = false
    var isNormalizingPinnedTabOrder = false
    var pendingNonFocusSplitFocusReassert: PendingNonFocusSplitFocusReassert?
    var nonFocusSplitFocusReassertGeneration: UInt64 = 0

    struct PendingNonFocusSplitFocusReassert {
        let generation: UInt64
        let preferredPanelId: UUID
        let splitPanelId: UUID
    }

    var detachingTabIds: Set<TabID> = []
    var pendingDetachedSurfaces: [TabID: DetachedSurfaceTransfer] = [:]
    var activeDetachCloseTransactions: Int = 0
    var isDetachingCloseTransaction: Bool { activeDetachCloseTransactions > 0 }
    var pendingRemoteSurfaceTTYName: String?
    var pendingRemoteSurfaceTTYSurfaceId: UUID?
    var pendingRemoteSurfacePortKickReason: WorkspaceRemoteSessionController.PortScanKickReason?
    var pendingRemoteSurfacePortKickSurfaceId: UUID?
    // When the last live remote terminal is detached out, the source workspace may be
    // closed immediately after the move succeeds. That teardown must not shut down the
    // shared SSH control master that is still serving the moved terminal.
    var skipControlMasterCleanupAfterDetachedRemoteTransfer = false
    var transferredRemoteCleanupConfigurationsByPanelId: [UUID: WorkspaceRemoteConfiguration] = [:]

#if DEBUG
    func debugElapsedMs(since start: TimeInterval) -> String {
        let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
        return String(format: "%.2f", ms)
    }
#endif

}

// MARK: - BonsplitDelegate

extension Workspace: BonsplitDelegate {
}

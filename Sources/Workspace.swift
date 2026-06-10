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

final class WorkspaceRemoteDaemonRPCClient {
    static let maxStdoutBufferBytes = 256 * 1024
    static let bakedVMDaemonSocketPath = "/run/cmuxd-remote.sock"
    static let socketForwardStartupGracePeriod: TimeInterval = 0.75
    static let requiredProxyStreamCapability = "proxy.stream.push"
    static let requiredPTYSessionCapability = "pty.session"
    static let requiredPTYSessionTokenCapability = "pty.session.token"
    static let requiredPTYPersistentDaemonCapability = "pty.session.persistent_daemon"
    static let requiredPTYWriteNotificationCapability = "pty.write.notification"

    enum StreamEvent {
        case data(Data)
        case eof(Data)
        case error(String)
    }

    enum PTYEvent {
        case ready
        case data(Data)
        case exit
        case error(String)
    }

    struct StreamSubscription {
        let queue: DispatchQueue
        let handler: (StreamEvent) -> Void
    }

    struct PTYSubscription {
        let queue: DispatchQueue
        let handler: (PTYEvent) -> Void
    }

    let configuration: WorkspaceRemoteConfiguration
    let remotePath: String
    let onUnexpectedTermination: (String) -> Void
    let writeQueue = DispatchQueue(label: "com.cmux.remote-ssh.daemon-rpc.write.\(UUID().uuidString)")
    let stateQueue = DispatchQueue(label: "com.cmux.remote-ssh.daemon-rpc.state.\(UUID().uuidString)")
    let pendingCalls = WorkspaceRemoteDaemonPendingCallRegistry()

    var process: Process?
    var stdinPipe: Pipe?
    var stdoutPipe: Pipe?
    var stderrPipe: Pipe?
    var stdinHandle: FileHandle?
    var stdoutHandle: FileHandle?
    var stderrHandle: FileHandle?
    var webSocketSession: URLSession?
    var webSocketTask: URLSessionWebSocketTask?
    var webSocketDelegate: WebSocketDelegate?
    var isClosed = true
    var shouldReportTermination = true

    var stdoutBuffer = Data()
    var stderrBuffer = ""
    var streamSubscriptions: [String: StreamSubscription] = [:]
    var ptySubscriptions: [String: PTYSubscription] = [:]

    init(
        configuration: WorkspaceRemoteConfiguration,
        remotePath: String,
        onUnexpectedTermination: @escaping (String) -> Void
    ) {
        self.configuration = configuration
        self.remotePath = remotePath
        self.onUnexpectedTermination = onUnexpectedTermination
    }

}

final class WorkspaceRemoteSessionController {
#if DEBUG
    // XCTest seam: tests assign this before starting a controller and clear it
    // after disconnect teardown; production/debug app code leaves it nil. The
    // override closure owns synchronization for any captured test-only state.
    nonisolated(unsafe) static var runProcessOverrideForTesting: ((String, [String], Data?, TimeInterval) throws -> (status: Int32, stdout: String, stderr: String))?
    nonisolated(unsafe) static var runProcessReadHandlesDidInstallForTesting: ((FileHandle, FileHandle) -> Void)?
#endif

    enum PortScanKickReason: String {
        case command
        case refresh

        var burstOffsets: [Double] {
            switch self {
            case .command:
                return [0.5, 1.5, 3.0, 5.0, 7.5, 10.0]
            case .refresh:
                return [0.0]
            }
        }

        func merged(with other: Self) -> Self {
            switch (self, other) {
            case (.command, _), (_, .command):
                return .command
            case (.refresh, .refresh):
                return .refresh
            }
        }
    }

    struct RetrySchedule {
        let retry: Int
        let delay: TimeInterval
    }

    struct CommandResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    struct RemotePlatform {
        let goOS: String
        let goArch: String
    }

    struct RemoteBootstrapState {
        let platform: RemotePlatform
        let homeDirectory: String
        let binaryExists: Bool
    }

    struct RemoteDaemonInstallLocation {
        let relativePath: String
        let absolutePath: String

        var directory: String {
            (absolutePath as NSString).deletingLastPathComponent
        }
    }

    struct DaemonHello {
        let name: String
        let version: String
        let capabilities: [String]
        let remotePath: String
    }

    /// The capabilities advertised by the cmuxd-remote baked into the Freestyle snapshot
    /// (scratch/vm-experiments/images/install.sh pins v0.63.2). Keep this in lockstep with
    /// the daemon's `hello` response — if the baked version advertises a new capability,
    /// bump it here too.
    static func bakedVMDaemonHello() -> DaemonHello {
        DaemonHello(
            name: "cmuxd-remote",
            version: "v0.63.2-baked",
            capabilities: [
                "session.basic",
                "session.resize.min",
                "proxy.http_connect",
                "proxy.socks5",
                "proxy.stream",
                "proxy.stream.push",
            ],
            remotePath: "/usr/local/bin/cmuxd-remote"
        )
    }

    let queue = DispatchQueue(label: "com.cmux.remote-ssh.\(UUID().uuidString)", qos: .utility)
    let queueKey = DispatchSpecificKey<Void>()
    weak var workspace: Workspace?
    let configuration: WorkspaceRemoteConfiguration
    let controllerID: UUID

    enum RemotePortPollingMode {
        case hostWide
        case hostWideDelta
        case ttyScoped

        var initialDelay: TimeInterval {
            switch self {
            case .hostWide:
                return 0.5
            case .hostWideDelta:
                return 0.5
            case .ttyScoped:
                return 1.0
            }
        }

        var repeatInterval: TimeInterval {
            switch self {
            case .hostWide:
                return 2.0
            case .hostWideDelta:
                return 5.0
            case .ttyScoped:
                return 5.0
            }
        }
    }

    struct PendingPTYBridgeStart {
        let sessionID: String
        let attachmentID: String
        let command: String?
        let requireExisting: Bool
        let isCancelled: () -> Bool
        let completion: (Result<WorkspaceRemotePTYBridgeServer.Endpoint, Error>) -> Void
    }

    var isStopping = false
    var proxyLease: WorkspaceRemoteProxyBroker.Lease?
    var proxyEndpoint: BrowserProxyEndpoint?
    var daemonReady = false
    var daemonBootstrapVersion: String?
    var daemonRemotePath: String?
    var reverseRelayProcess: Process?
    var reverseRelayControlMasterForwardSpec: String?
    var cliRelayServer: WorkspaceRemoteCLIRelayServer?
    var remotePortScanTTYNames: [UUID: String] = [:]
    var remoteScannedPortsByPanel: [UUID: [Int]] = [:]
    var remotePortScanBurstActive = false
    var remotePortScanActiveReason: PortScanKickReason?
    var remotePortScanPendingReason: PortScanKickReason?
    var remotePortScanGeneration: UInt64 = 0
    var remotePortScanCoalesceWorkItem: DispatchWorkItem?
    var remotePortPollTimer: DispatchSourceTimer?
    var remotePortPollMode: RemotePortPollingMode?
    var polledRemotePorts: [Int] = []
    var remotePortPollBaselinePorts: Set<Int>?
    var keepPolledRemotePortsUntilTTYScan = false
    var bootstrapRemoteTTYResolved = false
    var bootstrapRemoteTTYRetryWorkItem: DispatchWorkItem?
    var bootstrapRemoteTTYFetchInFlight = false
    var bootstrapRemoteTTYRetryCount = 0
    var reverseRelayStderrPipe: Pipe?
    var reverseRelayRestartWorkItem: DispatchWorkItem?
    var reverseRelayStderrBuffer = ""
    var reconnectRetryCount = 0
    var reconnectWorkItem: DispatchWorkItem?
    var heartbeatCount: Int = 0
    var connectionAttemptStartedAt: Date?
    var pendingPTYBridgeStarts: [UUID: PendingPTYBridgeStart] = [:]
    var remoteRelayWorkspaceAliases: [UUID: UUID] = [:]
    var remoteRelaySurfaceAliases: [UUID: UUID] = [:]

    init(workspace: Workspace, configuration: WorkspaceRemoteConfiguration, controllerID: UUID) {
        self.workspace = workspace
        self.configuration = configuration
        self.controllerID = controllerID
        queue.setSpecific(key: queueKey, value: ())
    }

}

/// Workspace represents a sidebar tab.
/// Each workspace contains one BonsplitController that manages split panes and nested surfaces.
@MainActor
final class Workspace: Identifiable, ObservableObject {
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
    @Published var title: String
    @Published var customTitle: String?
    @Published var customDescription: String?
    @Published var isPinned: Bool = false
    /// Identifier of the WorkspaceGroup this workspace belongs to, or nil if ungrouped.
    /// The group entity itself lives in `TabManager.workspaceGroups`.
    @Published var groupId: UUID?
    @Published var customColor: String?  // hex string, e.g. "#C0392B"
    // Legacy in-memory state for old helpers/tests. Product UI, rendering, and
    // session persistence no longer honor per-workspace scrollbar overrides.
    @Published var terminalScrollBarHidden: Bool = false
    @Published var currentDirectory: String {
        didSet {
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
    @Published var extensionSidebarProjectRootPath: String?
    var extensionSidebarProjectRootRefreshID: UInt64 = 0
    @Published var surfaceTabBarDirectory: String?
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
    @Published var panels: [UUID: any Panel] = [:]

    /// Monotonic counter bumped only when the spatial (left-to-right, top-to-bottom)
    /// order of panels changes without the panel *set* changing — i.e. a pure
    /// drag-reorder of tabs within or across panes. Membership changes already
    /// fire `$panels`; pure reorders mutate only `bonsplitController` state, which
    /// is not `@Published`, so observers (e.g. the mobile workspace-list observer)
    /// would otherwise never learn about a reorder. We gate the bump on an actual
    /// change of `orderedPanelIds` so that divider drags and selection-only events
    /// (which also flow through `didChangeGeometry`) do not fire `objectWillChange`.
    @Published var paneLayoutVersion: Int = 0

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
    @Published var panelDirectories: [UUID: String] = [:]
    @Published var panelTitles: [UUID: String] = [:]
    @Published var panelCustomTitles: [UUID: String] = [:]
    @Published var pinnedPanelIds: Set<UUID> = []
    @Published var manualUnreadPanelIds: Set<UUID> = [] {
        didSet {
            guard manualUnreadPanelIds != oldValue else { return }
            syncPanelDerivedWorkspaceUnread()
        }
    }
    @Published var restoredUnreadPanelIndicators: [UUID: RestoredPanelUnreadIndicator] = [:] {
        didSet {
            guard restoredUnreadPanelIndicators != oldValue else { return }
            syncPanelDerivedWorkspaceUnread()
        }
    }
    var restoredUnreadPanelIds: Set<UUID> {
        Set(restoredUnreadPanelIndicators.keys)
    }
    @Published var tmuxLayoutSnapshot: LayoutSnapshot?
    @Published var tmuxWorkspaceFlashPanelId: UUID?
    @Published var tmuxWorkspaceFlashReason: WorkspaceAttentionFlashReason?
    @Published var tmuxWorkspaceFlashToken: UInt64 = 0
    var manualUnreadMarkedAt: [UUID: Date] = [:]
    @Published var statusEntries: [String: SidebarStatusEntry] = [:]
    @Published var metadataBlocks: [String: SidebarMetadataBlock] = [:]
    @Published var latestConversationMessage: String?
    @Published var latestSubmittedMessage: String?
    @Published var latestSubmittedAt: Date?
    @Published var logEntries: [SidebarLogEntry] = []
    @Published var progress: SidebarProgressState?
    @Published var gitBranch: SidebarGitBranchState?
    @Published var panelGitBranches: [UUID: SidebarGitBranchState] = [:]
    @Published var pullRequest: SidebarPullRequestState?
    @Published var panelPullRequests: [UUID: SidebarPullRequestState] = [:]
    @Published var surfaceListeningPorts: [UUID: [Int]] = [:]
    var agentListeningPorts: [Int] = []
    @Published var remoteConfiguration: WorkspaceRemoteConfiguration?
    @Published var remoteConnectionState: WorkspaceRemoteConnectionState = .disconnected
    @Published var remoteConnectionDetail: String?
    @Published var remoteDaemonStatus: WorkspaceRemoteDaemonStatus = WorkspaceRemoteDaemonStatus()
    @Published var remoteDetectedPorts: [Int] = []
    @Published var remoteForwardedPorts: [Int] = []
    @Published var remotePortConflicts: [Int] = []
    @Published var remoteProxyEndpoint: BrowserProxyEndpoint?
    @Published var remoteHeartbeatCount: Int = 0
    @Published var remoteLastHeartbeatAt: Date?
    @Published var listeningPorts: [Int] = []
    @Published var activeRemoteTerminalSessionCount: Int = 0
    var surfaceTTYNames: [UUID: String] = [:]
    var remoteSessionController: WorkspaceRemoteSessionController?
    var pendingRemoteForegroundAuthToken: String?
    var activeRemoteSessionControllerID: UUID?
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
    var pendingTerminalInputObserversByPanelId: [UUID: [WorkspacePendingTerminalInputObserver]] = [:]

    private func sidebarObservationSignal<Value: Equatable>(
        _ publisher: Published<Value>.Publisher
    ) -> AnyPublisher<Void, Never> {
        publisher
            .dropFirst()
            .removeDuplicates()
            .map { _ in () }
            .eraseToAnyPublisher()
    }

    lazy var sidebarImmediateObservationPublisher: AnyPublisher<Void, Never> = {
        let publishers: [AnyPublisher<Void, Never>] = [
            sidebarObservationSignal($title),
            sidebarObservationSignal($customDescription),
            sidebarObservationSignal($isPinned),
            sidebarObservationSignal($customColor),
            sidebarObservationSignal($latestConversationMessage),
            sidebarObservationSignal($latestSubmittedMessage),
            sidebarObservationSignal($latestSubmittedAt),
        ]

        return Publishers.MergeMany(publishers).eraseToAnyPublisher()
    }()

    lazy var sidebarObservationPublisher: AnyPublisher<Void, Never> = {
        let publishers: [AnyPublisher<Void, Never>] = [
            sidebarObservationSignal($currentDirectory),
            sidebarObservationSignal($extensionSidebarProjectRootPath),
            $panels
                .map(SidebarPanelObservationState.init)
                .dropFirst()
                .removeDuplicates()
                .map { _ in () }
                .eraseToAnyPublisher(),
            sidebarObservationSignal($panelDirectories),
            sidebarObservationSignal($statusEntries),
            sidebarObservationSignal($metadataBlocks),
            sidebarObservationSignal($logEntries),
            sidebarObservationSignal($progress),
            sidebarObservationSignal($gitBranch),
            sidebarObservationSignal($panelGitBranches),
            sidebarObservationSignal($pullRequest),
            sidebarObservationSignal($panelPullRequests),
            sidebarObservationSignal($remoteConfiguration),
            sidebarObservationSignal($remoteConnectionState),
            sidebarObservationSignal($remoteConnectionDetail),
            sidebarObservationSignal($activeRemoteTerminalSessionCount),
            sidebarObservationSignal($listeningPorts),
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

        // Forward shared agent-index refreshes as our own objectWillChange so the bonsplit
        // tab-bar re-evaluates the Fork Conversation availability the moment a background
        // refresh lands.
        sharedLiveAgentIndexCancellable = SharedLiveAgentIndex.shared.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    private var sharedLiveAgentIndexCancellable: AnyCancellable?

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

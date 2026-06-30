import CmuxSettingsUI
import AppKit
import CmuxRemoteSession
import CmuxCore
import CmuxAuthRuntime
import CmuxFeedback
import CmuxBrowser
import CmuxControlSocket
import CmuxFoundation
import CmuxPanes
import CmuxRemoteDaemon
import CmuxRemoteWorkspace
import CmuxTerminal
import CmuxSettings
import CmuxSwiftRenderUI
import Carbon.HIToolbox
import CMUXMobileCore
import CMUXAgentLaunch
import Foundation
import Bonsplit
import WebKit
import CmuxSidebar
import CmuxWorkspaces

extension Notification.Name {
    static let socketListenerDidStart = Notification.Name("cmux.socketListenerDidStart")
    // terminalSurfaceDidBecomeReady moved to CmuxTerminal (posted by TerminalSurface).
    static let terminalSurfaceHostedViewDidMoveToWindow = Notification.Name("cmux.terminalSurfaceHostedViewDidMoveToWindow")
    static let mainWindowContextsDidChange = Notification.Name("cmux.mainWindowContextsDidChange")
    static let browserDownloadEventDidArrive = Notification.Name("cmux.browserDownloadEventDidArrive")
    static let reactGrabDidCopySelection = Notification.Name("cmux.reactGrabDidCopySelection")
}

nonisolated private struct SocketLineProcessingResult: Sendable {
    let response: String?
    let authenticated: Bool
}

nonisolated private struct RemotePTYSocketTarget {
    let controller: RemoteSessionCoordinator?
    let windowId: UUID?
    let windowRef: Any
    let workspaceId: UUID
    let workspaceRef: Any
    let workspaceTitle: String
}

nonisolated func remotePTYSessionListErrorIsUnsupportedDaemon(_ error: Error) -> Bool {
    let nsError = error as NSError
    guard nsError.domain == "cmux.remote.daemon.rpc", nsError.code == 14 else {
        return false
    }
    return error.localizedDescription
        .range(of: "pty.list failed (method_not_found)", options: [.caseInsensitive]) != nil
}

nonisolated private func v2RemotePTYUserFacingErrorMessage(_ error: Error) -> String {
    v2RemotePTYUserFacingErrorMessage(error.localizedDescription)
}

nonisolated private func v2RemotePTYUserFacingErrorMessage(_ message: String) -> String {
    let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "remote PTY operation failed" }
    let lowered = trimmed.lowercased()
    if lowered.contains("missing required capability") ||
        lowered.contains("pty.session") ||
        lowered.contains("method_not_found") {
        return "remote daemon does not support persistent SSH PTY sessions; reconnect the remote workspace to update cmux"
    }
    if lowered.contains("pty_session_not_found") ||
        (lowered.contains("persistent ssh pty session") && lowered.contains("not running")) ||
        (lowered.contains("persistent pty session") && lowered.contains("not running")) {
        return "persistent SSH PTY session is no longer running"
    }
    if lowered.contains("pty_input_queue_full") || lowered.contains("pty input queue is full") {
        return "remote PTY input is temporarily backed up"
    }
    if lowered.contains("remote connection is not active") {
        return "remote connection is not active"
    }
    if lowered.contains("remote daemon is not ready") || lowered.contains("remote daemon tunnel is not ready") {
        return "remote daemon is not ready"
    }
    if lowered.contains("missing workspace_id in ssh pty session list response") {
        return "missing workspace_id in SSH PTY session list response"
    }
    if lowered.contains("missing session_id in ssh pty session list response") {
        return "missing session_id in SSH PTY session list response"
    }
    if lowered.contains("timed out") || lowered.contains("timeout") {
        return "remote daemon did not respond in time"
    }
    return "remote PTY operation failed"
}

/// Unix socket-based controller for programmatic terminal control
/// Allows automated testing and external control of terminal tabs
@MainActor
class TerminalController {
    static let shared = TerminalController()

    private nonisolated let remotePTYControllerAvailabilityCondition = NSCondition()
    private nonisolated(unsafe) var remotePTYControllerAvailabilityGeneration: UInt64 = 0
    var tabManager: TabManager?
    /// The shared auth coordinator + browser sign-in flow, injected once via
    /// `attachAuth` at app startup (AppDelegate `configure`) before the socket
    /// listener starts. Socket auth commands read these on the main actor.
    @MainActor private(set) var authCoordinator: AuthCoordinator?
    @MainActor private(set) var browserSignInFlow: HostBrowserSignInFlow?
    @MainActor var agentChatTranscriptService: AgentChatTranscriptService?
    // Sendable value type; injected at construction so socket auth never reaches a global.
    private nonisolated let passwordStore: SocketControlPasswordStore
    /// Process-wide proxy-tunnel broker (one shared tunnel per remote transport across all
    /// windows), constructed at this app-hub composition point and injected into each
    /// `WorkspaceRemoteSessionController`; ownership moves to the composition root with the
    /// planned `RemoteSessionCoordinator` wiring.
    nonisolated let remoteProxyBroker: any RemoteProxyBrokering
    // Stateless Sendable structs from CmuxControlSocket; injected at construction.
    // `transport` is internal so sibling-file extensions (CmuxEventStream) can write through it.
    nonisolated let transport: SocketTransport
    // The package-owned listener: path/bind/lock lifecycle, accept source,
    // backoff/rearm recovery, and the generation-counted state machine.
    nonisolated let socketServer: SocketControlServer
    // Accepted-connection consumer; runs until process exit (singleton).
    private nonisolated let socketConnectionsTask: Task<Void, Never>
    // Per-surface dedupe for high-frequency report_* socket telemetry. Main-
    // isolated: after the 3c cutover its only callers are the @MainActor
    // sidebar/surface seam conformances (the worker-thread fast path retired
    // with the legacy dispatcher), so the former `nonisolated` is gone. The
    // package type keeps its internal lock for its own tested contract.
    let socketFastPathState = SocketFastPathState()
    // Stateless sidebar-metadata/command argument parser (CmuxSidebar).
    // Pure transforms over the raw arg string; holds no state and reaches no
    // app singletons, so the `report_*`/sidebar-mutation handlers forward to it.
    private nonisolated let sidebarMetadataArgumentParser = SidebarMetadataArgumentParser()
    private nonisolated let myPid = getpid()
    private nonisolated static let socketCommandFocusAllowanceStackKey = "cmux.socketCommandFocusAllowanceStack"
    private nonisolated static let socketListenerFailureCaptureCooldown: TimeInterval = 60
    private nonisolated static let v2BrowserDownloadWaitDefaultTimeoutMs = 10_000
    private nonisolated static let v2BrowserDownloadWaitMaxTimeoutMs = 120_000
    private nonisolated static let socketListenerFailureCaptureLock = NSLock()
    private nonisolated(unsafe) static var socketListenerFailureLastCapturedAt: [String: Date] = [:]
    private struct MobileViewportReport {
        var columns: Int
        var rows: Int
        var updatedAt: Date
        /// Sticky reports come from the dedicated `mobile.terminal.viewport`
        /// RPC and live for the client's connection lifetime (cleared on
        /// disconnect or surface detach), so an idle paired device keeps its
        /// viewport border. Non-sticky reports piggyback on `terminal.input`
        /// and expire on the TTL so a client that only ever typed once does
        /// not pin the grid forever.
        var sticky: Bool = false
    }
    private static let mobileViewportReportTTL: TimeInterval = 5
    private var mobileViewportReportsBySurfaceID: [UUID: [String: MobileViewportReport]] = [:]
    private var mobileViewportReportCleanupTimersBySurfaceID: [UUID: DispatchSourceTimer] = [:]
#if DEBUG
    private nonisolated static let socketCommandDebugLogEnvironmentKey = "CMUX_DEBUG_SOCKET_COMMAND_LOG"
    private nonisolated static let socketCommandSlowThresholdMs: Double = 500
#endif
    static var terminalProcessExitedMessage: String {
        String(
            localized: "socket.terminal.processExited",
            defaultValue: "The terminal session has ended; reopen it or create a new terminal session."
        )
    }

    static var terminalInputQueueFullMessage: String {
        String(
            localized: "socket.terminal.inputQueueFull",
            defaultValue: "The terminal can't accept more input right now. Wait a moment and retry, or reopen the terminal if it stays unavailable."
        )
    }

    static var terminalSurfaceUnavailableMessage: String {
        String(
            localized: "socket.terminal.surfaceUnavailable",
            defaultValue: "The terminal surface is no longer available; reopen it or create a new terminal session."
        )
    }

    private static var terminalProcessExitedSocketError: String {
        "ERROR: \(terminalProcessExitedMessage)"
    }

    private static var terminalInputQueueFullSocketError: String {
        "ERROR: \(terminalInputQueueFullMessage)"
    }

    private static var terminalSurfaceUnavailableSocketError: String {
        "ERROR: \(terminalSurfaceUnavailableMessage)"
    }

    private nonisolated static let focusIntentV1Commands: Set<String> = [
        "focus_window",
        "select_workspace",
        "focus_surface",
        "focus_pane",
        "focus_surface_by_panel",
        "focus_webview",
        "focus_notification",
        "activate_app",
        "debug_right_sidebar_focus",
    ]

    private nonisolated static let focusIntentV2Methods: Set<String> = [
        "window.focus",
        "workspace.select",
        "workspace.next",
        "workspace.previous",
        "workspace.last",
        "workspace.group.focus",
        "surface.focus",
        "pane.focus",
        "pane.last",
        "file.open",
        "browser.focus_webview",
        "browser.focus",
        "browser.tab.switch",
        "notification.open",
        "notification.jump_to_unread",
        "debug.command_palette.toggle",
        "debug.notification.focus",
        "debug.app.activate",
        "debug.right_sidebar.focus",
        "feed.jump"
    ]

    /// The main-actor RPC dispatch coordinator (CmuxControlSocket). Owns the
    /// `kind:N` handle registry and the moved command domains (window so far,
    /// growing per stage-3c sub-stage); this controller is its interim
    /// composition owner and ``ControlCommandContext`` conformer. Constructed in
    /// `init`; its `context` is wired to `self` once `self` is available.
    let controlCommandCoordinator = ControlCommandCoordinator()

    private struct V2BrowserElementRefEntry {
        let surfaceId: UUID
        let selector: String
    }

    private struct V2BrowserPendingDialog {
        let type: String
        let message: String
        let defaultText: String?
        let responder: (_ accept: Bool, _ text: String?) -> Void
    }

    private final class V2BrowserUndefinedSentinel: Sendable {}

    private nonisolated static let v2BrowserEvalEnvelopeTypeKey = "__cmux_t"
    private nonisolated static let v2BrowserEvalEnvelopeValueKey = "__cmux_v"
    private nonisolated static let v2BrowserEvalEnvelopeTypeUndefined = "undefined"
    private nonisolated static let v2BrowserEvalEnvelopeTypeValue = "value"

    private var v2BrowserNextElementOrdinal: Int = 1
    private var v2BrowserElementRefs: [String: V2BrowserElementRefEntry] = [:]
    private var v2BrowserFrameSelectorBySurface: [UUID: String] = [:]
    private var v2BrowserInitScriptsBySurface: [UUID: [String]] = [:]
    private var v2BrowserInitStylesBySurface: [UUID: [String]] = [:]
    private var v2BrowserDialogQueueBySurface: [UUID: [V2BrowserPendingDialog]] = [:]
    private var v2BrowserDownloadEventsBySurface: [UUID: [[String: Any]]] = [:]
    private var v2BrowserUnsupportedNetworkRequestsBySurface: [UUID: [[String: Any]]] = [:]
    private nonisolated let v2BrowserUndefinedSentinel = V2BrowserUndefinedSentinel()
    /// Stateless browser-control logic (JS builders, value normalization,
    /// diagnostics, failure classification) extracted to `CmuxBrowser`.
    /// The per-surface mutable state and WebKit evaluation seam stay here.
    private nonisolated let v2BrowserControl = BrowserControlService(
        evalEnvelope: BrowserEvalEnvelope(
            typeKey: TerminalController.v2BrowserEvalEnvelopeTypeKey,
            valueKey: TerminalController.v2BrowserEvalEnvelopeValueKey,
            typeUndefined: TerminalController.v2BrowserEvalEnvelopeTypeUndefined,
            typeValue: TerminalController.v2BrowserEvalEnvelopeTypeValue
        )
    )
    private var browserDownloadObserver: NSObjectProtocol?

    func cleanupSurfaceState(surfaceIds: [UUID]) {
        for surfaceId in Set(surfaceIds) {
            v2BrowserFrameSelectorBySurface.removeValue(forKey: surfaceId)
            v2BrowserInitScriptsBySurface.removeValue(forKey: surfaceId)
            v2BrowserInitStylesBySurface.removeValue(forKey: surfaceId)
            v2BrowserDialogQueueBySurface.removeValue(forKey: surfaceId)
            v2BrowserDownloadEventsBySurface.removeValue(forKey: surfaceId)
            v2BrowserUnsupportedNetworkRequestsBySurface.removeValue(forKey: surfaceId)
            v2BrowserElementRefs = v2BrowserElementRefs.filter { $0.value.surfaceId != surfaceId }

            controlCommandCoordinator.removeRef(kind: .surface, uuid: surfaceId)
        }
    }

    /// Bridges the package server's event closures back to the controller.
    /// Assigned exactly once during `init`, before the listener can start, and
    /// read-only afterward; the controller is an app-lifetime singleton.
    private final class ServerEventTarget: @unchecked Sendable {
        weak var controller: TerminalController?
    }

    private init(
        passwordStore: SocketControlPasswordStore = SocketControlPasswordStore(),
        transport: SocketTransport = SocketTransport(),
        listenerPolicy: SocketListenerPolicy = SocketListenerPolicy(),
        remoteProxyBroker: any RemoteProxyBrokering = RemoteProxyBroker(
            tunnelProvider: RemoteDaemonProxyTunnelProvider(strings: .appLocalized, ptyBridgeStrings: AppRemotePTYBridgeStrings())
        )
    ) {
        self.passwordStore = passwordStore
        self.transport = transport
        self.remoteProxyBroker = remoteProxyBroker
        let serverEventTarget = ServerEventTarget()
        let socketServer = SocketControlServer(
            transport: transport,
            listenerPolicy: listenerPolicy,
            events: Self.makeSocketServerEvents(target: serverEventTarget)
        )
        self.socketServer = socketServer
        // Single consumer of the accepted-connection stream, detached so
        // accepts never funnel through the main actor. Each connection still
        // gets a dedicated thread: command bodies block (main-thread sync
        // hops, semaphore waits), so never the cooperative pool.
        self.socketConnectionsTask = Task.detached {
            for await connection in socketServer.connections {
                guard let controller = serverEventTarget.controller else {
                    close(connection.socket)
                    continue
                }
                controller.spawnClientHandler(socket: connection.socket, peerPid: connection.peerProcessID)
            }
        }
        serverEventTarget.controller = self
        controlCommandCoordinator.context = self
        browserDownloadObserver = NotificationCenter.default.addObserver(
            forName: .browserDownloadEventDidArrive,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let surfaceId = note.userInfo?["surfaceId"] as? UUID,
                  let event = note.userInfo?["event"] as? [String: Any] else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                var queue = self.v2BrowserDownloadEventsBySurface[surfaceId] ?? []
                queue.append(event)
                self.v2BrowserDownloadEventsBySurface[surfaceId] = queue
            }
        }
    }
    nonisolated func currentSocketPathForRemoteRestore() -> String? {
        socketServer.currentSocketPathForRemoteRestore()
    }

    @discardableResult
    func reserveStartupSocketPath(_ path: String) -> String {
        socketServer.reserveStartupSocketPath(path)
    }

    nonisolated func activeSocketPath(preferredPath: String) -> String {
        socketServer.activeSocketPath(preferredPath: preferredPath)
    }

    nonisolated static func shouldSuppressSocketCommandActivation() -> Bool {
        !currentSocketCommandFocusAllowanceStack().isEmpty
    }

    nonisolated static func socketCommandAllowsInAppFocusMutations() -> Bool {
        allowsInAppFocusMutationsForActiveSocketCommand()
    }

    private nonisolated static func allowsInAppFocusMutationsForActiveSocketCommand() -> Bool {
        currentSocketCommandFocusAllowanceStack().last ?? false
    }

    private func socketCommandAllowsInAppFocusMutations() -> Bool {
        Self.allowsInAppFocusMutationsForActiveSocketCommand()
    }

    func v2FocusAllowed(requested: Bool = true) -> Bool {
        requested && socketCommandAllowsInAppFocusMutations()
    }

    func v2MaybeFocusWindow(for tabManager: TabManager) {
        guard socketCommandAllowsInAppFocusMutations(),
              let windowId = v2ResolveWindowId(tabManager: tabManager) else { return }
        _ = AppDelegate.shared?.focusMainWindow(windowId: windowId)
        setActiveTabManager(tabManager)
    }

    func v2MaybeSelectWorkspace(_ tabManager: TabManager, workspace: Workspace) {
        guard socketCommandAllowsInAppFocusMutations() else { return }
        if tabManager.selectedTabId != workspace.id {
            tabManager.selectWorkspace(workspace)
        }
    }

    private nonisolated static func socketCommandAllowsInAppFocusMutations(commandKey: String, isV2: Bool, params: [String: Any] = [:]) -> Bool {
        if isV2 {
            return focusIntentV2Methods.contains(commandKey)
                || explicitFocusParamAllowsFocus(commandKey: commandKey, params: params)
        }
        if commandKey == "right_sidebar" {
            return rightSidebarCommandAllowsInAppFocusMutations(args: params["args"] as? String ?? "")
        }
        return focusIntentV1Commands.contains(commandKey)
    }

    private nonisolated static func rightSidebarCommandAllowsInAppFocusMutations(args: String) -> Bool {
        let parsed = RightSidebarRemoteRequest.parse(tokens: Self.tokenizeArgs(args))
        guard case .success(let request) = parsed else { return false }
        switch request.command {
        case .toggle, .show, .focus:
            return true
        case .setMode(_, let focus):
            return focus
        case .hide, .getState:
            return false
        }
    }

    nonisolated func withSocketCommandPolicy<T>(commandKey: String, isV2: Bool, params: [String: Any] = [:], _ body: () -> T) -> T {
        let allowsFocusMutation = Self.socketCommandAllowsInAppFocusMutations(commandKey: commandKey, isV2: isV2, params: params)
        var stack = Self.currentSocketCommandFocusAllowanceStack()
        stack.append(allowsFocusMutation)
        Self.setCurrentSocketCommandFocusAllowanceStack(stack)
        defer {
            var stack = Self.currentSocketCommandFocusAllowanceStack()
            if !stack.isEmpty {
                _ = stack.popLast()
            }
            Self.setCurrentSocketCommandFocusAllowanceStack(stack)
        }
        return body()
    }

    private nonisolated static func currentSocketCommandFocusAllowanceStack() -> [Bool] {
        Thread.current.threadDictionary[socketCommandFocusAllowanceStackKey] as? [Bool] ?? []
    }

    private nonisolated static func setCurrentSocketCommandFocusAllowanceStack(_ stack: [Bool]) {
        if stack.isEmpty {
            Thread.current.threadDictionary.removeObject(forKey: socketCommandFocusAllowanceStackKey)
        } else {
            Thread.current.threadDictionary[socketCommandFocusAllowanceStackKey] = stack
        }
    }

    private nonisolated static func withSocketCommandPolicyStack<T>(_ stack: [Bool], _ body: () -> T) -> T {
        let previous = currentSocketCommandFocusAllowanceStack()
        setCurrentSocketCommandFocusAllowanceStack(stack)
        defer { setCurrentSocketCommandFocusAllowanceStack(previous) }
        return body()
    }

#if DEBUG
    static func debugSocketCommandPolicySnapshot(
        commandKey: String,
        isV2: Bool,
        params: [String: Any] = [:]
    ) -> (insideSuppressed: Bool, insideAllowsFocus: Bool, outsideSuppressed: Bool, outsideAllowsFocus: Bool) {
        var insideSuppressed = false
        var insideAllowsFocus = false
        _ = Self.shared.withSocketCommandPolicy(commandKey: commandKey, isV2: isV2, params: params) {
            insideSuppressed = Self.shouldSuppressSocketCommandActivation()
            insideAllowsFocus = Self.socketCommandAllowsInAppFocusMutations()
            return 0
        }
        return (
            insideSuppressed: insideSuppressed,
            insideAllowsFocus: insideAllowsFocus,
            outsideSuppressed: Self.shouldSuppressSocketCommandActivation(),
            outsideAllowsFocus: Self.socketCommandAllowsInAppFocusMutations()
        )
    }

    static func debugNotifyTargetQueuedResponseForTesting(_ args: String) -> String {
        Self.shared.notifyTargetQueued(args)
    }
#endif

    nonisolated static func shouldReplaceStatusEntry(
        current: SidebarStatusEntry?,
        key: String,
        value: String,
        icon: String?,
        color: String?,
        url: URL?,
        priority: Int,
        format: SidebarMetadataFormat
    ) -> Bool {
        guard let current else { return true }
        return current.key != key ||
            current.value != value ||
            current.icon != icon ||
            current.color != color ||
            current.url != url ||
            current.priority != priority ||
            current.format != format
    }

    nonisolated static func shouldReplaceMetadataBlock(
        current: SidebarMetadataBlock?,
        key: String,
        markdown: String,
        priority: Int
    ) -> Bool {
        guard let current else { return true }
        return current.key != key || current.markdown != markdown || current.priority != priority
    }

    nonisolated static func shouldReplaceProgress(
        current: SidebarProgressState?,
        value: Double,
        label: String?
    ) -> Bool {
        guard let current else { return true }
        return current.value != value || current.label != label
    }

    nonisolated static func shouldReplaceGitBranch(
        current: SidebarGitBranchState?,
        branch: String,
        isDirty: Bool
    ) -> Bool {
        guard let current else { return true }
        return current.branch != branch || current.isDirty != isDirty
    }

    nonisolated static func shouldReplacePullRequest(
        current: SidebarPullRequestState?,
        number: Int,
        label: String,
        url: URL,
        status: SidebarPullRequestStatus,
        branch: String?
    ) -> Bool {
        guard let current else { return true }
        let normalizedBranch = branch?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveBranch: String? = {
            if let normalizedBranch, !normalizedBranch.isEmpty {
                return normalizedBranch
            }
            guard current.number == number,
                  current.label == label,
                  current.url == url,
                  current.status == status else {
                return nil
            }
            return current.branch
        }()
        return current.number != number
            || current.label != label
            || current.url != url
            || current.status != status
            || current.branch != effectiveBranch
            || current.isStale
    }

    nonisolated static func shouldReplacePorts(current: [Int]?, next: [Int]) -> Bool {
        let currentSorted = Array(Set(current ?? [])).sorted()
        let nextSorted = Array(Set(next)).sorted()
        return currentSorted != nextSorted
    }

    nonisolated static func explicitSocketScope(
        options: [String: String]
    ) -> (workspaceId: UUID, panelId: UUID)? {
        guard let tabRaw = options["tab"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !tabRaw.isEmpty,
              let panelRaw = (options["panel"] ?? options["surface"])?.trimmingCharacters(in: .whitespacesAndNewlines),
              !panelRaw.isEmpty,
              let workspaceId = UUID(uuidString: tabRaw),
              let panelId = UUID(uuidString: panelRaw) else {
            return nil
        }
        return (workspaceId, panelId)
    }

    nonisolated static func normalizeReportedDirectory(_ directory: String) -> String {
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return directory }
        if trimmed.hasPrefix("file://"), let url = URL(string: trimmed), !url.path.isEmpty {
            return url.path
        }
        return trimmed
    }

    nonisolated static func normalizedExportedScreenPath(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed),
           url.isFileURL,
           !url.path.isEmpty {
            return url.path
        }
        return trimmed.hasPrefix("/") ? trimmed : nil
    }

    nonisolated static func shouldRemoveExportedScreenFile(
        fileURL: URL,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> Bool {
        let standardizedFile = fileURL.standardizedFileURL
        let temporary = temporaryDirectory.standardizedFileURL
        return standardizedFile.path.hasPrefix(temporary.path + "/")
    }

    nonisolated static func shouldRemoveExportedScreenDirectory(
        fileURL: URL,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> Bool {
        let directory = fileURL.deletingLastPathComponent().standardizedFileURL
        let temporary = temporaryDirectory.standardizedFileURL
        return directory.path.hasPrefix(temporary.path + "/")
    }

    nonisolated static func normalizedMobileVTExportText(_ text: String) -> String {
        // Ghostty's VT formatter writes row separators as CRLF. Swift treats
        // CRLF as one Character, so split(separator: "\n") would miss rows.
        text.replacingOccurrences(of: "\r\n", with: "\n")
    }

    nonisolated static func parseReportedShellActivityState(
        _ rawState: String
    ) -> PanelShellActivityState? {
        switch rawState.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "prompt", "idle":
            return .promptIdle
        case "running", "busy", "command":
            return .commandRunning
        case "unknown", "clear":
            return .unknown
        default:
            return nil
        }
    }

    nonisolated static func parseRemotePortScanKickReason(
        _ rawReason: String
    ) -> PortScanKickReason? {
        switch rawReason.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "command", "running", "foreground", "start":
            return .command
        case "refresh", "prompt", "idle":
            return .refresh
        default:
            return nil
        }
    }

    /// Update which window's TabManager receives socket commands.
    /// This is used when the user switches between multiple terminal windows.
    func setActiveTabManager(_ tabManager: TabManager?) {
        if let tabManager {
            AppDelegate.shared?.ensureMobileWorkspaceListObserver(for: tabManager)
        }
        self.tabManager = tabManager
    }

    func activeTabManagerForCallerNotification() -> TabManager? { tabManager }

    // MARK: - Process Ancestry Check

    /// Check if `pid` is a descendant of this process by walking the process tree.
    nonisolated func isDescendant(_ pid: pid_t) -> Bool {
        transport.isProcessDescendant(pid, of: myPid)
    }

    private nonisolated static func shouldCaptureSocketListenerFailure(
        message: String,
        stage: String,
        path: String,
        errnoCode: Int32?
    ) -> Bool {
        let key = "\(message)|\(stage)|\(path)|\(errnoCode.map(String.init) ?? "none")"
        let now = Date()
        socketListenerFailureCaptureLock.lock()
        defer { socketListenerFailureCaptureLock.unlock() }
        if let lastCapturedAt = socketListenerFailureLastCapturedAt[key],
           now.timeIntervalSince(lastCapturedAt) < socketListenerFailureCaptureCooldown {
            return false
        }
        socketListenerFailureLastCapturedAt[key] = now
        return true
    }

    /// Builds the package server's host-callback seam. `target` is filled in
    /// at the end of `init`; no listener event can fire before `start`.
    private nonisolated static func makeSocketServerEvents(
        target: ServerEventTarget
    ) -> SocketControlServerEvents {
        SocketControlServerEvents(
            breadcrumb: { message, data in
                sentryBreadcrumb(message, category: "socket", data: data)
            },
            failure: { message, stage, errnoCode, data in
                sentryBreadcrumb(message, category: "socket", data: data)
                guard shouldCaptureSocketListenerFailure(
                    message: message,
                    stage: stage,
                    path: data["path"] as? String ?? "",
                    errnoCode: errnoCode
                ) else {
                    return
                }
                sentryCaptureError(message, category: "socket", data: data, contextKey: "socket_listener")
            },
            listenerDidStart: { path, _ in
                // @MainActor closure, invoked synchronously inside start().
                target.controller?.socketListenerDidStart(path: path)
            },
            recordLastSocketPath: { path in
                SocketControlSettings.recordLastSocketPath(path)
            },
            pathMissingDetected: { path, generation in
                Task { @MainActor in
                    target.controller?.restartSocketListenerIfPathMissing(path: path, generation: generation)
                }
            },
            rearmRequested: { generation, errnoCode, consecutiveFailures, delayMs in
                target.controller?.scheduleListenerRearm(
                    generation: generation,
                    errnoCode: errnoCode,
                    consecutiveFailures: consecutiveFailures,
                    delayMs: delayMs
                )
            }
        )
    }

    /// Inject the auth graph. Call once at the composition root, before the
    /// socket listener accepts auth commands.
    @MainActor
    func attachAuth(coordinator: AuthCoordinator, browserSignIn: HostBrowserSignInFlow) {
        self.authCoordinator = coordinator
        self.browserSignInFlow = browserSignIn
    }


    func start(
        tabManager: TabManager,
        socketPath: String,
        accessMode: SocketControlMode,
        preserveAcceptFailureStreak: Bool = false
    ) {
        self.tabManager = tabManager
        socketServer.start(
            socketPath: socketPath,
            accessMode: accessMode,
            preserveAcceptFailureStreak: preserveAcceptFailureStreak
        )
    }

    /// Invoked synchronously inside the server's `start()` on the main
    /// actor, at the exact lifecycle point the legacy implementation posted
    /// `.socketListenerDidStart`.
    private func socketListenerDidStart(path: String) {
        NotificationCenter.default.post(
            name: .socketListenerDidStart,
            object: self,
            userInfo: ["path": path]
        )

        // Wire batched port scanner results back to workspace state.
        PortScanner.shared.onPortsUpdated = { [weak self] workspaceId, panelId, ports in
            guard let self, let tabManager = self.tabManager else { return }
            guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) else { return }
            let validSurfaceIds = Set(workspace.panels.keys)
            guard validSurfaceIds.contains(panelId) else { return }
            workspace.surfaceListeningPorts[panelId] = ports.isEmpty ? nil : ports
            workspace.recomputeListeningPorts()
        }
        PortScanner.shared.onAgentPortsUpdated = { [weak self] workspaceId, ports in
            guard let self, let tabManager = self.tabManager else { return false }
            guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) else { return false }
            if workspace.agentListeningPorts != ports {
                workspace.agentListeningPorts = ports
                workspace.recomputeListeningPorts()
            }
            return true
        }
        PortScanner.shared.agentPIDsProvider = { [weak self] workspaceIds in
            guard let self, let tabManager = self.tabManager else { return [:] }
            var pidsByWorkspace: [UUID: Set<Int>] = [:]
            for workspaceId in workspaceIds {
                guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) else { continue }
                let pids = Set(workspace.agentPIDs.values.compactMap { $0 > 0 ? Int($0) : nil })
                if !pids.isEmpty {
                    pidsByWorkspace[workspaceId] = pids
                }
            }
            return pidsByWorkspace
        }
        PortScanner.shared.setTrackedAgentScanningPaused(!NSApplication.shared.isActive)
    }

    nonisolated func socketListenerHealth(expectedSocketPath: String) -> SocketListenerHealth {
        socketServer.listenerHealth(expectedSocketPath: expectedSocketPath)
    }

    private func restartSocketListenerIfPathMissing(path: String, generation: UInt64) {
        guard let tabManager else { return }
        let restartMode = socketServer.accessMode
        guard socketServer.shouldRestartForMissingPath(path: path, generation: generation) else { return }

        sentryBreadcrumb(
            "socket.listener.restart",
            category: "socket",
            data: [
                "mode": restartMode.rawValue,
                "path": path,
                "source": "path_monitor",
                "generation": generation
            ]
        )
        stop()
        start(tabManager: tabManager, socketPath: path, accessMode: restartMode)
    }

    func stop() {
        // Synchronous by contract: termination needs the unlink before exit.
        socketServer.stop()
    }

    private nonisolated func writeSocketResponse(_ response: String, to socket: Int32) -> Bool {
        let payload = response + "\n"
        return transport.writeAll(Data(payload.utf8), to: socket)
    }

    private nonisolated func passwordAuthRequiredResponse(for command: String) -> String {
        let message = "Authentication required. Send auth <password> first."
        guard command.hasPrefix("{"),
              let data = command.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else {
            return "ERROR: Authentication required — send auth <password> first"
        }
        let id = dict["id"]
        return v2Error(id: id, code: "auth_required", message: message)
    }

    private nonisolated func passwordLoginV1ResponseIfNeeded(for command: String, authenticated: inout Bool) -> String? {
        let lowered = command.lowercased()
        guard lowered == "auth" || lowered.hasPrefix("auth ") else {
            return nil
        }
        guard passwordStore.hasConfiguredPassword(allowLazyKeychainFallback: true) else {
            return "ERROR: Password mode is enabled but no socket password is configured in Settings."
        }

        let provided: String
        if lowered == "auth" {
            provided = ""
        } else {
            provided = String(command.dropFirst(5))
        }
        guard !provided.isEmpty else {
            return "ERROR: Missing password. Usage: auth <password>"
        }
        guard passwordStore.verify(password: provided, allowLazyKeychainFallback: true) else {
            return "ERROR: Invalid password"
        }
        authenticated = true
        return "OK: Authenticated"
    }

    private nonisolated func passwordLoginV2ResponseIfNeeded(for command: String, authenticated: inout Bool) -> String? {
        guard command.hasPrefix("{"),
              let data = command.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else {
            return nil
        }
        let id = dict["id"]
        let method = (dict["method"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard method == "auth.login" else {
            return nil
        }

        guard let params = dict["params"] as? [String: Any],
              let provided = params["password"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "auth.login requires params.password")
        }

        guard passwordStore.hasConfiguredPassword(allowLazyKeychainFallback: true) else {
            return v2Error(
                id: id,
                code: "auth_unconfigured",
                message: "Password mode is enabled but no socket password is configured in Settings."
            )
        }

        guard passwordStore.verify(password: provided, allowLazyKeychainFallback: true) else {
            return v2Error(id: id, code: "auth_failed", message: "Invalid password")
        }
        authenticated = true
        return v2Ok(id: id, result: ["authenticated": true])
    }

    private nonisolated func authResponseIfNeeded(for command: String, authenticated: inout Bool) -> String? {
        guard socketServer.accessMode.requiresPasswordAuth else {
            return nil
        }
        if let v2Response = passwordLoginV2ResponseIfNeeded(for: command, authenticated: &authenticated) {
            return v2Response
        }
        if let v1Response = passwordLoginV1ResponseIfNeeded(for: command, authenticated: &authenticated) {
            return v1Response
        }
        if !authenticated {
            return passwordAuthRequiredResponse(for: command)
        }
        return nil
    }

    /// Interim bridged view of a decoded `ControlRequest` with Foundation
    /// (`Any`) field shapes, so the existing command bodies keep their
    /// `[String: Any]` params until they migrate onto the typed DTOs in the
    /// ControlCommandCoordinator stage.
    private struct V2SocketRequest {
        let id: Any?
        let method: String
        let params: [String: Any]

        init(bridging request: ControlRequest) {
            id = request.id.map(\.foundationObject)
            method = request.method
            params = request.params.mapValues { $0.foundationObject }
        }
    }

    /// Wire-protocol helpers (parse/encode) shared with the package;
    /// stateless, so single instances serve every thread.
    private nonisolated static let v2Parser = ControlRequestParser()
    private nonisolated static let v2Encoder = ControlResponseEncoder()

    private nonisolated static func executionPolicy(forV2Method method: String) -> ControlCommandExecutionPolicy {
        ControlCommandExecutionPolicy(forMethod: method)
    }

    private nonisolated func parseV2SocketRequest(_ command: String) -> V2SocketRequest? {
        guard let request = Self.v2Parser.lenientRequest(fromLine: command) else {
            return nil
        }
        return V2SocketRequest(bridging: request)
    }

    private nonisolated func socketWorkerV2ResponseIfHandled(for command: String) -> (handled: Bool, response: String?) {
        guard let request = parseV2SocketRequest(command),
              Self.executionPolicy(forV2Method: request.method).runsOnSocketWorker else {
            return (false, nil)
        }

        return withSocketCommandPolicy(commandKey: request.method, isV2: true, params: request.params) {
            if let workspaceParamError = v2UnsupportedWorkspaceAliasError(method: request.method, params: request.params) {
                return (true, v2Result(id: request.id, workspaceParamError))
            }
            if request.method == "feed.push", request.id == nil {
                guard let waitTimeout = Self.feedPushWaitTimeoutSeconds(params: request.params) else {
                    return (true, v2Error(
                        id: request.id,
                        code: "invalid_params",
                        message: "feed.push wait_timeout_seconds must be numeric and between 0 and 120"
                    ))
                }
                guard waitTimeout == 0 else {
                    return (true, v2Error(
                        id: request.id,
                        code: "invalid_params",
                        message: "feed.push without an id requires wait_timeout_seconds 0"
                    ))
                }
                _ = socketWorkerV2Response(request)
                return (true, nil)
            }
            return (true, socketWorkerV2Response(request))
        }
    }

    private nonisolated static func feedPushWaitTimeoutSeconds(params: [String: Any]) -> TimeInterval? {
        guard let rawTimeout = params["wait_timeout_seconds"] else {
            return 0
        }
        let seconds: Double?
        if let number = rawTimeout as? NSNumber {
            seconds = number.doubleValue
        } else if let value = rawTimeout as? Double {
            seconds = value
        } else if let value = rawTimeout as? Int {
            seconds = Double(value)
        } else {
            seconds = nil
        }
        guard let seconds, seconds.isFinite, seconds >= 0, seconds <= 120 else {
            return nil
        }
        return seconds
    }

    private nonisolated func socketWorkerV2Response(_ request: V2SocketRequest) -> String {
        switch request.method {
        case "auth.status":
            let semaphore = DispatchSemaphore(value: 0)
            Task { @MainActor [weak self] in
                await self?.authCoordinator?.awaitBootstrapped()
                semaphore.signal()
            }
            semaphore.wait()
            return v2Ok(id: request.id, result: v2AuthStatusPayload(timedOut: false))
        case "auth.sign_in_url":
            var signInURL: String?
            v2MainSync {
                MainActor.assumeIsolated {
                    signInURL = self.browserSignInFlow?.manualSignInURL.absoluteString
                }
            }
            var result: [String: Any] = [:]
            if let signInURL {
                result["url"] = signInURL
            }
            return v2Ok(id: request.id, result: result)
        case "auth.begin_sign_in":
            let timeoutSeconds = (request.params["timeout_seconds"] as? Double) ?? 300
            let semaphore = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var signedIn = false
            Task { @MainActor [weak self] in
                signedIn = await self?.browserSignInFlow?.signIn(
                    timeout: timeoutSeconds
                ) ?? false
                semaphore.signal()
            }
            semaphore.wait()
            return v2Ok(id: request.id, result: v2AuthStatusPayload(timedOut: !signedIn))
        case "auth.sign_out":
            let semaphore = DispatchSemaphore(value: 0)
            Task { @MainActor [weak self] in
                await self?.browserSignInFlow?.signOut(timeout: 5)
                semaphore.signal()
            }
            semaphore.wait()
            return v2Ok(id: request.id, result: v2AuthStatusPayload(timedOut: false))
        case "feedback.submit":
            return v2Result(id: request.id, v2FeedbackSubmit(params: request.params))
        case "feed.push":
            return v2Result(id: request.id, v2FeedPush(params: request.params))
        case "feed.permission.reply":
            return v2Result(id: request.id, v2FeedPermissionReply(params: request.params))
        case "feed.question.reply":
            return v2Result(id: request.id, v2FeedQuestionReply(params: request.params))
        case "feed.exit_plan.reply":
            return v2Result(id: request.id, v2FeedExitPlanReply(params: request.params))
        case "browser.download.wait":
            return v2Result(id: request.id, v2BrowserDownloadWaitOnSocketWorker(params: request.params))
        case "browser.navigate", "browser.back", "browser.forward", "browser.reload",
             "browser.snapshot", "browser.eval", "browser.wait", "browser.screenshot",
             "browser.click", "browser.dblclick", "browser.hover", "browser.focus",
             "browser.type", "browser.fill", "browser.press", "browser.keydown", "browser.keyup",
             "browser.check", "browser.uncheck", "browser.select", "browser.scroll",
             "browser.scroll_into_view",
             "browser.get.text", "browser.get.html", "browser.get.value", "browser.get.attr",
             "browser.get.count", "browser.get.box", "browser.get.styles",
             "browser.is.visible", "browser.is.enabled", "browser.is.checked",
             "browser.find.role", "browser.find.text", "browser.find.label",
             "browser.find.placeholder", "browser.find.alt", "browser.find.title",
             "browser.find.testid", "browser.find.first", "browser.find.last", "browser.find.nth",
             "browser.highlight",
             "browser.frame.select",
             "browser.dialog.accept", "browser.dialog.dismiss",
             "browser.cookies.get", "browser.cookies.set", "browser.cookies.clear",
             "browser.storage.get", "browser.storage.set", "browser.storage.clear",
             "browser.console.list", "browser.console.clear", "browser.errors.list",
             "browser.state.save", "browser.state.load",
             "browser.addinitscript", "browser.addscript", "browser.addstyle":
            // Keep ref payloads fresh like the main-actor dispatch path does.
            v2MainSync { self.v2RefreshKnownRefs() }
            return v2Result(id: request.id, v2BrowserAutomationCommandOnSocketWorker(method: request.method, params: request.params))
        case "browser.profiles.list":
            return v2VmCall(id: request.id, timeoutSeconds: 30) {
                try await BrowserProfileAutomation.list(params: request.params)
            }
        case "browser.profiles.create":
            return v2VmCall(id: request.id, timeoutSeconds: 30) {
                try await BrowserProfileAutomation.create(params: request.params)
            }
        case "browser.profiles.rename":
            return v2VmCall(id: request.id, timeoutSeconds: 30) {
                try await BrowserProfileAutomation.rename(params: request.params)
            }
        case "browser.profiles.clear":
            return v2VmCall(id: request.id, timeoutSeconds: 120) {
                try await BrowserProfileAutomation.clear(params: request.params)
            }
        case "browser.profiles.delete":
            return v2VmCall(id: request.id, timeoutSeconds: 120) {
                try await BrowserProfileAutomation.delete(params: request.params)
            }
        case "browser.import.cookies":
            return v2VmCall(id: request.id, timeoutSeconds: 10 * 60) {
                let outcome = try await BrowserImportAutomation.importCookies(params: request.params)
                return outcome.socketPayload
            }
        case "mobile.attach_ticket.create":
            return v2AsyncResultCall(id: request.id, timeoutSeconds: 30) {
                await self.v2MobileAttachTicketCreate(params: request.params)
            }
        case "mobile.terminal.set_font":
            return v2Result(id: request.id, v2MobileTerminalSetFont(params: request.params))
        case "system.ping":
            return v2Ok(id: request.id, result: ["pong": true])
        case "system.capabilities":
            return v2Ok(id: request.id, result: v2Capabilities())
        case "collaboration.status":
            return v2AsyncResultCall(id: request.id, timeoutSeconds: 5) {
                let payload = await CollaborationRuntime.shared.statusPayload()
                return .ok(payload)
            }
        case "collaboration.session.create":
            let relayURL = request.params["relay_url"] as? String
            return v2AsyncResultCall(id: request.id, timeoutSeconds: 30) {
                let payload = await CollaborationRuntime.shared.createSessionForAutomation(relayURL: relayURL)
                return .ok(payload)
            }
        case "collaboration.session.join":
            guard let code = request.params["session_code"] as? String,
                  let token = request.params["invite_token"] as? String else {
                return v2Result(
                    id: request.id,
                    .err(
                        code: "invalid_params",
                        message: "collaboration.session.join requires session_code and invite_token",
                        data: nil
                    )
                )
            }
            let relayURL = request.params["relay_url"] as? String
            return v2AsyncResultCall(id: request.id, timeoutSeconds: 15) {
                let payload = await CollaborationRuntime.shared.joinSessionForAutomation(
                    relayURL: relayURL,
                    code: code,
                    token: token
                )
                return .ok(payload)
            }
        case "collaboration.session.leave":
            return v2AsyncResultCall(id: request.id, timeoutSeconds: 5) {
                let payload = await CollaborationRuntime.shared.leaveSessionForAutomation()
                return .ok(payload)
            }
        case "system.top":
            return v2Result(id: request.id, v2SystemTop(params: request.params))
        case "system.memory":
            return v2Result(id: request.id, v2SystemMemory(params: request.params))
        case "workspace.env":
            return v2Result(id: request.id, v2WorkspaceEnv(params: request.params))
        case "workspace.remote.pty_sessions":
            return v2Result(id: request.id, v2WorkspaceRemotePTYSessions(params: request.params))
        case "workspace.remote.pty_close":
            return v2Result(id: request.id, v2WorkspaceRemotePTYClose(params: request.params))
        case "workspace.remote.pty_detach":
            return v2Result(id: request.id, v2WorkspaceRemotePTYDetach(params: request.params))
        case "workspace.remote.pty_bridge":
            return v2Result(id: request.id, v2WorkspaceRemotePTYBridge(params: request.params))
        case "workspace.remote.pty_resize":
            return v2Result(id: request.id, v2WorkspaceRemotePTYResize(params: request.params))
        case "remote.tmux.sessions":
            return v2RemoteTmuxSessions(id: request.id, params: request.params)
        case "remote.tmux.attach":
            return v2RemoteTmuxAttach(id: request.id, params: request.params)
        case "remote.tmux.detach":
            return v2RemoteTmuxDetach(id: request.id, params: request.params)
        case "remote.tmux.state":
            return v2RemoteTmuxState(id: request.id, params: request.params)
        case "remote.tmux.mirror":
            return v2RemoteTmuxMirror(id: request.id, params: request.params)
        case "remote.tmux.window":
            return v2RemoteTmuxWindow(id: request.id, params: request.params)
        case "sidebar.custom.validate":
            return v2Result(id: request.id, v2CustomSidebarValidate(params: request.params))
        case "sidebar.custom.reload":
            return v2Result(id: request.id, v2CustomSidebarReload(params: request.params))
        case "sidebar.custom.select":
            return v2Result(id: request.id, v2CustomSidebarSelect(params: request.params))
        case "sidebar.custom.open":
            return v2Result(id: request.id, v2CustomSidebarOpen(params: request.params))
#if DEBUG
        case "debug.sidebar.simulate_drag":
            return v2Result(id: request.id, v2DebugSidebarSimulateDrag(params: request.params))
#endif
        case let method where method.hasPrefix("vm."):
            return socketWorkerCloudVMResponse(method: method, id: request.id, params: request.params)
        case let method where method.hasPrefix("remotes."):
            return socketWorkerRemotesResponse(method: method, id: request.id, params: request.params)
        default:
            return v2Error(id: request.id, code: "method_not_found", message: "Unknown method")
        }
    }

    private nonisolated func spawnClientHandler(socket clientSocket: Int32, peerPid: pid_t?) {
        Thread.detachNewThread { [weak self] in
            guard let self else {
                close(clientSocket)
                return
            }
            self.handleClient(clientSocket, peerPid: peerPid)
        }
    }

    private nonisolated func scheduleListenerRearm(
        generation: UInt64,
        errnoCode: Int32,
        consecutiveFailures: Int,
        delayMs: Int
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Bounded rearm delay on the server's injected recovery clock
            // (replaces the legacy main-queue asyncAfter); a stale fire is a
            // no-op via the pending-rearm generation guard in the claim.
            try? await self.socketServer.recoveryClock.sleep(forMilliseconds: delayMs)
            guard let tabManager = self.tabManager else { return }
            guard let restartPath = self.socketServer.claimPendingRearm(
                generation: generation,
                errnoCode: errnoCode,
                consecutiveFailures: consecutiveFailures,
                delayMs: delayMs
            ) else { return }

            let restartMode = self.socketServer.accessMode

            self.stop()
            self.start(
                tabManager: tabManager,
                socketPath: restartPath,
                accessMode: restartMode,
                preserveAcceptFailureStreak: true
            )
        }
    }

    private nonisolated func handleClient(_ socket: Int32, peerPid: pid_t? = nil) {
        defer { close(socket) }

        // In cmuxOnly mode, verify the connecting process is a descendant of cmux.
        // In allowAll mode (env-var only), skip the ancestry check.
        if socketServer.accessMode == .cmuxOnly {
            // Use pre-captured peer PID if available (captured in accept loop before
            // the peer can disconnect), falling back to live lookup.
            let pid = peerPid ?? transport.peerProcessID(of: socket)
            if let pid {
                guard isDescendant(pid) else {
                    _ = writeSocketResponse(
                        "ERROR: Access denied — only processes started inside cmux can connect",
                        to: socket
                    )
                    return
                }
            }
            // If pid is nil, LOCAL_PEERPID failed (peer disconnected before we
            // could read it — common with ncat --send-only). We still verify the
            // peer runs as the same user via LOCAL_PEERCRED. This is the same
            // security boundary as the socket file permissions (0600), so it does
            // not widen the attack surface. We also require that the peer actually
            // sent data (checked in the read loop below) — a connect-only probe
            // with no data is harmless.
            if pid == nil {
                guard transport.peerHasSameUID(socket) else {
                    _ = writeSocketResponse(
                        "ERROR: Unable to verify client process",
                        to: socket
                    )
                    return
                }
            }
        }

        var authenticated = false
        let lineReader = ControlClientLineReader(socket: socket)

        while let line = lineReader.nextLine(shouldContinueReading: { socketServer.isRunning }) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            var shouldCloseSocket = false
            autoreleasepool {
                if isEventsStreamRequest(trimmed) {
                    if let response = authResponseIfNeeded(for: trimmed, authenticated: &authenticated) {
                        if !writeSocketResponse(response, to: socket) {
                            shouldCloseSocket = true
                        }
                        return
                    }
                    handleEventsStreamRequest(trimmed, socket: socket)
                    shouldCloseSocket = true
                    return
                }

                let result = processSocketLine(trimmed, authenticated: authenticated)
                authenticated = result.authenticated
                if let response = result.response {
                    let didWriteResponse = writeSocketResponse(response, to: socket)
                    publishSocketEvents(command: trimmed, response: response)
                    if !didWriteResponse {
                        shouldCloseSocket = true
                    }
                }
            }
            if shouldCloseSocket {
                return
            }
        }
    }

    private nonisolated func processSocketLine(
        _ command: String,
        authenticated: Bool
    ) -> SocketLineProcessingResult {
#if DEBUG
        let debugInfo = Self.socketCommandDebugInfo(command)
        let debugStart = DispatchTime.now().uptimeNanoseconds
        let debugLoggingEnabled = Self.socketCommandDebugLoggingEnabled()
        if debugLoggingEnabled {
            Self.debugLogSocketCommand(
                "socket.command.begin proto=\(debugInfo.protocolName) method=\(debugInfo.commandKey)"
            )
        }
#endif
        var nextAuthenticated = authenticated
        if let response = authResponseIfNeeded(for: command, authenticated: &nextAuthenticated) {
#if DEBUG
            Self.debugLogSocketCommandEndIfNeeded(
                debugInfo: debugInfo,
                startedAt: debugStart,
                response: response,
                loggingEnabled: debugLoggingEnabled
            )
#endif
            return SocketLineProcessingResult(response: response, authenticated: nextAuthenticated)
        }

        let response = processCommandUsingSocketExecutionPolicy(command)
#if DEBUG
        if let response {
            Self.debugLogSocketCommandEndIfNeeded(
                debugInfo: debugInfo,
                startedAt: debugStart,
                response: response,
                loggingEnabled: debugLoggingEnabled
            )
        }
#endif
        return SocketLineProcessingResult(response: response, authenticated: nextAuthenticated)
    }

#if DEBUG
    private struct SocketCommandDebugInfo {
        let protocolName: String
        let commandKey: String
    }

    private nonisolated static func socketCommandDebugLoggingEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard let rawValue = environment[socketCommandDebugLogEnvironmentKey] else {
            return false
        }
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            return true
        default:
            return false
        }
    }

    private nonisolated static func socketCommandDebugInfo(_ command: String) -> SocketCommandDebugInfo {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"),
              let data = trimmed.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any],
              let method = dict["method"] as? String else {
            let commandKey = trimmed.split(separator: " ", maxSplits: 1).first.map(String.init) ?? "<empty>"
            return SocketCommandDebugInfo(protocolName: "v1", commandKey: sanitizedSocketDebugToken(commandKey))
        }
        return SocketCommandDebugInfo(protocolName: "v2", commandKey: sanitizedSocketDebugToken(method))
    }

    private nonisolated static func sanitizedSocketDebugToken(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-:")
        let scalars = trimmed.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "_"
        }
        let sanitized = String(scalars).prefix(96)
        return sanitized.isEmpty ? "<empty>" : String(sanitized)
    }

    private nonisolated static func socketCommandDebugStatus(response: String) -> String {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("ERROR:") {
            return "error"
        }
        if trimmed.hasPrefix("{") {
            let prefix = trimmed.prefix(4096)
            if topLevelJSONResponseStatus(in: prefix) == "error" {
                return "error"
            }
        }
        return "ok"
    }

    private nonisolated static func topLevelJSONResponseStatus(in text: Substring) -> String? {
        var index = text.startIndex
        skipJSONWhitespace(in: text, index: &index)
        guard index < text.endIndex, text[index] == "{" else { return nil }
        index = text.index(after: index)

        while index < text.endIndex {
            skipJSONWhitespace(in: text, index: &index)
            if index >= text.endIndex { return nil }
            if text[index] == "}" { return nil }
            if text[index] == "," {
                index = text.index(after: index)
                continue
            }
            guard text[index] == "\"",
                  let key = scanJSONString(in: text, index: &index) else {
                return nil
            }
            skipJSONWhitespace(in: text, index: &index)
            guard index < text.endIndex, text[index] == ":" else { return nil }
            index = text.index(after: index)
            skipJSONWhitespace(in: text, index: &index)

            if key == "error" {
                return "error"
            }
            if key == "ok" {
                if text[index...].hasPrefix("false") {
                    return "error"
                }
                if text[index...].hasPrefix("true") {
                    return "ok"
                }
            }
            guard skipJSONValue(in: text, index: &index) else {
                return nil
            }
        }
        return nil
    }

    private nonisolated static func scanJSONString(in text: Substring, index: inout String.Index) -> String? {
        guard index < text.endIndex, text[index] == "\"" else { return nil }
        index = text.index(after: index)
        var result = ""
        var isEscaped = false
        while index < text.endIndex {
            let char = text[index]
            index = text.index(after: index)
            if isEscaped {
                result.append(char)
                isEscaped = false
                continue
            }
            if char == "\\" {
                isEscaped = true
                continue
            }
            if char == "\"" {
                return result
            }
            result.append(char)
        }
        return nil
    }

    private nonisolated static func skipJSONValue(in text: Substring, index: inout String.Index) -> Bool {
        guard index < text.endIndex else { return false }
        switch text[index] {
        case "\"":
            return scanJSONString(in: text, index: &index) != nil
        case "{", "[":
            return skipJSONContainer(in: text, index: &index)
        default:
            while index < text.endIndex {
                switch text[index] {
                case ",", "}":
                    return true
                default:
                    index = text.index(after: index)
                }
            }
            return true
        }
    }

    private nonisolated static func skipJSONContainer(in text: Substring, index: inout String.Index) -> Bool {
        guard index < text.endIndex else { return false }
        let opener = text[index]
        let closer: Character = opener == "{" ? "}" : "]"
        var depth = 1
        index = text.index(after: index)
        var isInString = false
        var isEscaped = false
        while index < text.endIndex {
            let char = text[index]
            index = text.index(after: index)
            if isInString {
                if isEscaped {
                    isEscaped = false
                } else if char == "\\" {
                    isEscaped = true
                } else if char == "\"" {
                    isInString = false
                }
                continue
            }
            if char == "\"" {
                isInString = true
            } else if char == opener {
                depth += 1
            } else if char == closer {
                depth -= 1
                if depth == 0 {
                    return true
                }
            }
        }
        return false
    }

    private nonisolated static func skipJSONWhitespace(in text: Substring, index: inout String.Index) {
        while index < text.endIndex {
            switch text[index] {
            case " ", "\t", "\n", "\r":
                index = text.index(after: index)
            default:
                return
            }
        }
    }

    private nonisolated static func debugLogSocketCommandEndIfNeeded(
        debugInfo: SocketCommandDebugInfo,
        startedAt: UInt64,
        response: String,
        loggingEnabled: Bool
    ) {
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
        let status = socketCommandDebugStatus(response: response)
        guard loggingEnabled || elapsedMs >= socketCommandSlowThresholdMs || status != "ok" else {
            return
        }
        let elapsedText = String(format: "%.2f", elapsedMs)
        debugLogSocketCommand(
            "socket.command.end proto=\(debugInfo.protocolName) method=\(debugInfo.commandKey) status=\(status) ms=\(elapsedText) bytes=\(response.utf8.count)"
        )
    }

    private nonisolated static func debugLogSocketCommand(_ message: @autoclosure () -> String) {
        cmuxDebugLog(message())
    }
#endif

    private nonisolated func processCommandUsingSocketExecutionPolicy(_ command: String) -> String? {
        if Thread.isMainThread,
           let request = parseV2SocketRequest(command),
           Self.executionPolicy(forV2Method: request.method) == .socketWorker(mainThreadCallable: false) {
            return v2Error(
                id: request.id,
                code: "invalid_dispatch",
                message: "\(request.method) must run off the main thread"
            )
        }

        let socketWorkerResult = socketWorkerV2ResponseIfHandled(for: command)
        if socketWorkerResult.handled {
            guard let response = socketWorkerResult.response else {
                return nil
            }
            return response
        }

        if command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "ping" {
            return withSocketCommandPolicy(commandKey: "ping", isV2: false) {
                "PONG"
            }
        }

        return v2MainSync {
            self.processCommand(command)
        }
    }

    /// Public entry point mirroring the socket's `processCommand` path so
    /// in-process callers (e.g. the Feed coordinator's `feed.jump` focus
    /// request) can reuse the full V1/V2 dispatcher without duplicating
    /// its auth/policy wrappers.
    nonisolated func handleSocketLine(_ line: String) -> String {
        return processCommandUsingSocketExecutionPolicy(line) ?? ""
    }

    private func processCommand(_ command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "ERROR: Empty command" }

        // v2 protocol: newline-delimited JSON.
        if trimmed.hasPrefix("{") {
            return processV2Command(trimmed)
        }

        let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
        guard !parts.isEmpty else { return "ERROR: Empty command" }

        let cmd = parts[0].lowercased()
        let args = parts.count > 1 ? parts[1] : ""

        let policyParams = cmd == "right_sidebar" ? ["args": args] : [:]
        return withSocketCommandPolicy(commandKey: cmd, isV2: false, params: policyParams) {
            // V1 domains migrated into CmuxControlSocket's ControlCommandCoordinator
            // (the sidebar metadata/pane/surface commands and the browser panel
            // commands) answer here; everything else falls through to the legacy
            // switch below.
            if let coordinatorV1 = controlCommandCoordinator.handleSidebarV1(command: cmd, args: args)
                ?? controlCommandCoordinator.handleBrowserPanelV1(command: cmd, args: args)
                ?? controlCommandCoordinator.handleDebugV1(command: cmd, args: args) {
                return coordinatorV1
            }
            switch cmd {
        case "ping":
            return "PONG"

        case "auth":
            return "OK: Authentication not required"

        case "list_windows":
            return listWindows()

        case "current_window":
            return currentWindow()

        case "focus_window":
            return focusWindow(args)

        case "new_window":
            return newWindow()

        case "close_window":
            return closeWindow(args)

        case "move_workspace_to_window":
            return moveWorkspaceToWindow(args)

        case "list_workspaces":
            return listWorkspaces()

	        case "new_workspace":
	            return newWorkspace(args)

	        case "new_split":
	            return newSplit(args)

        case "list_surfaces":
            return listSurfaces(args)

        case "focus_surface":
            return focusSurface(args)

        case "close_workspace":
            return closeWorkspace(args)

        case "select_workspace":
            return selectWorkspace(args)

        case "current_workspace":
            return currentWorkspace()

        case "send":
            return sendInput(args)

        case "send_key":
            return sendKey(args)

        case "send_surface":
            return sendInputToSurface(args)

        case "send_key_surface":
            return sendKeyToSurface(args)

        case "notify":
            return notifyCurrent(args)

        case "notify_surface":
            return notifySurface(args)

        case "notify_target":
            return notifyTarget(args)

        case "notify_target_async":
            return notifyTargetQueued(args)

        case "list_notifications":
            return listNotifications()

        case "clear_notifications":
            return clearNotifications(args)

        case "set_app_focus":
            return setAppFocusOverride(args)

        case "simulate_app_active":
            return simulateAppDidBecomeActive()

        // Sidebar metadata/reporting commands (set_status/report_meta/
        // report_meta_block/clear_status/clear_meta/clear_meta_block/list_status/
        // list_meta/list_meta_blocks/set_agent_pid/set_agent_lifecycle/
        // agent_hibernation/clear_agent_pid/log/clear_log/list_log/set_progress/
        // clear_progress/report_git_branch/clear_git_branch/report_pr/report_review/
        // clear_pr/report_ports/clear_ports/report_tty/ports_kick/report_shell_state/
        // report_pr_action/report_pwd/sidebar_state/reset_sidebar/right_sidebar)
        // handled by ControlCommandCoordinator.

        case "read_screen":
            return readScreenText(args)


#if DEBUG
        case "send_workspace":
            return sendInputToWorkspace(args)

        case "sleepy_mode":
            return sleepyModeCommand(args)

        case "simulate_type":
            return simulateType(args)

        case "simulate_file_drop":
            return simulateFileDrop(args)

        case "seed_drag_pasteboard_fileurl":
            return seedDragPasteboardFileURL()

        case "seed_drag_pasteboard_tabtransfer":
            return seedDragPasteboardTabTransfer()

        case "seed_drag_pasteboard_sidebar_reorder":
            return seedDragPasteboardSidebarReorder()

        case "seed_drag_pasteboard_types":
            return seedDragPasteboardTypes(args)

        case "clear_drag_pasteboard":
            return clearDragPasteboard()

        case "drop_hit_test":
            return dropHitTest(args)

        case "drag_hit_chain":
            return dragHitChain(args)

        case "overlay_hit_gate":
            return overlayHitGate(args)

        case "overlay_drop_gate":
            return overlayDropGate(args)

        case "portal_hit_gate":
            return portalHitGate(args)

        case "sidebar_overlay_gate":
            return sidebarOverlayGate(args)

        case "terminal_drop_overlay_probe":
            return terminalDropOverlayProbe(args)
#endif

        case "help":
            return helpText()

        // Browser panel commands (open_browser/navigate/browser_back/browser_forward/
        // browser_reload/get_url/focus_webview/is_webview_focused) and the bonsplit
        // pane/surface commands (list_panes/list_pane_surfaces/focus_pane/
        // focus_surface_by_panel/drag_surface_to_split/new_pane/new_surface/
        // close_surface/reload_config/refresh_surfaces/surface_health) handled by
        // ControlCommandCoordinator (drag_surface_to_split forwards to the
        // still-shared v2SurfaceSplitOff).

            default:
                return "ERROR: Unknown command '\(cmd)'. Use 'help' for available commands."
            }
        }
    }

    // MARK: - V2 JSON Socket Protocol

    /// Runs a v2 command line (`{"method","params","id"}`) through the
    /// dispatcher in-process and returns the JSON response. Internal seam so
    /// in-app callers (e.g. custom-sidebar button actions) can drive the same
    /// command surface as the socket without reaching the private dispatcher.
    func runV2CommandLine(_ jsonLine: String) -> String {
        processV2Command(jsonLine)
    }

    private func processV2Command(_ jsonLine: String) -> String {
        // v1 access-mode gating applies to v2 as well. We can't know which v2 method maps
        // to which v1 command without parsing, so parse first and then apply allow-list.

        let request: ControlRequest
        switch Self.v2Parser.request(fromLine: jsonLine) {
        case .failure(let parseError):
            return Self.v2Encoder.response(for: parseError)
        case .success(let parsed):
            request = parsed
        }

        let bridged = V2SocketRequest(bridging: request)
        let id: Any? = bridged.id
        let method = bridged.method
        let params = bridged.params

        guard Self.executionPolicy(forV2Method: method) == .mainActor else {
            return v2Error(
                id: id,
                code: "invalid_dispatch",
                message: "\(method) must run on the socket worker"
            )
        }

        return withSocketCommandPolicy(commandKey: method, isV2: true, params: params) {
            if let workspaceParamError = v2UnsupportedWorkspaceAliasError(method: method, params: params) {
                return v2Result(id: id, workspaceParamError)
            }

            v2MainSync { self.v2RefreshKnownRefs() }

            // Domains migrated into CmuxControlSocket's ControlCommandCoordinator
            // (window so far) answer here, on the main actor, and encode through
            // the same encoder/id; everything else falls through to the legacy
            // switch below. processV2Command already runs on main, so the
            // coordinator's bodies need no per-read v2MainSync hop.
            if let coordinatorResult = controlCommandCoordinator.handle(request) {
                return Self.v2Encoder.response(id: request.id, coordinatorResult)
            }

            switch method {
        case "system.ping":
            return v2Ok(id: id, result: ["pong": true])
        case "system.capabilities":
            return v2Ok(id: id, result: v2Capabilities())
        case "collaboration.status":
            return v2Ok(id: id, result: CollaborationRuntime.shared.statusPayload())
        case "collaboration.session.create":
            let relayURL = params["relay_url"] as? String
            return v2Result(
                id: id,
                .ok(CollaborationRuntime.shared.createSessionForAutomationRequest(relayURL: relayURL))
            )
        case "collaboration.session.join":
            guard let code = params["session_code"] as? String,
                  let token = params["invite_token"] as? String else {
                return v2Result(
                    id: id,
                    .err(
                        code: "invalid_params",
                        message: "collaboration.session.join requires session_code and invite_token",
                        data: nil
                    )
                )
            }
            let relayURL = params["relay_url"] as? String
            return v2Result(
                id: id,
                .ok(CollaborationRuntime.shared.joinSessionForAutomationRequest(
                    relayURL: relayURL,
                    code: code,
                    token: token
                ))
            )
        case "collaboration.session.leave":
            return v2Ok(id: id, result: CollaborationRuntime.shared.leaveSessionForAutomation())
        // mobile.host.status/mobile.workspace.list/mobile.terminal.* (+terminal.*
        // aliases), mobile.terminal.paste/terminal.paste, and chat.sessions.dump
        // handled by ControlCommandCoordinator (bodies stay; shared with
        // mobileHostHandleRPC).

        // system.identify (forwards to the still-shared v2Identify), system.tree,
        // auth.login, and the DEBUG-only mobile.dev_stack_auth.configure handled
        // by ControlCommandCoordinator.

        // Windows (`window.*`) are handled above by ControlCommandCoordinator.

        // Workspaces
        // workspace.* (list/create/select/current/close/move_to_window/reorder[_many]/
        // prompt_submit/rename) + workspace.group.* handled by ControlCommandCoordinator.
        // workspace.action (forwards to the still-shared v2WorkspaceAction) and
        // extension.sidebar.snapshot handled by ControlCommandCoordinator.
        // workspace.next/previous/last/equalize_splits + workspace.remote.* (configure/
        // foreground_auth_ready/reconnect/disconnect/status/pty_attach_end/
        // terminal_session_end) handled by ControlCommandCoordinator. The worker-lane
        // workspace.remote.pty_* methods stay on the app-side worker path.
        case "workspace.set_auto_title":
            return v2Result(id: id, self.v2WorkspaceSetAutoTitle(params: params))

        // Settings/session/feedback: session.restore_previous, settings.open, and
        // feedback.open handled by ControlCommandCoordinator.

        // Feed (workstream): feed.jump/feed.list handled by ControlCommandCoordinator.
        case "sidebar.custom.open":
            return v2Result(id: id, self.v2CustomSidebarOpen(params: params))


        // Surfaces / input: surface.list/current/focus/split/respawn/create/close/move/
        // reorder handled by ControlCommandCoordinator (surface.move forwards to the
        // still-shared v2SurfaceMove). surface.action/tab.action and
        // surface.drag_to_split/surface.split_off (the latter forwarding to the
        // still-shared v2SurfaceSplitOff) handled by ControlCommandCoordinator too.
        // surface.refresh/health/resume.set/get/clear, debug.terminals, surface.send_text/
        // send_key/report_tty/report_pwd/report_shell_state/ports_kick/clear_history/
        // trigger_flash/read_text handled by ControlCommandCoordinator.

        // Panes
        // pane.* handled by ControlCommandCoordinator.

        // Notifications: all but notification.create_for_caller handled by
        // ControlCommandCoordinator (create_for_caller keeps its app-side resolver).
        case "notification.create_for_caller":
            return v2Result(id: id, self.v2NotificationCreateForCaller(params: params))

        // App focus (app.focus_override.set/app.simulate_active) handled by ControlCommandCoordinator.

        // Browser
        case "browser.open_split":
            return v2Result(id: id, self.v2BrowserOpenSplit(params: params))
        // Browser automation methods that can wait on page JavaScript, WebKit
        // cookies, or capture callbacks run on the socket worker (see
        // ControlCommandExecutionPolicy.socketWorkerMethods and
        // v2BrowserAutomationCommandOnSocketWorker); they never reach this switch.
        case "browser.react_grab.toggle":
            return v2Result(id: id, self.v2BrowserReactGrabToggle(params: params))
        case "browser.devtools.toggle":
            return v2Result(id: id, self.v2BrowserDevToolsToggle(params: params))
        case "browser.console.show":
            return v2Result(id: id, self.v2BrowserConsoleShow(params: params))
        case "browser.focus_mode.set":
            return v2Result(id: id, self.v2BrowserFocusModeSet(params: params))
        case "browser.zoom.set":
            return v2Result(id: id, self.v2BrowserZoomSet(params: params))
        case "browser.history.clear":
            return v2Result(id: id, self.v2BrowserHistoryClear(params: params))
        case "browser.url.get":
            return v2Result(id: id, self.v2BrowserGetURL(params: params))
        case "browser.focus_webview":
            return v2Result(id: id, self.v2BrowserFocusWebView(params: params))
        case "browser.is_webview_focused":
            return v2Result(id: id, self.v2BrowserIsWebViewFocused(params: params))
        case "browser.get.title":
            return v2Result(id: id, self.v2BrowserGetTitle(params: params))
        case "browser.frame.main":
            return v2Result(id: id, self.v2BrowserFrameMain(params: params))
        case "browser.import.dialog":
            return v2Result(id: id, self.v2BrowserImportDialog(params: params))
        case "browser.tab.new":
            return v2Result(id: id, self.v2BrowserTabNew(params: params))
        case "browser.tab.list":
            return v2Result(id: id, self.v2BrowserTabList(params: params))
        case "browser.tab.switch":
            return v2Result(id: id, self.v2BrowserTabSwitch(params: params))
        case "browser.tab.close":
            return v2Result(id: id, self.v2BrowserTabClose(params: params))
        case "browser.viewport.set":
            return v2Result(id: id, self.v2BrowserViewportSet(params: params))
        case "browser.geolocation.set":
            return v2Result(id: id, self.v2BrowserGeolocationSet(params: params))
        case "browser.offline.set":
            return v2Result(id: id, self.v2BrowserOfflineSet(params: params))
        case "browser.trace.start":
            return v2Result(id: id, self.v2BrowserTraceStart(params: params))
        case "browser.trace.stop":
            return v2Result(id: id, self.v2BrowserTraceStop(params: params))
        case "browser.network.route":
            return v2Result(id: id, self.v2BrowserNetworkRoute(params: params))
        case "browser.network.unroute":
            return v2Result(id: id, self.v2BrowserNetworkUnroute(params: params))
        case "browser.network.requests":
            return v2Result(id: id, self.v2BrowserNetworkRequests(params: params))
        case "browser.screencast.start":
            return v2Result(id: id, self.v2BrowserScreencastStart(params: params))
        case "browser.screencast.stop":
            return v2Result(id: id, self.v2BrowserScreencastStop(params: params))
        case "browser.input_mouse":
            return v2Result(id: id, self.v2BrowserInputMouse(params: params))
        case "browser.input_keyboard":
            return v2Result(id: id, self.v2BrowserInputKeyboard(params: params))
        case "browser.input_touch":
            return v2Result(id: id, self.v2BrowserInputTouch(params: params))

        // Markdown/files/projects: markdown.open, file.open (forwards to the
        // still-shared v2FileOpen), and project.* handled by ControlCommandCoordinator.

        // surface.read_text handled by ControlCommandCoordinator.


        // Debug / test-only: the DEBUG-gated debug.* domain (shortcuts, typing,
        // textbox fixtures, command palette, browser probes, sidebar/terminal
        // focus, file drop, layout/portal/flash/panel-snapshot counters, window
        // screenshot, and the session-snapshot benchmark/seed methods) handled
        // by ControlCommandCoordinator. debug.sidebar.simulate_drag is dispatched
        // on the socket worker (see ControlCommandExecutionPolicy + the worker
        // switch in processCommand) so its inter-tick Thread.sleep never blocks
        // the main actor.

            default:
                return v2Error(id: id, code: "method_not_found", message: "Unknown method")
            }
        }
    }

    private nonisolated func v2Capabilities() -> [String: Any] {
        var methods: [String] = [
            "system.ping",
            "system.capabilities",
            "collaboration.status",
            "collaboration.session.create",
            "collaboration.session.join",
            "collaboration.session.leave",
            "system.identify",
            "system.tree",
            "sidebar.custom.open",
            "system.top",
            "system.memory",
            "mobile.host.status",
            "mobile.attach_ticket.create",
            "mobile.terminal.set_font",
            "mobile.workspace.list",
            "mobile.terminal.create",
            "mobile.terminal.input",
            "mobile.terminal.paste",
            "mobile.terminal.replay",
            "mobile.terminal.viewport", "mobile.events.subscribe", "mobile.events.unsubscribe",
            "terminal.create",
            "terminal.input",
            "terminal.paste",
            "terminal.replay",
            "terminal.viewport",
            "auth.login",
            "auth.status",
            "auth.sign_in_url",
            "auth.begin_sign_in",
            "auth.sign_out",
            "vm.list",
            "vm.create",
            "vm.destroy",
            "vm.exec",
            "vm.attach_info",
            "vm.ssh_info",
            "window.list",
            "window.current",
            "window.focus",
            "window.create",
            "window.close",
            "window.displays",
            "window.display",
            "workspace.list",
            "workspace.create",
            "workspace.env",
            "workspace.select",
            "workspace.current",
            "workspace.close",
            "workspace.move_to_window",
            "workspace.reorder",
            "workspace.reorder_many",
            "workspace.prompt_submit",
            "workspace.rename",
            "workspace.set_auto_title",
            "workspace.group.list",
            "workspace.group.create",
            "workspace.group.ungroup",
            "workspace.group.delete",
            "workspace.group.rename",
            "workspace.group.collapse",
            "workspace.group.expand",
            "workspace.group.pin",
            "workspace.group.unpin",
            "workspace.group.add",
            "workspace.group.remove",
            "workspace.group.set_anchor",
            "workspace.group.new_workspace",
            "workspace.group.set_color",
            "workspace.group.set_icon",
            "workspace.group.move",
            "workspace.group.focus",
            "workspace.action",
            "extension.sidebar.snapshot",
            "workspace.next",
            "workspace.previous",
            "workspace.last",
            "workspace.equalize_splits",
            "workspace.remote.configure",
            "workspace.remote.foreground_auth_ready",
            "workspace.remote.reconnect",
            "workspace.remote.disconnect",
            "workspace.remote.status",
            "workspace.remote.pty_sessions",
            "workspace.remote.pty_close",
            "workspace.remote.pty_detach",
            "workspace.remote.pty_bridge",
            "workspace.remote.pty_resize",
            "workspace.remote.pty_attach_end",
            "workspace.remote.terminal_session_end", "remote.tmux.sessions", "remote.tmux.attach", "remote.tmux.detach", "remote.tmux.state", "remote.tmux.mirror", "remote.tmux.window",
            "session.restore_previous",
            "settings.open",
            "feedback.open",
            "feedback.submit",
            "feed.push",
            "feed.permission.reply",
            "feed.question.reply",
            "feed.exit_plan.reply",
            "feed.jump",
            "feed.list",
            "surface.list",
            "surface.current",
            "surface.focus",
            "surface.split",
            "surface.respawn",
            "surface.create",
            "surface.close",
            "surface.drag_to_split",
            "surface.split_off",
            "surface.move",
            "surface.reorder",
            "surface.action",
            "tab.action",
            "surface.refresh",
            "surface.health",
            "surface.resume.set",
            "surface.resume.get",
            "surface.resume.clear",
            "debug.terminals",
            "surface.send_text",
            "surface.send_key",
            "surface.report_tty",
            "surface.report_pwd",
            "surface.report_shell_state",
            "surface.ports_kick",
            "surface.read_text",
            "surface.clear_history",
            "surface.trigger_flash",
            "pane.list",
            "pane.focus",
            "pane.surfaces",
            "pane.create",
            "pane.resize",
            "pane.swap",
            "pane.break",
            "pane.join",
            "pane.last",
            "notification.create",
            "notification.create_for_caller",
            "notification.create_for_surface",
            "notification.create_for_target",
            "notification.list",
            "notification.clear",
            "notification.dismiss",
            "notification.mark_read",
            "notification.open",
            "notification.jump_to_unread",
            "app.focus_override.set",
            "app.simulate_active",
            "file.open",
            "markdown.open",
            "browser.open_split",
            "browser.navigate",
            "browser.back",
            "browser.forward",
            "browser.reload",
            "browser.react_grab.toggle",
            "browser.devtools.toggle",
            "browser.console.show",
            "browser.focus_mode.set",
            "browser.zoom.set",
            "browser.history.clear",
            "browser.url.get",
            "browser.snapshot",
            "browser.eval",
            "browser.wait",
            "browser.click",
            "browser.dblclick",
            "browser.hover",
            "browser.focus",
            "browser.type",
            "browser.fill",
            "browser.press",
            "browser.keydown",
            "browser.keyup",
            "browser.check",
            "browser.uncheck",
            "browser.select",
            "browser.scroll",
            "browser.scroll_into_view",
            "browser.screenshot",
            "browser.get.text",
            "browser.get.html",
            "browser.get.value",
            "browser.get.attr",
            "browser.get.title",
            "browser.get.count",
            "browser.get.box",
            "browser.get.styles",
            "browser.is.visible",
            "browser.is.enabled",
            "browser.is.checked",
            "browser.focus_webview",
            "browser.is_webview_focused",
            "browser.find.role",
            "browser.find.text",
            "browser.find.label",
            "browser.find.placeholder",
            "browser.find.alt",
            "browser.find.title",
            "browser.find.testid",
            "browser.find.first",
            "browser.find.last",
            "browser.find.nth",
            "browser.frame.select",
            "browser.frame.main",
            "browser.dialog.accept",
            "browser.dialog.dismiss",
            "browser.download.wait",
            "browser.cookies.get",
            "browser.cookies.set",
            "browser.cookies.clear",
            "browser.storage.get",
            "browser.storage.set",
            "browser.storage.clear",
            "browser.tab.new",
            "browser.tab.list",
            "browser.tab.switch",
            "browser.tab.close",
            "browser.console.list",
            "browser.console.clear",
            "browser.errors.list",
            "browser.highlight",
            "browser.state.save",
            "browser.state.load",
            "browser.addinitscript",
            "browser.addscript",
            "browser.addstyle",
            "browser.viewport.set",
            "browser.geolocation.set",
            "browser.offline.set",
            "browser.trace.start",
            "browser.trace.stop",
            "browser.network.route",
            "browser.network.unroute",
            "browser.network.requests",
            "browser.screencast.start",
            "browser.screencast.stop",
            "browser.input_mouse",
            "browser.input_keyboard",
            "browser.input_touch",
        ]
#if DEBUG
        methods.append(contentsOf: Self.v2DebugMethodNames)
#endif

        return [
            "protocol": "cmux-socket",
            "version": 2,
            "socket_path": socketServer.currentSocketPath,
            "access_mode": socketServer.accessMode.rawValue,
            "methods": methods.sorted()
        ]
    }

    func v2Identify(params: [String: Any]) -> [String: Any] {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return [
                "socket_path": socketServer.currentSocketPath,
                "focused": NSNull(),
                "caller": NSNull()
            ]
        }

        var focused: [String: Any] = [:]
        v2MainSync {
            let windowId = v2ResolveWindowId(tabManager: tabManager)
            if let wsId = tabManager.selectedTabId,
               let ws = tabManager.tabs.first(where: { $0.id == wsId }) {
                let paneUUID = ws.bonsplitController.focusedPaneId?.id
                let surfaceUUID = ws.focusedPanelId
                focused = [
                    "window_id": v2OrNull(windowId?.uuidString),
                    "window_ref": v2Ref(kind: .window, uuid: windowId),
                    "workspace_id": wsId.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: wsId),
                    "pane_id": v2OrNull(paneUUID?.uuidString),
                    "pane_ref": v2Ref(kind: .pane, uuid: paneUUID),
                    "surface_id": v2OrNull(surfaceUUID?.uuidString),
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceUUID),
                    "tab_id": v2OrNull(surfaceUUID?.uuidString),
                    "tab_ref": v2TabRef(uuid: surfaceUUID),
                    "surface_type": v2OrNull(surfaceUUID.flatMap { ws.panels[$0]?.panelType.rawValue }),
                    "is_browser_surface": v2OrNull(surfaceUUID.flatMap { ws.panels[$0]?.panelType == .browser })
                ]
            } else {
                focused = [
                    "window_id": v2OrNull(windowId?.uuidString),
                    "window_ref": v2Ref(kind: .window, uuid: windowId)
                ]
            }
        }

        // Optionally validate a caller-provided location (useful for agents calling from inside a surface).
        var resolvedCaller: [String: Any]? = nil
        if let callerObj = params["caller"] as? [String: Any],
           let wsId = v2UUIDAny(callerObj["workspace_id"]) {
            let surfaceId = v2UUIDAny(callerObj["surface_id"]) ?? v2UUIDAny(callerObj["tab_id"])
            v2MainSync {
                let callerTabManager = AppDelegate.shared?.tabManagerFor(tabId: wsId) ?? tabManager
                if let ws = callerTabManager.tabs.first(where: { $0.id == wsId }) {
                    let callerWindowId = v2ResolveWindowId(tabManager: callerTabManager)
                    var payload: [String: Any] = [
                        "window_id": v2OrNull(callerWindowId?.uuidString),
                        "window_ref": v2Ref(kind: .window, uuid: callerWindowId),
                        "workspace_id": wsId.uuidString,
                        "workspace_ref": v2Ref(kind: .workspace, uuid: wsId)
                    ]

                    if let surfaceId, ws.panels[surfaceId] != nil {
                        let paneUUID = ws.paneId(forPanelId: surfaceId)?.id
                        payload["surface_id"] = surfaceId.uuidString
                        payload["surface_ref"] = v2Ref(kind: .surface, uuid: surfaceId)
                        payload["tab_id"] = surfaceId.uuidString
                        payload["tab_ref"] = v2TabRef(uuid: surfaceId)
                        payload["surface_type"] = v2OrNull(ws.panels[surfaceId]?.panelType.rawValue)
                        payload["is_browser_surface"] = v2OrNull(ws.panels[surfaceId]?.panelType == .browser)
                        payload["pane_id"] = v2OrNull(paneUUID?.uuidString)
                        payload["pane_ref"] = v2Ref(kind: .pane, uuid: paneUUID)
                    } else {
                        payload["surface_id"] = NSNull()
                        payload["surface_ref"] = NSNull()
                        payload["tab_id"] = NSNull()
                        payload["tab_ref"] = NSNull()
                        payload["surface_type"] = NSNull()
                        payload["is_browser_surface"] = NSNull()
                        payload["pane_id"] = NSNull()
                        payload["pane_ref"] = NSNull()
                    }
                    resolvedCaller = payload
                }
            }
        }

        var result: [String: Any] = [
            "socket_path": socketServer.currentSocketPath,
            "focused": focused.isEmpty ? NSNull() : focused,
            "caller": v2OrNull(resolvedCaller)
        ]
        if let bundleIdentifier = Bundle.main.bundleIdentifier {
            result["bundle_identifier"] = bundleIdentifier
        }
        result["app_bundle_path"] = Bundle.main.bundleURL.path
        if let executablePath = Bundle.main.executableURL?.path {
            result["app_executable_path"] = executablePath
        }
        if let cliPath = Bundle.main.resourceURL?
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("cmux", isDirectory: false)
            .path {
            result["app_cli_path"] = cliPath
        }
        return result
    }

    private struct V2WindowRouting {
        let includeAllWindows: Bool
        let requestedWindowId: UUID?
        let focused: [String: Any]
        let caller: [String: Any]
        let focusedWindowId: UUID?
    }

    private func v2WindowSelectorDetails(params: [String: Any]) -> [String: Any]? {
        guard let rawWindowId = params["window_id"] else { return nil }
        if let string = rawWindowId as? String {
            return ["window_id": string]
        }
        return ["window_id": String(describing: rawWindowId)]
    }

    private func parseV2WindowRouting(params: [String: Any]) -> (routing: V2WindowRouting?, error: V2CallResult?) {
        if params["all_windows"] != nil, v2Bool(params, "all_windows") == nil {
            return (
                nil,
                .err(
                    code: "invalid_params",
                    message: "Invalid all_windows. Pass true or false, or omit it. Use --window <id|ref|index> to target one window or --all-windows to target all windows.",
                    data: nil
                )
            )
        }

        let includeAllWindows = v2Bool(params, "all_windows") ?? false
        let requestedWindowId = v2UUID(params, "window_id")
        if params["window_id"] != nil && requestedWindowId == nil {
            return (
                nil,
                .err(
                    code: "invalid_params",
                    message: "Invalid window selector. Use --window <id|ref|index> to target one window, or run `cmux list-windows` to see available windows and retry.",
                    data: v2WindowSelectorDetails(params: params)
                )
            )
        }
        if includeAllWindows, requestedWindowId != nil {
            return (
                nil,
                .err(
                    code: "invalid_params",
                    message: "Choose either --window <id|ref|index> or --all-windows, not both. Run `cmux list-windows` to see available windows and retry.",
                    data: v2WindowSelectorDetails(params: params)
                )
            )
        }

        var identifyParams: [String: Any] = [:]
        if let caller = params["caller"] as? [String: Any], !caller.isEmpty {
            identifyParams["caller"] = caller
        }
        if let requestedWindowId {
            identifyParams["window_id"] = requestedWindowId.uuidString
        }
        let identifyPayload = v2Identify(params: identifyParams)
        let focused = identifyPayload["focused"] as? [String: Any] ?? [:]
        let caller = identifyPayload["caller"] as? [String: Any] ?? [:]
        let focusedWindowId = v2UUIDAny(focused["window_id"]) ?? v2UUIDAny(focused["window_ref"])
        return (
            V2WindowRouting(
                includeAllWindows: includeAllWindows,
                requestedWindowId: requestedWindowId,
                focused: focused,
                caller: caller,
                focusedWindowId: focusedWindowId
            ),
            nil
        )
    }

    private func v2WindowNotFoundResult(params: [String: Any], windowId: UUID) -> V2CallResult {
        .err(
            code: "not_found",
            message: "Window not found. Run `cmux list-windows` to see available windows, then retry with --window <id|ref|index>.",
            data: v2WindowSelectorDetails(params: params) ?? ["window_id": windowId.uuidString]
        )
    }

#if DEBUG
#endif

    func taskManagerTopPayload(includeProcesses: Bool) async throws -> [String: Any] {
        v2RefreshKnownRefs()

        let identifyPayload = v2Identify(params: [:])
        let focused = identifyPayload["focused"] as? [String: Any] ?? [:]
        var windowNodes: [[String: Any]] = []

        if let app = AppDelegate.shared {
            let summaries = app.listMainWindowSummaries()

            for (windowIndex, summary) in summaries.enumerated() {
                guard let manager = app.tabManagerFor(windowId: summary.windowId) else { continue }
                let workspaceNodes = manager.tabs.enumerated().map { workspaceIndex, workspace in
                    v2TopWorkspaceNode(
                        workspace: workspace,
                        index: workspaceIndex,
                        selected: workspace.id == manager.selectedTabId
                    )
                }
                windowNodes.append(
                    v2TopWindowNode(
                        summary: summary,
                        index: windowIndex,
                        workspaceNodes: workspaceNodes
                    )
                )
            }
        }
        v2AttachTopApplicationProcess(to: &windowNodes)

        let processSnapshot = await withTaskGroup(
            of: CmuxTopProcessSnapshot.self,
            returning: CmuxTopProcessSnapshot.self
        ) { group in
            group.addTask(priority: .utility) {
                CmuxTopProcessSnapshot.capture(includeProcessDetails: includeProcesses)
            }
            return await group.next()!
        }
        let browserPIDOccurrences = v2TopBrowserPIDOccurrences(in: windowNodes)
        var annotatedWindows = windowNodes
        let totalPIDs = v2AnnotateTopWindows(
            &annotatedWindows,
            processSnapshot: processSnapshot,
            browserPIDOccurrences: browserPIDOccurrences,
            includeProcesses: includeProcesses
        )
        let aggregates = processAggregates(from: processSnapshot, totalPIDs: totalPIDs)
        let memoryDiagnostic = v2TopMemoryDiagnosticPayload(
            processSnapshot: processSnapshot,
            annotatedWindows: annotatedWindows
        )

        return [
            "active": focused.isEmpty ? (NSNull() as Any) : focused,
            "caller": NSNull(),
            "sample": processSnapshot.samplePayload(),
            "totals": processSnapshot.summaryPayload(for: totalPIDs),
            "memory_diagnostic": memoryDiagnostic,
            "program_totals": aggregates.programs,
            "coding_agents": aggregates.codingAgents,
            "windows": annotatedWindows
        ]
    }

    private nonisolated func processAggregates(
        from processSnapshot: CmuxTopProcessSnapshot,
        totalPIDs: Set<Int>
    ) -> (programs: [[String: Any]], codingAgents: [[String: Any]]) {
        (
            programs: processSnapshot.programSummaryPayload(for: totalPIDs),
            codingAgents: processSnapshot.codingAgentSummaryPayload(for: totalPIDs)
        )
    }

    private nonisolated func v2SystemTop(params: [String: Any]) -> V2CallResult {
        let base = v2MainSync {
            self.v2RefreshKnownRefs()
            return self.v2SystemTopBasePayload(params: params)
        }
        guard case .ok(let value) = base else { return base }
        guard var payload = value as? [String: Any],
              let includeProcesses = payload.removeValue(forKey: "include_processes") as? Bool,
              var windowNodes = payload.removeValue(forKey: "windows") as? [[String: Any]] else {
            return .err(code: "internal_error", message: "Invalid system.top payload", data: nil)
        }
        let processSnapshot = CmuxTopProcessSnapshot.capture(includeProcessDetails: includeProcesses)
        let browserPIDOccurrences = v2TopBrowserPIDOccurrences(in: windowNodes)
        let totalPIDs = v2AnnotateTopWindows(
            &windowNodes,
            processSnapshot: processSnapshot,
            browserPIDOccurrences: browserPIDOccurrences,
            includeProcesses: includeProcesses
        )
        let aggregates = processAggregates(from: processSnapshot, totalPIDs: totalPIDs)
        let memoryDiagnostic = v2TopMemoryDiagnosticPayload(
            processSnapshot: processSnapshot,
            annotatedWindows: windowNodes
        )

        payload["sample"] = processSnapshot.samplePayload()
        payload["totals"] = processSnapshot.summaryPayload(for: totalPIDs)
        payload["memory_diagnostic"] = memoryDiagnostic
        payload["program_totals"] = aggregates.programs
        payload["coding_agents"] = aggregates.codingAgents
        payload["windows"] = windowNodes
        return .ok(payload)
    }

    private nonisolated func v2SystemMemory(params: [String: Any]) -> V2CallResult {
        var baseParams = params
        baseParams["include_processes"] = false
        let base = v2MainSync {
            self.v2RefreshKnownRefs()
            return self.v2SystemTopBasePayload(params: baseParams)
        }
        guard case .ok(let value) = base else { return base }
        guard var payload = value as? [String: Any],
              var windowNodes = payload.removeValue(forKey: "windows") as? [[String: Any]] else {
            return .err(code: "internal_error", message: "Invalid system.memory payload", data: nil)
        }
        func intParam(_ key: String) -> Int? {
            if let i = params[key] as? Int { return i }
            if let n = params[key] as? NSNumber {
                guard CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
                let value = n.doubleValue
                guard value.isFinite,
                      value.rounded(.towardZero) == value,
                      value >= Double(Int.min),
                      value <= Double(Int.max) else {
                    return nil
                }
                return n.intValue
            }
            if let s = params[key] as? String {
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty,
                      trimmed.range(of: #"^[+-]?\d+$"#, options: .regularExpression) != nil else {
                    return nil
                }
                return Int(trimmed)
            }
            return nil
        }
        var invalidLimitKey: String?
        func groupLimitParam(_ key: String) -> Int? {
            guard params[key] != nil else { return nil }
            guard let value = intParam(key), (1...100).contains(value) else {
                invalidLimitKey = key
                return nil
            }
            return value
        }
        let topGroupLimitValue = groupLimitParam("top_group_limit")
        if let invalidLimitKey {
            return .err(code: "invalid_params", message: "\(invalidLimitKey) must be an integer from 1 to 100", data: nil)
        }
        let groupLimitValue = groupLimitParam("group_limit")
        if let invalidLimitKey {
            return .err(code: "invalid_params", message: "\(invalidLimitKey) must be an integer from 1 to 100", data: nil)
        }
        let topGroupLimit = topGroupLimitValue ?? groupLimitValue ?? 12
        let processSnapshot = CmuxTopProcessSnapshot.captureCached(
            includeProcessDetails: true,
            maximumAge: 2
        )
        let browserPIDOccurrences = v2TopBrowserPIDOccurrences(in: windowNodes)
        _ = v2AnnotateTopWindows(
            &windowNodes,
            processSnapshot: processSnapshot,
            browserPIDOccurrences: browserPIDOccurrences,
            includeProcesses: false
        )
        payload["sample"] = processSnapshot.samplePayload()
        payload["memory_diagnostic"] = v2TopMemoryDiagnosticPayload(
            processSnapshot: processSnapshot,
            annotatedWindows: windowNodes,
            topGroupLimit: topGroupLimit
        )
        return .ok(payload)
    }

    private func v2SystemTopBasePayload(params: [String: Any]) -> V2CallResult {
        let workspaceFilter = v2UUID(params, "workspace_id")
        if params["workspace_id"] != nil && workspaceFilter == nil {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }
        if params["include_processes"] != nil, v2Bool(params, "include_processes") == nil { return .err(code: "invalid_params", message: "Missing or invalid include_processes", data: nil) }
        let includeProcesses = v2Bool(params, "include_processes") ?? false
        let routingResult = parseV2WindowRouting(params: params)
        if let error = routingResult.error { return error }
        guard let routing = routingResult.routing else {
            return .err(code: "internal_error", message: "Invalid window routing payload", data: nil)
        }

        var windowNodes: [[String: Any]] = []
        var workspaceFound = (workspaceFilter == nil)
        var windowFound = (routing.requestedWindowId == nil)

        if let app = AppDelegate.shared {
            let summaries = app.listMainWindowSummaries()
            let defaultWindowId = routing.requestedWindowId ?? routing.focusedWindowId ?? summaries.first?.windowId

            for (windowIndex, summary) in summaries.enumerated() {
                if let requestedWindowId = routing.requestedWindowId, summary.windowId != requestedWindowId {
                    continue
                }
                windowFound = true
                guard let manager = app.tabManagerFor(windowId: summary.windowId) else { continue }

                if let workspaceFilter {
                    guard let workspaceIndex = manager.tabs.firstIndex(where: { $0.id == workspaceFilter }) else {
                        continue
                    }
                    let workspace = manager.tabs[workspaceIndex]
                    let workspaceNode = v2TopWorkspaceNode(
                        workspace: workspace,
                        index: workspaceIndex,
                        selected: workspace.id == manager.selectedTabId
                    )
                    windowNodes = [
                        v2TopWindowNode(
                            summary: summary,
                            index: windowIndex,
                            workspaceNodes: [workspaceNode]
                        )
                    ]
                    workspaceFound = true
                    break
                }

                if !routing.includeAllWindows && summary.windowId != defaultWindowId {
                    continue
                }

                let workspaceNodesForWindow = manager.tabs.enumerated().map { workspaceIndex, workspace in
                    v2TopWorkspaceNode(
                        workspace: workspace,
                        index: workspaceIndex,
                        selected: workspace.id == manager.selectedTabId
                    )
                }

                windowNodes.append(
                    v2TopWindowNode(
                        summary: summary,
                        index: windowIndex,
                        workspaceNodes: workspaceNodesForWindow
                    )
                )
            }
        }

        v2AttachTopApplicationProcess(to: &windowNodes, workspaceFilter: workspaceFilter)

        if let requestedWindowId = routing.requestedWindowId, !windowFound {
            return v2WindowNotFoundResult(params: params, windowId: requestedWindowId)
        }
        if let workspaceFilter, !workspaceFound {
            return .err(
                code: "not_found",
                message: "Workspace not found",
                data: [
                    "workspace_id": workspaceFilter.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceFilter)
                ]
            )
        }

        return .ok([
            "active": routing.focused.isEmpty ? (NSNull() as Any) : routing.focused,
            "caller": routing.caller.isEmpty ? (NSNull() as Any) : routing.caller,
            "include_processes": includeProcesses,
            "windows": windowNodes
        ])
    }

    private func v2TopWindowNode(
        summary: AppDelegate.MainWindowSummary,
        index: Int,
        workspaceNodes: [[String: Any]]
    ) -> [String: Any] {
        return [
            "kind": "window",
            "id": summary.windowId.uuidString,
            "ref": v2Ref(kind: .window, uuid: summary.windowId),
            "index": index,
            "key": summary.isKeyWindow,
            "visible": summary.isVisible,
            "workspace_count": workspaceNodes.count,
            "selected_workspace_id": v2OrNull(summary.selectedWorkspaceId?.uuidString),
            "selected_workspace_ref": v2Ref(kind: .workspace, uuid: summary.selectedWorkspaceId),
            "workspaces": workspaceNodes
        ]
    }

    private func v2TopWorkspaceNode(
        workspace: Workspace,
        index: Int,
        selected: Bool
    ) -> [String: Any] {
        var paneByPanelId: [UUID: UUID] = [:]
        var indexInPaneByPanelId: [UUID: Int] = [:]
        var selectedInPaneByPanelId: [UUID: Bool] = [:]

        let paneIds = workspace.bonsplitController.allPaneIds
        for paneId in paneIds {
            let tabs = workspace.bonsplitController.tabs(inPane: paneId)
            let selectedTab = workspace.bonsplitController.selectedTab(inPane: paneId)
            for (tabIndex, tab) in tabs.enumerated() {
                guard let panelId = workspace.panelIdFromSurfaceId(tab.id) else { continue }
                paneByPanelId[panelId] = paneId.id
                indexInPaneByPanelId[panelId] = tabIndex
                selectedInPaneByPanelId[panelId] = (tab.id == selectedTab?.id)
            }
        }

        var surfacesByPane: [UUID: [[String: Any]]] = [:]
        let focusedSurfaceId = workspace.focusedPanelId
        for (surfaceIndex, panel) in orderedPanels(in: workspace).enumerated() {
            let paneUUID = paneByPanelId[panel.id]
            let selectedInPane = selectedInPaneByPanelId[panel.id] ?? false

            var item: [String: Any] = [
                "kind": "surface",
                "id": panel.id.uuidString,
                "ref": v2Ref(kind: .surface, uuid: panel.id),
                "index": surfaceIndex,
                "type": panel.panelType.rawValue,
                "title": workspace.panelTitle(panelId: panel.id) ?? panel.displayTitle,
                "focused": panel.id == focusedSurfaceId,
                "selected": selectedInPane,
                "selected_in_pane": v2OrNull(selectedInPaneByPanelId[panel.id]),
                "pane_id": v2OrNull(paneUUID?.uuidString),
                "pane_ref": v2Ref(kind: .pane, uuid: paneUUID),
                "index_in_pane": v2OrNull(indexInPaneByPanelId[panel.id]),
                "tty": v2OrNull(workspace.surfaceTTYNames[panel.id]),
                "webviews": []
            ]

            if panel.panelType == .browser, let browserPanel = panel as? BrowserPanel {
                let webContentPID = CmuxWebContentProcessIdentifier.pid(for: browserPanel.webView)
                let url = browserPanel.currentURL?.absoluteString ?? ""
                let webViewLifecycle = browserPanel.webViewLifecycleTopPayload()
                item["url"] = url
                item["browser_web_content_pid"] = v2OrNull(webContentPID)
                item["browser_webview_lifecycle_state"] = browserPanel.webViewLifecycleState.rawValue
                item["webviews"] = [
                    [
                        "kind": "webview",
                        "id": "\(panel.id.uuidString):webview",
                        "ref": "\(v2Ref(kind: .surface, uuid: panel.id)):webview",
                        "index": 0,
                        "surface_id": panel.id.uuidString,
                        "surface_ref": v2Ref(kind: .surface, uuid: panel.id),
                        "title": browserPanel.displayTitle,
                        "url": url,
                        "pid": v2OrNull(webContentPID),
                        "lifecycle": webViewLifecycle
                    ] as [String: Any]
                ]
            } else {
                item["url"] = NSNull()
                item["browser_web_content_pid"] = NSNull()
            }
            if let paneUUID {
                surfacesByPane[paneUUID, default: []].append(item)
            }
        }

        for paneUUID in surfacesByPane.keys {
            surfacesByPane[paneUUID]?.sort {
                let lhs = ($0["index_in_pane"] as? Int) ?? ($0["index"] as? Int) ?? Int.max
                let rhs = ($1["index_in_pane"] as? Int) ?? ($1["index"] as? Int) ?? Int.max
                return lhs < rhs
            }
        }

        let focusedPaneId = workspace.bonsplitController.focusedPaneId
        let panes: [[String: Any]] = paneIds.enumerated().map { paneIndex, paneId in
            let tabs = workspace.bonsplitController.tabs(inPane: paneId)
            let surfaceUUIDs: [UUID] = tabs.compactMap { workspace.panelIdFromSurfaceId($0.id) }
            let selectedTab = workspace.bonsplitController.selectedTab(inPane: paneId)
            let selectedSurfaceUUID = selectedTab.flatMap { workspace.panelIdFromSurfaceId($0.id) }

            return [
                "kind": "pane",
                "id": paneId.id.uuidString,
                "ref": v2Ref(kind: .pane, uuid: paneId.id),
                "index": paneIndex,
                "focused": paneId == focusedPaneId,
                "surface_ids": surfaceUUIDs.map { $0.uuidString },
                "surface_refs": surfaceUUIDs.map { v2Ref(kind: .surface, uuid: $0) },
                "selected_surface_id": v2OrNull(selectedSurfaceUUID?.uuidString),
                "selected_surface_ref": v2Ref(kind: .surface, uuid: selectedSurfaceUUID),
                "surface_count": surfaceUUIDs.count,
                "surfaces": surfacesByPane[paneId.id] ?? []
            ]
        }

        return [
            "kind": "workspace",
            "id": workspace.id.uuidString,
            "ref": v2Ref(kind: .workspace, uuid: workspace.id),
            "index": index,
            "title": workspace.title,
            "description": v2OrNull(workspace.customDescription),
            "selected": selected,
            "pinned": workspace.isPinned,
            "panes": panes,
            "tags": v2TopTagNodes(for: workspace)
        ]
    }

    private func v2TopTagNodes(for workspace: Workspace) -> [[String: Any]] {
        var tags: [[String: Any]] = []
        var seenKeys = Set<String>()

        for (index, entry) in workspace.sidebarStatusEntriesInDisplayOrder().enumerated() {
            let pid = workspace.agentPIDs[entry.key].flatMap { $0 > 0 ? Int($0) : nil }
            tags.append([
                "kind": "tag",
                "id": v2TopTagIdentifier(workspaceId: workspace.id, key: entry.key),
                "ref": v2TopTagRef(workspaceId: workspace.id, key: entry.key),
                "index": index,
                "key": entry.key,
                "value": entry.value,
                "icon": v2OrNull(entry.icon),
                "color": v2OrNull(entry.color),
                "url": v2OrNull(entry.url?.absoluteString),
                "priority": entry.priority,
                "format": entry.format.rawValue,
                "visible": true,
                "pid": v2OrNull(pid)
            ])
            seenKeys.insert(entry.key)
        }

        for key in workspace.agentPIDs.keys.sorted() where !seenKeys.contains(key) {
            let pid = workspace.agentPIDs[key].flatMap { $0 > 0 ? Int($0) : nil }
            tags.append([
                "kind": "tag",
                "id": v2TopTagIdentifier(workspaceId: workspace.id, key: key),
                "ref": v2TopTagRef(workspaceId: workspace.id, key: key),
                "index": tags.count,
                "key": key,
                "value": "",
                "icon": NSNull(),
                "color": NSNull(),
                "url": NSNull(),
                "priority": 0,
                "format": "plain",
                "visible": false,
                "pid": v2OrNull(pid)
            ])
        }

        return tags
    }

    // MARK: - V2 Helpers (encoding + result plumbing)
    // MARK: - V2 Helpers (encoding + result plumbing)

    private nonisolated func v2AuthStatusPayload(timedOut: Bool) -> [String: Any] {
        var result: [String: Any] = [:]
        v2MainSync {
            MainActor.assumeIsolated {
                guard let coordinator = self.authCoordinator else {
                    result = [
                        "signed_in": false,
                        "is_restoring_session": false,
                        "is_loading": false,
                        "timed_out": timedOut
                    ]
                    return
                }
                let isSigningIn = self.browserSignInFlow?.isSigningIn ?? false
                var status: [String: Any] = [
                    "signed_in": coordinator.isAuthenticated,
                    "is_restoring_session": coordinator.isRestoringSession,
                    "is_loading": coordinator.isLoading || isSigningIn,
                    "timed_out": timedOut
                ]
                if let user = coordinator.currentUser {
                    var userDict: [String: Any] = ["id": user.id]
                    if let email = user.primaryEmail { userDict["email"] = email }
                    if let name = user.displayName { userDict["display_name"] = name }
                    status["user"] = userDict
                }
                if let teamID = coordinator.resolvedTeamID {
                    status["selected_team_id"] = teamID
                }
                if !coordinator.availableTeams.isEmpty {
                    status["teams"] = coordinator.availableTeams.map { team -> [String: Any] in
                        var dict: [String: Any] = [
                            "id": team.id,
                            "display_name": team.displayName
                        ]
                        if let slug = team.slug { dict["slug"] = slug }
                        return dict
                    }
                }
                result = status
            }
        }
        return result
    }

    nonisolated func v2OrNull(_ value: Any?) -> Any {
        // Avoid relying on `?? NSNull()` inference (Swift toolchains can disagree).
        if let value { return value }
        return NSNull()
    }

    private static func notificationCreatedAtString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private static func notificationListTrailingField(_ value: String) -> String {
        "pct:" + value
            .replacingOccurrences(of: "%", with: "%25")
            .replacingOccurrences(of: "|", with: "%7C")
            .replacingOccurrences(of: "\n", with: "%0A")
            .replacingOccurrences(of: "\r", with: "%0D")
    }

    nonisolated func v2NonEmptyString(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    nonisolated func v2MainSync<T>(_ body: @MainActor () -> T) -> T {
        let policyStack = Self.currentSocketCommandFocusAllowanceStack()
        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                Self.withSocketCommandPolicyStack(policyStack) {
                    body()
                }
            }
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                Self.withSocketCommandPolicyStack(policyStack) {
                    body()
                }
            }
        }
    }

    private nonisolated func v2Ok(id: Any?, result: Any) -> String {
        guard let idValue = Self.v2WireId(id),
              let payload = JSONValue(foundationObject: result) else {
            return ControlResponseEncoder.encodeFailureResponse
        }
        return Self.v2Encoder.ok(id: idValue, result: payload)
    }

    /// Bridges a legacy `Any?` request id to the wire value: missing ids
    /// encode as JSON `null`; an unencodable id reports overall encode
    /// failure (the legacy `isValidJSONObject` behavior).
    private nonisolated static func v2WireId(_ id: Any?) -> JSONValue? {
        guard let id else { return .null }
        return JSONValue(foundationObject: id)
    }

    /// Bridge an async throws closure into a socket RPC response. Runs the work on a detached
    /// Task (so VMClient's URLSession hops are free to use any actor) and blocks the socket
    /// worker thread on a semaphore. Mirrors the auth.begin_sign_in pattern above.
    nonisolated func v2VmCall(
        id: Any?,
        timeoutSeconds: TimeInterval = 17 * 60,
        _ work: @escaping () async throws -> [String: Any]
    ) -> String {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Result<[String: Any], Error>?
        let task = Task {
            do {
                result = .success(try await work())
            } catch {
                result = .failure(error)
            }
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + timeoutSeconds) == .timedOut {
            task.cancel()
            return v2Error(
                id: id,
                code: "timeout",
                message: "VM request timed out after \(Int(timeoutSeconds)) seconds"
            )
        }
        switch result {
        case .success(let payload):
            return v2Ok(id: id, result: payload)
        case .failure(let error):
            return v2Error(
                id: id,
                code: "vm_error",
                message: String(describing: error)
            )
        case nil:
            return v2Error(
                id: id,
                code: "vm_error",
                message: "unknown vm error"
            )
        }
    }

    nonisolated func v2AsyncResultCall(
        id: Any?,
        timeoutSeconds: TimeInterval,
        _ work: @escaping () async -> V2CallResult
    ) -> String {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: V2CallResult?
        let task = Task {
            result = await work()
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + timeoutSeconds) == .timedOut {
            task.cancel()
            return v2Error(
                id: id,
                code: "timeout",
                message: "Request timed out after \(Int(timeoutSeconds)) seconds"
            )
        }
        guard let result else {
            return v2Error(
                id: id,
                code: "request_error",
                message: "Request failed before returning a result"
            )
        }
        return v2Result(id: id, result)
    }

    nonisolated func v2Error(id: Any?, code: String, message: String, data: Any? = nil) -> String {
        guard let idValue = Self.v2WireId(id) else {
            return ControlResponseEncoder.encodeFailureResponse
        }
        var dataValue: JSONValue?
        if let data {
            guard let bridgedData = JSONValue(foundationObject: data) else {
                return ControlResponseEncoder.encodeFailureResponse
            }
            dataValue = bridgedData
        }
        return Self.v2Encoder.error(id: idValue, code: code, message: message, data: dataValue)
    }

    /// Interim `Any`-shaped twin of the package's `ControlCallResult`, kept
    /// while the command bodies still build Foundation payloads. Bodies
    /// migrate onto the typed DTO in the ControlCommandCoordinator stage.
    enum V2CallResult {
        case ok(Any)
        case err(code: String, message: String, data: Any?)
    }

    private nonisolated func v2Result(id: Any?, _ res: V2CallResult) -> String {
        switch res {
        case .ok(let payload):
            return v2Ok(id: id, result: payload)
        case .err(let code, let message, let data):
            return v2Error(id: id, code: code, message: message, data: data)
        }
    }

    private nonisolated func v2UnsupportedWorkspaceAliasError(method: String, params: [String: Any]) -> V2CallResult? {
        guard method.hasPrefix("workspace."), params.keys.contains("window") else { return nil }
        return .err(
            code: "invalid_params",
            message: String(
                localized: "socket.workspace.unsupportedWindowParam",
                defaultValue: "Unsupported parameter `window`; use `window_id` with a window UUID or ref from `window.list`."
            ),
            data: [
                "method": method,
                "unsupported_param": "window",
                "supported_param": "window_id"
            ]
        )
    }

    private nonisolated func v2Encode(_ object: Any) -> String {
        guard let value = JSONValue(foundationObject: object) else {
            return ControlResponseEncoder.encodeFailureResponse
        }
        return Self.v2Encoder.encode(value)
    }

    private func v2EnsureHandleRef(kind: ControlHandleKind, uuid: UUID) -> String {
        controlCommandCoordinator.ensureRef(kind: kind, uuid: uuid)
    }

    func v2ResolveHandleRef(_ handle: String) -> UUID? {
        controlCommandCoordinator.resolveRef(handle)
    }

    nonisolated func v2Ref(kind: ControlHandleKind, uuid: UUID?) -> Any {
        guard let uuid else { return NSNull() }
        return v2MainSync { v2EnsureHandleRef(kind: kind, uuid: uuid) }
    }

    func v2WorkspaceRefs(for ids: [UUID]) -> [UUID: String] {
        var refs: [UUID: String] = [:]
        refs.reserveCapacity(ids.count)
        for id in ids {
            refs[id] = v2EnsureHandleRef(kind: .workspace, uuid: id)
        }
        return refs
    }

    func v2WorkspacePaneAndSurfaceRefs(
        workspaceId: UUID,
        paneId: UUID?,
        surfaceId: UUID
    ) -> (workspaceRef: String, paneRef: String?, surfaceRef: String) {
        return (
            workspaceRef: v2EnsureHandleRef(kind: .workspace, uuid: workspaceId),
            paneRef: paneId.map { v2EnsureHandleRef(kind: .pane, uuid: $0) },
            surfaceRef: v2EnsureHandleRef(kind: .surface, uuid: surfaceId)
        )
    }

    func v2TabRef(uuid: UUID?) -> Any {
        guard let uuid else { return NSNull() }
        let surfaceRef = v2EnsureHandleRef(kind: .surface, uuid: uuid)
        return surfaceRef.replacingOccurrences(of: "surface:", with: "tab:")
    }

    private func v2RefreshKnownRefs() {
        guard let app = AppDelegate.shared else { return }

        let windows = app.listMainWindowSummaries()
        for item in windows {
            _ = v2EnsureHandleRef(kind: .window, uuid: item.windowId)
            if let tm = app.tabManagerFor(windowId: item.windowId) {
                for ws in tm.tabs {
                    _ = v2EnsureHandleRef(kind: .workspace, uuid: ws.id)
                    for paneId in ws.bonsplitController.allPaneIds {
                        _ = v2EnsureHandleRef(kind: .pane, uuid: paneId.id)
                    }
                    for panelId in ws.panels.keys {
                        _ = v2EnsureHandleRef(kind: .surface, uuid: panelId)
                    }
                }
                // Mint workspace_group refs for groups that exist before any
                // workspace.group.* call so callers can pass `workspace_group:N`
                // immediately after restore (otherwise the first ref hand-off
                // happens only on `list`/`create`).
                for group in tm.workspaceGroups {
                    _ = v2EnsureHandleRef(kind: .workspaceGroup, uuid: group.id)
                }
            }
        }
    }

    // MARK: - V2 Context Resolution

    nonisolated func v2ResolveTabManager(params: [String: Any]) -> TabManager? {
        // Prefer explicit window_id routing. Otherwise prefer group_id (group
        // methods are the only routing key for cross-window group ops, and
        // CLI helpers always inject caller workspace_id/surface_id, which
        // would otherwise win even when the group belongs to a different
        // window). Fall back to workspace/surface/pane lookup, then the
        // active window's TabManager.
        if v2HasNonNullParam(params, "window_id") {
            guard let windowId = v2UUID(params, "window_id") else { return nil }
            return v2MainSync { AppDelegate.shared?.tabManagerFor(windowId: windowId) }
        }
        if let groupId = v2UUID(params, "group_id") {
            if let tm = v2MainSync({ v2LocateTabManager(forGroupId: groupId) }) {
                return tm
            }
        }
        if let wsId = v2UUID(params, "workspace_id") {
            if let tm = v2MainSync({ AppDelegate.shared?.tabManagerFor(tabId: wsId) }) {
                return tm
            }
        }
        if let surfaceId = v2UUID(params, "surface_id")
            ?? v2UUID(params, "terminal_id")
            ?? v2UUID(params, "tab_id") {
            if let located = v2MainSync({ AppDelegate.shared?.locateSurface(surfaceId: surfaceId) ?? locateDockSurface(surfaceId) }) { return located.tabManager }
        }
        if let paneId = v2UUID(params, "pane_id") {
            if let tm = v2MainSync({ v2LocatePane(paneId)?.tabManager ?? locateDockPane(paneId)?.tabManager }) {
                return tm
            }
        }
        return v2MainSync { tabManager ?? AppDelegate.shared?.currentScriptableMainWindow()?.tabManager }
    }

    @MainActor
    private func v2LocateTabManager(forGroupId groupId: UUID) -> TabManager? {
        guard let app = AppDelegate.shared else { return nil }
        for summary in app.listMainWindowSummaries() {
            guard let tm = app.tabManagerFor(windowId: summary.windowId) else { continue }
            if tm.workspaceGroups.contains(where: { $0.id == groupId }) {
                return tm
            }
        }
        return nil
    }

    /// Mirrors the former `v2ResolveTabManager` precedence for the
    /// ``ControlCommandContext`` window resolution, operating on selectors the
    /// coordinator already resolved through the shared handle registry: explicit
    /// `window_id` wins (a present-but-unresolvable one yields no target), then
    /// group, workspace, surface, pane, then the caller's window, then the
    /// active scriptable window. Lives here so it can read the controller's
    /// `private` `tabManager` / `v2LocateTabManager`.
    func resolveTabManager(routing: ControlRoutingSelectors) -> TabManager? {
        if routing.hasWindowIDParam {
            guard let windowId = routing.windowID else { return nil }
            return AppDelegate.shared?.tabManagerFor(windowId: windowId)
        }
        if let groupId = routing.groupID,
           let tm = v2LocateTabManager(forGroupId: groupId) {
            return tm
        }
        if let workspaceId = routing.workspaceID,
           let tm = AppDelegate.shared?.tabManagerFor(tabId: workspaceId) {
            return tm
        }
        if let surfaceId = routing.surfaceID {
            if let located = AppDelegate.shared?.locateSurface(surfaceId: surfaceId) ?? locateDockSurface(surfaceId) { return located.tabManager }
        }
        if let paneId = routing.paneID,
           let tm = v2LocatePane(paneId)?.tabManager ?? locateDockPane(paneId)?.tabManager {
            return tm
        }
        return tabManager ?? AppDelegate.shared?.currentScriptableMainWindow()?.tabManager
    }

    func v2ResolveWindowId(tabManager: TabManager?) -> UUID? {
        guard let tabManager else { return nil }
        return v2MainSync { AppDelegate.shared?.windowId(for: tabManager) }
    }

    private func v2ResolveWorkspaceOwner(_ workspaceId: UUID) -> TabManager? {
        v2MainSync { AppDelegate.shared?.tabManagerFor(tabId: workspaceId) }
    }

    // MARK: - V2 Workspace Methods

    @MainActor

    private func v2ExtensionSidebarRootPath(for workspace: Workspace) -> String? {
        let trimmed = workspace.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// `workspace.set_auto_title`: applies an AI-generated title to a workspace
    /// (and optionally one of its panels/tabs) with `.auto` provenance, so a
    /// user-set title is never overwritten. Gated on the opt-in
    /// `workspaceAutoNamingEnabled` setting; `{"probe": true}` reads the live
    /// setting state without writing, which lets hook processes honor
    /// mid-session toggles. `panel_id` accepts either a panel UUID or a
    /// surface UUID.
    private func v2WorkspaceSetAutoTitle(params: [String: Any]) -> V2CallResult {
        let enabled = AutomationCatalogSection().workspaceAutoNaming.value(in: .standard)
        if v2Bool(params, "probe") == true {
            let agentSlug = AutomationCatalogSection().autoNamingAgent.value(in: .standard)
            var result: [String: Any] = [
                "enabled": enabled,
                "summarizer_agent": v2OrNull(agentSlug == AutoNamingAgentCatalog.autoSlug ? nil : agentSlug)
            ]
            // With a workspace_id the probe also reports user ownership, so
            // naming engines can skip the LLM call entirely for workspaces
            // the user renamed.
            if let workspaceId = v2UUID(params, "workspace_id"),
               let tabManager = v2ResolveTabManager(params: params) {
                var userOwned: Bool?
                v2MainSync {
                    guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) else { return }
                    userOwned = workspace.effectiveCustomTitleSource == .user
                }
                result["workspace_user_owned"] = v2OrNull(userOwned)
            }
            return .ok(result)
        }
        guard enabled else {
            return .err(code: "disabled", message: "Workspace auto-naming is disabled in Settings", data: ["enabled": false])
        }
        // A naming pass reporting a problem (rate limit / out of tokens / signed
        // out / missing override binary). Recorded for the Settings status line
        // only — it never reaches a workspace or tab title.
        if let failure = v2String(params, "failure") {
            AutoNamingStatusStore.record(
                rawCategory: failure,
                agent: v2String(params, "agent") ?? "",
                at: Date().timeIntervalSince1970
            )
            return .ok(["recorded": true, "enabled": true])
        }
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let workspaceId = v2UUID(params, "workspace_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }
        guard let titleRaw = v2String(params, "title"),
              !titleRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .err(code: "invalid_params", message: "Missing or invalid title", data: nil)
        }
        let panelId = v2UUID(params, "panel_id")

        let title = titleRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        let panelOnlyIfMultiple = v2Bool(params, "panel_only_if_multiple") ?? false
        var found = false
        var workspaceApplied = false
        var panelApplied: Bool?
        v2MainSync {
            guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) else { return }
            found = true
            workspaceApplied = tabManager.setCustomTitle(tabId: workspaceId, title: title, source: .auto)
            if let panelId {
                // Hook payloads carry surface ids; accept either a panel id
                // or a surface id for the tab target.
                let resolvedPanelId = workspace.panels[panelId] != nil
                    ? panelId
                    : workspace.panelIdFromSurfaceId(TabID(uuid: panelId))
                if let resolvedPanelId,
                   !(panelOnlyIfMultiple && workspace.panels.count < 2) {
                    panelApplied = workspace.setPanelCustomTitle(panelId: resolvedPanelId, title: title, source: .auto)
                }
            }
        }

        guard found else {
            return .err(code: "not_found", message: "Workspace not found", data: [
                "workspace_id": workspaceId.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId)
            ])
        }

        // A title landed, so the naming agent is working again: clear any stale
        // failure the Settings status line may be showing.
        if workspaceApplied {
            AutoNamingStatusStore.clear()
        }

        return .ok([
            "workspace_id": workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
            "title": title,
            "workspace_applied": workspaceApplied,
            "panel_applied": v2OrNull(panelApplied),
            "enabled": true
        ])
    }





















    private nonisolated func v2RequestedRemotePTYWorkspaceID(params: [String: Any]) -> (
        workspaceId: UUID?,
        error: V2CallResult?
    ) {
        var workspaceId: UUID?
        var invalidWorkspaceID = false
        v2MainSync {
            v2RefreshKnownRefs()
            workspaceId = v2UUID(params, "workspace_id")
            invalidWorkspaceID = v2HasNonNullParam(params, "workspace_id") && workspaceId == nil
        }
        if invalidWorkspaceID {
            return (
                nil,
                .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
            )
        }
        return (workspaceId, nil)
    }

    private nonisolated func v2RequestedRemotePTYSurfaceID(params: [String: Any]) -> (
        surfaceId: UUID?,
        error: V2CallResult?
    ) {
        var surfaceId: UUID?
        var invalidSurfaceID = false
        v2MainSync {
            v2RefreshKnownRefs()
            surfaceId = v2UUID(params, "surface_id")
            invalidSurfaceID = v2HasNonNullParam(params, "surface_id") && surfaceId == nil
        }
        if invalidSurfaceID {
            return (
                nil,
                .err(code: "invalid_params", message: "Missing or invalid surface_id", data: nil)
            )
        }
        return (surfaceId, nil)
    }

    private nonisolated func v2ResolveRemotePTYTarget(
        params: [String: Any],
        requestedWorkspaceId: UUID?,
        preferredSurfaceId: UUID? = nil
    ) -> (target: RemotePTYSocketTarget?, error: V2CallResult?) {
        if v2HasNonNullParam(params, "allow_moved_surface"),
           v2Bool(params, "allow_moved_surface") == nil {
            return (
                nil,
                .err(code: "invalid_params", message: "Missing or invalid allow_moved_surface", data: nil)
            )
        }
        let allowMovedSurface = v2Bool(params, "allow_moved_surface") ?? false
        let requestedSessionID = v2RawString(params, "session_id").flatMap { raw -> String? in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        var resolvedWorkspaceId: UUID?
        var target: RemotePTYSocketTarget?
        var workspaceMismatchData: [String: Any]?

        v2MainSync {
            v2RefreshKnownRefs()
            let fallbackTabManager = v2ResolveTabManager(params: params)
            let fallbackWorkspaceId = requestedWorkspaceId ?? fallbackTabManager?.selectedTabId
            var owner: TabManager?
            var workspace: Workspace?
            if let preferredSurfaceId {
                if let fallbackTabManager,
                   let surfaceWorkspace = fallbackTabManager.tabs.first(where: {
                       $0.panels[preferredSurfaceId] != nil
                           && $0.surfaceIdFromPanelId(preferredSurfaceId) != nil
                   }) {
                    owner = fallbackTabManager
                    workspace = surfaceWorkspace
                } else if let located = AppDelegate.shared?.workspaceContainingPanel(
                    panelId: preferredSurfaceId,
                    preferredWorkspaceId: fallbackWorkspaceId
                ) {
                    owner = located.tabManager
                    workspace = located.workspace
                }
            }
            if workspace == nil,
               let fallbackWorkspaceId,
               let fallbackOwner = AppDelegate.shared?.tabManagerFor(tabId: fallbackWorkspaceId),
               let fallbackWorkspace = fallbackOwner.tabs.first(where: { $0.id == fallbackWorkspaceId }) {
                owner = fallbackOwner
                workspace = fallbackWorkspace
            }
            resolvedWorkspaceId = workspace?.id ?? fallbackWorkspaceId
            guard let owner, let workspace else {
                return
            }
            if let requestedWorkspaceId,
               workspace.id != requestedWorkspaceId {
                let matchedMovedSurface = allowMovedSurface
                    && preferredSurfaceId.map {
                        workspace.remotePTYSessionIDMatches(panelId: $0, sessionID: requestedSessionID)
                    } == true
                guard matchedMovedSurface else {
                    workspaceMismatchData = [
                        "workspace_id": requestedWorkspaceId.uuidString,
                        "workspace_ref": v2Ref(kind: .workspace, uuid: requestedWorkspaceId),
                        "surface_id": v2OrNull(preferredSurfaceId?.uuidString),
                        "surface_ref": v2Ref(kind: .surface, uuid: preferredSurfaceId),
                        "resolved_workspace_id": workspace.id.uuidString,
                        "resolved_workspace_ref": v2Ref(kind: .workspace, uuid: workspace.id),
                    ]
                    return
                }
            }

            let windowId = v2ResolveWindowId(tabManager: owner)
            target = RemotePTYSocketTarget(
                controller: workspace.remotePTYSessionControllerForSocketCommand(),
                windowId: windowId,
                windowRef: v2Ref(kind: .window, uuid: windowId),
                workspaceId: workspace.id,
                workspaceRef: v2Ref(kind: .workspace, uuid: workspace.id),
                workspaceTitle: workspace.title
            )
        }

        if let workspaceMismatchData {
            return (
                nil,
                .err(
                    code: "invalid_params",
                    message: "surface_id does not belong to workspace_id",
                    data: workspaceMismatchData
                )
            )
        }
        guard let resolvedWorkspaceId else {
            return (
                nil,
                .err(code: "invalid_params", message: "Missing workspace_id", data: nil)
            )
        }
        guard let target else {
            return (
                nil,
                .err(
                    code: "not_found",
                    message: "Workspace not found",
                    data: v2RemotePTYWorkspaceData(workspaceId: resolvedWorkspaceId)
                )
            )
        }
        return (target, nil)
    }

    nonisolated func notifyRemotePTYControllerAvailabilityChanged() {
        remotePTYControllerAvailabilityCondition.lock()
        remotePTYControllerAvailabilityGeneration &+= 1
        remotePTYControllerAvailabilityCondition.broadcast()
        remotePTYControllerAvailabilityCondition.unlock()
    }

    private nonisolated func v2ResolveRemotePTYTargetWaitingForController(
        params: [String: Any],
        requestedWorkspaceId: UUID?,
        preferredSurfaceId: UUID?,
        deadline: Date
    ) -> (target: RemotePTYSocketTarget?, error: V2CallResult?) {
        var observedGeneration: UInt64?

        while true {
            let resolved = v2ResolveRemotePTYTarget(
                params: params,
                requestedWorkspaceId: requestedWorkspaceId,
                preferredSurfaceId: preferredSurfaceId
            )
            if let error = resolved.error {
                return (nil, error)
            }
            guard let target = resolved.target else {
                return resolved
            }
            if target.controller != nil || Date() >= deadline {
                return (target, nil)
            }

            remotePTYControllerAvailabilityCondition.lock()
            let currentGeneration = remotePTYControllerAvailabilityGeneration
            guard let previousGeneration = observedGeneration else {
                observedGeneration = currentGeneration
                remotePTYControllerAvailabilityCondition.unlock()
                continue
            }
            if previousGeneration != currentGeneration {
                observedGeneration = currentGeneration
                remotePTYControllerAvailabilityCondition.unlock()
                continue
            }
            _ = remotePTYControllerAvailabilityCondition.wait(until: deadline)
            observedGeneration = remotePTYControllerAvailabilityGeneration
            remotePTYControllerAvailabilityCondition.unlock()
        }
    }

    private nonisolated func v2RemotePTYWorkspaceData(workspaceId: UUID) -> [String: Any] {
        var workspaceRef: Any = NSNull()
        v2MainSync {
            workspaceRef = v2Ref(kind: .workspace, uuid: workspaceId)
        }
        return [
            "workspace_id": workspaceId.uuidString,
            "workspace_ref": workspaceRef,
        ]
    }

    private nonisolated func v2RemotePTYTargetPayload(_ target: RemotePTYSocketTarget) -> [String: Any] {
        [
            "window_id": v2OrNull(target.windowId?.uuidString),
            "window_ref": target.windowRef,
            "workspace_id": target.workspaceId.uuidString,
            "workspace_ref": target.workspaceRef,
            "workspace_title": target.workspaceTitle,
        ]
    }

    /// `workspace.env` — read a workspace's user-defined environment (issue #5995).
    /// Resolves the workspace by `workspace_id` / surface / pane, falling back to the
    /// selected workspace only when no explicit target is supplied, and returns the
    /// raw configured set. An explicit-but-unresolvable target errors. Secret masking is a
    /// CLI presentation concern (`cmux workspace env --mask`): the local control
    /// socket already exposes the surrounding workspace state, so values are returned
    /// verbatim and the env set is deliberately kept out of `workspace.list` so a
    /// plain listing never echoes secrets.
    private nonisolated func v2WorkspaceEnv(params: [String: Any]) -> V2CallResult {
        // Validate any explicit target before resolving. This endpoint can print
        // secrets, so a malformed or stale explicit target must error rather than
        // silently fall back to the selected workspace (unlike the generic
        // v2ResolveWorkspace, which falls through to the selection).
        for key in ["workspace_id", "surface_id", "terminal_id", "tab_id", "pane_id"] {
            if v2HasNonNullParam(params, key), v2UUID(params, key) == nil {
                return .err(code: "invalid_params", message: "Missing or invalid \(key)", data: nil)
            }
        }
        return v2MainSync { () -> V2CallResult in
            v2RefreshKnownRefs()
            guard let tabManager = v2ResolveTabManager(params: params) else {
                return .err(code: "unavailable", message: "TabManager not available", data: nil)
            }
            // Resolve strictly for explicit targets; only fall back to the selected
            // workspace when no explicit target was supplied.
            let resolved: Workspace?
            if let wsId = v2UUID(params, "workspace_id") {
                resolved = tabManager.tabs.first(where: { $0.id == wsId })
            } else if let surfaceId = v2UUID(params, "surface_id") ?? v2UUID(params, "terminal_id") ?? v2UUID(params, "tab_id") {
                resolved = tabManager.tabs.first(where: { $0.panels[surfaceId] != nil })
            } else if let paneId = v2UUID(params, "pane_id") {
                if let located = v2LocatePane(paneId), located.tabManager === tabManager {
                    resolved = located.workspace
                } else {
                    resolved = nil
                }
            } else if let selectedId = tabManager.selectedTabId {
                resolved = tabManager.tabs.first(where: { $0.id == selectedId })
            } else {
                resolved = nil
            }
            guard let workspace = resolved else {
                return .err(code: "not_found", message: "Workspace not found", data: nil)
            }
            let windowId = v2ResolveWindowId(tabManager: tabManager)
            let env = workspace.workspaceEnvironment
            return .ok([
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "workspace_id": workspace.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: workspace.id),
                "env": env,
                "count": env.count,
            ])
        }
    }

    private nonisolated func v2WorkspaceRemotePTYSessions(params: [String: Any]) -> V2CallResult {
        if v2HasNonNullParam(params, "all_workspaces"), v2Bool(params, "all_workspaces") == nil {
            return .err(code: "invalid_params", message: "Missing or invalid all_workspaces", data: nil)
        }
        let allWorkspaces = v2Bool(params, "all_workspaces") ?? false
        let workspaceSelection = v2RequestedRemotePTYWorkspaceID(params: params)
        if let error = workspaceSelection.error { return error }
        let surfaceSelection = v2RequestedRemotePTYSurfaceID(params: params)
        if let error = surfaceSelection.error { return error }
        let requestedWorkspaceId = workspaceSelection.workspaceId
        if allWorkspaces, requestedWorkspaceId != nil {
            return .err(code: "invalid_params", message: "all_workspaces cannot be combined with workspace_id", data: nil)
        }
        if allWorkspaces {
            var targets: [RemotePTYSocketTarget] = []
            v2MainSync {
                v2RefreshKnownRefs()
                guard let app = AppDelegate.shared else { return }
                for summary in app.listMainWindowSummaries() {
                    guard let owner = app.tabManagerFor(windowId: summary.windowId) else { continue }
                    for workspace in owner.tabs where workspace.isRemoteWorkspace {
                        targets.append(
                            RemotePTYSocketTarget(
                                controller: workspace.remotePTYSessionControllerForSocketCommand(),
                                windowId: summary.windowId,
                                windowRef: v2Ref(kind: .window, uuid: summary.windowId),
                                workspaceId: workspace.id,
                                workspaceRef: v2Ref(kind: .workspace, uuid: workspace.id),
                                workspaceTitle: workspace.title
                            )
                        )
                    }
                }
            }

            var sessions: [[String: Any]] = []
            var errors: [[String: Any]] = []
            for target in targets {
                guard let controller = target.controller else {
                    var payload = v2RemotePTYTargetPayload(target)
                    payload["error"] = "remote connection is not active"
                    errors.append(payload)
                    continue
                }
                do {
                    let workspaceSessions = try controller.listPTYSessions()
                    sessions.append(contentsOf: workspaceSessions.map {
                        v2RemotePTYSessionPayload($0, target: target)
                    })
                } catch {
                    var payload = v2RemotePTYTargetPayload(target)
                    payload["error"] = v2RemotePTYUserFacingErrorMessage(error)
                    errors.append(payload)
                }
            }

            return .ok([
                "all_workspaces": true,
                "workspace_count": targets.count,
                "sessions": sessions,
                "errors": errors,
            ])
        }

        let resolved = v2ResolveRemotePTYTarget(
            params: params,
            requestedWorkspaceId: requestedWorkspaceId,
            preferredSurfaceId: surfaceSelection.surfaceId
        )
        if let error = resolved.error { return error }
        guard let target = resolved.target else {
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        }
        guard let controller = target.controller else {
            return .err(code: "remote_pty_error", message: "remote connection is not active", data: [
                "workspace_id": target.workspaceId.uuidString,
                "workspace_ref": target.workspaceRef,
            ])
        }

        do {
            let sessions = try controller.listPTYSessions()
            var payload = v2RemotePTYTargetPayload(target)
            payload["sessions"] = sessions.map { v2RemotePTYSessionPayload($0, target: target) }
            return .ok(payload)
        } catch {
            return .err(code: "remote_pty_error", message: v2RemotePTYUserFacingErrorMessage(error), data: [
                "workspace_id": target.workspaceId.uuidString,
                "workspace_ref": target.workspaceRef,
            ])
        }
    }

    private nonisolated func v2RemotePTYSessionPayload(
        _ session: [String: Any],
        target: RemotePTYSocketTarget
    ) -> [String: Any] {
        var payload = session
        payload["window_id"] = v2OrNull(target.windowId?.uuidString)
        payload["window_ref"] = target.windowRef
        payload["workspace_id"] = target.workspaceId.uuidString
        payload["workspace_ref"] = target.workspaceRef
        payload["workspace_title"] = target.workspaceTitle
        return payload
    }

    private nonisolated func v2WorkspaceRemotePTYClose(params: [String: Any]) -> V2CallResult {
        let workspaceSelection = v2RequestedRemotePTYWorkspaceID(params: params)
        if let error = workspaceSelection.error { return error }
        guard let sessionID = v2RawString(params, "session_id")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionID.isEmpty else {
            return .err(code: "invalid_params", message: "Missing session_id", data: nil)
        }
        let surfaceSelection = v2RequestedRemotePTYSurfaceID(params: params)
        if let error = surfaceSelection.error { return error }

        let resolved = v2ResolveRemotePTYTarget(
            params: params,
            requestedWorkspaceId: workspaceSelection.workspaceId,
            preferredSurfaceId: surfaceSelection.surfaceId
        )
        if let error = resolved.error { return error }
        guard let target = resolved.target else {
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        }
        guard let controller = target.controller else {
            return .err(code: "remote_pty_error", message: "remote connection is not active", data: [
                "workspace_id": target.workspaceId.uuidString,
                "workspace_ref": target.workspaceRef,
                "session_id": sessionID,
            ])
        }

        do {
            try controller.closePTYSession(sessionID: sessionID)
            var payload = v2RemotePTYTargetPayload(target)
            payload["session_id"] = sessionID
            payload["closed"] = true
            return .ok(payload)
        } catch {
            return .err(code: "remote_pty_error", message: v2RemotePTYUserFacingErrorMessage(error), data: [
                "workspace_id": target.workspaceId.uuidString,
                "workspace_ref": target.workspaceRef,
                "session_id": sessionID,
            ])
        }
    }

    private nonisolated func v2WorkspaceRemotePTYDetach(params: [String: Any]) -> V2CallResult {
        let workspaceSelection = v2RequestedRemotePTYWorkspaceID(params: params)
        if let error = workspaceSelection.error { return error }
        guard let sessionID = v2RawString(params, "session_id")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionID.isEmpty else {
            return .err(code: "invalid_params", message: "Missing session_id", data: nil)
        }
        guard let attachmentID = v2RawString(params, "attachment_id")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !attachmentID.isEmpty else {
            return .err(code: "invalid_params", message: "Missing attachment_id", data: nil)
        }
        guard let attachmentToken = v2RawString(params, "attachment_token")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !attachmentToken.isEmpty else {
            return .err(code: "invalid_params", message: "Missing attachment_token", data: nil)
        }
        let surfaceSelection = v2RequestedRemotePTYSurfaceID(params: params)
        if let error = surfaceSelection.error { return error }

        let resolved = v2ResolveRemotePTYTarget(
            params: params,
            requestedWorkspaceId: workspaceSelection.workspaceId,
            preferredSurfaceId: surfaceSelection.surfaceId
        )
        if let error = resolved.error { return error }
        guard let target = resolved.target else {
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        }
        guard let controller = target.controller else {
            return .err(code: "remote_pty_error", message: "remote connection is not active", data: [
                "workspace_id": target.workspaceId.uuidString,
                "workspace_ref": target.workspaceRef,
                "session_id": sessionID,
                "attachment_id": attachmentID,
            ])
        }

        do {
            try controller.detachPTYSession(
                sessionID: sessionID,
                attachmentID: attachmentID,
                attachmentToken: attachmentToken
            )
            var payload = v2RemotePTYTargetPayload(target)
            payload["session_id"] = sessionID
            payload["attachment_id"] = attachmentID
            payload["detached"] = true
            return .ok(payload)
        } catch {
            return .err(code: "remote_pty_error", message: v2RemotePTYUserFacingErrorMessage(error), data: [
                "workspace_id": target.workspaceId.uuidString,
                "workspace_ref": target.workspaceRef,
                "session_id": sessionID,
                "attachment_id": attachmentID,
            ])
        }
    }

    private nonisolated func v2WorkspaceRemotePTYBridge(params: [String: Any]) -> V2CallResult {
        let workspaceSelection = v2RequestedRemotePTYWorkspaceID(params: params)
        if let error = workspaceSelection.error { return error }
        guard let sessionID = v2RawString(params, "session_id")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionID.isEmpty else {
            return .err(code: "invalid_params", message: "Missing session_id", data: nil)
        }
        let attachmentID = (v2RawString(params, "attachment_id")?
            .trimmingCharacters(in: .whitespacesAndNewlines))
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? UUID().uuidString.lowercased()
        let command = v2RawString(params, "command")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let requireExisting = v2Bool(params, "require_existing") ?? false
        let waitForReady = v2Bool(params, "wait_for_ready") ?? false
        let surfaceSelection = v2RequestedRemotePTYSurfaceID(params: params)
        if let error = surfaceSelection.error { return error }
        let preferredSurfaceId = surfaceSelection.surfaceId ?? UUID(uuidString: attachmentID)

        let controllerDeadline = Date().addingTimeInterval(waitForReady ? 90.0 : 8.0)
        let resolved = waitForReady
            ? v2ResolveRemotePTYTargetWaitingForController(
                params: params,
                requestedWorkspaceId: workspaceSelection.workspaceId,
                preferredSurfaceId: preferredSurfaceId,
                deadline: controllerDeadline
            )
            : v2ResolveRemotePTYTarget(
                params: params,
                requestedWorkspaceId: workspaceSelection.workspaceId,
                preferredSurfaceId: preferredSurfaceId
            )
        if let error = resolved.error { return error }
        guard let target = resolved.target else {
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        }
        guard let controller = target.controller else {
            return .err(code: "remote_pty_error", message: "remote connection is not active", data: [
                "workspace_id": target.workspaceId.uuidString,
                "workspace_ref": target.workspaceRef,
                "session_id": sessionID,
                "attachment_id": attachmentID,
            ])
        }

        do {
            let endpoint = try controller.startPTYBridge(
                sessionID: sessionID,
                attachmentID: attachmentID,
                command: command?.isEmpty == true ? nil : command,
                requireExisting: requireExisting,
                waitForReady: waitForReady,
                timeout: waitForReady ? 90.0 : max(0.1, controllerDeadline.timeIntervalSinceNow)
            )
            var payload = v2RemotePTYTargetPayload(target)
            payload["host"] = endpoint.host
            payload["port"] = endpoint.port
            payload["token"] = endpoint.token
            payload["session_id"] = endpoint.sessionID
            payload["attachment_id"] = endpoint.attachmentID
            return .ok(payload)
        } catch {
            return .err(code: "remote_pty_error", message: v2RemotePTYUserFacingErrorMessage(error), data: [
                "workspace_id": target.workspaceId.uuidString,
                "workspace_ref": target.workspaceRef,
                "session_id": sessionID,
                "attachment_id": attachmentID,
            ])
        }
    }

    private nonisolated func v2WorkspaceRemotePTYResize(params: [String: Any]) -> V2CallResult {
        let workspaceSelection = v2RequestedRemotePTYWorkspaceID(params: params)
        if let error = workspaceSelection.error { return error }
        guard let sessionID = v2RawString(params, "session_id")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionID.isEmpty else {
            return .err(code: "invalid_params", message: "Missing session_id", data: nil)
        }
        guard let attachmentID = v2RawString(params, "attachment_id")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !attachmentID.isEmpty else {
            return .err(code: "invalid_params", message: "Missing attachment_id", data: nil)
        }
        guard let attachmentToken = v2RawString(params, "attachment_token")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !attachmentToken.isEmpty else {
            return .err(code: "invalid_params", message: "Missing attachment_token", data: nil)
        }
        guard let cols = v2StrictInt(params, "cols"), cols > 0,
              let rows = v2StrictInt(params, "rows"), rows > 0 else {
            return .err(code: "invalid_params", message: "cols and rows must be positive integers", data: nil)
        }
        let surfaceSelection = v2RequestedRemotePTYSurfaceID(params: params)
        if let error = surfaceSelection.error { return error }

        let resolved = v2ResolveRemotePTYTarget(
            params: params,
            requestedWorkspaceId: workspaceSelection.workspaceId,
            preferredSurfaceId: surfaceSelection.surfaceId
        )
        if let error = resolved.error { return error }
        guard let target = resolved.target else {
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        }
        guard let controller = target.controller else {
            return .err(code: "remote_pty_error", message: "remote connection is not active", data: [
                "workspace_id": target.workspaceId.uuidString,
                "workspace_ref": target.workspaceRef,
                "session_id": sessionID,
                "attachment_id": attachmentID,
            ])
        }

        do {
            try controller.resizePTY(
                sessionID: sessionID,
                attachmentID: attachmentID,
                attachmentToken: attachmentToken,
                cols: cols,
                rows: rows
            )
            var payload = v2RemotePTYTargetPayload(target)
            payload["session_id"] = sessionID
            payload["attachment_id"] = attachmentID
            payload["attachment_token"] = attachmentToken
            payload["cols"] = cols
            payload["rows"] = rows
            payload["resized"] = true
            return .ok(payload)
        } catch {
            return .err(code: "remote_pty_error", message: v2RemotePTYUserFacingErrorMessage(error), data: [
                "workspace_id": target.workspaceId.uuidString,
                "workspace_ref": target.workspaceRef,
                "session_id": sessionID,
                "attachment_id": attachmentID,
            ])
        }
    }






    @MainActor

    func v2WorkspaceAction(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let action = v2ActionKey(params) else {
            return .err(code: "invalid_params", message: "Missing action", data: nil)
        }
        let supportedActions = [
            "pin", "unpin", "rename", "clear_name",
            "set_description", "clear_description",
            "move_up", "move_down", "move_top",
            "close_others", "close_above", "close_below",
            "mark_read", "mark_unread",
            "set_color", "clear_color"
        ]

        var result: V2CallResult = .err(code: "invalid_params", message: "Unknown workspace action", data: [
            "action": action,
            "supported_actions": supportedActions
        ])

        v2MainSync {
            let requestedWorkspaceId = v2UUID(params, "workspace_id") ?? tabManager.selectedTabId
            guard let workspaceId = requestedWorkspaceId,
                  let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }

            let windowId = v2ResolveWindowId(tabManager: tabManager)

            @MainActor
            func closeWorkspaces(_ workspaces: [Workspace]) -> Int {
                var closed = 0
                for candidate in workspaces where candidate.id != workspace.id {
                    let existedBefore = tabManager.tabs.contains(where: { $0.id == candidate.id })
                    guard existedBefore else { continue }
                    tabManager.closeWorkspace(candidate)
                    if !tabManager.tabs.contains(where: { $0.id == candidate.id }) {
                        closed += 1
                    }
                }
                return closed
            }

            @MainActor
            func finish(_ extras: [String: Any] = [:]) {
                var payload: [String: Any] = [
                    "action": action,
                    "workspace_id": workspace.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: workspace.id),
                    "window_id": v2OrNull(windowId?.uuidString),
                    "window_ref": v2Ref(kind: .window, uuid: windowId)
                ]
                for (key, value) in extras {
                    payload[key] = value
                }
                result = .ok(payload)
            }

            switch action {
            case "pin":
                tabManager.setPinned(workspace, pinned: true)
                finish(["pinned": true])

            case "unpin":
                tabManager.setPinned(workspace, pinned: false)
                finish(["pinned": false])

            case "rename":
                guard let titleRaw = v2String(params, "title"),
                      !titleRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    result = .err(code: "invalid_params", message: "Missing or invalid title", data: nil)
                    return
                }
                let title = titleRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                tabManager.setCustomTitle(tabId: workspace.id, title: title)
                finish(["title": title])

            case "clear_name":
                tabManager.clearCustomTitle(tabId: workspace.id)
                finish(["title": workspace.title])

            case "set_description":
                guard let descriptionRaw = v2String(params, "description"),
                      !descriptionRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    result = .err(code: "invalid_params", message: "Missing or invalid description", data: nil)
                    return
                }
                tabManager.setCustomDescription(tabId: workspace.id, description: descriptionRaw)
                finish(["description": v2OrNull(workspace.customDescription)])

            case "clear_description":
                tabManager.clearCustomDescription(tabId: workspace.id)
                finish(["description": NSNull()])

            case "move_up":
                guard let currentIndex = tabManager.tabs.firstIndex(where: { $0.id == workspace.id }) else {
                    result = .err(code: "not_found", message: "Workspace not found", data: nil)
                    return
                }
                _ = tabManager.reorderWorkspace(tabId: workspace.id, toIndex: max(currentIndex - 1, 0))
                finish(["index": v2OrNull(tabManager.tabs.firstIndex(where: { $0.id == workspace.id }))])

            case "move_down":
                guard let currentIndex = tabManager.tabs.firstIndex(where: { $0.id == workspace.id }) else {
                    result = .err(code: "not_found", message: "Workspace not found", data: nil)
                    return
                }
                _ = tabManager.reorderWorkspace(tabId: workspace.id, toIndex: min(currentIndex + 1, tabManager.tabs.count - 1))
                finish(["index": v2OrNull(tabManager.tabs.firstIndex(where: { $0.id == workspace.id }))])

            case "move_top":
                tabManager.moveTabToTop(workspace.id)
                finish(["index": v2OrNull(tabManager.tabs.firstIndex(where: { $0.id == workspace.id }))])

            case "close_others":
                let candidates = tabManager.tabs.filter { $0.id != workspace.id && !$0.isPinned }
                let closed = closeWorkspaces(candidates)
                finish(["closed": closed])

            case "close_above":
                guard let index = tabManager.tabs.firstIndex(where: { $0.id == workspace.id }) else {
                    result = .err(code: "not_found", message: "Workspace not found", data: nil)
                    return
                }
                let candidates = Array(tabManager.tabs.prefix(index)).filter { !$0.isPinned }
                let closed = closeWorkspaces(candidates)
                finish(["closed": closed])

            case "close_below":
                guard let index = tabManager.tabs.firstIndex(where: { $0.id == workspace.id }) else {
                    result = .err(code: "not_found", message: "Workspace not found", data: nil)
                    return
                }
                let candidates: [Workspace]
                if index + 1 < tabManager.tabs.count {
                    candidates = Array(tabManager.tabs.suffix(from: index + 1)).filter { !$0.isPinned }
                } else {
                    candidates = []
                }
                let closed = closeWorkspaces(candidates)
                finish(["closed": closed])

            case "mark_read":
                AppDelegate.shared?.notificationStore?.markRead(forTabId: workspace.id)
                finish()

            case "mark_unread":
                AppDelegate.shared?.notificationStore?.markUnread(forTabId: workspace.id)
                finish()

            case "set_color":
                guard let colorRaw = v2String(params, "color"),
                      !colorRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    result = .err(code: "invalid_params", message: "Missing or invalid color", data: nil)
                    return
                }
                let colorInput = colorRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                // Resolve named colors from the effective palette, including file-defined additions.
                let effectivePalette = WorkspaceTabColorSettings.palette()
                let hex: String
                if let entry = effectivePalette.first(where: {
                    $0.name.caseInsensitiveCompare(colorInput) == .orderedSame
                }) {
                    hex = entry.hex
                } else if let normalized = WorkspaceTabColorSettings.normalizedHex(colorInput) {
                    hex = normalized
                } else {
                    let colorNames = effectivePalette.map(\.name)
                    result = .err(code: "invalid_params", message: "Invalid color. Use a hex value (#RRGGBB) or a named color.", data: [
                        "named_colors": colorNames
                    ])
                    return
                }
                tabManager.setTabColor(tabId: workspace.id, color: hex)
                finish(["color": hex])

            case "clear_color":
                tabManager.setTabColor(tabId: workspace.id, color: nil)
                finish(["color": NSNull()])

            default:
                result = .err(code: "invalid_params", message: "Unknown workspace action", data: [
                    "action": action,
                    "supported_actions": supportedActions
                ])
            }
        }

        return result
    }

    // MARK: - V2 Surface Methods

    @MainActor
    @discardableResult
    func closeSurfaceRecordingHistory(in workspace: Workspace, surfaceId: UUID, force: Bool) -> Bool {
        if let tabId = workspace.surfaceIdFromPanelId(surfaceId) {
            if force {
                return workspace.requestNonInteractiveCloseTabRecordingHistory(tabId)
            }
            return workspace.requestCloseTabRecordingHistory(tabId, force: force)
        }

        workspace.markCloseHistoryEligible(panelId: surfaceId)
        return workspace.closePanel(surfaceId, force: force)
    }

    func v2ResolveWorkspace(params: [String: Any], tabManager: TabManager) -> Workspace? {
        if let wsId = v2UUID(params, "workspace_id") {
            return tabManager.tabs.first(where: { $0.id == wsId })
        }
        if let surfaceId = v2UUID(params, "surface_id")
            ?? v2UUID(params, "terminal_id")
            ?? v2UUID(params, "tab_id") {
            return tabManager.tabs.first(where: { $0.panels[surfaceId] != nil })
        }
        if let paneId = v2UUID(params, "pane_id"),
           let located = v2LocatePane(paneId) {
            guard located.tabManager === tabManager else { return nil }
            return located.workspace
        }
        guard let wsId = tabManager.selectedTabId else { return nil }
        return tabManager.tabs.first(where: { $0.id == wsId })
    }












    @MainActor




    private func v2AgentSessionOptions(params: [String: Any]) -> (
        providerID: AgentSessionProviderID,
        rendererKind: AgentSessionRendererKind,
        error: V2CallResult?
    ) {
        let providerRaw = v2String(params, "provider_id") ?? v2String(params, "provider")
        let rendererRaw = v2String(params, "renderer_kind") ?? v2String(params, "renderer")

        let providerID: AgentSessionProviderID
        if let providerRaw {
            switch v2NormalizedToken(providerRaw) {
            case "codex":
                providerID = .codex
            case "claude", "claudecode":
                providerID = .claude
            case "opencode":
                providerID = .opencode
            default:
                return (
                    .codex,
                    .react,
                    .err(
                        code: "invalid_params",
                        message: "Invalid provider (codex|claude|opencode)",
                        data: ["provider": providerRaw]
                    )
                )
            }
        } else {
            providerID = .codex
        }

        let rendererKind: AgentSessionRendererKind
        if let rendererRaw {
            switch v2NormalizedToken(rendererRaw) {
            case "react":
                rendererKind = .react
            case "solid":
                rendererKind = .solid
            default:
                return (
                    providerID,
                    .react,
                    .err(
                        code: "invalid_params",
                        message: "Invalid renderer (react|solid)",
                        data: ["renderer": rendererRaw]
                    )
                )
            }
        } else {
            rendererKind = .react
        }

        return (providerID, rendererKind, nil)
    }





    // `internal` (not `private`): the Pane domain's app conformance forwards
    // `pane.join` to this body. The Surface domain extraction will relocate it.
    func v2SurfaceMove(params: [String: Any]) -> V2CallResult {
        guard let surfaceId = v2UUID(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid surface_id", data: nil)
        }

        let requestedPaneUUID = v2UUID(params, "pane_id")
        let requestedWorkspaceUUID = v2UUID(params, "workspace_id")
        let requestedWindowUUID = v2UUID(params, "window_id")
        let beforeSurfaceId = v2UUID(params, "before_surface_id")
        let afterSurfaceId = v2UUID(params, "after_surface_id")
        let explicitIndex = v2Int(params, "index")
        let focus = v2FocusAllowed(requested: v2Bool(params, "focus") ?? false)

        let anchorCount = (beforeSurfaceId != nil ? 1 : 0) + (afterSurfaceId != nil ? 1 : 0)
        if anchorCount > 1 {
            return .err(code: "invalid_params", message: "Specify at most one of before_surface_id or after_surface_id", data: nil)
        }

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to move surface", data: nil)
        v2MainSync {
            guard let app = AppDelegate.shared else {
                result = .err(code: "unavailable", message: "AppDelegate not available", data: nil)
                return
            }

            guard let source = app.locateSurface(surfaceId: surfaceId),
                  let sourceWorkspace = source.tabManager.tabs.first(where: { $0.id == source.workspaceId }) else {
                result = .err(code: "not_found", message: "Surface not found", data: ["surface_id": surfaceId.uuidString])
                return
            }

            let sourcePane = sourceWorkspace.paneId(forPanelId: surfaceId)
            let sourceIndex = sourceWorkspace.indexInPane(forPanelId: surfaceId)

            var targetWindowId = source.windowId
            var targetTabManager = source.tabManager
            var targetWorkspace = sourceWorkspace
            var targetPane = sourcePane ?? sourceWorkspace.bonsplitController.focusedPaneId ?? sourceWorkspace.bonsplitController.allPaneIds.first
            var targetIndex = explicitIndex

            if let anchorSurfaceId = beforeSurfaceId ?? afterSurfaceId {
                guard let anchor = app.locateSurface(surfaceId: anchorSurfaceId),
                      let anchorWorkspace = anchor.tabManager.tabs.first(where: { $0.id == anchor.workspaceId }),
                      let anchorPane = anchorWorkspace.paneId(forPanelId: anchorSurfaceId),
                      let anchorIndex = anchorWorkspace.indexInPane(forPanelId: anchorSurfaceId) else {
                    result = .err(code: "not_found", message: "Anchor surface not found", data: ["surface_id": anchorSurfaceId.uuidString])
                    return
                }
                targetWindowId = anchor.windowId
                targetTabManager = anchor.tabManager
                targetWorkspace = anchorWorkspace
                targetPane = anchorPane
                targetIndex = (beforeSurfaceId != nil) ? anchorIndex : (anchorIndex + 1)
            } else if let paneUUID = requestedPaneUUID {
                guard let located = v2LocatePane(paneUUID) else {
                    result = .err(code: "not_found", message: "Pane not found", data: ["pane_id": paneUUID.uuidString])
                    return
                }
                targetWindowId = located.windowId
                targetTabManager = located.tabManager
                targetWorkspace = located.workspace
                targetPane = located.paneId
            } else if let workspaceUUID = requestedWorkspaceUUID {
                guard let tm = app.tabManagerFor(tabId: workspaceUUID),
                      let ws = tm.tabs.first(where: { $0.id == workspaceUUID }) else {
                    result = .err(code: "not_found", message: "Workspace not found", data: ["workspace_id": workspaceUUID.uuidString])
                    return
                }
                targetTabManager = tm
                targetWorkspace = ws
                targetWindowId = app.windowId(for: tm) ?? targetWindowId
                targetPane = ws.bonsplitController.focusedPaneId ?? ws.bonsplitController.allPaneIds.first
            } else if let windowUUID = requestedWindowUUID {
                guard let tm = app.tabManagerFor(windowId: windowUUID) else {
                    result = .err(code: "not_found", message: "Window not found", data: ["window_id": windowUUID.uuidString])
                    return
                }
                targetWindowId = windowUUID
                targetTabManager = tm
                guard let selectedWorkspaceId = tm.selectedTabId,
                      let ws = tm.tabs.first(where: { $0.id == selectedWorkspaceId }) else {
                    result = .err(code: "not_found", message: "Target window has no selected workspace", data: ["window_id": windowUUID.uuidString])
                    return
                }
                targetWorkspace = ws
                targetPane = ws.bonsplitController.focusedPaneId ?? ws.bonsplitController.allPaneIds.first
            }

            guard let destinationPane = targetPane else {
                result = .err(code: "not_found", message: "No destination pane", data: nil)
                return
            }

            if targetWorkspace.id == sourceWorkspace.id {
                guard sourceWorkspace.moveSurface(panelId: surfaceId, toPane: destinationPane, atIndex: targetIndex, focus: focus) else {
                    result = .err(code: "internal_error", message: "Failed to move surface", data: nil)
                    return
                }
                result = .ok([
                    "window_id": targetWindowId.uuidString,
                    "window_ref": v2Ref(kind: .window, uuid: targetWindowId),
                    "workspace_id": targetWorkspace.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: targetWorkspace.id),
                    "pane_id": destinationPane.id.uuidString,
                    "pane_ref": v2Ref(kind: .pane, uuid: destinationPane.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId)
                ])
                return
            }

            guard let transfer = sourceWorkspace.detachSurface(panelId: surfaceId) else {
                result = .err(code: "internal_error", message: "Failed to detach surface", data: nil)
                return
            }

            if targetWorkspace.attachDetachedSurface(transfer, inPane: destinationPane, atIndex: targetIndex, focus: focus) == nil {
                // Roll back to source workspace if attach fails.
                let rollbackPane = sourcePane.flatMap { sp in sourceWorkspace.bonsplitController.allPaneIds.first(where: { $0 == sp }) }
                    ?? sourceWorkspace.bonsplitController.focusedPaneId
                    ?? sourceWorkspace.bonsplitController.allPaneIds.first
                if let rollbackPane {
                    _ = sourceWorkspace.attachDetachedSurface(transfer, inPane: rollbackPane, atIndex: sourceIndex, focus: focus)
                }
                result = .err(code: "internal_error", message: "Failed to attach surface to destination", data: nil)
                return
            }

            if focus {
                _ = app.focusMainWindow(windowId: targetWindowId)
                setActiveTabManager(targetTabManager)
                targetTabManager.selectWorkspace(targetWorkspace)
            }

            result = .ok([
                "window_id": targetWindowId.uuidString,
                "window_ref": v2Ref(kind: .window, uuid: targetWindowId),
                "workspace_id": targetWorkspace.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: targetWorkspace.id),
                "pane_id": destinationPane.id.uuidString,
                "pane_ref": v2Ref(kind: .pane, uuid: destinationPane.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId)
            ])
        }

        return result
    }



    func v2DebugTerminals(params _: [String: Any]) -> V2CallResult {
        var payload: [String: Any]?

        v2MainSync {
            guard let app = AppDelegate.shared else { return }

            struct MappedTerminalLocation {
                let windowIndex: Int
                let windowId: UUID
                let window: NSWindow?
                let workspaceIndex: Int
                let workspaceSelected: Bool
                let workspace: Workspace
                let terminalPanel: TerminalPanel
                let paneId: PaneID?
                let paneIndex: Int?
                let surfaceIndex: Int
                let selectedInPane: Bool?
                let bonsplitTabId: TabID?
            }

            func nonEmpty(_ raw: String?) -> String? {
                guard let raw else { return nil }
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }

            func rectPayload(_ rect: CGRect) -> [String: Double] {
                [
                    "x": Double(rect.origin.x),
                    "y": Double(rect.origin.y),
                    "width": Double(rect.size.width),
                    "height": Double(rect.size.height)
                ]
            }

            func objectPointerString(_ object: AnyObject?) -> String {
                guard let object else { return "nil" }
                return String(describing: Unmanaged.passUnretained(object).toOpaque())
            }

            func ghosttyPointerString(_ surface: ghostty_surface_t?) -> String {
                guard let surface else { return "nil" }
                return String(describing: surface)
            }

            func className(_ object: AnyObject?) -> String? {
                guard let object else { return nil }
                return String(describing: type(of: object))
            }

            let iso8601Formatter = ISO8601DateFormatter()
            let now = Date()

            func iso8601String(_ date: Date?) -> String? {
                guard let date else { return nil }
                return iso8601Formatter.string(from: date)
            }

            func ageSeconds(since date: Date?) -> Double? {
                guard let date else { return nil }
                return (now.timeIntervalSince(date) * 1000).rounded() / 1000
            }

            @MainActor
            func superviewClassChain(for view: NSView, limit: Int = 8) -> [String] {
                var chain: [String] = [String(describing: type(of: view))]
                var currentSuperview = view.superview
                while chain.count < limit, let nextSuperview = currentSuperview {
                    chain.append(String(describing: type(of: nextSuperview)))
                    currentSuperview = nextSuperview.superview
                }
                if currentSuperview != nil {
                    chain.append("...")
                }
                return chain
            }

            let windows = app.scriptableMainWindows()
            let windowIndexById = Dictionary(
                uniqueKeysWithValues: windows.enumerated().map { ($0.element.windowId, $0.offset) }
            )

            @MainActor
            func resolvedWindowMetadata(for window: NSWindow?) -> (windowId: UUID?, windowIndex: Int?) {
                guard let window else { return (nil, nil) }

                if let match = windows.enumerated().first(where: { _, state in
                    guard let stateWindow = state.window else { return false }
                    return stateWindow === window || stateWindow.windowNumber == window.windowNumber
                }) {
                    return (match.element.windowId, match.offset)
                }

                guard let raw = window.identifier?.rawValue else { return (nil, nil) }
                let prefix = "cmux.main."
                guard raw.hasPrefix(prefix),
                      let parsedWindowId = UUID(uuidString: String(raw.dropFirst(prefix.count))) else {
                    return (nil, nil)
                }
                return (parsedWindowId, windowIndexById[parsedWindowId])
            }

            var mappedLocations: [ObjectIdentifier: MappedTerminalLocation] = [:]
            for (windowIndex, state) in windows.enumerated() {
                let tabManager = state.tabManager
                for (workspaceIndex, workspace) in tabManager.tabs.enumerated() {
                    let paneIndexById = Dictionary(
                        uniqueKeysWithValues: workspace.bonsplitController.allPaneIds.enumerated().map {
                            ($0.element.id, $0.offset)
                        }
                    )
                    var selectedInPaneByPanelId: [UUID: Bool] = [:]
                    for paneId in workspace.bonsplitController.allPaneIds {
                        let selectedTab = workspace.bonsplitController.selectedTab(inPane: paneId)
                        for tab in workspace.bonsplitController.tabs(inPane: paneId) {
                            guard let panelId = workspace.panelIdFromSurfaceId(tab.id) else { continue }
                            selectedInPaneByPanelId[panelId] = (tab.id == selectedTab?.id)
                        }
                    }

                    for (surfaceIndex, panel) in orderedPanels(in: workspace).enumerated() {
                        guard let terminalPanel = panel as? TerminalPanel else { continue }
                        mappedLocations[ObjectIdentifier(terminalPanel.surface)] = MappedTerminalLocation(
                            windowIndex: windowIndex,
                            windowId: state.windowId,
                            window: state.window,
                            workspaceIndex: workspaceIndex,
                            workspaceSelected: workspace.id == tabManager.selectedTabId,
                            workspace: workspace,
                            terminalPanel: terminalPanel,
                            paneId: workspace.paneId(forPanelId: terminalPanel.id),
                            paneIndex: workspace.paneId(forPanelId: terminalPanel.id).flatMap { paneIndexById[$0.id] },
                            surfaceIndex: surfaceIndex,
                            selectedInPane: selectedInPaneByPanelId[terminalPanel.id],
                            bonsplitTabId: workspace.surfaceIdFromPanelId(terminalPanel.id)
                        )
                    }
                }
            }

            let surfaces = GhosttyApp.terminalSurfaceRegistry.allTerminalSurfaces()
            let terminals: [[String: Any]] = surfaces.enumerated().map { index, terminalSurface in
                let mapped = mappedLocations[ObjectIdentifier(terminalSurface)]
                let hostedView = terminalSurface.hostedView
                let hostedWindow = mapped?.window ?? terminalSurface.uiWindow
                let fallbackWindowMetadata = resolvedWindowMetadata(for: hostedWindow)
                let resolvedWindowId = mapped?.windowId ?? fallbackWindowMetadata.windowId
                let resolvedWindowIndex = mapped?.windowIndex ?? fallbackWindowMetadata.windowIndex
                let workspace = mapped?.workspace
                let panelId = mapped?.terminalPanel.id ?? terminalSurface.id
                let portalState = hostedView.portalBindingGuardState()
                let portalHostLease = terminalSurface.debugPortalHostLease()
                let gitBranchState = workspace?.panelGitBranches[panelId]
                let listeningPorts = (workspace?.surfaceListeningPorts[panelId] ?? []).sorted()
                let title = workspace?.panelTitle(panelId: panelId)
                let paneId = mapped?.paneId
                let treeVisible = mapped?.bonsplitTabId != nil && paneId != nil
                let ttyName = workspace?.surfaceTTYNames[panelId]
                let currentDirectory = nonEmpty(workspace?.panelDirectories[panelId] ?? mapped?.terminalPanel.directory)
                let teardownRequest = terminalSurface.debugTeardownRequest()
                let lastKnownWorkspaceId = terminalSurface.debugLastKnownWorkspaceId()

                var item: [String: Any] = [
                    "index": index,
                    "mapped": mapped != nil,
                    "tree_visible": treeVisible,
                    "window_index": v2OrNull(resolvedWindowIndex),
                    "window_id": v2OrNull(resolvedWindowId?.uuidString),
                    "window_ref": v2Ref(kind: .window, uuid: resolvedWindowId),
                    "window_number": v2OrNull(hostedWindow?.windowNumber),
                    "window_key": hostedWindow?.isKeyWindow ?? false,
                    "window_main": hostedWindow?.isMainWindow ?? false,
                    "window_visible": hostedWindow?.isVisible ?? false,
                    "window_occluded": hostedWindow.map { !$0.occlusionState.contains(.visible) } ?? false,
                    "window_identifier": v2OrNull(hostedWindow?.identifier?.rawValue),
                    "window_title": v2OrNull(nonEmpty(hostedWindow?.title)),
                    "window_class": v2OrNull(className(hostedWindow)),
                    "window_delegate_class": v2OrNull(className(hostedWindow?.delegate as AnyObject?)),
                    "window_controller_class": v2OrNull(className(hostedWindow?.windowController)),
                    "window_level": v2OrNull(hostedWindow?.level.rawValue),
                    "window_frame": hostedWindow.map { rectPayload($0.frame) } ?? NSNull(),
                    "workspace_index": v2OrNull(mapped?.workspaceIndex),
                    "workspace_id": v2OrNull(workspace?.id.uuidString),
                    "workspace_ref": v2Ref(kind: .workspace, uuid: workspace?.id),
                    "workspace_title": v2OrNull(workspace?.title),
                    "workspace_selected": v2OrNull(mapped?.workspaceSelected),
                    "pane_index": v2OrNull(mapped?.paneIndex),
                    "pane_id": v2OrNull(paneId?.id.uuidString),
                    "pane_ref": v2Ref(kind: .pane, uuid: paneId?.id),
                    "surface_index": v2OrNull(mapped?.surfaceIndex),
                    "surface_index_in_pane": v2OrNull(workspace?.indexInPane(forPanelId: panelId)),
                    "surface_id": panelId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: panelId),
                    "surface_title": v2OrNull(title),
                    "surface_focused": v2OrNull(workspace.map { panelId == $0.focusedPanelId }),
                    "surface_selected_in_pane": v2OrNull(mapped?.selectedInPane),
                    "surface_pinned": v2OrNull(workspace.map { $0.isPanelPinned(panelId) }),
                    "surface_context": terminalSurface.debugSurfaceContextLabel(),
                    "surface_created_at": v2OrNull(iso8601String(terminalSurface.debugCreatedAt())),
                    "surface_age_seconds": v2OrNull(ageSeconds(since: terminalSurface.debugCreatedAt())),
                    "runtime_surface_created_at": v2OrNull(iso8601String(terminalSurface.debugRuntimeSurfaceCreatedAt())),
                    "runtime_surface_age_seconds": v2OrNull(ageSeconds(since: terminalSurface.debugRuntimeSurfaceCreatedAt())),
                    "bonsplit_tab_id": v2OrNull(mapped?.bonsplitTabId?.uuid.uuidString),
                    "terminal_object_ptr": objectPointerString(terminalSurface),
                    "ghostty_surface_ptr": ghosttyPointerString(terminalSurface.surface),
                    "runtime_surface_ready": terminalSurface.surface != nil,
                    "hosted_view_ptr": objectPointerString(hostedView),
                    "hosted_view_class": className(hostedView) ?? "nil",
                    "hosted_view_in_window": terminalSurface.isViewInWindow,
                    "hosted_view_in_headless_bootstrap_window": terminalSurface.isHeadlessStartupWindow(hostedView.window),
                    "hosted_view_has_superview": hostedView.superview != nil,
                    "hosted_view_hidden": hostedView.isHidden,
                    "hosted_view_hidden_or_ancestor_hidden": hostedView.isHiddenOrHasHiddenAncestor,
                    "hosted_view_alpha": hostedView.alphaValue,
                    "hosted_view_visible_in_ui": hostedView.debugPortalVisibleInUI,
                    "hosted_view_superview_chain": superviewClassChain(for: hostedView),
                    "surface_view_first_responder": hostedView.isSurfaceViewFirstResponder(),
                    "hosted_view_frame": rectPayload(hostedView.frame),
                    "hosted_view_bounds": rectPayload(hostedView.bounds),
                    "hosted_view_frame_in_window": rectPayload(hostedView.debugPortalFrameInWindow),
                    "portal_binding_state": portalState.state,
                    "portal_binding_generation": v2OrNull(portalState.generation),
                    "portal_host_id": v2OrNull(portalHostLease.hostId),
                    "portal_host_in_window": v2OrNull(portalHostLease.inWindow),
                    "portal_host_area": v2OrNull(portalHostLease.area.map(Double.init)),
                    "tty": v2OrNull(ttyName),
                    "current_directory": v2OrNull(currentDirectory),
                    "requested_working_directory": v2OrNull(nonEmpty(terminalSurface.requestedWorkingDirectory)),
                    "initial_command": v2OrNull(nonEmpty(terminalSurface.debugInitialCommand())),
                    "tmux_start_command": v2OrNull(nonEmpty(terminalSurface.debugTmuxStartCommand())),
                    "git_branch": v2OrNull(nonEmpty(gitBranchState?.branch)),
                    "git_dirty": v2OrNull(gitBranchState?.isDirty),
                    "listening_ports": listeningPorts,
                    "key_state_indicator": v2OrNull(nonEmpty(terminalSurface.currentKeyStateIndicatorText)),
                    "last_known_workspace_id": lastKnownWorkspaceId.uuidString,
                    "last_known_workspace_ref": v2Ref(kind: .workspace, uuid: lastKnownWorkspaceId),
                    "teardown_requested": teardownRequest.requestedAt != nil,
                    "teardown_requested_at": v2OrNull(iso8601String(teardownRequest.requestedAt)),
                    "teardown_requested_age_seconds": v2OrNull(ageSeconds(since: teardownRequest.requestedAt)),
                    "teardown_requested_reason": v2OrNull(nonEmpty(teardownRequest.reason))
                ]

                if title == nil, let fallbackTitle = mapped?.terminalPanel.displayTitle, !fallbackTitle.isEmpty {
                    item["surface_title"] = fallbackTitle
                }
                return item
            }

            payload = [
                "count": terminals.count,
                "terminals": terminals
            ]
        }

        guard let payload else {
            return .err(code: "unavailable", message: "AppDelegate not available", data: nil)
        }
        return .ok(payload)
    }





    struct TerminalTextRawSnapshot {
        var viewport: String?
        var screen: String?
        var history: String?
        var active: String?
    }

    struct TerminalTextPayload: Equatable {
        let text: String
        let base64: String
    }

    struct TerminalTextPayloadError: Error, Equatable {
        let message: String
    }

    func readTerminalTextRawSnapshot(
        terminalPanel: TerminalPanel,
        includeScrollback: Bool
    ) -> TerminalTextRawSnapshot? {
        guard terminalPanel.surface.surface != nil else { return nil }
        if includeScrollback {
            return TerminalTextRawSnapshot(
                viewport: nil,
                screen: readTerminalSelectionText(terminalPanel: terminalPanel, pointTag: GHOSTTY_POINT_SCREEN),
                history: readTerminalSelectionText(terminalPanel: terminalPanel, pointTag: GHOSTTY_POINT_SURFACE),
                active: readTerminalSelectionText(terminalPanel: terminalPanel, pointTag: GHOSTTY_POINT_ACTIVE)
            )
        }
        return TerminalTextRawSnapshot(
            viewport: readTerminalSelectionText(terminalPanel: terminalPanel, pointTag: GHOSTTY_POINT_VIEWPORT),
            screen: nil,
            history: nil,
            active: nil
        )
    }

    private func readTerminalSelectionText(terminalPanel: TerminalPanel, pointTag: ghostty_point_tag_e) -> String? {
        guard let surface = terminalPanel.surface.surface else { return nil }
        let topLeft = ghostty_point_s(
            tag: pointTag,
            coord: GHOSTTY_POINT_COORD_TOP_LEFT,
            x: 0,
            y: 0
        )
        let bottomRight = ghostty_point_s(
            tag: pointTag,
            coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
            x: 0,
            y: 0
        )
        let selection = ghostty_selection_s(
            top_left: topLeft,
            bottom_right: bottomRight,
            rectangle: false
        )

        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else {
            return nil
        }
        defer {
            ghostty_surface_free_text(surface, &text)
        }

        guard let ptr = text.text, text.text_len > 0 else {
            return ""
        }
        let rawData = Data(bytes: ptr, count: Int(text.text_len))
        return String(decoding: rawData, as: UTF8.self)
    }

    private func readTerminalTextBase64(terminalPanel: TerminalPanel, includeScrollback: Bool = false, lineLimit: Int? = nil) -> String {
        guard terminalPanel.surface.liveSurfaceForGhosttyAccess(reason: "readTerminalTextBase64") != nil else {
            return "ERROR: Terminal surface not found"
        }
        guard let snapshot = readTerminalTextRawSnapshot(
            terminalPanel: terminalPanel,
            includeScrollback: includeScrollback
        ) else {
            return "ERROR: Terminal surface not found"
        }
        switch Self.terminalTextPayload(
            from: snapshot,
            includeScrollback: includeScrollback,
            lineLimit: lineLimit
        ) {
        case .success(let payload):
            return "OK \(payload.base64)"
        case .failure(let error):
            return "ERROR: \(error.message)"
        }
    }

    nonisolated static func terminalTextPayload(
        from snapshot: TerminalTextRawSnapshot,
        includeScrollback: Bool,
        lineLimit: Int?
    ) -> Result<TerminalTextPayload, TerminalTextPayloadError> {
        let output: String
        if includeScrollback {
            var candidates: [String] = []
            if let screen = snapshot.screen {
                candidates.append(lineLimit.map { Self.tailTerminalLines(screen, maxLines: $0) } ?? screen)
            }
            if snapshot.history != nil || snapshot.active != nil {
                var merged = lineLimit.map {
                    Self.tailTerminalLines(snapshot.history ?? "", maxLines: $0)
                } ?? (snapshot.history ?? "")
                if let active = snapshot.active {
                    if !merged.isEmpty, !merged.hasSuffix("\n"), !active.isEmpty {
                        merged.append("\n")
                    }
                    merged.append(lineLimit.map { Self.tailTerminalLines(active, maxLines: $0) } ?? active)
                }
                candidates.append(lineLimit.map { Self.tailTerminalLines(merged, maxLines: $0) } ?? merged)
            }

            guard let best = candidates.max(by: { lhs, rhs in
                let left = terminalTextCandidateScore(lhs)
                let right = terminalTextCandidateScore(rhs)
                if left.lines != right.lines {
                    return left.lines < right.lines
                }
                return left.bytes < right.bytes
            }) else {
                return .failure(TerminalTextPayloadError(message: "Failed to read terminal text"))
            }
            output = best
        } else {
            guard var viewport = snapshot.viewport else {
                return .failure(TerminalTextPayloadError(message: "Failed to read terminal text"))
            }
            if let lineLimit {
                viewport = Self.tailTerminalLines(viewport, maxLines: lineLimit)
            }
            output = viewport
        }

        let base64 = output.data(using: .utf8)?.base64EncodedString() ?? ""
        return .success(TerminalTextPayload(text: output, base64: base64))
    }

    nonisolated private static func terminalTextCandidateScore(_ text: String) -> (lines: Int, bytes: Int) {
        if text.isEmpty { return (0, 0) }
        var newlineCount = 0
        var byteCount = 0
        for byte in text.utf8 {
            byteCount += 1
            if byte == 0x0A {
                newlineCount += 1
            }
        }
        return (newlineCount + 1, byteCount)
    }

    private func readTerminalTextFromVTExportForSnapshot(
        terminalPanel: TerminalPanel,
        bindingAction: String = "write_screen_file:copy,vt",
        lineLimit: Int?,
        normalizeLineEndings: Bool = true
    ) -> String? {
        var actionSucceeded = false
        let exportedPath = GhosttyApp.terminalPasteboard.captureNextStandardClipboardWrite {
            let ok = terminalPanel.performBindingAction(bindingAction)
            actionSucceeded = ok
            return ok
        }
        #if DEBUG
        cmuxDebugLog("mobile.vtExport action=\(bindingAction) succeeded=\(actionSucceeded) hasPath=\(exportedPath != nil)")
        #endif
        guard let exportedPath = Self.normalizedExportedScreenPath(exportedPath) else {
            return nil
        }

        let fileURL = URL(fileURLWithPath: exportedPath)
        defer {
            if Self.shouldRemoveExportedScreenFile(fileURL: fileURL) {
                try? FileManager.default.removeItem(at: fileURL)
                if Self.shouldRemoveExportedScreenDirectory(fileURL: fileURL) {
                    try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
                }
            }
        }

        guard let data = try? Data(contentsOf: fileURL),
              let rawOutput = String(data: data, encoding: .utf8) else {
            return nil
        }
        var output = normalizeLineEndings
            ? Self.normalizedMobileVTExportText(rawOutput)
            : rawOutput
        if let lineLimit {
            output = Self.tailTerminalLines(output, maxLines: lineLimit)
        }
        return output
    }

    private func readPlainTerminalTextForSnapshot(
        terminalPanel: TerminalPanel,
        includeScrollback: Bool = false,
        lineLimit: Int? = nil
    ) -> String? {
        let response = readTerminalTextBase64(
            terminalPanel: terminalPanel,
            includeScrollback: includeScrollback,
            lineLimit: lineLimit
        )
        guard response.hasPrefix("OK ") else { return nil }
        let base64 = String(response.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        if base64.isEmpty {
            return ""
        }
        guard let data = Data(base64Encoded: base64),
              let decoded = String(data: data, encoding: .utf8) else {
            return nil
        }
        return decoded
    }

    func readTerminalTextForSnapshot(
        terminalPanel: TerminalPanel,
        includeScrollback: Bool = false,
        lineLimit: Int? = nil,
        allowVTExport: Bool = true
    ) -> String? {
        if includeScrollback,
           allowVTExport,
           let vtOutput = readTerminalTextFromVTExportForSnapshot(
               terminalPanel: terminalPanel,
               lineLimit: lineLimit
           ) {
            return vtOutput
        }

        return readPlainTerminalTextForSnapshot(
            terminalPanel: terminalPanel,
            includeScrollback: includeScrollback,
            lineLimit: lineLimit
        )
    }

    func readTerminalTextForHibernationFingerprint(
        terminalPanel: TerminalPanel,
        lineLimit: Int
    ) -> String? {
        // This runs from the periodic hibernation timer. Sample the visible tail
        // only, rather than copying full scrollback every cycle.
        readTerminalTextForSnapshot(
            terminalPanel: terminalPanel,
            includeScrollback: false,
            lineLimit: lineLimit,
            allowVTExport: false
        )
    }

    func readTerminalTextForSessionSnapshot(
        terminalPanel: TerminalPanel,
        includeScrollback: Bool = false,
        lineLimit: Int? = nil
    ) -> String? {
        readTerminalTextForSnapshot(
            terminalPanel: terminalPanel,
            includeScrollback: includeScrollback,
            lineLimit: lineLimit
        )
    }


    private nonisolated func v2FeedbackSubmit(params: [String: Any]) -> V2CallResult {
        guard let email = params["email"] as? String else {
            return .err(code: "invalid_params", message: "Missing email", data: ["field": "email"])
        }
        guard let body = params["body"] as? String else {
            return .err(code: "invalid_params", message: "Missing body", data: ["field": "body"])
        }
        let imagePaths = params["image_paths"] as? [String] ?? []

        let semaphore = DispatchSemaphore(value: 0)
        var result: V2CallResult = .err(code: "internal_error", message: "Feedback submission failed", data: nil)

        Task {
            let resolved: V2CallResult
            do {
                let attachmentCount = try await FeedbackComposerBridge().submit(
                    email: email,
                    message: body,
                    imagePaths: imagePaths
                )
                resolved = .ok([
                    "submitted": true,
                    "attachment_count": attachmentCount,
                ])
            } catch let error as FeedbackComposerBridgeError {
                let code: String
                switch error {
                case .invalidEmail, .emptyMessage, .messageTooLong, .tooManyImages, .invalidImagePath:
                    code = "invalid_params"
                case .submissionFailed:
                    code = "request_failed"
                }
                resolved = .err(code: code, message: error.localizedDescription, data: nil)
            } catch {
                resolved = .err(code: "internal_error", message: error.localizedDescription, data: nil)
            }

            result = resolved
            semaphore.signal()
        }

        if semaphore.wait(timeout: .now() + 35) == .timedOut {
            return .err(code: "timeout", message: "Feedback submission timed out", data: nil)
        }

        return result
    }

    // MARK: - V2 Feed (workstream) handlers

    private nonisolated func v2FeedPush(params: [String: Any]) -> V2CallResult {
        let waitTimeout: TimeInterval
        if let rawTimeout = params["wait_timeout_seconds"] {
            let seconds: Double?
            if let number = rawTimeout as? NSNumber {
                seconds = number.doubleValue
            } else if let value = rawTimeout as? Double {
                seconds = value
            } else if let value = rawTimeout as? Int {
                seconds = Double(value)
            } else {
                seconds = nil
            }
            guard let seconds else {
                return .err(
                    code: "invalid_params",
                    message: "feed.push wait_timeout_seconds must be numeric",
                    data: nil
                )
            }
            guard seconds.isFinite, seconds >= 0, seconds <= 120 else {
                return .err(
                    code: "invalid_params",
                    message: "feed.push wait_timeout_seconds must be between 0 and 120",
                    data: nil
                )
            }
            waitTimeout = seconds
        } else {
            waitTimeout = 0
        }
        let eventDict: [String: Any]
        if let nested = params["event"] as? [String: Any] {
            eventDict = nested
        } else if params["session_id"] != nil,
                  params["hook_event_name"] != nil,
                  params["_source"] != nil {
            eventDict = params
        } else {
            return .err(
                code: "invalid_params",
                message: "feed.push requires an `event` object",
                data: nil
            )
        }

        let event: WorkstreamEvent
        do {
            let data = try JSONSerialization.data(withJSONObject: eventDict)
            event = try JSONDecoder().decode(WorkstreamEvent.self, from: data)
        } catch {
            return .err(
                code: "invalid_params",
                message: "feed.push event failed to decode: \(error)",
                data: nil
            )
        }

        CmuxEventBus.shared.publishWorkstreamEvent(event, phase: "received")
        v2ApplyIMessageModeSideEffects(for: event)
        Task { @MainActor in self.agentChatTranscriptService?.noteHookEvent(event) }

        let result = FeedCoordinator.shared.ingestBlocking(
            event: event,
            waitTimeout: waitTimeout
        )
        CmuxEventBus.shared.publishWorkstreamEvent(
            event,
            phase: "completed",
            result: FeedSocketEncoding.payload(for: result)
        )
        return .ok(FeedSocketEncoding.payload(for: result))
    }

    private nonisolated func v2ApplyIMessageModeSideEffects(for event: WorkstreamEvent) {
        guard event.hookEventName == .userPromptSubmit || event.hookEventName == .stop,
              let rawWorkspaceId = event.workspaceId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawWorkspaceId.isEmpty
        else { return }

        let iMessageModeEnabled = IMessageModeSettings.isEnabled()
        switch event.hookEventName {
        case .userPromptSubmit:
            v2MainSync {
                guard let workspaceId = v2UUIDAny(rawWorkspaceId) else { return }
                guard let tabManager = AppDelegate.shared?.tabManagerFor(tabId: workspaceId) else { return }
                _ = tabManager.handlePromptSubmit(
                    workspaceId: workspaceId,
                    message: event.submittedPromptMessage,
                    iMessageModeEnabled: iMessageModeEnabled
                )
            }
        case .stop:
            let assistantFinalMessage = event.assistantFinalMessage
            Task { @MainActor [weak self, rawWorkspaceId, assistantFinalMessage, iMessageModeEnabled] in
                guard let self,
                      let workspaceId = self.v2UUIDAny(rawWorkspaceId) else { return }
                guard let tabManager = AppDelegate.shared?.tabManagerFor(tabId: workspaceId) else { return }
                _ = tabManager.handleAssistantFinalMessage(
                    workspaceId: workspaceId,
                    message: assistantFinalMessage,
                    iMessageModeEnabled: iMessageModeEnabled
                )
            }
        default:
            break
        }
    }

    private nonisolated func v2FeedPermissionReply(params: [String: Any]) -> V2CallResult {
        guard let requestId = params["request_id"] as? String else {
            return .err(
                code: "invalid_params",
                message: "feed.permission.reply requires request_id",
                data: nil
            )
        }
        guard let modeRaw = params["mode"] as? String,
              let mode = WorkstreamPermissionMode(rawValue: modeRaw)
        else {
            return .err(
                code: "invalid_params",
                message: "feed.permission.reply requires mode ∈ once|always|all|bypass|deny",
                data: nil
            )
        }
        FeedCoordinator.shared.deliverReply(
            requestId: requestId,
            decision: .permission(mode)
        )
        return .ok(["delivered": true])
    }

    private nonisolated func v2FeedQuestionReply(params: [String: Any]) -> V2CallResult {
        guard let requestId = params["request_id"] as? String else {
            return .err(
                code: "invalid_params",
                message: "feed.question.reply requires request_id",
                data: nil
            )
        }
        guard let selections = params["selections"] as? [String] else {
            return .err(
                code: "invalid_params",
                message: "feed.question.reply requires selections: [string]",
                data: nil
            )
        }
        FeedCoordinator.shared.deliverReply(
            requestId: requestId,
            decision: .question(selections: selections)
        )
        return .ok(["delivered": true])
    }

    private nonisolated func v2FeedExitPlanReply(params: [String: Any]) -> V2CallResult {
        guard let requestId = params["request_id"] as? String else {
            return .err(
                code: "invalid_params",
                message: "feed.exit_plan.reply requires request_id",
                data: nil
            )
        }
        guard let modeRaw = params["mode"] as? String,
              let mode = WorkstreamExitPlanMode(rawValue: modeRaw)
        else {
            return .err(
                code: "invalid_params",
                message: "feed.exit_plan.reply requires mode ∈ ultraplan|bypassPermissions|autoAccept|manual|deny",
                data: nil
            )
        }
        let feedback = params["feedback"] as? String
        FeedCoordinator.shared.deliverReply(
            requestId: requestId,
            decision: .exitPlan(mode, feedback: feedback)
        )
        return .ok(["delivered": true])
    }

    // MARK: - V2 Browser Methods

    func v2BrowserWithPanel(
        params: [String: Any],
        _ body: (_ workspaceID: UUID, _ surfaceId: UUID, _ browserPanel: BrowserPanel) -> V2CallResult
    ) -> V2CallResult {
        var result: V2CallResult = .err(code: "internal_error", message: "Browser operation failed", data: nil)
        v2MainSync {
            guard let tabManager = v2ResolveTabManager(params: params) else {
                result = .err(code: "unavailable", message: "TabManager not available", data: nil)
                return
            }
            let resolved = v2ResolveBrowserPanelContext(params: params, tabManager: tabManager)
            if let error = resolved.error {
                result = error
                return
            }
            guard let context = resolved.context else {
                result = .err(code: "internal_error", message: "Browser operation failed", data: nil)
                return
            }
            result = body(context.workspaceId, context.surfaceId, context.browserPanel)
        }
        return result
    }

    /// Value snapshot of a resolved browser surface for socket-worker handlers:
    /// resolution happens on the main actor, the JS-evaluating body runs off it.
    private struct V2BrowserPanelContext {
        let workspaceId: UUID
        let surfaceId: UUID
        let browserPanel: BrowserPanel
        let webView: WKWebView
    }

    private func v2ResolveBrowserPanelContext(
        params: [String: Any],
        tabManager: TabManager
    ) -> (context: V2BrowserPanelContext?, error: V2CallResult?) {
        let globalDockResolution = v2ResolveGlobalDockBrowserPanelContext(params: params)
        if globalDockResolution.handled {
            return (globalDockResolution.context, globalDockResolution.error)
        }

        guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
            return (nil, .err(code: "not_found", message: "Workspace not found", data: nil))
        }
        let resolvedSurface = v2ResolveBrowserSurfaceId(params: params, workspace: ws)
        if let error = resolvedSurface.error {
            return (nil, error)
        }
        guard let surfaceId = resolvedSurface.surfaceId else {
            return (nil, .err(code: "not_found", message: "No focused browser surface", data: nil))
        }
        guard let browserPanel = ws.browserPanel(for: surfaceId) else {
            return (nil, .err(code: "invalid_params", message: "Surface is not a browser", data: ["surface_id": surfaceId.uuidString]))
        }
        return (
            V2BrowserPanelContext(
                workspaceId: ws.id,
                surfaceId: surfaceId,
                browserPanel: browserPanel,
                webView: browserPanel.webView
            ),
            nil
        )
    }

    private func v2ResolveGlobalDockBrowserPanelContext(
        params: [String: Any]
    ) -> (handled: Bool, context: V2BrowserPanelContext?, error: V2CallResult?) {
        let requestedWorkspaceID = v2UUID(params, "workspace_id")
        let requestedSurfaceID = v2UUID(params, "surface_id") ?? v2UUID(params, "tab_id")
        let requestedPaneID = v2UUID(params, "pane_id")

        let dockBySurface = requestedSurfaceID.flatMap { globalDockContainingPanel($0) }
        let dockByPane = requestedPaneID.flatMap { globalDockContainingPane($0) }
        let routesGlobalDock = requestedWorkspaceID.map(AppDelegate.isGlobalDockOwnerId) == true
            || dockBySurface != nil
            || dockByPane != nil
        guard routesGlobalDock else {
            return (false, nil, nil)
        }

        guard let dock = dockBySurface ?? dockByPane ?? AppDelegate.shared?.existingGlobalDock else {
            return (true, nil, .err(code: "not_found", message: "No focused browser surface", data: nil))
        }

        let surfaceId: UUID?
        if let requestedSurfaceID {
            surfaceId = requestedSurfaceID
        } else if let requestedPaneID {
            guard let pane = dock.bonsplitController.allPaneIds.first(where: { $0.id == requestedPaneID }) else {
                return (true, nil, .err(code: "not_found", message: "Pane not found", data: ["pane_id": requestedPaneID.uuidString]))
            }
            guard let selectedTab = dock.bonsplitController.selectedTab(inPane: pane),
                  let selectedSurface = dock.panel(for: selectedTab.id)?.id else {
                return (true, nil, .err(code: "not_found", message: "Pane has no selected surface", data: ["pane_id": requestedPaneID.uuidString]))
            }
            surfaceId = selectedSurface
        } else {
            surfaceId = dock.focusedPanelId
        }

        guard let surfaceId else {
            return (true, nil, .err(code: "not_found", message: "No focused browser surface", data: nil))
        }
        guard let browserPanel = dock.browserPanel(for: surfaceId) else {
            return (true, nil, .err(code: "invalid_params", message: "Surface is not a browser", data: ["surface_id": surfaceId.uuidString]))
        }
        return (
            true,
            V2BrowserPanelContext(
                workspaceId: dock.workspaceId,
                surfaceId: surfaceId,
                browserPanel: browserPanel,
                webView: browserPanel.webView
            ),
            nil
        )
    }

    private func v2ResolveGlobalDockBrowserTabStore(
        params: [String: Any]
    ) -> (handled: Bool, dock: DockSplitStore?, error: V2CallResult?) {
        let requestedWorkspaceID = v2UUID(params, "workspace_id")
        let requestedSurfaceID = v2UUID(params, "surface_id")
            ?? v2UUID(params, "tab_id")
            ?? v2UUID(params, "target_surface_id")
        let requestedPaneID = v2UUID(params, "pane_id")
            ?? v2UUID(params, "target_pane_id")

        let dockBySurface = requestedSurfaceID.flatMap { globalDockContainingPanel($0) }
        let dockByPane = requestedPaneID.flatMap { globalDockContainingPane($0) }
        let routesGlobalDock = requestedWorkspaceID.map(AppDelegate.isGlobalDockOwnerId) == true
            || dockBySurface != nil
            || dockByPane != nil
        guard routesGlobalDock else {
            return (false, nil, nil)
        }

        let dock = dockBySurface
            ?? dockByPane
            ?? AppDelegate.shared?.globalDock
        guard let dock else {
            return (true, nil, .err(code: "not_found", message: "Workspace not found", data: nil))
        }
        return (true, dock, nil)
    }

    private func v2BrowserTabListPayload(
        workspaceId: UUID,
        focusedPanelId: UUID?,
        panels: [any Panel],
        paneIdForPanel: (UUID) -> PaneID?
    ) -> [String: Any] {
        let browserPanels = panels.compactMap { $0 as? BrowserPanel }
        let tabs: [[String: Any]] = browserPanels.enumerated().map { index, panel in
            let paneId = paneIdForPanel(panel.id)
            return [
                "id": panel.id.uuidString,
                "ref": v2Ref(kind: .surface, uuid: panel.id),
                "index": index,
                "title": panel.displayTitle,
                "url": panel.currentURL?.absoluteString ?? "",
                "focused": panel.id == focusedPanelId,
                "pane_id": v2OrNull(paneId?.id.uuidString),
                "pane_ref": v2Ref(kind: .pane, uuid: paneId?.id)
            ]
        }
        return [
            "workspace_id": workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
            "surface_id": v2OrNull(focusedPanelId?.uuidString),
            "surface_ref": v2Ref(kind: .surface, uuid: focusedPanelId),
            "tabs": tabs
        ]
    }

    private func closeGlobalDockBrowserPanel(_ targetId: UUID, in dock: DockSplitStore) -> Bool {
        guard let tabId = dock.surfaceId(forPanelId: targetId) else { return false }
        dock.forceCloseDockTabIds.insert(tabId)
        let closed = dock.bonsplitController.closeTab(tabId)
        if !closed {
            dock.forceCloseDockTabIds.remove(tabId)
        }
        return closed
    }

    private nonisolated func v2BrowserPanelFields(_ ctx: V2BrowserPanelContext, adding fields: [String: Any] = [:]) -> [String: Any] {
        var result: [String: Any] = [
            "workspace_id": ctx.workspaceId.uuidString, "workspace_ref": v2Ref(kind: .workspace, uuid: ctx.workspaceId),
            "surface_id": ctx.surfaceId.uuidString, "surface_ref": v2Ref(kind: .surface, uuid: ctx.surfaceId)
        ]
        fields.forEach { result[$0.key] = $0.value }
        return result
    }

    /// Off-main counterpart of v2BrowserWithPanel for the socket-worker browser
    /// methods: the panel is resolved inside v2MainSync, but `body` runs on the
    /// calling (worker) thread so blocking JavaScript waits never hold the main
    /// actor. `body` must wrap any UI/model access of its own in v2MainSync.
    private nonisolated func v2BrowserWithPanelContext(
        params: [String: Any],
        _ body: (_ ctx: V2BrowserPanelContext) -> V2CallResult
    ) -> V2CallResult {
        var resolved: V2BrowserPanelContext?
        var failure: V2CallResult = .err(code: "internal_error", message: "Browser operation failed", data: nil)
        v2MainSync {
            guard let tabManager = v2ResolveTabManager(params: params) else {
                failure = .err(code: "unavailable", message: "TabManager not available", data: nil)
                return
            }
            let resolvedContext = v2ResolveBrowserPanelContext(params: params, tabManager: tabManager)
            if let error = resolvedContext.error {
                failure = error
                return
            }
            guard let context = resolvedContext.context else {
                failure = .err(code: "internal_error", message: "Browser operation failed", data: nil)
                return
            }
            resolved = context
        }
        guard let resolved else { return failure }
        return body(resolved)
    }

    private func v2ResolveBrowserSurfaceId(
        params: [String: Any],
        workspace: Workspace
    ) -> (surfaceId: UUID?, error: V2CallResult?) {
        if let surfaceId = v2UUID(params, "surface_id") ?? v2UUID(params, "tab_id") {
            return (surfaceId, nil)
        }
        if let paneId = v2UUID(params, "pane_id") {
            guard let pane = workspace.bonsplitController.allPaneIds.first(where: { $0.id == paneId }) else {
                return (
                    nil,
                    .err(code: "not_found", message: "Pane not found", data: ["pane_id": paneId.uuidString])
                )
            }
            guard let selectedTab = workspace.bonsplitController.selectedTab(inPane: pane),
                  let selectedSurface = workspace.panelIdFromSurfaceId(selectedTab.id) else {
                return (
                    nil,
                    .err(code: "not_found", message: "Pane has no selected surface", data: ["pane_id": paneId.uuidString])
                )
            }
            return (selectedSurface, nil)
        }
        return (workspace.focusedPanelId, nil)
    }

    private nonisolated func v2JSONLiteral(_ value: Any) -> String {
        v2BrowserControl.jsonLiteral(value)
    }

    private nonisolated func v2NormalizeJSValue(_ value: Any?) -> Any {
        v2BrowserControl.normalizeJSValue(value) { $0 is V2BrowserUndefinedSentinel }
    }

    enum V2JavaScriptResult {
        case success(Any?)
        case failure(String)
    }

    /// True when a page-world JS failure looks like a CSP block of eval/function
    /// construction (script-src without 'unsafe-eval'). That is the only failure
    /// the isolated-world retry is meant to recover from; gating on it keeps the
    /// retry from re-running a script that already failed for an ordinary reason
    /// (a thrown exception, a timeout), which would duplicate any side effect the
    /// script performed before throwing and could return a value from the wrong
    /// JS context.
    private nonisolated func v2BrowserFailureLooksLikeCSPEvalBlock(_ message: String) -> Bool {
        v2BrowserControl.failureLooksLikeCSPEvalBlock(message)
    }

    /// Sendable stand-in for `WKContentWorld` so nonisolated callers can pick a world without
    /// touching the main-actor-isolated `WKContentWorld.page`/`.defaultClient` statics. The real
    /// world is resolved on the main actor inside `v2RunJavaScript`.
    private enum V2JSContentWorld: Sendable { case page, isolated }

    private nonisolated func v2RunJavaScript(
        _ webView: WKWebView,
        script: String,
        timeout: TimeInterval = 5.0,
        preferAsync: Bool = false,
        world: V2JSContentWorld
    ) -> V2JavaScriptResult {
        let timeoutSeconds = max(0.01, timeout)
        // Capture the held browser-control service (a Sendable value) rather than
        // `self`, reusing the already-initialized instance for error description.
        let browserControl = v2BrowserControl
        // The evaluator only ever runs on the main actor (Thread.isMainThread branch or
        // DispatchQueue.main.async below), so assumeIsolated is safe and lets us touch the
        // main-actor WKWebView APIs and WKContentWorld statics without spurious isolation warnings.
        let evaluator: (@escaping (Any?, String?) -> Void) -> Void = { finish in
            MainActor.assumeIsolated {
                let contentWorld: WKContentWorld = (world == .page) ? .page : .defaultClient
                if preferAsync, #available(macOS 11.0, *) {
                    webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: contentWorld) { result in
                        switch result {
                        case .success(let value):
                            finish(value, nil)
                        case .failure(let error):
                            finish(nil, browserControl.describeJavaScriptError(error))
                        }
                    }
                } else {
                    webView.evaluateJavaScript(script) { value, error in
                        if let error {
                            finish(nil, browserControl.describeJavaScriptError(error))
                        } else {
                            finish(value, nil)
                        }
                    }
                }
            }
        }

        let outcome: (Any?, String?)?
        if Thread.isMainThread {
            outcome = v2AwaitCallback(timeout: timeoutSeconds) { finish in
                evaluator { value, error in
                    finish((value, error))
                }
            }
        } else {
            outcome = v2AwaitCallback(timeout: timeoutSeconds) { finish in
                DispatchQueue.main.async {
                    evaluator { value, error in
                        finish((value, error))
                    }
                }
            }
        }

        guard let outcome else {
#if DEBUG
            cmuxDebugLog(
                "browser.jsRun.timeout preferAsync=\(preferAsync) " +
                "world=\(world == .page ? "page" : "isolated") timeout=\(timeoutSeconds)"
            )
#endif
            return .failure("Timed out waiting for JavaScript result")
        }
        if let resultError = outcome.1 {
            return .failure(resultError)
        }
        return .success(outcome.0)
    }

    private nonisolated func v2AwaitCallback<T>(
        timeout: TimeInterval,
        start: (@escaping (T) -> Void) -> Void
    ) -> T? {
        socketAwaitCallback(timeout: timeout, start: start)
    }

    private nonisolated func v2WaitForBrowserCondition(
        _ webView: WKWebView,
        surfaceId: UUID,
        conditionScript: String,
        timeoutMs: Int
    ) -> V2BrowserWaitOutcome {
        let timeout = Double(timeoutMs) / 1000.0
        let waitScript = """
        (() => {
          const __cmuxEvaluate = () => {
            try {
              return !!(\(conditionScript));
            } catch (_) {
              return false;
            }
          };

          if (__cmuxEvaluate()) {
            return true;
          }

          return new Promise((resolve) => {
            let finished = false;
            let observer = null;
            const cleanups = [];
            const finish = (value) => {
              if (finished) return;
              finished = true;
              if (observer) observer.disconnect();
              for (const cleanup of cleanups) {
                try { cleanup(); } catch (_) {}
              }
              resolve(value);
            };
            const recheck = () => {
              if (__cmuxEvaluate()) {
                finish(true);
              }
            };
            const addListener = (target, eventName, options) => {
              if (!target || typeof target.addEventListener !== 'function') return;
              const handler = () => recheck();
              target.addEventListener(eventName, handler, options);
              cleanups.push(() => target.removeEventListener(eventName, handler, options));
            };

            try {
              observer = new MutationObserver(() => recheck());
              observer.observe(document.documentElement || document, {
                childList: true,
                subtree: true,
                attributes: true,
                characterData: true
              });
            } catch (_) {}

            addListener(document, 'readystatechange', true);
            addListener(window, 'load', true);
            addListener(window, 'pageshow', true);
            addListener(window, 'hashchange', true);
            addListener(window, 'popstate', true);

            const timeoutId = window.setTimeout(() => {
              finish(false);
            }, \(timeoutMs));
            cleanups.push(() => window.clearTimeout(timeoutId));
            recheck();
          });
        })()
        """

        switch v2RunBrowserJavaScript(
            webView,
            surfaceId: surfaceId,
            script: waitScript,
            timeout: timeout + 1.0,
            useEval: false
        ) {
        case .success(let value):
            return (value as? Bool) == true ? .met : .timedOut
        case .failure(let message):
            return .evaluationFailed(message)
        }
    }

    private enum V2BrowserWaitOutcome {
        case met
        case timedOut
        case evaluationFailed(String)
    }

    private nonisolated func v2BrowserSelector(_ params: [String: Any]) -> String? {
        v2String(params, "selector")
            ?? v2String(params, "sel")
            ?? v2String(params, "element_ref")
            ?? v2String(params, "ref")
    }

    private func v2BrowserNotSupported(_ method: String, details: String) -> V2CallResult {
        .err(code: "not_supported", message: "\(method) is not supported on WKWebView", data: ["details": details])
    }

    private nonisolated func v2BrowserAllocateElementRef(surfaceId: UUID, selector: String) -> String {
        v2MainSync {
            let ref = "@e\(v2BrowserNextElementOrdinal)"
            v2BrowserNextElementOrdinal += 1
            v2BrowserElementRefs[ref] = V2BrowserElementRefEntry(surfaceId: surfaceId, selector: selector)
            return ref
        }
    }

    private nonisolated func v2BrowserResolveSelector(_ rawSelector: String, surfaceId: UUID) -> String? {
        let trimmed = rawSelector.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let refKey: String? = {
            if trimmed.hasPrefix("@e") { return trimmed }
            if trimmed.hasPrefix("e"), Int(trimmed.dropFirst()) != nil { return "@\(trimmed)" }
            return nil
        }()

        if let refKey {
            guard let entry = v2MainSync({ v2BrowserElementRefs[refKey] }), entry.surfaceId == surfaceId else { return nil }
            return entry.selector
        }
        return trimmed
    }

    private nonisolated func v2BrowserCurrentFrameSelector(surfaceId: UUID) -> String? {
        v2MainSync { v2BrowserFrameSelectorBySurface[surfaceId] }
    }

    /// A WKWebView that has never committed a navigation has no JavaScript context, so the
    /// first evaluateJavaScript/callAsyncJavaScript call can hang for its full timeout. A
    /// URL-less browser surface never mounts its webview either (no render, no host window),
    /// so a raw webView.load() would not progress. Kick such surfaces through the panel's
    /// normal navigate path (which hosts the webview) to about:blank, and wait for the URL
    /// to commit (KVO, bounded by `timeout`) before any automation JS runs against them.
    private nonisolated func v2EnsureBrowserDocumentLoaded(
        _ webView: WKWebView,
        surfaceId: UUID,
        timeout: TimeInterval = 3.0
    ) {
        let needsKick: Bool = v2MainSync {
            guard webView.url == nil,
                  !webView.isLoading,
                  webView.backForwardList.currentItem == nil else { return false }
            guard let located = AppDelegate.shared?.locateSurface(surfaceId: surfaceId),
                  let workspace = located.tabManager.tabs.first(where: { $0.id == located.workspaceId }),
                  let browserPanel = workspace.browserPanel(for: surfaceId),
                  let blankURL = URL(string: "about:blank") else {
#if DEBUG
                cmuxDebugLog("browser.jsKick.locateFailed surface=\(surfaceId.uuidString.prefix(5))")
#endif
                return false
            }
            // Discarded/restored tabs also have a fresh nil-url webview but preserve
            // the user's page; bring that back instead of clobbering it with blank.
            if browserPanel.restoreDiscardedWebViewIfNeeded(reason: "automation-js") {
                return true
            }
            if let preserved = browserPanel.currentURL {
                browserPanel.navigate(to: preserved)
            } else {
                browserPanel.navigate(to: blankURL)
            }
            return true
        }
        guard needsKick else { return }

        // Register synchronously and invalidate after the await (both on main) so
        // the observation cannot leak when the commit never arrives before timeout.
        nonisolated(unsafe) var observation: NSKeyValueObservation?
        let committed = v2AwaitCallback(timeout: timeout) { (finish: @escaping (Bool) -> Void) in
            v2MainSync {
                observation = webView.observe(\.url, options: [.initial, .new]) { observed, _ in
                    guard observed.url != nil else { return }
                    finish(true)
                }
            }
        }
        v2MainSync {
            observation?.invalidate()
            observation = nil
        }
#if DEBUG
        cmuxDebugLog(
            "browser.jsKick surface=\(surfaceId.uuidString.prefix(5)) " +
            "committed=\(committed == true) url=\(v2MainSync { webView.url?.absoluteString ?? "nil" })"
        )
#endif
    }

    private nonisolated func v2RunBrowserJavaScript(
        _ webView: WKWebView,
        surfaceId: UUID,
        script: String,
        timeout: TimeInterval = 5.0,
        useEval: Bool = true,
        onIsolatedWorldFallback: (() -> Void)? = nil
    ) -> V2JavaScriptResult {
        v2EnsureBrowserDocumentLoaded(webView, surfaceId: surfaceId)
        let scriptLiteral = v2JSONLiteral(script)
        let framePrelude: String
        if let frameSelector = v2BrowserCurrentFrameSelector(surfaceId: surfaceId) {
            let selectorLiteral = v2JSONLiteral(frameSelector)
            framePrelude = """
            let __cmuxDoc = document;
            try {
              const __cmuxFrame = document.querySelector(\(selectorLiteral));
              if (__cmuxFrame && __cmuxFrame.contentDocument) {
                __cmuxDoc = __cmuxFrame.contentDocument;
              }
            } catch (_) {}
            """
        } else {
            framePrelude = "const __cmuxDoc = document;"
        }

        let executionBlock: String
        if useEval {
            executionBlock = "const __r = eval(\(scriptLiteral));"
        } else {
            executionBlock = "const __r = \(script);"
        }

        let asyncFunctionBody = """
        \(framePrelude)

        const __cmuxMaybeAwait = async (__r) => {
          if (__r !== null && (typeof __r === 'object' || typeof __r === 'function') && typeof __r.then === 'function') {
            return await __r;
          }
          return __r;
        };

        const __cmuxEvalInFrame = async function() {
          const document = __cmuxDoc;
          \(executionBlock)
          const __value = await __cmuxMaybeAwait(__r);
          return {
            __cmux_t: (typeof __value === 'undefined') ? 'undefined' : 'value',
            __cmux_v: __value
          };
        };

        return await __cmuxEvalInFrame();
        """

        var rawResult: V2JavaScriptResult
        if #available(macOS 11.0, *) {
            rawResult = v2RunJavaScript(
                webView,
                script: asyncFunctionBody,
                timeout: timeout,
                preferAsync: true,
                world: .page
            )
        } else {
            let evaluateFallback = """
            (async () => {
              \(asyncFunctionBody)
            })()
            """
            rawResult = v2RunJavaScript(webView, script: evaluateFallback, timeout: timeout, world: .page)
        }

        // Retry in the isolated world only when page CSP blocked eval/function construction
        // (script-src without 'unsafe-eval'). That block applies to callAsyncJavaScript and page
        // eval() but not to isolated content worlds, which share the DOM, so DOM-only automation
        // scripts and DOM-reading user evals (document.title) still work there.
        //
        // Gating on the CSP signature matters: a script can fail in the page world for ordinary
        // reasons (a thrown exception, a timeout) after performing a side effect, and an
        // unconditional retry would run it a second time and duplicate that side effect, or return
        // a value from the isolated world that differs from the page world with no visible signal.
        //
        // The isolated world cannot see page-world JS globals (window.reactRoot set by the page's
        // own scripts). For internal automation (useEval == false) that is transparent. For a
        // user-supplied browser.eval (useEval == true) it matters, so we invoke
        // onIsolatedWorldFallback to let browser.eval annotate the result with the content world.
        if case .failure(let pageMessage) = rawResult,
           v2BrowserFailureLooksLikeCSPEvalBlock(pageMessage),
           #available(macOS 11.0, *) {
            let isolatedResult = v2RunJavaScript(
                webView,
                script: asyncFunctionBody,
                timeout: timeout,
                preferAsync: true,
                world: .isolated
            )
            switch isolatedResult {
            case .success:
                rawResult = isolatedResult
                onIsolatedWorldFallback?()
            case .failure(let isolatedMessage):
                if isolatedMessage != pageMessage {
                    rawResult = .failure("\(pageMessage) (isolated-world retry: \(isolatedMessage))")
                }
            }
        }

        switch rawResult {
        case .failure(let message):
            return .failure(message)
        case .success(let value):
            guard let dict = value as? [String: Any],
                  let type = dict[Self.v2BrowserEvalEnvelopeTypeKey] as? String else {
                return .success(value)
            }

            switch type {
            case Self.v2BrowserEvalEnvelopeTypeUndefined:
                return .success(v2BrowserUndefinedSentinel)
            case Self.v2BrowserEvalEnvelopeTypeValue:
                return .success(dict[Self.v2BrowserEvalEnvelopeValueKey])
            default:
                return .success(value)
            }
        }
    }

    private nonisolated func v2BrowserRecordUnsupportedRequest(surfaceId: UUID, request: [String: Any]) {
        v2MainSync {
            var logs = v2BrowserUnsupportedNetworkRequestsBySurface[surfaceId] ?? []
            logs.append(request)
            if logs.count > 256 {
                logs.removeFirst(logs.count - 256)
            }
            v2BrowserUnsupportedNetworkRequestsBySurface[surfaceId] = logs
        }
    }

    private nonisolated func v2BrowserPendingDialogs(surfaceId: UUID) -> [[String: Any]] {
        let queue = v2MainSync { v2BrowserDialogQueueBySurface[surfaceId] ?? [] }
        return queue.enumerated().map { index, d in
            [
                "index": index,
                "type": d.type,
                "message": d.message,
                "default_text": v2OrNull(d.defaultText)
            ]
        }
    }

    func enqueueBrowserDialog(
        surfaceId: UUID,
        type: String,
        message: String,
        defaultText: String?,
        responder: @escaping (_ accept: Bool, _ text: String?) -> Void
    ) {
        var queue = v2BrowserDialogQueueBySurface[surfaceId] ?? []
        queue.append(V2BrowserPendingDialog(type: type, message: message, defaultText: defaultText, responder: responder))
        if queue.count > 16 {
            // Keep bounded memory while preserving FIFO semantics for newest entries.
            queue.removeFirst(queue.count - 16)
        }
        v2BrowserDialogQueueBySurface[surfaceId] = queue
    }

    private func v2BrowserPopDialog(surfaceId: UUID) -> V2BrowserPendingDialog? {
        var queue = v2BrowserDialogQueueBySurface[surfaceId] ?? []
        guard !queue.isEmpty else { return nil }
        let first = queue.removeFirst()
        v2BrowserDialogQueueBySurface[surfaceId] = queue
        return first
    }

    private func v2BrowserEnsureInitScriptsApplied(surfaceId: UUID, browserPanel: BrowserPanel) {
        let scripts = v2BrowserInitScriptsBySurface[surfaceId] ?? []
        let styles = v2BrowserInitStylesBySurface[surfaceId] ?? []
        guard !scripts.isEmpty || !styles.isEmpty else { return }

        let injector = """
        (() => {
          window.__cmuxInitScriptsApplied = window.__cmuxInitScriptsApplied || { scripts: [], styles: [] };
          return true;
        })()
        """
        _ = v2RunBrowserJavaScript(v2MainSync { browserPanel.webView }, surfaceId: surfaceId, script: injector)

        for script in scripts {
            _ = v2RunBrowserJavaScript(v2MainSync { browserPanel.webView }, surfaceId: surfaceId, script: script)
        }
        for css in styles {
            let cssLiteral = v2JSONLiteral(css)
            let styleScript = """
            (() => {
              const id = 'cmux-init-style-' + btoa(unescape(encodeURIComponent(\(cssLiteral)))).replace(/=+$/g, '');
              if (document.getElementById(id)) return true;
              const el = document.createElement('style');
              el.id = id;
              el.textContent = String(\(cssLiteral));
              (document.head || document.documentElement || document.body).appendChild(el);
              return true;
            })()
            """
            _ = v2RunBrowserJavaScript(v2MainSync { browserPanel.webView }, surfaceId: surfaceId, script: styleScript)
        }
    }

    private nonisolated func v2PNGData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private nonisolated func bestEffortPruneTemporaryFiles(
        in directoryURL: URL,
        keepingMostRecent maxCount: Int = 50,
        maxAge: TimeInterval = 24 * 60 * 60
    ) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let now = Date()
        let datedEntries = entries.compactMap { url -> (url: URL, date: Date)? in
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .creationDateKey]),
                  values.isRegularFile == true else {
                return nil
            }
            return (url, values.contentModificationDate ?? values.creationDate ?? .distantPast)
        }.sorted { $0.date > $1.date }

        for (index, entry) in datedEntries.enumerated() {
            if index >= maxCount || now.timeIntervalSince(entry.date) > maxAge {
                try? FileManager.default.removeItem(at: entry.url)
            }
        }
    }

    // MARK: - Markdown

    // MARK: - Project

    // MARK: - Project state driving (debug RPC for autonomous iteration)

    private func v2ResolveProjectPanel(params: [String: Any]) -> (Workspace, ProjectPanel)? {
        guard let tabManager = v2ResolveTabManager(params: params) else { return nil }
        var result: (Workspace, ProjectPanel)?
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else { return }
            let surfaceId = v2UUID(params, "surface_id") ?? ws.focusedPanelId
            guard let surfaceId,
                  let panel = ws.panels[surfaceId] as? ProjectPanel else { return }
            result = (ws, panel)
        }
        return result
    }

    // MARK: - Browser

    private func v2BrowserDisabledExternalOpenResult(
        rawURL: String? = nil,
        url: URL?,
        tabManager: TabManager?
    ) -> V2CallResult {
        if let rawURL, url == nil {
            return .err(
                code: "invalid_params",
                message: "Invalid URL",
                data: ["url": rawURL]
            )
        }
        guard let url else {
            return .err(code: "browser_disabled", message: "cmux browser is disabled", data: nil)
        }

        var result: V2CallResult = .err(
            code: "external_open_failed",
            message: "Failed to open URL externally",
            data: ["url": url.absoluteString]
        )
        v2MainSync {
            guard NSWorkspace.shared.open(url) else { return }
            let windowId = v2ResolveWindowId(tabManager: tabManager)
            result = .ok([
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "workspace_id": v2OrNull(nil),
                "workspace_ref": v2Ref(kind: .workspace, uuid: nil),
                "pane_id": v2OrNull(nil),
                "pane_ref": v2Ref(kind: .pane, uuid: nil),
                "surface_id": v2OrNull(nil),
                "surface_ref": v2Ref(kind: .surface, uuid: nil),
                "created_split": false,
                "opened_externally": true,
                "browser_disabled": true,
                "placement_strategy": "external_browser_disabled",
                "url": url.absoluteString
            ])
        }
        return result
    }

    private func v2BrowserOpenSplit(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        let urlStr = v2String(params, "url")
        // Resolve with the same smart logic as browser.navigate (URL, then search fallback)
        // so an unparseable raw string fails loudly instead of silently opening about:blank.
        let url: URL?
        if let urlStr {
            let trimmedURLStr = urlStr.trimmingCharacters(in: .whitespacesAndNewlines)
            if let navigable = resolveBrowserNavigableURL(urlStr) {
                // http/https/file plus host-like inputs (example.com, localhost:3000).
                url = navigable
            } else if let parsed = URL(string: trimmedURLStr), parsed.scheme != nil {
                // Preserve any real-scheme URL the navigable resolver rejects: about:blank,
                // the trusted cmux-diff-viewer:// scheme, and external app/deep-link schemes
                // (mailto:, xcode://, ...). The downstream browser-disabled, external-open, and
                // diff-viewer-registration paths act on the original URL; only scheme-less,
                // non-navigable input should fall through to a search query.
                url = parsed
            } else if let search = BrowserSearchSettingsStore().currentConfiguration.searchURL(query: urlStr) {
                url = search
            } else {
                return .err(
                    code: "invalid_params",
                    message: "Could not resolve URL or search query",
                    data: ["url": urlStr]
                )
            }
        } else {
            url = nil
        }
        let respectExternalOpenRules = v2Bool(params, "respect_external_open_rules") ?? false

        if BrowserAvailabilitySettings.isDisabled() {
            if v2IsDiffViewerURL(url) {
                return .err(code: "browser_disabled", message: "cmux browser is disabled", data: nil)
            }
            return v2BrowserDisabledExternalOpenResult(rawURL: urlStr, url: url, tabManager: tabManager)
        }
        if let error = v2RegisterDiffViewerURLIfNeeded(params: params, url: url) {
            return error
        }

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to create browser", data: nil)
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            if let url,
               respectExternalOpenRules,
               BrowserLinkOpenSettings.shouldOpenExternally(url) {
                guard NSWorkspace.shared.open(url) else {
                    result = .err(
                        code: "external_open_failed",
                        message: "Failed to open URL externally",
                        data: ["url": url.absoluteString]
                    )
                    return
                }
                let windowId = v2ResolveWindowId(tabManager: tabManager)
                result = .ok([
                    "window_id": v2OrNull(windowId?.uuidString),
                    "window_ref": v2Ref(kind: .window, uuid: windowId),
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "pane_id": v2OrNull(nil),
                    "pane_ref": v2Ref(kind: .pane, uuid: nil),
                    "surface_id": v2OrNull(nil),
                    "surface_ref": v2Ref(kind: .surface, uuid: nil),
                    "created_split": false,
                    "placement_strategy": "external",
                    "opened_externally": true,
                    "url": url.absoluteString
                ])
                return
            }
            v2MaybeFocusWindow(for: tabManager)
            v2MaybeSelectWorkspace(tabManager, workspace: ws)

            let sourceSurfaceId = v2UUID(params, "surface_id") ?? ws.focusedPanelId
            guard let sourceSurfaceId else {
                result = .err(code: "not_found", message: "No focused surface to split", data: nil)
                return
            }
            guard ws.panels[sourceSurfaceId] != nil else {
                result = .err(code: "not_found", message: "Source surface not found", data: ["surface_id": sourceSurfaceId.uuidString])
                return
            }

            let sourcePaneUUID = ws.paneId(forPanelId: sourceSurfaceId)?.id
            let focus = v2FocusAllowed(requested: v2Bool(params, "focus") ?? false)
            let omnibarVisible = v2Bool(params, "show_omnibar") ?? true
            let transparentBackground = v2Bool(params, "transparent_background") ?? false
            let bypassRemoteProxy = v2Bool(params, "bypass_remote_proxy") ?? v2IsDiffViewerURL(url)

            var createdSplit = true
            var placementStrategy = "split_right"
            let createdPanel: BrowserPanel?
            if let targetPane = ws.preferredRightSideTargetPane(fromPanelId: sourceSurfaceId) {
                createdPanel = ws.newBrowserSurface(
                    inPane: targetPane,
                    url: url,
                    focus: focus,
                    selectWhenNotFocused: true,
                    creationPolicy: .automationPreload,
                    omnibarVisible: omnibarVisible,
                    transparentBackground: transparentBackground,
                    bypassRemoteProxy: bypassRemoteProxy
                )
                createdSplit = false
                placementStrategy = "reuse_right_sibling"
            } else {
                createdPanel = ws.newBrowserSplit(
                    from: sourceSurfaceId,
                    orientation: .horizontal,
                    url: url,
                    focus: focus,
                    creationPolicy: .automationPreload,
                    omnibarVisible: omnibarVisible,
                    transparentBackground: transparentBackground,
                    bypassRemoteProxy: bypassRemoteProxy
                )
            }

            guard let browserPanelId = createdPanel?.id else {
                result = .err(code: "internal_error", message: "Failed to create browser", data: nil)
                return
            }

            let targetPaneUUID = ws.paneId(forPanelId: browserPanelId)?.id
            let windowId = v2ResolveWindowId(tabManager: tabManager)
            result = .ok([
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "pane_id": v2OrNull(targetPaneUUID?.uuidString),
                "pane_ref": v2Ref(kind: .pane, uuid: targetPaneUUID),
                "surface_id": browserPanelId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: browserPanelId),
                "source_surface_id": sourceSurfaceId.uuidString,
                "source_surface_ref": v2Ref(kind: .surface, uuid: sourceSurfaceId),
                "source_pane_id": v2OrNull(sourcePaneUUID?.uuidString),
                "source_pane_ref": v2Ref(kind: .pane, uuid: sourcePaneUUID),
                "target_pane_id": v2OrNull(targetPaneUUID?.uuidString),
                "target_pane_ref": v2Ref(kind: .pane, uuid: targetPaneUUID),
                "created_split": createdSplit,
                "placement_strategy": placementStrategy,
                "show_omnibar": createdPanel?.isOmnibarVisible ?? omnibarVisible,
                "transparent_background": transparentBackground,
                "bypass_remote_proxy": bypassRemoteProxy
            ])
        }
        return result
    }

    private func v2IsDiffViewerURL(_ url: URL?) -> Bool {
        guard let url else { return false }
        if url.scheme?.lowercased() == CmuxDiffViewerURLSchemeHandler.scheme {
            return true
        }
        return url.scheme?.lowercased() == "http" &&
            url.host == "127.0.0.1" &&
            url.fragment == "cmux-diff-viewer"
    }

    private func v2RegisterDiffViewerURLIfNeeded(params: [String: Any], url: URL?) -> V2CallResult? {
        guard let url,
              url.scheme == CmuxDiffViewerURLSchemeHandler.scheme else {
            return nil
        }
        guard let token = v2String(params, "diff_viewer_token"),
              token == url.host,
              let rawFiles = params["diff_viewer_files"] as? [[String: Any]],
              !rawFiles.isEmpty,
              rawFiles.count <= CmuxDiffViewerURLSchemeHandler.maxRegisteredFiles else {
            return .err(code: "invalid_params", message: "Missing or invalid trusted diff viewer allowlist", data: nil)
        }

        let files = rawFiles.compactMap(CmuxDiffViewerURLSchemeHandler.registeredFile(from:))
        guard files.count == rawFiles.count else {
            return .err(code: "invalid_params", message: "Invalid trusted diff viewer allowlist", data: nil)
        }

        do {
            try CmuxDiffViewerURLSchemeHandler.shared.register(token: token, files: files)
            return nil
        } catch {
            return .err(
                code: "invalid_params",
                message: "Invalid trusted diff viewer allowlist",
                data: ["details": error.localizedDescription]
            )
        }
    }

    private nonisolated func v2BrowserNavigate(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let surfaceId = v2UUID(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid surface_id", data: nil)
        }
        guard let url = v2String(params, "url") else {
            return .err(code: "invalid_params", message: "Missing url", data: nil)
        }

        var basePayload: [String: Any]?
        v2MainSync {
            let resolvedContext = v2ResolveBrowserPanelContext(params: params, tabManager: tabManager)
            if resolvedContext.error != nil { return }
            guard let context = resolvedContext.context,
                  context.surfaceId == surfaceId else { return }
            context.browserPanel.navigateSmart(url)
            let windowId = v2ResolveWindowId(tabManager: tabManager)
            basePayload = [
                "workspace_id": context.workspaceId.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: context.workspaceId),
                "surface_id": context.surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: context.surfaceId),
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId)
            ]
        }
        guard var payload = basePayload else {
            return .err(code: "not_found", message: "Surface not found or not a browser", data: ["surface_id": surfaceId.uuidString])
        }
        // Run the optional --snapshot-after walk on the worker thread (not inside
        // v2MainSync) so a slow accessibility-tree snapshot on a fresh surface
        // can't block SwiftUI and recreate mount deadlocks. Standalone
        // browser.snapshot already runs here; keep the post-action path identical.
        v2BrowserAppendPostSnapshot(params: params, surfaceId: surfaceId, payload: &payload)
        return .ok(payload)
    }

    private nonisolated func v2BrowserBack(params: [String: Any]) -> V2CallResult {
        return v2BrowserNavSimple(params: params, action: "back")
    }

    private nonisolated func v2BrowserForward(params: [String: Any]) -> V2CallResult {
        return v2BrowserNavSimple(params: params, action: "forward")
    }

    private nonisolated func v2BrowserReload(params: [String: Any]) -> V2CallResult {
        return v2BrowserNavSimple(params: params, action: "reload")
    }

    private nonisolated func v2BrowserNotFoundDiagnostics(
        surfaceId: UUID,
        browserPanel: BrowserPanel,
        selector: String
    ) -> [String: Any] {
        let script = v2BrowserControl.notFoundDiagnosticsScript(selector: selector)

        switch v2RunBrowserJavaScript(v2MainSync { browserPanel.webView }, surfaceId: surfaceId, script: script, timeout: 4.0) {
        case .failure(let message):
            return [
                "selector": selector,
                "diagnostics_error": message
            ]
        case .success(let value):
            guard let dict = value as? [String: Any] else {
                return ["selector": selector]
            }
            var out: [String: Any] = ["selector": selector]
            if let count = dict["count"] { out["match_count"] = count }
            if let visibleCount = dict["visible_count"] { out["visible_match_count"] = visibleCount }
            if let sample = dict["sample"] { out["sample"] = v2NormalizeJSValue(sample) }
            if let excerpt = dict["snapshot_excerpt"] { out["snapshot_excerpt"] = excerpt }
            if let body = dict["body_excerpt"] { out["body_excerpt"] = body }
            if let title = dict["title"] { out["title"] = title }
            if let url = dict["url"] { out["url"] = url }
            if let err = dict["error"] { out["diagnostics_code"] = err }
            if let details = dict["details"] { out["diagnostics_details"] = details }
            return out
        }
    }

    private nonisolated func v2BrowserElementNotFoundResult(
        actionName: String,
        selector: String,
        attempts: Int,
        surfaceId: UUID,
        browserPanel: BrowserPanel
    ) -> V2CallResult {
        var data = v2BrowserNotFoundDiagnostics(surfaceId: surfaceId, browserPanel: browserPanel, selector: selector)
        data["action"] = actionName
        data["retry_attempts"] = attempts
        data["hint"] = "Run 'browser snapshot' to refresh refs, then retry with a more specific selector."

        let count = (data["match_count"] as? Int) ?? (data["match_count"] as? NSNumber)?.intValue ?? 0
        let visibleCount = (data["visible_match_count"] as? Int) ?? (data["visible_match_count"] as? NSNumber)?.intValue ?? 0

        let message = v2BrowserControl.elementNotFoundMessage(
            selector: selector,
            matchCount: count,
            visibleCount: visibleCount
        )

        return .err(code: "not_found", message: message, data: data)
    }

    private nonisolated func v2BrowserAppendPostSnapshot(
        params: [String: Any],
        surfaceId: UUID,
        payload: inout [String: Any]
    ) {
        guard v2Bool(params, "snapshot_after") ?? false else { return }

        var snapshotParams: [String: Any] = [
            "surface_id": surfaceId.uuidString,
            "interactive": v2Bool(params, "snapshot_interactive") ?? true,
            "cursor": v2Bool(params, "snapshot_cursor") ?? false,
            "compact": v2Bool(params, "snapshot_compact") ?? true,
            "max_depth": max(0, v2Int(params, "snapshot_max_depth") ?? 10)
        ]
        if let selector = v2String(params, "snapshot_selector"),
           !selector.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            snapshotParams["selector"] = selector
        }

        switch v2BrowserSnapshot(params: snapshotParams) {
        case .ok(let snapshotAny):
            guard let snapshot = snapshotAny as? [String: Any] else {
                payload["post_action_snapshot_error"] = [
                    "code": "internal_error",
                    "message": "Invalid snapshot payload"
                ]
                return
            }
            if let value = snapshot["snapshot"] {
                payload["post_action_snapshot"] = value
            }
            if let value = snapshot["refs"] {
                payload["post_action_refs"] = value
            }
            if let value = snapshot["title"] {
                payload["post_action_title"] = value
            }
            if let value = snapshot["url"] {
                payload["post_action_url"] = value
            }
        case .err(code: let code, message: let message, data: let data):
            var err: [String: Any] = [
                "code": code,
                "message": message,
            ]
            err["data"] = v2OrNull(data)
            payload["post_action_snapshot_error"] = err
        }
    }

    private nonisolated func v2BrowserSelectorAction(
        params: [String: Any],
        actionName: String,
        scriptBuilder: (_ selectorLiteral: String) -> String
    ) -> V2CallResult {
        guard let selectorRaw = v2BrowserSelector(params) else {
            return .err(code: "invalid_params", message: "Missing selector", data: nil)
        }

        return v2BrowserWithPanelContext(params: params) { ctx in
            let surfaceId = ctx.surfaceId
            let browserPanel = ctx.browserPanel
            guard let selector = v2BrowserResolveSelector(selectorRaw, surfaceId: surfaceId) else {
                return .err(code: "not_found", message: "Element reference not found", data: ["selector": selectorRaw])
            }
            let script = scriptBuilder(v2JSONLiteral(selector))
            let retryAttempts = max(1, v2Int(params, "retry_attempts") ?? 3)
            let selectorCondition = "document.querySelector(\(v2JSONLiteral(selector))) !== null"

            for attempt in 1...retryAttempts {
                switch v2RunBrowserJavaScript(ctx.webView, surfaceId: surfaceId, script: script, useEval: false) {
                case .failure(let message):
                    return .err(code: "js_error", message: message, data: ["action": actionName, "selector": selector])
                case .success(let value):
                    if let dict = value as? [String: Any],
                       let ok = dict["ok"] as? Bool,
                       ok {
                        var payload: [String: Any] = [
                            "workspace_id": ctx.workspaceId.uuidString,
                            "surface_id": surfaceId.uuidString,
                            "action": actionName,
                            "attempts": attempt
                        ]
                        payload["workspace_ref"] = v2Ref(kind: .workspace, uuid: ctx.workspaceId)
                        payload["surface_ref"] = v2Ref(kind: .surface, uuid: surfaceId)
                        if let resultValue = dict["value"] {
                            payload["value"] = v2NormalizeJSValue(resultValue)
                        }
                        v2BrowserAppendPostSnapshot(params: params, surfaceId: surfaceId, payload: &payload)
                        return .ok(payload)
                    }

                    let errorText = (value as? [String: Any])?["error"] as? String
                    if errorText == "not_found", attempt < retryAttempts {
                        let waitTimeoutMs = max(80, (retryAttempts - attempt) * 80)
                        guard case .met = v2WaitForBrowserCondition(
                            ctx.webView,
                            surfaceId: surfaceId,
                            conditionScript: selectorCondition,
                            timeoutMs: waitTimeoutMs
                        ) else {
                            return v2BrowserElementNotFoundResult(
                                actionName: actionName,
                                selector: selector,
                                attempts: attempt,
                                surfaceId: surfaceId,
                                browserPanel: browserPanel
                            )
                        }
                        continue
                    }
                    if errorText == "not_found" {
                        return v2BrowserElementNotFoundResult(
                            actionName: actionName,
                            selector: selector,
                            attempts: retryAttempts,
                            surfaceId: surfaceId,
                            browserPanel: browserPanel
                        )
                    }

                    return .err(code: "js_error", message: "Browser action failed", data: ["action": actionName, "selector": selector])
                }
            }

            return v2BrowserElementNotFoundResult(
                actionName: actionName,
                selector: selector,
                attempts: retryAttempts,
                surfaceId: surfaceId,
                browserPanel: browserPanel
            )
        }
    }

    private nonisolated func v2BrowserEval(params: [String: Any]) -> V2CallResult {
        guard let script = v2String(params, "script") else {
            return .err(code: "invalid_params", message: "Missing script", data: nil)
        }
        return v2BrowserWithPanelContext(params: params) { ctx in
            var usedIsolatedWorld = false
            switch v2RunBrowserJavaScript(
                ctx.webView,
                surfaceId: ctx.surfaceId,
                script: script,
                timeout: 10.0,
                onIsolatedWorldFallback: { usedIsolatedWorld = true }
            ) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                var payload: [String: Any] = [
                    "workspace_id": ctx.workspaceId.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ctx.workspaceId),
                    "surface_id": ctx.surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: ctx.surfaceId),
                    "value": v2NormalizeJSValue(value)
                ]
                if usedIsolatedWorld {
                    // Page-world eval was blocked (typically CSP without 'unsafe-eval'); this value
                    // came from the isolated content world. It shares the DOM but cannot read
                    // page-world JS globals, so flag it instead of returning silently.
                    payload["content_world"] = "isolated"
                    payload["content_world_note"] = "Page-world eval was blocked (likely CSP without 'unsafe-eval'); value came from the isolated content world, which shares the DOM but cannot see page-world JS globals."
                }
                return .ok(payload)
            }
        }
    }

    private nonisolated func v2BrowserSnapshot(params: [String: Any]) -> V2CallResult {
        let interactiveOnly = v2Bool(params, "interactive") ?? false
        let includeCursor = v2Bool(params, "cursor") ?? false
        let compact = v2Bool(params, "compact") ?? false
        let maxDepth = max(0, v2Int(params, "max_depth") ?? v2Int(params, "maxDepth") ?? 12)
        let scopeSelector = v2String(params, "selector")

        return v2BrowserWithPanelContext(params: params) { ctx in
            let surfaceId = ctx.surfaceId
            let interactiveLiteral = interactiveOnly ? "true" : "false"
            let cursorLiteral = includeCursor ? "true" : "false"
            let compactLiteral = compact ? "true" : "false"
            let scopeLiteral = scopeSelector.map(v2JSONLiteral) ?? "null"

            let script = """
            (() => {
              const __interactiveOnly = \(interactiveLiteral);
              const __includeCursor = \(cursorLiteral);
              const __compact = \(compactLiteral);
              const __maxDepth = \(maxDepth);
              const __scopeSelector = \(scopeLiteral);

              const __normalize = (s) => String(s || '').replace(/\\s+/g, ' ').trim();
              const __interactiveRoles = new Set(['button','link','textbox','checkbox','radio','combobox','listbox','menuitem','menuitemcheckbox','menuitemradio','option','searchbox','slider','spinbutton','switch','tab','treeitem']);
              const __contentRoles = new Set(['heading','cell','gridcell','columnheader','rowheader','listitem','article','region','main','navigation']);
              const __structuralRoles = new Set(['generic','group','list','table','row','rowgroup','grid','treegrid','menu','menubar','toolbar','tablist','tree','directory','document','application','presentation','none']);

              const __isVisible = (el) => {
                try {
                  if (!el) return false;
                  const style = getComputedStyle(el);
                  const rect = el.getBoundingClientRect();
                  if (!style || !rect) return false;
                  if (rect.width <= 0 || rect.height <= 0) return false;
                  if (style.display === 'none' || style.visibility === 'hidden') return false;
                  if (parseFloat(style.opacity || '1') <= 0.01) return false;
                  return true;
                } catch (_) {
                  return false;
                }
              };

              const __implicitRole = (el) => {
                const tag = String(el.tagName || '').toLowerCase();
                if (tag === 'button') return 'button';
                if (tag === 'a' && el.hasAttribute('href')) return 'link';
                if (tag === 'input') {
                  const type = String(el.getAttribute('type') || 'text').toLowerCase();
                  if (type === 'checkbox') return 'checkbox';
                  if (type === 'radio') return 'radio';
                  if (type === 'submit' || type === 'button' || type === 'reset') return 'button';
                  return 'textbox';
                }
                if (tag === 'textarea') return 'textbox';
                if (tag === 'select') return 'combobox';
                if (tag === 'summary') return 'button';
                if (tag === 'h1' || tag === 'h2' || tag === 'h3' || tag === 'h4' || tag === 'h5' || tag === 'h6') return 'heading';
                if (tag === 'li') return 'listitem';
                return null;
              };

              const __nameFor = (el) => {
                const aria = __normalize(el.getAttribute('aria-label') || '');
                if (aria) return aria;
                const labelledBy = __normalize(el.getAttribute('aria-labelledby') || '');
                if (labelledBy) {
                  const text = labelledBy.split(/\\s+/).map((id) => document.getElementById(id)).filter(Boolean).map((n) => __normalize(n.textContent || '')).join(' ').trim();
                  if (text) return text;
                }
                if (el.tagName && String(el.tagName).toLowerCase() === 'input') {
                  const placeholder = __normalize(el.getAttribute('placeholder') || '');
                  if (placeholder) return placeholder;
                  const value = __normalize(el.value || '');
                  if (value) return value;
                }
                const title = __normalize(el.getAttribute('title') || '');
                if (title) return title;
                const text = __normalize(el.innerText || el.textContent || '');
                if (text) return text.slice(0, 120);
                return '';
              };

              const __cssPath = (el) => {
                if (!el || el.nodeType !== 1) return null;
                if (el.id) return '#' + CSS.escape(el.id);
                const parts = [];
                let cur = el;
                while (cur && cur.nodeType === 1) {
                  let part = String(cur.tagName || '').toLowerCase();
                  if (!part) break;
                  if (cur.id) {
                    part += '#' + CSS.escape(cur.id);
                    parts.unshift(part);
                    break;
                  }
                  const tag = part;
                  const parent = cur.parentElement;
                  if (parent) {
                    const siblings = Array.from(parent.children).filter((n) => String(n.tagName || '').toLowerCase() === tag);
                    if (siblings.length > 1) {
                      const index = siblings.indexOf(cur) + 1;
                      part += `:nth-of-type(${index})`;
                    }
                  }
                  parts.unshift(part);
                  cur = cur.parentElement;
                  if (parts.length >= 6) break;
                }
                return parts.join(' > ');
              };

              const __root = (() => {
                if (__scopeSelector) {
                  return document.querySelector(__scopeSelector) || document.body || document.documentElement;
                }
                return document.body || document.documentElement;
              })();

              const __entries = [];
              const __seen = new Set();
              const __appendEntry = (el, depth, forcedRole) => {
                if (!__isVisible(el)) return;
                const explicitRole = __normalize(el.getAttribute('role') || '').toLowerCase();
                const role = forcedRole || explicitRole || __implicitRole(el) || '';
                if (!role) return;

                if (__interactiveOnly && !__interactiveRoles.has(role)) return;
                if (!__interactiveOnly) {
                  const includeRole = __interactiveRoles.has(role) || __contentRoles.has(role);
                  if (!includeRole) return;
                  if (__compact && __structuralRoles.has(role)) {
                    const name = __nameFor(el);
                    if (!name) return;
                  }
                }

                const selector = __cssPath(el);
                if (!selector || __seen.has(selector)) return;
                __seen.add(selector);
                __entries.push({
                  selector,
                  role,
                  name: __nameFor(el),
                  depth
                });
              };

              const __walk = (node, depth) => {
                if (!node || depth > __maxDepth || node.nodeType !== 1) return;
                const el = node;
                __appendEntry(el, depth, null);
                for (const child of Array.from(el.children || [])) {
                  __walk(child, depth + 1);
                }
              };

              if (__root) {
                __walk(__root, 0);
              }

              if (__includeCursor && __root) {
                const all = Array.from(__root.querySelectorAll('*'));
                for (const el of all) {
                  if (!__isVisible(el)) continue;
                  const style = getComputedStyle(el);
                  const hasOnClick = typeof el.onclick === 'function' || el.hasAttribute('onclick');
                  const hasCursorPointer = style.cursor === 'pointer';
                  const tabIndex = el.getAttribute('tabindex');
                  const hasTabIndex = tabIndex != null && String(tabIndex) !== '-1';
                  if (!hasOnClick && !hasCursorPointer && !hasTabIndex) continue;
                  __appendEntry(el, 0, 'generic');
                  if (__entries.length >= 256) break;
                }
              }

              const body = document.body;
              const root = document.documentElement;
              return {
                title: __normalize(document.title || ''),
                url: String(location.href || ''),
                ready_state: String(document.readyState || ''),
                text: body ? String(body.innerText || '') : '',
                html: root ? String(root.outerHTML || '') : '',
                entries: __entries
              };
            })()
            """

            switch v2RunBrowserJavaScript(ctx.webView, surfaceId: surfaceId, script: script, timeout: 10.0, useEval: false) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                guard let dict = value as? [String: Any] else {
                    return .err(code: "js_error", message: "Invalid snapshot payload", data: nil)
                }

                let title = (dict["title"] as? String) ?? ""
                let url = (dict["url"] as? String) ?? ""
                let readyState = (dict["ready_state"] as? String) ?? ""
                let text = (dict["text"] as? String) ?? ""
                let html = (dict["html"] as? String) ?? ""
                let entries = (dict["entries"] as? [[String: Any]]) ?? []

                var refs: [String: [String: Any]] = [:]
                var treeLines: [String] = []
                var seenSelectors: Set<String> = []

                for entry in entries {
                    guard let selector = entry["selector"] as? String,
                          !selector.isEmpty,
                          !seenSelectors.contains(selector) else {
                        continue
                    }
                    seenSelectors.insert(selector)

                    let roleRaw = (entry["role"] as? String) ?? "generic"
                    let role = roleRaw.isEmpty ? "generic" : roleRaw
                    let name = ((entry["name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let depth = max(0, (entry["depth"] as? Int) ?? ((entry["depth"] as? NSNumber)?.intValue ?? 0))

                    let refToken = v2BrowserAllocateElementRef(surfaceId: surfaceId, selector: selector)
                    let shortRef = refToken.hasPrefix("@") ? String(refToken.dropFirst()) : refToken

                    var refInfo: [String: Any] = ["role": role]
                    if !name.isEmpty {
                        refInfo["name"] = name
                    }
                    refs[shortRef] = refInfo

                    let indent = String(repeating: "  ", count: depth)
                    var line = "\(indent)- \(role)"
                    if !name.isEmpty {
                        let cleanName = name.replacingOccurrences(of: "\"", with: "'")
                        line += " \"\(cleanName)\""
                    }
                    line += " [ref=\(shortRef)]"
                    treeLines.append(line)
                }

                let titleForTree = title.isEmpty ? "page" : title.replacingOccurrences(of: "\"", with: "'")
                var snapshotLines = ["- document \"\(titleForTree)\""]
                if !treeLines.isEmpty {
                    snapshotLines.append(contentsOf: treeLines)
                } else {
                    let excerpt = text
                        .replacingOccurrences(of: "\n", with: " ")
                        .replacingOccurrences(of: "\t", with: " ")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !excerpt.isEmpty {
                        let clipped = String(excerpt.prefix(240)).replacingOccurrences(of: "\"", with: "'")
                        snapshotLines.append("- text \"\(clipped)\"")
                    } else {
                        snapshotLines.append("- (empty)")
                    }
                }
                let snapshotText = snapshotLines.joined(separator: "\n")

                var payload: [String: Any] = [
                    "workspace_id": ctx.workspaceId.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ctx.workspaceId),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "snapshot": snapshotText,
                    "title": title,
                    "url": url,
                    "ready_state": readyState,
                    "page": [
                        "title": title,
                        "url": url,
                        "ready_state": readyState,
                        "text": text,
                        "html": html
                    ]
                ]
                if !refs.isEmpty {
                    payload["refs"] = refs
                }
                return .ok(payload)
            }
        }
    }

    private nonisolated func v2BrowserWait(params: [String: Any]) -> V2CallResult {
        let timeoutMs = max(1, v2Int(params, "timeout_ms") ?? 5_000)
        let selectorRaw = v2BrowserSelector(params)

        let conditionScriptBase: String = {
            if let urlContains = v2String(params, "url_contains") {
                let literal = v2JSONLiteral(urlContains)
                return "String(location.href || '').includes(\(literal))"
            }
            if let textContains = v2String(params, "text_contains") {
                let literal = v2JSONLiteral(textContains)
                return "(document.body && String(document.body.innerText || '').includes(\(literal)))"
            }
            if let loadState = v2String(params, "load_state") {
                let normalizedLoadState = loadState.lowercased()
                if normalizedLoadState == "interactive" {
                    return """
                    (() => {
                      const __state = String(document.readyState || '').toLowerCase();
                      return __state === 'interactive' || __state === 'complete';
                    })()
                    """
                }
                let literal = v2JSONLiteral(normalizedLoadState)
                return "String(document.readyState || '').toLowerCase() === \(literal)"
            }
            if let fn = v2String(params, "function") {
                return "(() => { return !!(\(fn)); })()"
            }
            return "document.readyState === 'complete'"
        }()

        var setupResult: V2CallResult?
        var workspaceId: UUID?
        var surfaceIdOut: UUID?
        var webView: WKWebView?

        v2MainSync {
            guard let tabManager = self.v2ResolveTabManager(params: params) else {
                setupResult = .err(code: "unavailable", message: "TabManager not available", data: nil)
                return
            }
            let resolvedContext = self.v2ResolveBrowserPanelContext(params: params, tabManager: tabManager)
            if let error = resolvedContext.error {
                setupResult = error
                return
            }
            guard let context = resolvedContext.context else {
                setupResult = .err(code: "internal_error", message: "Failed to resolve browser surface", data: nil)
                return
            }
            workspaceId = context.workspaceId
            surfaceIdOut = context.surfaceId
            webView = context.webView
        }

        if let setupResult {
            return setupResult
        }
        guard let workspaceId, let surfaceIdOut, let webView else {
            return .err(code: "internal_error", message: "Failed to resolve browser surface", data: nil)
        }

        let conditionScript: String
        if let selectorRaw {
            guard let selector = v2BrowserResolveSelector(selectorRaw, surfaceId: surfaceIdOut) else {
                return .err(code: "not_found", message: "Element reference not found", data: ["selector": selectorRaw])
            }
            let literal = v2JSONLiteral(selector)
            conditionScript = "document.querySelector(\(literal)) !== null"
        } else {
            conditionScript = conditionScriptBase
        }

        switch v2WaitForBrowserCondition(
            webView,
            surfaceId: surfaceIdOut,
            conditionScript: conditionScript,
            timeoutMs: timeoutMs
        ) {
        case .met:
            return .ok([
                "workspace_id": workspaceId.uuidString,
                "workspace_ref": self.v2Ref(kind: .workspace, uuid: workspaceId),
                "surface_id": surfaceIdOut.uuidString,
                "surface_ref": self.v2Ref(kind: .surface, uuid: surfaceIdOut),
                "waited": true
            ])
        case .timedOut:
            return .err(code: "timeout", message: "Condition not met before timeout", data: ["timeout_ms": timeoutMs])
        case .evaluationFailed(let message):
            return .err(
                code: "js_error",
                message: "Wait condition could not be evaluated: \(message)",
                data: [
                    "timeout_ms": timeoutMs,
                    "url": v2MainSync { webView.url?.absoluteString ?? "about:blank" },
                    "hint": "Verify the page loaded with 'cmux browser <surface> get url' before waiting"
                ]
            )
        }
    }

    private nonisolated func v2BrowserClick(params: [String: Any]) -> V2CallResult {
        v2BrowserSelectorAction(params: params, actionName: "click") { selectorLiteral in
            """
            (() => {
              \(Self.browserInputHelpers)
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              if (el.disabled) return { ok: false, error: 'disabled' };
              el.scrollIntoView({ block: 'nearest', inline: 'nearest' });
              __cmuxClick(el);
              return { ok: true };
            })()
            """
        }
    }

    private nonisolated func v2BrowserDblClick(params: [String: Any]) -> V2CallResult {
        v2BrowserSelectorAction(params: params, actionName: "dblclick") { selectorLiteral in
            """
            (() => {
              \(Self.browserInputHelpers)
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              if (el.disabled) return { ok: false, error: 'disabled' };
              el.scrollIntoView({ block: 'nearest', inline: 'nearest' });
              __cmuxClick(el);
              __cmuxClick(el);
              const c = __cmuxCenter(el);
              __cmuxMouse(el, 'dblclick', c, 0, 2);
              return { ok: true };
            })()
            """
        }
    }

    private nonisolated func v2BrowserHover(params: [String: Any]) -> V2CallResult {
        v2BrowserSelectorAction(params: params, actionName: "hover") { selectorLiteral in
            """
            (() => {
              \(Self.browserInputHelpers)
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              el.scrollIntoView({ block: 'nearest', inline: 'nearest' });
              __cmuxHover(el);
              return { ok: true };
            })()
            """
        }
    }

    private nonisolated func v2BrowserFocusElement(params: [String: Any]) -> V2CallResult {
        v2BrowserSelectorAction(params: params, actionName: "focus") { selectorLiteral in
            """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              if (typeof el.focus === 'function') el.focus();
              return { ok: true };
            })()
            """
        }
    }

    /// JavaScript snippet that sets an input element's value using the native
    /// prototype setter. Frameworks like React, Vue, and Angular override the
    /// value property on instances, so a plain `el.value = x` assignment only
    /// updates the DOM without notifying the framework's internal state.
    /// Calling the native setter from the prototype bypasses the override and
    /// triggers the framework's change-detection when followed by an `input`
    /// event. Walks the prototype chain instead of using instanceof so it
    /// works with cross-realm elements (iframes) and custom web components.
    /// Expects `el` and `newValue` to be in scope.
    private nonisolated static let reactCompatibleSetValue = """
        let nativeSetter = null;
        for (let proto = Object.getPrototypeOf(el); proto; proto = Object.getPrototypeOf(proto)) {
          const desc = Object.getOwnPropertyDescriptor(proto, 'value');
          if (desc && desc.set) { nativeSetter = desc.set; break; }
        }
        if (nativeSetter) {
          nativeSetter.call(el, newValue);
        } else {
          el.value = newValue;
        }
    """

    /// Reusable JS that dispatches framework-correct input events. Synthetic (untrusted) events do
    /// not run native default actions, and many frameworks/libraries listen on the full pointer +
    /// mouse sequence (not just `click`) or need legacy KeyboardEvent fields (keyCode/which/code).
    /// These helpers reproduce a real user gesture so React, Vue, Svelte, Angular, Solid, and
    /// vanilla handlers all fire. Define them once at the top of an injected snippet, then call
    /// `__cmuxClick(el)`, `__cmuxHover(el)`, `__cmuxSetChecked(el, desired)`, and `__cmuxKey(t,type,key)`.
    private nonisolated static let browserInputHelpers = """
    function __cmuxCenter(el){const r=el.getBoundingClientRect();return {x:Math.floor(r.left+Math.min(r.width,r.width/2)),y:Math.floor(r.top+Math.min(r.height,r.height/2))};}
    function __cmuxPointer(el,type,c,buttons,bubbles){try{el.dispatchEvent(new PointerEvent(type,{bubbles:(bubbles===false?false:true),cancelable:true,composed:true,view:window,pointerId:1,pointerType:'mouse',isPrimary:true,button:0,buttons:buttons,clientX:c.x,clientY:c.y,screenX:c.x,screenY:c.y}));}catch(e){}}
    function __cmuxMouse(el,type,c,buttons,detail,bubbles){el.dispatchEvent(new MouseEvent(type,{bubbles:(bubbles===false?false:true),cancelable:true,composed:true,view:window,button:0,buttons:buttons,detail:detail||0,clientX:c.x,clientY:c.y,screenX:c.x,screenY:c.y}));}
    function __cmuxClick(el){const c=__cmuxCenter(el);
      __cmuxPointer(el,'pointerover',c,0);__cmuxMouse(el,'mouseover',c,0);
      __cmuxPointer(el,'pointerenter',c,0,false);__cmuxMouse(el,'mouseenter',c,0,0,false);
      __cmuxPointer(el,'pointermove',c,0);__cmuxMouse(el,'mousemove',c,0);
      __cmuxPointer(el,'pointerdown',c,1);__cmuxMouse(el,'mousedown',c,1,1);
      if(typeof el.focus==='function'){try{el.focus({preventScroll:true});}catch(e){try{el.focus();}catch(e2){}}}
      __cmuxPointer(el,'pointerup',c,0);__cmuxMouse(el,'mouseup',c,0,1);
      if(typeof el.click==='function'){el.click();}else{__cmuxMouse(el,'click',c,0,1);}
    }
    function __cmuxHover(el){const c=__cmuxCenter(el);
      __cmuxPointer(el,'pointerover',c,0);__cmuxMouse(el,'mouseover',c,0);
      __cmuxPointer(el,'pointerenter',c,0,false);__cmuxMouse(el,'mouseenter',c,0,0,false);
      __cmuxPointer(el,'pointermove',c,0);__cmuxMouse(el,'mousemove',c,0);
    }
    function __cmuxSetChecked(el,desired){
      // A click event runs the checkbox/radio activation behavior (it TOGGLES a checkbox / SELECTS a
      // radio) even when dispatched, and is also what React maps onChange to. So the correct way to
      // reach a target state is to click only when it differs; that fires input + change + (React)
      // onChange and leaves checked === desired. Setting el.checked directly does not update React's
      // controlled state and a separate click would toggle it back.
      if(el.checked===desired) return;
      // A radio cannot be turned OFF by clicking (clicking a radio only ever selects it). For that
      // one case set the property directly via the native setter and notify listeners.
      if(desired===false && el.type==='radio'){
        let ns=null;
        for(let p=Object.getPrototypeOf(el);p;p=Object.getPrototypeOf(p)){
          const d=Object.getOwnPropertyDescriptor(p,'checked'); if(d&&d.set){ns=d.set;break;}
        }
        if(ns){ns.call(el,false);}else{el.checked=false;}
        el.dispatchEvent(new Event('input',{bubbles:true}));
        el.dispatchEvent(new Event('change',{bubbles:true}));
        return;
      }
      if(typeof el.click==='function'){el.click();}
      else {const c=__cmuxCenter(el); __cmuxMouse(el,'click',c,0,1);}
    }
    function __cmuxKeyMeta(key){
      const map={Enter:[13,'Enter'],Tab:[9,'Tab'],Backspace:[8,'Backspace'],Delete:[46,'Delete'],Escape:[27,'Escape'],' ':[32,'Space'],ArrowUp:[38,'ArrowUp'],ArrowDown:[40,'ArrowDown'],ArrowLeft:[37,'ArrowLeft'],ArrowRight:[39,'ArrowRight'],Home:[36,'Home'],End:[35,'End'],PageUp:[33,'PageUp'],PageDown:[34,'PageDown']};
      if(map[key])return {keyCode:map[key][0],code:map[key][1]};
      if(key&&key.length===1){const u=key.toUpperCase();
        if(/[A-Z]/.test(u))return {keyCode:u.charCodeAt(0),code:'Key'+u};
        if(/[0-9]/.test(u))return {keyCode:u.charCodeAt(0),code:'Digit'+u};
        return {keyCode:key.charCodeAt(0),code:''};}
      return {keyCode:0,code:key||''};
    }
    function __cmuxKey(target,type,key){
      const meta=__cmuxKeyMeta(key);
      const ev=new KeyboardEvent(type,{key:key,code:meta.code,location:0,repeat:false,isComposing:false,bubbles:true,cancelable:true,composed:true,view:window});
      try{Object.defineProperty(ev,'keyCode',{get(){return meta.keyCode;}});}catch(e){}
      try{Object.defineProperty(ev,'which',{get(){return meta.keyCode;}});}catch(e){}
      return target.dispatchEvent(ev);
    }
    """

    private nonisolated func v2BrowserType(params: [String: Any]) -> V2CallResult {
        guard let text = v2String(params, "text") else {
            return .err(code: "invalid_params", message: "Missing text", data: nil)
        }
        return v2BrowserSelectorAction(params: params, actionName: "type") { selectorLiteral in
            let textLiteral = v2JSONLiteral(text)
            return """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              if (typeof el.focus === 'function') el.focus();
              const chunk = String(\(textLiteral));
              if ('value' in el) {
                const newValue = (el.value || '') + chunk;
                // beforeinput is cancelable; honor a page that rejects the edit (input masks,
                // controlled editors) instead of forcing the value and drifting from app state.
                let proceed = true;
                try { proceed = el.dispatchEvent(new InputEvent('beforeinput', { bubbles: true, cancelable: true, inputType: 'insertText', data: chunk })); } catch (e) {}
                if (!proceed) return { ok: false, error: 'input_rejected' };
                \(Self.reactCompatibleSetValue)
                try { el.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: chunk })); }
                catch (e) { el.dispatchEvent(new Event('input', { bubbles: true })); }
                el.dispatchEvent(new Event('change', { bubbles: true }));
              } else {
                // contenteditable / non-value elements get the same cancelable beforeinput so a rich
                // editor (ProseMirror, Slate, etc.) that manages its own model can reject the edit
                // instead of us silently overwriting textContent and drifting from app state.
                let proceed = true;
                try { proceed = el.dispatchEvent(new InputEvent('beforeinput', { bubbles: true, cancelable: true, inputType: 'insertText', data: chunk })); } catch (e) {}
                if (!proceed) return { ok: false, error: 'input_rejected' };
                el.textContent = (el.textContent || '') + chunk;
                try { el.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: chunk })); } catch (e) {}
              }
              return { ok: true };
            })()
            """
        }
    }

    private nonisolated func v2BrowserFill(params: [String: Any]) -> V2CallResult {
        // `fill` must allow empty strings so callers can clear existing input values.
        guard let text = v2RawString(params, "text") ?? v2RawString(params, "value") else {
            return .err(code: "invalid_params", message: "Missing text/value", data: nil)
        }
        return v2BrowserSelectorAction(params: params, actionName: "fill") { selectorLiteral in
            let textLiteral = v2JSONLiteral(text)
            return """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              if (typeof el.focus === 'function') el.focus();
              const newValue = String(\(textLiteral));
              if ('value' in el) {
                // beforeinput is cancelable; honor a page that rejects the edit instead of forcing
                // the value and drifting from app state.
                let proceed = true;
                try { proceed = el.dispatchEvent(new InputEvent('beforeinput', { bubbles: true, cancelable: true, inputType: 'insertReplacementText', data: newValue })); } catch (e) {}
                if (!proceed) return { ok: false, error: 'input_rejected' };
                \(Self.reactCompatibleSetValue)
                try { el.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertReplacementText', data: newValue })); }
                catch (e) { el.dispatchEvent(new Event('input', { bubbles: true })); }
                el.dispatchEvent(new Event('change', { bubbles: true }));
              } else {
                // contenteditable / non-value elements get the same cancelable beforeinput so a rich
                // editor that manages its own model can reject the edit instead of us silently
                // overwriting textContent.
                let proceed = true;
                try { proceed = el.dispatchEvent(new InputEvent('beforeinput', { bubbles: true, cancelable: true, inputType: 'insertReplacementText', data: newValue })); } catch (e) {}
                if (!proceed) return { ok: false, error: 'input_rejected' };
                el.textContent = newValue;
                try { el.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertReplacementText', data: newValue })); } catch (e) {}
              }
              return { ok: true };
            })()
            """
        }
    }

    private nonisolated func v2BrowserPress(params: [String: Any]) -> V2CallResult {
        guard let key = v2String(params, "key") else {
            return .err(code: "invalid_params", message: "Missing key", data: nil)
        }

        return v2BrowserWithPanelContext(params: params) { ctx in
            let surfaceId = ctx.surfaceId
            let keyLiteral = v2JSONLiteral(key)
            let script = """
            (() => {
              \(Self.browserInputHelpers)
              const target = document.activeElement || document.body || document.documentElement;
              if (!target) return { ok: false, error: 'not_found' };
              const k = String(\(keyLiteral));
              const kdNotPrevented = __cmuxKey(target, 'keydown', k);
              // keypress historically fires for character-producing keys, which includes Enter and
              // Space; many pages still bind submit/search to keypress for Enter.
              let kpNotPrevented = true;
              if (k.length === 1 || k === 'Enter') { kpNotPrevented = __cmuxKey(target, 'keypress', k); }
              __cmuxKey(target, 'keyup', k);
              // Synthetic key events do not run WebKit's native "Enter submits the form" default
              // action. Mirror real-user behavior, but only when neither keydown nor keypress was
              // canceled (pages cancel Enter to run their own handling) and the native HTML implicit
              // submission rules would apply: focus is a single-line text-like field AND the form has
              // a submit control or exactly one such field.
              if (k === 'Enter' && kdNotPrevented && kpNotPrevented && target && target.tagName === 'INPUT' && target.form) {
                const submitTypes = ['text','search','email','url','tel','password','number','date','datetime-local','month','week','time'];
                if (submitTypes.indexOf((target.type || 'text').toLowerCase()) !== -1) {
                  const hasSubmit = !!target.form.querySelector('input[type=submit],input[type=image],button[type=submit],button:not([type])');
                  const textFields = target.form.querySelectorAll('input[type=text],input[type=search],input[type=email],input[type=url],input[type=tel],input[type=password],input[type=number],input[type=date],input[type=datetime-local],input[type=month],input[type=week],input[type=time],input:not([type])');
                  if (hasSubmit || textFields.length === 1) {
                    try { if (target.form.requestSubmit) { target.form.requestSubmit(); } else { target.form.submit(); } } catch (e) {}
                  }
                }
              }
              return { ok: true };
            })()
            """
            switch v2RunBrowserJavaScript(ctx.webView, surfaceId: surfaceId, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success:
                var payload: [String: Any] = [
                    "workspace_id": ctx.workspaceId.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ctx.workspaceId),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId)
                ]
                v2BrowserAppendPostSnapshot(params: params, surfaceId: surfaceId, payload: &payload)
                return .ok(payload)
            }
        }
    }

    private nonisolated func v2BrowserKeyDown(params: [String: Any]) -> V2CallResult {
        guard let key = v2String(params, "key") else {
            return .err(code: "invalid_params", message: "Missing key", data: nil)
        }
        return v2BrowserWithPanelContext(params: params) { ctx in
            let surfaceId = ctx.surfaceId
            let keyLiteral = v2JSONLiteral(key)
            let script = """
            (() => {
              \(Self.browserInputHelpers)
              const target = document.activeElement || document.body || document.documentElement;
              if (!target) return { ok: false, error: 'not_found' };
              const k = String(\(keyLiteral));
              __cmuxKey(target, 'keydown', k);
              return { ok: true };
            })()
            """
            switch v2RunBrowserJavaScript(ctx.webView, surfaceId: surfaceId, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success:
                var payload: [String: Any] = [
                    "workspace_id": ctx.workspaceId.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ctx.workspaceId),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId)
                ]
                v2BrowserAppendPostSnapshot(params: params, surfaceId: surfaceId, payload: &payload)
                return .ok(payload)
            }
        }
    }

    private nonisolated func v2BrowserKeyUp(params: [String: Any]) -> V2CallResult {
        guard let key = v2String(params, "key") else {
            return .err(code: "invalid_params", message: "Missing key", data: nil)
        }
        return v2BrowserWithPanelContext(params: params) { ctx in
            let surfaceId = ctx.surfaceId
            let keyLiteral = v2JSONLiteral(key)
            let script = """
            (() => {
              \(Self.browserInputHelpers)
              const target = document.activeElement || document.body || document.documentElement;
              if (!target) return { ok: false, error: 'not_found' };
              const k = String(\(keyLiteral));
              __cmuxKey(target, 'keyup', k);
              return { ok: true };
            })()
            """
            switch v2RunBrowserJavaScript(ctx.webView, surfaceId: surfaceId, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success:
                var payload: [String: Any] = [
                    "workspace_id": ctx.workspaceId.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ctx.workspaceId),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId)
                ]
                v2BrowserAppendPostSnapshot(params: params, surfaceId: surfaceId, payload: &payload)
                return .ok(payload)
            }
        }
    }

    private nonisolated func v2BrowserCheck(params: [String: Any], checked: Bool) -> V2CallResult {
        v2BrowserSelectorAction(params: params, actionName: checked ? "check" : "uncheck") { selectorLiteral in
            """
            (() => {
              \(Self.browserInputHelpers)
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              if (!('checked' in el)) return { ok: false, error: 'not_checkable' };
              if (el.disabled) return { ok: false, error: 'disabled' };
              el.scrollIntoView({ block: 'nearest', inline: 'nearest' });
              if (typeof el.focus === 'function') { try { el.focus({ preventScroll: true }); } catch (e) {} }
              __cmuxSetChecked(el, \(checked ? "true" : "false"));
              if (el.checked !== \(checked ? "true" : "false")) return { ok: false, error: 'not_changed' };
              return { ok: true };
            })()
            """
        }
    }

    private nonisolated func v2BrowserSelect(params: [String: Any]) -> V2CallResult {
        let selectedValue = v2String(params, "value") ?? v2String(params, "text")
        guard let selectedValue else {
            return .err(code: "invalid_params", message: "Missing value", data: nil)
        }
        return v2BrowserSelectorAction(params: params, actionName: "select") { selectorLiteral in
            let valueLiteral = v2JSONLiteral(selectedValue)
            return """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              if (!('value' in el)) return { ok: false, error: 'not_select' };
              const newValue = String(\(valueLiteral));
              \(Self.reactCompatibleSetValue)
              el.dispatchEvent(new Event('input', { bubbles: true }));
              el.dispatchEvent(new Event('change', { bubbles: true }));
              return { ok: true };
            })()
            """
        }
    }

    private nonisolated func v2BrowserScroll(params: [String: Any]) -> V2CallResult {
        let dx = v2Int(params, "dx") ?? 0
        let dy = v2Int(params, "dy") ?? 0
        let selectorRaw = v2BrowserSelector(params)

        return v2BrowserWithPanelContext(params: params) { ctx in
            let surfaceId = ctx.surfaceId
            let selector = selectorRaw.flatMap { v2BrowserResolveSelector($0, surfaceId: surfaceId) }
            if selectorRaw != nil && selector == nil {
                return .err(code: "not_found", message: "Element reference not found", data: ["selector": selectorRaw ?? ""])
            }

            let script: String
            if let selector {
                let selectorLiteral = v2JSONLiteral(selector)
                script = """
                (() => {
                  const el = document.querySelector(\(selectorLiteral));
                  if (!el) return { ok: false, error: 'not_found' };
                  if (typeof el.scrollBy === 'function') {
                    el.scrollBy({ left: \(dx), top: \(dy), behavior: 'instant' });
                  } else {
                    el.scrollLeft += \(dx);
                    el.scrollTop += \(dy);
                  }
                  return { ok: true };
                })()
                """
            } else {
                script = "window.scrollBy({ left: \(dx), top: \(dy), behavior: 'instant' }); ({ ok: true })"
            }

            switch v2RunBrowserJavaScript(ctx.webView, surfaceId: surfaceId, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                if let dict = value as? [String: Any],
                   let ok = dict["ok"] as? Bool,
                   !ok,
                   let errorText = dict["error"] as? String,
                   errorText == "not_found" {
                    if let selector {
                        return v2BrowserElementNotFoundResult(
                            actionName: "scroll",
                            selector: selector,
                            attempts: 1,
                            surfaceId: surfaceId,
                            browserPanel: ctx.browserPanel
                        )
                    }
                    return .err(code: "not_found", message: "Element not found", data: ["selector": selector ?? ""])
                }
                var payload: [String: Any] = [
                    "workspace_id": ctx.workspaceId.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ctx.workspaceId),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId)
                ]
                v2BrowserAppendPostSnapshot(params: params, surfaceId: surfaceId, payload: &payload)
                return .ok(payload)
            }
        }
    }

    private nonisolated func v2BrowserScrollIntoView(params: [String: Any]) -> V2CallResult {
        v2BrowserSelectorAction(params: params, actionName: "scroll_into_view") { selectorLiteral in
            """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
              return { ok: true };
            })()
            """
        }
    }

    private nonisolated func v2BrowserScreenshot(params: [String: Any]) -> V2CallResult {
        let resolved: (
            error: V2CallResult?,
            workspaceId: UUID?,
            surfaceId: UUID?,
            browserPanel: BrowserPanel?
        ) = v2MainSync {
            guard let tabManager = v2ResolveTabManager(params: params) else {
                return (.err(code: "unavailable", message: "TabManager not available", data: nil), nil, nil, nil)
            }
            let resolvedContext = v2ResolveBrowserPanelContext(params: params, tabManager: tabManager)
            if let error = resolvedContext.error {
                return (error, nil, nil, nil)
            }
            guard let context = resolvedContext.context else {
                return (.err(code: "internal_error", message: "Browser operation failed", data: nil), nil, nil, nil)
            }
            return (nil, context.workspaceId, context.surfaceId, context.browserPanel)
        }

        if let error = resolved.error {
            return error
        }
        guard let workspaceId = resolved.workspaceId,
              let surfaceId = resolved.surfaceId,
              let browserPanel = resolved.browserPanel else {
            return .err(code: "internal_error", message: "Browser operation failed", data: nil)
        }

        let snapshotResult: Data?? = v2AwaitCallback(timeout: 15.0) { finish in
            v2MainSync {
                browserPanel.captureAutomationVisibleViewportSnapshot { result in
                    switch result {
                    case .success(let image):
                        finish(self.v2PNGData(from: image))
                    case .failure:
                        finish(nil)
                    }
                }
            }
        }

        guard let snapshotResult else {
            return .err(code: "timeout", message: "Timed out waiting for snapshot", data: nil)
        }
        guard let imageData = snapshotResult else {
            return .err(code: "internal_error", message: "Failed to capture snapshot", data: nil)
        }

        var result: [String: Any] = [
            "workspace_id": workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
            "surface_id": surfaceId.uuidString,
            "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
            "png_base64": imageData.base64EncodedString()
        ]

        // Best effort: keep screenshot data available even when temp-file writes fail.
        let screenshotsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-browser-screenshots", isDirectory: true)
        if (try? FileManager.default.createDirectory(at: screenshotsDirectory, withIntermediateDirectories: true)) != nil {
            bestEffortPruneTemporaryFiles(in: screenshotsDirectory)
            let timestampMs = Int(Date().timeIntervalSince1970 * 1000)
            let shortSurfaceId = String(surfaceId.uuidString.prefix(8))
            let shortRandomId = String(UUID().uuidString.prefix(8))
            let filename = "surface-\(shortSurfaceId)-\(timestampMs)-\(shortRandomId).png"
            let imageURL = screenshotsDirectory.appendingPathComponent(filename, isDirectory: false)
            if (try? imageData.write(to: imageURL, options: .atomic)) != nil {
                result["path"] = imageURL.path
                result["url"] = imageURL.absoluteString
            }
        }

        return .ok(result)
    }

    private nonisolated func v2BrowserGetText(params: [String: Any]) -> V2CallResult {
        v2BrowserSelectorAction(params: params, actionName: "get.text") { selectorLiteral in
            """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              return { ok: true, value: String(el.innerText || el.textContent || '') };
            })()
            """
        }
    }

    private nonisolated func v2BrowserGetHTML(params: [String: Any]) -> V2CallResult {
        v2BrowserSelectorAction(params: params, actionName: "get.html") { selectorLiteral in
            """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              return { ok: true, value: String(el.outerHTML || '') };
            })()
            """
        }
    }

    private nonisolated func v2BrowserGetValue(params: [String: Any]) -> V2CallResult {
        v2BrowserSelectorAction(params: params, actionName: "get.value") { selectorLiteral in
            """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              const value = ('value' in el) ? el.value : (el.textContent || '');
              return { ok: true, value: String(value || '') };
            })()
            """
        }
    }

    private nonisolated func v2BrowserGetAttr(params: [String: Any]) -> V2CallResult {
        guard let attr = v2String(params, "attr") ?? v2String(params, "name") else {
            return .err(code: "invalid_params", message: "Missing attr/name", data: nil)
        }
        return v2BrowserSelectorAction(params: params, actionName: "get.attr") { selectorLiteral in
            let attrLiteral = v2JSONLiteral(attr)
            return """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              return { ok: true, value: el.getAttribute(String(\(attrLiteral))) };
            })()
            """
        }
    }

    private func v2BrowserGetTitle(params: [String: Any]) -> V2CallResult {
        v2BrowserWithPanel(params: params) { workspaceId, surfaceId, browserPanel in
            .ok([
                "workspace_id": workspaceId.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "title": browserPanel.pageTitle
            ])
        }
    }

    private nonisolated func v2BrowserGetCount(params: [String: Any]) -> V2CallResult {
        guard let selectorRaw = v2BrowserSelector(params) else {
            return .err(code: "invalid_params", message: "Missing selector", data: nil)
        }
        return v2BrowserWithPanelContext(params: params) { ctx in
            let surfaceId = ctx.surfaceId
            guard let selector = v2BrowserResolveSelector(selectorRaw, surfaceId: surfaceId) else {
                return .err(code: "not_found", message: "Element reference not found", data: ["selector": selectorRaw])
            }
            let selectorLiteral = v2JSONLiteral(selector)
            let script = "document.querySelectorAll(\(selectorLiteral)).length"
            switch v2RunBrowserJavaScript(ctx.webView, surfaceId: surfaceId, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                let count = (value as? NSNumber)?.intValue ?? 0
                return .ok([
                    "workspace_id": ctx.workspaceId.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ctx.workspaceId),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "count": count
                ])
            }
        }
    }

    private nonisolated func v2BrowserGetBox(params: [String: Any]) -> V2CallResult {
        v2BrowserSelectorAction(params: params, actionName: "get.box") { selectorLiteral in
            """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              const r = el.getBoundingClientRect();
              return { ok: true, value: { x: r.x, y: r.y, width: r.width, height: r.height, top: r.top, left: r.left, right: r.right, bottom: r.bottom } };
            })()
            """
        }
    }

    private nonisolated func v2BrowserGetStyles(params: [String: Any]) -> V2CallResult {
        let property = v2String(params, "property")
        return v2BrowserSelectorAction(params: params, actionName: "get.styles") { selectorLiteral in
            if let property {
                let propLiteral = v2JSONLiteral(property)
                return """
                (() => {
                  const el = document.querySelector(\(selectorLiteral));
                  if (!el) return { ok: false, error: 'not_found' };
                  const style = getComputedStyle(el);
                  return { ok: true, value: style.getPropertyValue(String(\(propLiteral))) };
                })()
                """
            }
            return """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              const style = getComputedStyle(el);
              return { ok: true, value: {
                display: style.display,
                visibility: style.visibility,
                opacity: style.opacity,
                color: style.color,
                background: style.background,
                width: style.width,
                height: style.height
              } };
            })()
            """
        }
    }

    private nonisolated func v2BrowserIsVisible(params: [String: Any]) -> V2CallResult {
        v2BrowserSelectorAction(params: params, actionName: "is.visible") { selectorLiteral in
            """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              const style = getComputedStyle(el);
              const rect = el.getBoundingClientRect();
              const visible = style.display !== 'none' && style.visibility !== 'hidden' && parseFloat(style.opacity || '1') > 0 && rect.width > 0 && rect.height > 0;
              return { ok: true, value: visible };
            })()
            """
        }
    }

    private nonisolated func v2BrowserIsEnabled(params: [String: Any]) -> V2CallResult {
        v2BrowserSelectorAction(params: params, actionName: "is.enabled") { selectorLiteral in
            """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              const enabled = !el.disabled;
              return { ok: true, value: !!enabled };
            })()
            """
        }
    }

    private nonisolated func v2BrowserIsChecked(params: [String: Any]) -> V2CallResult {
        v2BrowserSelectorAction(params: params, actionName: "is.checked") { selectorLiteral in
            """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              const checked = ('checked' in el) ? !!el.checked : false;
              return { ok: true, value: checked };
            })()
            """
        }
    }


    private nonisolated func v2BrowserNavSimple(params: [String: Any], action: String) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let surfaceId = v2UUID(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid surface_id", data: nil)
        }

        var setupError: V2CallResult?
        var basePayload: [String: Any]?
        v2MainSync {
            let resolvedContext = v2ResolveBrowserPanelContext(params: params, tabManager: tabManager)
            if let error = resolvedContext.error {
                setupError = error
                return
            }
            guard let context = resolvedContext.context,
                  context.surfaceId == surfaceId else { return }
            switch action {
            case "back":
                context.browserPanel.goBack()
            case "forward":
                context.browserPanel.goForward()
            case "reload":
                context.browserPanel.reload()
            default:
                break
            }
            let windowId = v2ResolveWindowId(tabManager: tabManager)
            basePayload = [
                "workspace_id": context.workspaceId.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: context.workspaceId),
                "surface_id": context.surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: context.surfaceId),
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId)
            ]
        }
        if let setupError {
            return setupError
        }
        guard var payload = basePayload else {
            return .err(code: "not_found", message: "Surface not found or not a browser", data: ["surface_id": surfaceId.uuidString])
        }
        // Run --snapshot-after off the main thread (see v2BrowserNavigate): the
        // accessibility-tree walk must not block SwiftUI on a fresh surface.
        v2BrowserAppendPostSnapshot(params: params, surfaceId: surfaceId, payload: &payload)
        return .ok(payload)
    }

    /// Resolves the browser panel a CLI browser action should target, mirroring the
    /// GUI "act on the focused browser" semantics: an explicit `surface_id` browser wins,
    /// otherwise the workspace's focused browser, otherwise the sole browser in the workspace.
    @MainActor
    private func v2ResolveBrowserPanelForFocusedAction(
        workspace: Workspace,
        params: [String: Any]
    ) -> (panel: BrowserPanel, surfaceId: UUID)? {
        // An explicit surface is authoritative: if surface_id is SUPPLIED (even as a stale,
        // unresolvable, or empty handle) it must resolve to a browser in this workspace, else nil.
        // Only a genuinely ABSENT surface_id falls back to the focused/sole browser. Use
        // v2HasNonNullParam for presence so an empty string is not mistaken for absent.
        if v2HasNonNullParam(params, "surface_id") {
            guard let sid = v2UUID(params, "surface_id"),
                  let panel = workspace.browserPanel(for: sid) else { return nil }
            return (panel, sid)
        }
        if let focusedId = workspace.focusedPanelId, let panel = workspace.browserPanel(for: focusedId) {
            return (panel, focusedId)
        }
        let browsers: [(UUID, BrowserPanel)] = workspace.panels.values.compactMap { panel in
            (panel as? BrowserPanel).map { (panel.id, $0) }
        }
        if browsers.count == 1 { return (browsers[0].1, browsers[0].0) }
        return nil
    }

    /// Builds the standard workspace/surface/window identity payload for a browser action.
    @MainActor
    private func v2BrowserActionPayload(
        workspaceId: UUID,
        surfaceId: UUID,
        tabManager: TabManager,
        extra: [String: Any] = [:]
    ) -> [String: Any] {
        let windowId = v2ResolveWindowId(tabManager: tabManager)
        var payload: [String: Any] = [
            "workspace_id": workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
            "surface_id": surfaceId.uuidString,
            "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
            "window_id": v2OrNull(windowId?.uuidString),
            "window_ref": v2Ref(kind: .window, uuid: windowId)
        ]
        for (key, value) in extra { payload[key] = value }
        return payload
    }

    @MainActor
    private func v2BrowserActionPayload(
        workspace: Workspace,
        surfaceId: UUID,
        tabManager: TabManager,
        extra: [String: Any] = [:]
    ) -> [String: Any] {
        v2BrowserActionPayload(
            workspaceId: workspace.id,
            surfaceId: surfaceId,
            tabManager: tabManager,
            extra: extra
        )
    }

    /// Returns an error if any of the given handle params is SUPPLIED but does not resolve.
    /// v2UUID returns nil for both an absent param and a present-but-unresolvable handle (e.g. a
    /// stale `surface:2`/`workspace:99` ref), so a supplied target must not be treated as omitted
    /// and silently fall back to the focused/selected context. Returns nil when all are valid.
    private func v2RejectUnresolvedHandles(_ params: [String: Any], _ keys: [String]) -> V2CallResult? {
        // Use v2HasNonNullParam (not v2String) for presence: v2String trims empties to nil, so an
        // empty/whitespace explicit handle would otherwise look absent and silently fall back.
        for key in keys where v2HasNonNullParam(params, key) && v2UUID(params, key) == nil {
            return .err(code: "invalid_params", message: "Unresolved \(key)", data: nil)
        }
        return nil
    }

    private func v2BrowserReactGrabToggle(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        if let err = v2RejectUnresolvedHandles(params, ["surface_id", "return_to", "workspace_id", "window_id"]) {
            return err
        }
        var result: V2CallResult = .err(code: "not_found", message: "No browser surface to toggle React Grab on", data: nil)
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else { return }
            let browserSurfaceId = v2UUID(params, "surface_id")
            let returnSurfaceId = v2UUID(params, "return_to")
            guard let actedBrowserId = tabManager.toggleReactGrab(
                in: ws,
                browserSurfaceId: browserSurfaceId,
                returnTerminalSurfaceId: returnSurfaceId
            ) else { return }
            result = .ok(v2BrowserActionPayload(
                workspace: ws,
                surfaceId: actedBrowserId,
                tabManager: tabManager,
                extra: ["toggled": true]
            ))
        }
        return result
    }

    private func v2BrowserDevToolsToggle(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        if let err = v2RejectUnresolvedHandles(params, ["surface_id", "workspace_id", "window_id"]) { return err }
        var result: V2CallResult = .err(code: "not_found", message: "No browser surface found", data: nil)
        v2MainSync {
            let dockResolution = v2ResolveGlobalDockBrowserPanelContext(params: params)
            if dockResolution.handled {
                if let error = dockResolution.error {
                    result = error
                    return
                }
                guard let context = dockResolution.context else { return }
                let handled = context.browserPanel.toggleDeveloperTools()
                result = .ok(v2BrowserActionPayload(
                    workspaceId: context.workspaceId,
                    surfaceId: context.surfaceId,
                    tabManager: tabManager,
                    extra: ["handled": handled]
                ))
                return
            }
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager),
                  let target = v2ResolveBrowserPanelForFocusedAction(workspace: ws, params: params) else { return }
            let handled = target.panel.toggleDeveloperTools()
            result = .ok(v2BrowserActionPayload(
                workspace: ws, surfaceId: target.surfaceId, tabManager: tabManager,
                extra: ["handled": handled]
            ))
        }
        return result
    }

    private func v2BrowserConsoleShow(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        if let err = v2RejectUnresolvedHandles(params, ["surface_id", "workspace_id", "window_id"]) { return err }
        var result: V2CallResult = .err(code: "not_found", message: "No browser surface found", data: nil)
        v2MainSync {
            let dockResolution = v2ResolveGlobalDockBrowserPanelContext(params: params)
            if dockResolution.handled {
                if let error = dockResolution.error {
                    result = error
                    return
                }
                guard let context = dockResolution.context else { return }
                let handled = context.browserPanel.showDeveloperToolsConsole()
                result = .ok(v2BrowserActionPayload(
                    workspaceId: context.workspaceId,
                    surfaceId: context.surfaceId,
                    tabManager: tabManager,
                    extra: ["handled": handled]
                ))
                return
            }
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager),
                  let target = v2ResolveBrowserPanelForFocusedAction(workspace: ws, params: params) else { return }
            let handled = target.panel.showDeveloperToolsConsole()
            result = .ok(v2BrowserActionPayload(
                workspace: ws, surfaceId: target.surfaceId, tabManager: tabManager,
                extra: ["handled": handled]
            ))
        }
        return result
    }

    private func v2BrowserFocusModeSet(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        if let err = v2RejectUnresolvedHandles(params, ["surface_id", "workspace_id", "window_id"]) { return err }
        let mode = (v2String(params, "mode") ?? "toggle").lowercased()
        let enterAliases: Set<String> = ["enter", "on", "true", "active"]
        let exitAliases: Set<String> = ["exit", "off", "false", "inactive"]
        guard mode == "toggle" || enterAliases.contains(mode) || exitAliases.contains(mode) else {
            return .err(code: "invalid_params", message: "mode must be one of: enter, exit, toggle, on, off", data: nil)
        }
        var result: V2CallResult = .err(code: "not_found", message: "No browser surface found", data: nil)
        v2MainSync {
            let dockResolution = v2ResolveGlobalDockBrowserPanelContext(params: params)
            if dockResolution.handled {
                if let error = dockResolution.error {
                    result = error
                    return
                }
                guard let context = dockResolution.context else { return }
                let willActivate = enterAliases.contains(mode)
                    || (mode == "toggle" && !context.browserPanel.isBrowserFocusModeActive)
                if willActivate,
                   context.browserPanel.searchState == nil,
                   let globalDock = globalDockContainingPanel(context.surfaceId),
                   globalDock.focusedPanelId != context.surfaceId {
                    globalDock.focusPanel(context.surfaceId)
                }
                let handled: Bool
                if enterAliases.contains(mode) {
                    handled = context.browserPanel.setBrowserFocusModeActive(true, reason: "cli.focusMode", focusWebView: true)
                } else if exitAliases.contains(mode) {
                    handled = context.browserPanel.setBrowserFocusModeActive(false, reason: "cli.focusMode", focusWebView: false)
                } else {
                    handled = context.browserPanel.toggleBrowserFocusMode(reason: "cli.focusMode", focusWebView: true)
                }
                result = .ok(v2BrowserActionPayload(
                    workspaceId: context.workspaceId,
                    surfaceId: context.surfaceId,
                    tabManager: tabManager,
                    extra: ["handled": handled, "mode": mode]
                ))
                return
            }
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager),
                  let target = v2ResolveBrowserPanelForFocusedAction(workspace: ws, params: params) else { return }
            // Entering browser focus mode requires the target browser to be the focused, on-screen
            // panel (the GUI shortcut already runs from inside it). When the CLI targets a browser
            // that is not focused, focus it first so "enter" actually engages instead of no-opping.
            // Focusing the panel makes the render/visibility/modal-host preconditions of
            // canEnterBrowserFocusMode true, so those are not a reason to withhold focus. An open
            // find bar (searchState) is the one precondition focusing does NOT satisfy: entry will
            // fail, so don't steal foreground focus or collapse a split-zoom for an action that
            // cannot engage.
            let willActivate = enterAliases.contains(mode)
                || (mode == "toggle" && !target.panel.isBrowserFocusModeActive)
            if willActivate, target.panel.searchState == nil, ws.focusedPanelId != target.surfaceId {
                ws.clearSplitZoom()
                ws.focusPanel(target.surfaceId)
            }
            let handled: Bool
            if enterAliases.contains(mode) {
                handled = target.panel.setBrowserFocusModeActive(true, reason: "cli.focusMode", focusWebView: true)
            } else if exitAliases.contains(mode) {
                handled = target.panel.setBrowserFocusModeActive(false, reason: "cli.focusMode", focusWebView: false)
            } else {
                handled = target.panel.toggleBrowserFocusMode(reason: "cli.focusMode", focusWebView: true)
            }
            result = .ok(v2BrowserActionPayload(
                workspace: ws, surfaceId: target.surfaceId, tabManager: tabManager,
                extra: ["handled": handled, "mode": mode]
            ))
        }
        return result
    }

    private func v2BrowserZoomSet(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        if let err = v2RejectUnresolvedHandles(params, ["surface_id", "workspace_id", "window_id"]) { return err }
        let direction = (v2String(params, "direction") ?? "").lowercased()
        guard ["in", "out", "reset"].contains(direction) else {
            return .err(code: "invalid_params", message: "direction must be one of: in, out, reset", data: nil)
        }
        var result: V2CallResult = .err(code: "not_found", message: "No browser surface found", data: nil)
        v2MainSync {
            let dockResolution = v2ResolveGlobalDockBrowserPanelContext(params: params)
            if dockResolution.handled {
                if let error = dockResolution.error {
                    result = error
                    return
                }
                guard let context = dockResolution.context else { return }
                let handled: Bool
                switch direction {
                case "in": handled = context.browserPanel.zoomIn()
                case "out": handled = context.browserPanel.zoomOut()
                default: handled = context.browserPanel.resetZoom()
                }
                result = .ok(v2BrowserActionPayload(
                    workspaceId: context.workspaceId,
                    surfaceId: context.surfaceId,
                    tabManager: tabManager,
                    extra: ["handled": handled, "direction": direction]
                ))
                return
            }
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager),
                  let target = v2ResolveBrowserPanelForFocusedAction(workspace: ws, params: params) else { return }
            let handled: Bool
            switch direction {
            case "in": handled = target.panel.zoomIn()
            case "out": handled = target.panel.zoomOut()
            default: handled = target.panel.resetZoom()
            }
            result = .ok(v2BrowserActionPayload(
                workspace: ws, surfaceId: target.surfaceId, tabManager: tabManager,
                extra: ["handled": handled, "direction": direction]
            ))
        }
        return result
    }

    private func v2BrowserHistoryClear(params: [String: Any]) -> V2CallResult {
        // Mirrors the View menu's "Clear Browser History", which clears the default profile's
        // history store (BrowserHistoryStore.shared). Per-profile history stores are NOT touched,
        // so the response reports scope=default to avoid a false "everything cleared" signal.
        // Destructive: require explicit deletion intent so a mistyped command or background agent
        // cannot silently wipe history.
        guard v2Bool(params, "force") == true else {
            return .err(code: "invalid_params", message: "browser.history.clear requires force=true", data: nil)
        }
        v2MainSync {
            BrowserHistoryStore.shared.clearHistory()
        }
        return .ok(["cleared": true, "scope": "default_profile"])
    }

    private func v2BrowserGetURL(params: [String: Any]) -> V2CallResult {
        guard let surfaceId = v2UUID(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid surface_id", data: nil)
        }

        return v2BrowserWithPanel(params: params) { workspaceId, resolvedSurfaceId, browserPanel in
            guard resolvedSurfaceId == surfaceId else {
                return .err(code: "not_found", message: "Surface not found or not a browser", data: ["surface_id": surfaceId.uuidString])
            }
            // A never-navigated surface reports about:blank (matching JS location.href)
            // instead of an empty string, so agents can tell "blank page" from "no data".
            let urlString = browserPanel.currentURL?.absoluteString
                ?? browserPanel.webView.url?.absoluteString
                ?? "about:blank"
            return .ok([
                "workspace_id": workspaceId.uuidString,
                "surface_id": resolvedSurfaceId.uuidString,
                "url": urlString
            ])
        }
    }

    private func v2BrowserFocusWebView(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let surfaceId = v2UUID(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid surface_id", data: nil)
        }

        var result: V2CallResult = .err(code: "not_found", message: "Surface not found or not a browser", data: ["surface_id": surfaceId.uuidString])
        v2MainSync {
            let resolvedContext = v2ResolveBrowserPanelContext(params: params, tabManager: tabManager)
            if let error = resolvedContext.error {
                result = error
                return
            }
            guard let context = resolvedContext.context,
                  context.surfaceId == surfaceId else { return }
            let browserPanel = context.browserPanel

            if let windowId = v2ResolveWindowId(tabManager: tabManager) {
                _ = AppDelegate.shared?.focusMainWindow(windowId: windowId)
                setActiveTabManager(tabManager)
            }
            if let globalDock = globalDockContainingPanel(surfaceId) {
                revealDockForFocus(tabManager: tabManager)
                globalDock.focusPanel(surfaceId)
            } else if let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) {
                if tabManager.selectedTabId != ws.id {
                    tabManager.selectWorkspace(ws)
                }
                if ws.focusedPanelId != surfaceId {
                    ws.focusPanel(surfaceId)
                }
            }

            // Prevent omnibar auto-focus from immediately stealing first responder back.
            browserPanel.suppressOmnibarAutofocus(for: 1.0)

            let webView = browserPanel.webView
            guard let window = webView.window else {
                result = .err(code: "invalid_state", message: "WebView is not in a window", data: nil)
                return
            }
            guard !webView.isHiddenOrHasHiddenAncestor else {
                result = .err(code: "invalid_state", message: "WebView is hidden", data: nil)
                return
            }

            window.makeFirstResponder(webView)
            if let fr = window.firstResponder as? NSView, fr.isDescendant(of: webView) {
                result = .ok(["focused": true])
            } else {
                result = .err(code: "internal_error", message: "Focus did not move into web view", data: nil)
            }
        }
        return result
    }

    private func v2BrowserIsWebViewFocused(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let surfaceId = v2UUID(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid surface_id", data: nil)
        }

        var focused = false
        v2MainSync {
            let resolvedContext = v2ResolveBrowserPanelContext(params: params, tabManager: tabManager)
            guard let context = resolvedContext.context,
                  context.surfaceId == surfaceId else { return }
            let browserPanel = context.browserPanel
            let webView = browserPanel.webView
            guard let window = webView.window,
                  let fr = window.firstResponder as? NSView else {
                focused = false
                return
            }
            focused = fr.isDescendant(of: webView)
        }
        return .ok(["focused": focused])
    }

    private nonisolated func v2BrowserFindWithScript(
        params: [String: Any],
        actionName: String,
        finderBody: String,
        metadata: [String: Any] = [:]
    ) -> V2CallResult {
        return v2BrowserWithPanelContext(params: params) { ctx in
            let surfaceId = ctx.surfaceId
            let script = v2BrowserControl.findScript(finderBody: finderBody)

            switch v2RunBrowserJavaScript(ctx.webView, surfaceId: surfaceId, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: ["action": actionName])
            case .success(let value):
                guard let dict = value as? [String: Any],
                      let ok = dict["ok"] as? Bool,
                      ok,
                      let selector = dict["selector"] as? String,
                      !selector.isEmpty else {
                    return .err(code: "not_found", message: "Element not found", data: metadata)
                }

                let ref = v2BrowserAllocateElementRef(surfaceId: surfaceId, selector: selector)
                var payload: [String: Any] = [
                    "workspace_id": ctx.workspaceId.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ctx.workspaceId),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "action": actionName,
                    "selector": selector,
                    "element_ref": ref,
                    "ref": ref
                ]
                for (k, v) in metadata {
                    payload[k] = v
                }
                if let tag = dict["tag"] as? String {
                    payload["tag"] = tag
                }
                if let text = dict["text"] as? String {
                    payload["text"] = text
                }
                return .ok(payload)
            }
        }
    }

    private nonisolated func v2BrowserFindRole(params: [String: Any]) -> V2CallResult {
        guard let role = (v2String(params, "role") ?? v2String(params, "value"))?.lowercased() else {
            return .err(code: "invalid_params", message: "Missing role", data: nil)
        }
        let name = v2String(params, "name")?.lowercased()
        let exact = v2Bool(params, "exact") ?? false

        let finder = v2BrowserControl.findRoleFinderBody(role: role, name: name, exact: exact)

        return v2BrowserFindWithScript(
            params: params,
            actionName: "find.role",
            finderBody: finder,
            metadata: [
                "role": role,
                "name": v2OrNull(name),
                "exact": exact
            ]
        )
    }

    private nonisolated func v2BrowserFindText(params: [String: Any]) -> V2CallResult {
        guard let text = (v2String(params, "text") ?? v2String(params, "value"))?.lowercased() else {
            return .err(code: "invalid_params", message: "Missing text", data: nil)
        }
        let exact = v2Bool(params, "exact") ?? false

        let finder = v2BrowserControl.findTextFinderBody(text: text, exact: exact)

        return v2BrowserFindWithScript(
            params: params,
            actionName: "find.text",
            finderBody: finder,
            metadata: ["text": text, "exact": exact]
        )
    }

    private nonisolated func v2BrowserFindLabel(params: [String: Any]) -> V2CallResult {
        guard let label = (v2String(params, "label") ?? v2String(params, "text") ?? v2String(params, "value"))?.lowercased() else {
            return .err(code: "invalid_params", message: "Missing label", data: nil)
        }
        let exact = v2Bool(params, "exact") ?? false

        let finder = v2BrowserControl.findLabelFinderBody(label: label, exact: exact)

        return v2BrowserFindWithScript(
            params: params,
            actionName: "find.label",
            finderBody: finder,
            metadata: ["label": label, "exact": exact]
        )
    }

    private nonisolated func v2BrowserFindPlaceholder(params: [String: Any]) -> V2CallResult {
        guard let placeholder = (v2String(params, "placeholder") ?? v2String(params, "text") ?? v2String(params, "value"))?.lowercased() else {
            return .err(code: "invalid_params", message: "Missing placeholder", data: nil)
        }
        let exact = v2Bool(params, "exact") ?? false

        let finder = v2BrowserControl.findPlaceholderFinderBody(placeholder: placeholder, exact: exact)

        return v2BrowserFindWithScript(
            params: params,
            actionName: "find.placeholder",
            finderBody: finder,
            metadata: ["placeholder": placeholder, "exact": exact]
        )
    }

    private nonisolated func v2BrowserFindAlt(params: [String: Any]) -> V2CallResult {
        guard let alt = (v2String(params, "alt") ?? v2String(params, "text") ?? v2String(params, "value"))?.lowercased() else {
            return .err(code: "invalid_params", message: "Missing alt text", data: nil)
        }
        let exact = v2Bool(params, "exact") ?? false

        let finder = v2BrowserControl.findAltFinderBody(alt: alt, exact: exact)

        return v2BrowserFindWithScript(
            params: params,
            actionName: "find.alt",
            finderBody: finder,
            metadata: ["alt": alt, "exact": exact]
        )
    }

    private nonisolated func v2BrowserFindTitle(params: [String: Any]) -> V2CallResult {
        guard let title = (v2String(params, "title") ?? v2String(params, "text") ?? v2String(params, "value"))?.lowercased() else {
            return .err(code: "invalid_params", message: "Missing title", data: nil)
        }
        let exact = v2Bool(params, "exact") ?? false

        let finder = v2BrowserControl.findTitleFinderBody(title: title, exact: exact)

        return v2BrowserFindWithScript(
            params: params,
            actionName: "find.title",
            finderBody: finder,
            metadata: ["title": title, "exact": exact]
        )
    }

    private nonisolated func v2BrowserFindTestId(params: [String: Any]) -> V2CallResult {
        guard let testId = v2String(params, "testid") ?? v2String(params, "test_id") ?? v2String(params, "value") else {
            return .err(code: "invalid_params", message: "Missing testid", data: nil)
        }
        let finder = v2BrowserControl.findTestIdFinderBody(testId: testId)

        return v2BrowserFindWithScript(
            params: params,
            actionName: "find.testid",
            finderBody: finder,
            metadata: ["testid": testId]
        )
    }

    private nonisolated func v2BrowserFindFirst(params: [String: Any]) -> V2CallResult {
        guard let selectorRaw = v2BrowserSelector(params) else {
            return .err(code: "invalid_params", message: "Missing selector", data: nil)
        }
        return v2BrowserWithPanelContext(params: params) { ctx in
            let surfaceId = ctx.surfaceId
            guard let selector = v2BrowserResolveSelector(selectorRaw, surfaceId: surfaceId) else {
                return .err(code: "not_found", message: "Element reference not found", data: ["selector": selectorRaw])
            }
            let script = v2BrowserControl.findFirstScript(selector: selector)
            switch v2RunBrowserJavaScript(ctx.webView, surfaceId: surfaceId, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                guard let dict = value as? [String: Any],
                      let ok = dict["ok"] as? Bool,
                      ok else {
                    return .err(code: "not_found", message: "Element not found", data: ["selector": selector])
                }
                let ref = v2BrowserAllocateElementRef(surfaceId: surfaceId, selector: selector)
                return .ok([
                    "workspace_id": ctx.workspaceId.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ctx.workspaceId),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "selector": selector,
                    "element_ref": ref,
                    "ref": ref,
                    "text": v2OrNull(dict["text"])
                ])
            }
        }
    }

    private nonisolated func v2BrowserFindLast(params: [String: Any]) -> V2CallResult {
        guard let selectorRaw = v2BrowserSelector(params) else {
            return .err(code: "invalid_params", message: "Missing selector", data: nil)
        }
        return v2BrowserWithPanelContext(params: params) { ctx in
            let surfaceId = ctx.surfaceId
            guard let selector = v2BrowserResolveSelector(selectorRaw, surfaceId: surfaceId) else {
                return .err(code: "not_found", message: "Element reference not found", data: ["selector": selectorRaw])
            }
            let script = v2BrowserControl.findLastScript(selector: selector)
            switch v2RunBrowserJavaScript(ctx.webView, surfaceId: surfaceId, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                guard let dict = value as? [String: Any],
                      let ok = dict["ok"] as? Bool,
                      ok,
                      let finalSelector = dict["selector"] as? String,
                      !finalSelector.isEmpty else {
                    return .err(code: "not_found", message: "Element not found", data: ["selector": selector])
                }
                let ref = v2BrowserAllocateElementRef(surfaceId: surfaceId, selector: finalSelector)
                return .ok([
                    "workspace_id": ctx.workspaceId.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ctx.workspaceId),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "selector": finalSelector,
                    "element_ref": ref,
                    "ref": ref,
                    "text": v2OrNull(dict["text"])
                ])
            }
        }
    }

    private nonisolated func v2BrowserFindNth(params: [String: Any]) -> V2CallResult {
        guard let selectorRaw = v2BrowserSelector(params) else {
            return .err(code: "invalid_params", message: "Missing selector", data: nil)
        }
        guard let index = v2Int(params, "index") ?? v2Int(params, "nth") else {
            return .err(code: "invalid_params", message: "Missing index", data: nil)
        }

        return v2BrowserWithPanelContext(params: params) { ctx in
            let surfaceId = ctx.surfaceId
            guard let selector = v2BrowserResolveSelector(selectorRaw, surfaceId: surfaceId) else {
                return .err(code: "not_found", message: "Element reference not found", data: ["selector": selectorRaw])
            }
            let script = v2BrowserControl.findNthScript(selector: selector, index: index)
            switch v2RunBrowserJavaScript(ctx.webView, surfaceId: surfaceId, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                guard let dict = value as? [String: Any],
                      let ok = dict["ok"] as? Bool,
                      ok,
                      let finalSelector = dict["selector"] as? String,
                      !finalSelector.isEmpty else {
                    return .err(code: "not_found", message: "Element not found", data: ["selector": selector, "index": index])
                }
                let ref = v2BrowserAllocateElementRef(surfaceId: surfaceId, selector: finalSelector)
                return .ok([
                    "workspace_id": ctx.workspaceId.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ctx.workspaceId),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "selector": finalSelector,
                    "element_ref": ref,
                    "ref": ref,
                    "index": v2OrNull(dict["index"]),
                    "text": v2OrNull(dict["text"])
                ])
            }
        }
    }

    private nonisolated func v2BrowserFrameSelect(params: [String: Any]) -> V2CallResult {
        guard let selectorRaw = v2BrowserSelector(params) else {
            return .err(code: "invalid_params", message: "Missing selector", data: nil)
        }

        return v2BrowserWithPanelContext(params: params) { ctx in
            let surfaceId = ctx.surfaceId
            guard let selector = v2BrowserResolveSelector(selectorRaw, surfaceId: surfaceId) else {
                return .err(code: "not_found", message: "Element reference not found", data: ["selector": selectorRaw])
            }
            let selectorLiteral = v2JSONLiteral(selector)
            let script = """
            (() => {
              const frame = document.querySelector(\(selectorLiteral));
              if (!frame) return { ok: false, error: 'not_found' };
              if (!('contentDocument' in frame)) return { ok: false, error: 'not_frame' };
              try {
                const sameOrigin = !!frame.contentDocument;
                if (!sameOrigin) return { ok: false, error: 'cross_origin' };
              } catch (_) {
                return { ok: false, error: 'cross_origin' };
              }
              return { ok: true };
            })()
            """
            switch v2RunBrowserJavaScript(ctx.webView, surfaceId: surfaceId, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                if let dict = value as? [String: Any],
                   let ok = dict["ok"] as? Bool,
                   ok {
                    v2MainSync {
                        v2BrowserFrameSelectorBySurface[surfaceId] = selector
                    }
                    return .ok(v2BrowserPanelFields(ctx, adding: ["frame_selector": selector]))
                }
                if let dict = value as? [String: Any],
                   let errorText = dict["error"] as? String,
                   errorText == "cross_origin" {
                    return .err(code: "not_supported", message: "Cross-origin iframe control is not supported", data: ["selector": selector])
                }
                return .err(code: "not_found", message: "Frame not found", data: ["selector": selector])
            }
        }
    }

    private func v2BrowserFrameMain(params: [String: Any]) -> V2CallResult {
        return v2BrowserWithPanel(params: params) { workspaceId, surfaceId, _ in
            v2BrowserFrameSelectorBySurface.removeValue(forKey: surfaceId)
            return .ok([
                "workspace_id": workspaceId.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "frame_selector": NSNull()
            ])
        }
    }

    private nonisolated func v2BrowserEnsureTelemetryHooks(surfaceId _: UUID, webView: WKWebView) {
        let source = v2MainSync { BrowserPanel.telemetryHookBootstrapScriptSource }
        _ = v2RunJavaScript(
            webView,
            script: source,
            timeout: 5.0,
            world: .page
        )
    }

    private nonisolated func v2BrowserEnsureDialogHooks(webView: WKWebView) {
        let source = v2MainSync { BrowserPanel.dialogTelemetryHookBootstrapScriptSource }
        _ = v2RunJavaScript(
            webView,
            script: source,
            timeout: 5.0,
            world: .page
        )
    }

    private nonisolated func v2BrowserDialogRespond(params: [String: Any], accept: Bool) -> V2CallResult {
        return v2BrowserWithPanelContext(params: params) { ctx in
            v2BrowserEnsureTelemetryHooks(surfaceId: ctx.surfaceId, webView: ctx.webView)
            v2BrowserEnsureDialogHooks(webView: ctx.webView)
            let text = v2String(params, "text") ?? v2String(params, "prompt_text")
            let acceptLiteral = accept ? "true" : "false"
            let textLiteral = text.map(v2JSONLiteral) ?? "null"
            let script = """
            (() => {
              const q = window.__cmuxDialogQueue || [];
              if (!q.length) return { ok: false, error: 'not_found' };
              const entry = q.shift();
              if (entry.type === 'confirm') {
                window.__cmuxDialogDefaults = window.__cmuxDialogDefaults || { confirm: false, prompt: null };
                window.__cmuxDialogDefaults.confirm = \(acceptLiteral);
              }
              if (entry.type === 'prompt') {
                window.__cmuxDialogDefaults = window.__cmuxDialogDefaults || { confirm: false, prompt: null };
                if (\(acceptLiteral)) {
                  window.__cmuxDialogDefaults.prompt = \(textLiteral);
                } else {
                  window.__cmuxDialogDefaults.prompt = null;
                }
              }
              return { ok: true, dialog: entry, remaining: q.length };
            })()
            """

            switch v2RunJavaScript(ctx.webView, script: script, timeout: 5.0, world: .page) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                guard let dict = value as? [String: Any],
                      let ok = dict["ok"] as? Bool,
                      ok else {
                    let pending = v2BrowserPendingDialogs(surfaceId: ctx.surfaceId)
                    return .err(code: "not_found", message: "No pending dialog", data: ["pending": pending])
                }

                return .ok(v2BrowserPanelFields(ctx, adding: [
                    "accepted": accept,
                    "dialog": v2NormalizeJSValue(dict["dialog"]),
                    "remaining": v2OrNull(dict["remaining"])
                ]))
            }
        }
    }

    private struct V2BrowserDownloadWaitSnapshot {
        let workspaceId: UUID
        let workspaceRef: Any
        let surfaceId: UUID
        let surfaceRef: Any
        let queuedEvent: [String: Any]?
        let error: V2CallResult?
    }

    private enum V2DownloadFileWaitResult: Sendable {
        case ready
        case timeout
        case watcherSetupFailed(errnoCode: Int32)
    }

    /// Socket-worker router for browser automation methods that may wait on WebKit.
    /// See ControlCommandExecutionPolicy for why these must not hold the main actor.
    private nonisolated func v2BrowserAutomationCommandOnSocketWorker(method: String, params: [String: Any]) -> V2CallResult {
        switch method {
        case "browser.navigate": return v2BrowserNavigate(params: params)
        case "browser.back": return v2BrowserBack(params: params)
        case "browser.forward": return v2BrowserForward(params: params)
        case "browser.reload": return v2BrowserReload(params: params)
        case "browser.snapshot": return v2BrowserSnapshot(params: params)
        case "browser.eval": return v2BrowserEval(params: params)
        case "browser.wait": return v2BrowserWait(params: params)
        case "browser.screenshot": return v2BrowserScreenshot(params: params)
        case "browser.click": return v2BrowserClick(params: params)
        case "browser.dblclick": return v2BrowserDblClick(params: params)
        case "browser.hover": return v2BrowserHover(params: params)
        case "browser.focus": return v2BrowserFocusElement(params: params)
        case "browser.type": return v2BrowserType(params: params)
        case "browser.fill": return v2BrowserFill(params: params)
        case "browser.press": return v2BrowserPress(params: params)
        case "browser.keydown": return v2BrowserKeyDown(params: params)
        case "browser.keyup": return v2BrowserKeyUp(params: params)
        case "browser.check": return v2BrowserCheck(params: params, checked: true)
        case "browser.uncheck": return v2BrowserCheck(params: params, checked: false)
        case "browser.select": return v2BrowserSelect(params: params)
        case "browser.scroll": return v2BrowserScroll(params: params)
        case "browser.scroll_into_view": return v2BrowserScrollIntoView(params: params)
        case "browser.get.text": return v2BrowserGetText(params: params)
        case "browser.get.html": return v2BrowserGetHTML(params: params)
        case "browser.get.value": return v2BrowserGetValue(params: params)
        case "browser.get.attr": return v2BrowserGetAttr(params: params)
        case "browser.get.count": return v2BrowserGetCount(params: params)
        case "browser.get.box": return v2BrowserGetBox(params: params)
        case "browser.get.styles": return v2BrowserGetStyles(params: params)
        case "browser.is.visible": return v2BrowserIsVisible(params: params)
        case "browser.is.enabled": return v2BrowserIsEnabled(params: params)
        case "browser.is.checked": return v2BrowserIsChecked(params: params)
        case "browser.find.role": return v2BrowserFindRole(params: params)
        case "browser.find.text": return v2BrowserFindText(params: params)
        case "browser.find.label": return v2BrowserFindLabel(params: params)
        case "browser.find.placeholder": return v2BrowserFindPlaceholder(params: params)
        case "browser.find.alt": return v2BrowserFindAlt(params: params)
        case "browser.find.title": return v2BrowserFindTitle(params: params)
        case "browser.find.testid": return v2BrowserFindTestId(params: params)
        case "browser.find.first": return v2BrowserFindFirst(params: params)
        case "browser.find.last": return v2BrowserFindLast(params: params)
        case "browser.find.nth": return v2BrowserFindNth(params: params)
        case "browser.highlight": return v2BrowserHighlight(params: params)
        case "browser.frame.select": return v2BrowserFrameSelect(params: params)
        case "browser.dialog.accept": return v2BrowserDialogRespond(params: params, accept: true)
        case "browser.dialog.dismiss": return v2BrowserDialogRespond(params: params, accept: false)
        case "browser.cookies.get": return v2BrowserCookiesGet(params: params)
        case "browser.cookies.set": return v2BrowserCookiesSet(params: params)
        case "browser.cookies.clear": return v2BrowserCookiesClear(params: params)
        case "browser.storage.get": return v2BrowserStorageGet(params: params)
        case "browser.storage.set": return v2BrowserStorageSet(params: params)
        case "browser.storage.clear": return v2BrowserStorageClear(params: params)
        case "browser.console.list": return v2BrowserConsoleList(params: params)
        case "browser.console.clear": return v2BrowserConsoleClear(params: params)
        case "browser.errors.list": return v2BrowserErrorsList(params: params)
        case "browser.state.save": return v2BrowserStateSave(params: params)
        case "browser.state.load": return v2BrowserStateLoad(params: params)
        case "browser.addinitscript": return v2BrowserAddInitScript(params: params)
        case "browser.addscript": return v2BrowserAddScript(params: params)
        case "browser.addstyle": return v2BrowserAddStyle(params: params)
        default:
            return .err(code: "invalid_dispatch", message: "Unhandled socket-worker browser method \(method)", data: nil)
        }
    }

    private nonisolated func v2BrowserDownloadWaitOnSocketWorker(params: [String: Any]) -> V2CallResult {
        let requestedTimeoutMs = max(
            1,
            Self.v2WorkerInt(params, "timeout_ms") ??
                Self.v2WorkerInt(params, "timeout") ??
                Self.v2BrowserDownloadWaitDefaultTimeoutMs
        )
        let timeoutMs = min(requestedTimeoutMs, Self.v2BrowserDownloadWaitMaxTimeoutMs)
        let timeout = Double(timeoutMs) / 1000.0
        let path = Self.v2WorkerString(params, "path")

        let snapshot = v2BrowserDownloadWaitSnapshot(params: params)
        if let error = snapshot.error {
            return error
        }

        if let path {
            switch v2WaitForDownloadFile(path: path, timeout: timeout) {
            case .ready:
                break
            case .timeout:
                return .err(
                    code: "timeout",
                    message: "Timed out waiting for download file",
                    data: [
                        "path": path,
                        "timeout_ms": timeoutMs,
                        "requested_timeout_ms": requestedTimeoutMs
                    ]
                )
            case .watcherSetupFailed(let errnoCode):
                return .err(
                    code: "internal_error",
                    message: "Failed to watch download path",
                    data: ["path": path, "errno": Int(errnoCode)]
                )
            }
            return .ok([
                "workspace_id": snapshot.workspaceId.uuidString,
                "workspace_ref": snapshot.workspaceRef,
                "surface_id": snapshot.surfaceId.uuidString,
                "surface_ref": snapshot.surfaceRef,
                "path": path,
                "downloaded": true
            ])
        }

        if let queuedEvent = snapshot.queuedEvent {
            return .ok([
                "workspace_id": snapshot.workspaceId.uuidString,
                "workspace_ref": snapshot.workspaceRef,
                "surface_id": snapshot.surfaceId.uuidString,
                "surface_ref": snapshot.surfaceRef,
                "download": queuedEvent
            ])
        }

        guard let downloadEvent = v2WaitForDownloadEvent(surfaceId: snapshot.surfaceId, timeout: timeout) else {
            return .err(
                code: "timeout",
                message: "No download event observed",
                data: [
                    "timeout_ms": timeoutMs,
                    "requested_timeout_ms": requestedTimeoutMs
                ]
            )
        }
        return .ok([
            "workspace_id": snapshot.workspaceId.uuidString,
            "workspace_ref": snapshot.workspaceRef,
            "surface_id": snapshot.surfaceId.uuidString,
            "surface_ref": snapshot.surfaceRef,
            "download": downloadEvent
        ])
    }

    private nonisolated static func v2WorkerString(_ params: [String: Any], _ key: String) -> String? {
        guard let raw = params[key] as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private nonisolated static func v2WorkerInt(_ params: [String: Any], _ key: String) -> Int? {
        if let intValue = params[key] as? Int {
            return intValue
        }
        if let number = params[key] as? NSNumber {
            return number.intValue
        }
        if let raw = v2WorkerString(params, key) {
            return Int(raw)
        }
        return nil
    }

    private nonisolated func v2BrowserDownloadWaitSnapshot(params: [String: Any]) -> V2BrowserDownloadWaitSnapshot {
        v2MainSync {
            v2RefreshKnownRefs()
            guard let tabManager = v2ResolveTabManager(params: params) else {
                return V2BrowserDownloadWaitSnapshot(
                    workspaceId: UUID(),
                    workspaceRef: NSNull(),
                    surfaceId: UUID(),
                    surfaceRef: NSNull(),
                    queuedEvent: nil,
                    error: .err(code: "unavailable", message: "TabManager not available", data: nil)
                )
            }
            let resolvedContext = v2ResolveBrowserPanelContext(params: params, tabManager: tabManager)
            if let error = resolvedContext.error {
                return V2BrowserDownloadWaitSnapshot(
                    workspaceId: UUID(),
                    workspaceRef: NSNull(),
                    surfaceId: UUID(),
                    surfaceRef: NSNull(),
                    queuedEvent: nil,
                    error: error
                )
            }
            guard let context = resolvedContext.context else {
                return V2BrowserDownloadWaitSnapshot(
                    workspaceId: UUID(),
                    workspaceRef: NSNull(),
                    surfaceId: UUID(),
                    surfaceRef: NSNull(),
                    queuedEvent: nil,
                    error: .err(code: "internal_error", message: "Browser operation failed", data: nil)
                )
            }

            return V2BrowserDownloadWaitSnapshot(
                workspaceId: context.workspaceId,
                workspaceRef: v2Ref(kind: .workspace, uuid: context.workspaceId),
                surfaceId: context.surfaceId,
                surfaceRef: v2Ref(kind: .surface, uuid: context.surfaceId),
                queuedEvent: Self.v2WorkerString(params, "path") == nil
                    ? v2PopBrowserDownloadEvent(surfaceId: context.surfaceId)
                    : nil,
                error: nil
            )
        }
    }

    private func v2PopBrowserDownloadEvent(surfaceId: UUID) -> [String: Any]? {
        guard let first = v2BrowserDownloadEventsBySurface[surfaceId]?.first else {
            return nil
        }
        var remaining = v2BrowserDownloadEventsBySurface[surfaceId] ?? []
        remaining.removeFirst()
        v2BrowserDownloadEventsBySurface[surfaceId] = remaining
        return first
    }

    private nonisolated func v2WaitForDownloadFile(path: String, timeout: TimeInterval) -> V2DownloadFileWaitResult {
        let fm = FileManager.default
        let pathIsReady = {
            guard fm.fileExists(atPath: path),
                  let attrs = try? fm.attributesOfItem(atPath: path),
                  let size = attrs[.size] as? NSNumber else {
                return false
            }
            return size.intValue > 0
        }
        if pathIsReady() {
            return .ready
        }

        let watchedPath = URL(fileURLWithPath: path).deletingLastPathComponent().path
        let fd = open(watchedPath, O_EVTONLY)
        guard fd >= 0 else {
            return .watcherSetupFailed(errnoCode: errno)
        }

        let lock = NSLock()
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var finished = false
        nonisolated(unsafe) var ready = false
        let finishOnce: (Bool) -> Void = { value in
            lock.lock()
            guard !finished else {
                lock.unlock()
                return
            }
            finished = true
            ready = value
            lock.unlock()
            semaphore.signal()
        }

        let watcherQueue = DispatchQueue(label: "com.cmux.browser.download.wait.file")
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .attrib, .link, .rename],
            queue: watcherQueue
        )
        source.setEventHandler {
            if pathIsReady() {
                finishOnce(true)
            }
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        if pathIsReady() {
            finishOnce(true)
        }
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            finishOnce(pathIsReady())
        }
        source.cancel()
        return ready ? .ready : .timeout
    }

    private nonisolated func v2WaitForDownloadEvent(surfaceId: UUID, timeout: TimeInterval) -> [String: Any]? {
        let lock = NSLock()
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var finished = false
        nonisolated(unsafe) var event: [String: Any]?
        var observer: NSObjectProtocol?

        let finishOnce: ([String: Any]?) -> Void = { value in
            lock.lock()
            guard !finished else {
                lock.unlock()
                return
            }
            finished = true
            event = value
            lock.unlock()
            semaphore.signal()
        }

        observer = NotificationCenter.default.addObserver(
            forName: .browserDownloadEventDidArrive,
            object: nil,
            queue: nil
        ) { note in
            guard let candidateSurfaceId = note.userInfo?["surfaceId"] as? UUID,
                  candidateSurfaceId == surfaceId,
                  let event = note.userInfo?["event"] as? [String: Any] else {
                return
            }
            finishOnce(event)
        }

        if let queued = v2MainSync({ v2PopBrowserDownloadEvent(surfaceId: surfaceId) }) {
            finishOnce(queued)
        }
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            finishOnce(nil)
        }
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        return event
    }

    private func v2BrowserImportDialog(params: [String: Any]) -> V2CallResult {
        let scope: BrowserImportScope?
        if params.keys.contains("scope") {
            guard let raw = v2String(params, "scope")?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  !raw.isEmpty else {
                return .err(code: "invalid_params", message: "scope must be a non-empty string", data: ["param": "scope"])
            }
            switch raw {
            case "cookie", "cookies", "cookiesonly", "cookies_only", "cookies-only":
                scope = .cookiesOnly
            case "history", "historyonly", "history_only", "history-only":
                scope = .historyOnly
            case "cookiesandhistory", "cookies_and_history", "cookies-and-history", "all-basic":
                scope = .cookiesAndHistory
            case "everything", "all":
                scope = .everything
            default:
                return .err(code: "invalid_params", message: "scope is invalid", data: ["param": "scope"])
            }
        } else {
            scope = nil
        }

        let defaultDestinationProfileID: UUID?
        if params.keys.contains("destination_profile") {
            guard let query = v2String(params, "destination_profile")?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !query.isEmpty else {
                return .err(
                    code: "invalid_params",
                    message: "destination_profile must be a non-empty string",
                    data: ["param": "destination_profile"]
                )
            }
            let profiles = BrowserProfileStore.shared.profiles
            if let uuid = UUID(uuidString: query),
               profiles.contains(where: { $0.id == uuid }) {
                defaultDestinationProfileID = uuid
            } else if let profile = profiles.first(where: {
                $0.displayName.localizedCaseInsensitiveCompare(query) == .orderedSame ||
                    $0.slug.localizedCaseInsensitiveCompare(query) == .orderedSame
            }) {
                defaultDestinationProfileID = profile.id
            } else if v2Bool(params, "create_destination_profile") == true ||
                v2Bool(params, "create_profile") == true {
                guard let createdProfileID = BrowserProfileStore.shared.createProfile(named: query)?.id else {
                    return .err(
                        code: "invalid_params",
                        message: "destination_profile could not be created",
                        data: ["param": "destination_profile"]
                    )
                }
                defaultDestinationProfileID = createdProfileID
            } else {
                return .err(
                    code: "invalid_params",
                    message: "destination_profile does not match a cmux browser profile",
                    data: ["param": "destination_profile"]
                )
            }
        } else {
            defaultDestinationProfileID = nil
        }
        Task { @MainActor in
            BrowserDataImportCoordinator.shared.presentImportDialog(
                defaultDestinationProfileID: defaultDestinationProfileID,
                defaultScope: scope
            )
        }
        return .ok([
            "opened": true,
            "scope": scope.map { $0.rawValue as Any } ?? NSNull(),
        ])
    }

    private nonisolated func v2BrowserCookieDict(_ cookie: HTTPCookie) -> [String: Any] {
        var out: [String: Any] = [
            "name": cookie.name,
            "value": cookie.value,
            "domain": cookie.domain,
            "path": cookie.path,
            "secure": cookie.isSecure,
            "session_only": cookie.isSessionOnly
        ]
        if let expiresDate = cookie.expiresDate {
            out["expires"] = Int(expiresDate.timeIntervalSince1970)
        } else {
            out["expires"] = NSNull()
        }
        return out
    }

    private nonisolated func v2BrowserCookieStoreAll(_ store: WKHTTPCookieStore, timeout: TimeInterval = 3.0) -> [HTTPCookie]? {
        v2AwaitCallback(timeout: timeout) { finish in
            v2MainSync {
                store.getAllCookies { items in
                    finish(items)
                }
            }
        }
    }

    private nonisolated func v2BrowserCookieStoreSet(_ store: WKHTTPCookieStore, cookie: HTTPCookie, timeout: TimeInterval = 3.0) -> Bool {
        v2AwaitCallback(timeout: timeout) { finish in
            v2MainSync {
                store.setCookie(cookie) {
                    finish(true)
                }
            }
        } ?? false
    }

    private nonisolated func v2BrowserCookieStoreDelete(_ store: WKHTTPCookieStore, cookie: HTTPCookie, timeout: TimeInterval = 3.0) -> Bool {
        v2AwaitCallback(timeout: timeout) { finish in
            v2MainSync {
                store.delete(cookie) {
                    finish(true)
                }
            }
        } ?? false
    }

    private nonisolated func v2BrowserCookieFromObject(_ raw: [String: Any], fallbackURL: URL?) -> HTTPCookie? {
        var props: [HTTPCookiePropertyKey: Any] = [:]
        if let name = raw["name"] as? String {
            props[.name] = name
        }
        if let value = raw["value"] as? String {
            props[.value] = value
        }

        if let urlStr = raw["url"] as? String, let url = URL(string: urlStr) {
            props[.originURL] = url
        } else if let fallbackURL {
            props[.originURL] = fallbackURL
        }

        if let domain = raw["domain"] as? String {
            props[.domain] = domain
        } else if let host = fallbackURL?.host {
            props[.domain] = host
        }

        if let path = raw["path"] as? String {
            props[.path] = path
        } else {
            props[.path] = "/"
        }

        if let secure = raw["secure"] as? Bool, secure {
            props[.secure] = "TRUE"
        }
        if let expires = raw["expires"] as? TimeInterval {
            props[.expires] = Date(timeIntervalSince1970: expires)
        } else if let expiresInt = raw["expires"] as? Int {
            props[.expires] = Date(timeIntervalSince1970: TimeInterval(expiresInt))
        }

        return HTTPCookie(properties: props)
    }

    private nonisolated func v2BrowserCookiesGet(params: [String: Any]) -> V2CallResult {
        return v2BrowserWithPanelContext(params: params) { ctx in
            let store = v2MainSync {
                ctx.webView.configuration.websiteDataStore.httpCookieStore
            }
            guard var cookies = v2BrowserCookieStoreAll(store) else {
                return .err(code: "timeout", message: "Timed out reading cookies", data: nil)
            }

            if let name = v2String(params, "name") {
                cookies = cookies.filter { $0.name == name }
            }
            if let domain = v2String(params, "domain") {
                cookies = cookies.filter { $0.domain.contains(domain) }
            }
            if let path = v2String(params, "path") {
                cookies = cookies.filter { $0.path == path }
            }

            return .ok(v2BrowserPanelFields(ctx, adding: ["cookies": cookies.map(v2BrowserCookieDict)]))
        }
    }

    private nonisolated func v2BrowserCookiesSet(params: [String: Any]) -> V2CallResult {
        return v2BrowserWithPanelContext(params: params) { ctx in
            let cookieContext = v2MainSync {
                (
                    store: ctx.webView.configuration.websiteDataStore.httpCookieStore,
                    fallbackURL: ctx.browserPanel.currentURL
                )
            }

            var cookieObjects: [[String: Any]] = []
            if let rows = params["cookies"] as? [[String: Any]] {
                cookieObjects = rows
            } else {
                var single: [String: Any] = [:]
                if let name = v2String(params, "name") { single["name"] = name }
                if let value = v2String(params, "value") { single["value"] = value }
                if let url = v2String(params, "url") { single["url"] = url }
                if let domain = v2String(params, "domain") { single["domain"] = domain }
                if let path = v2String(params, "path") { single["path"] = path }
                if let secure = v2Bool(params, "secure") { single["secure"] = secure }
                if let expires = v2Int(params, "expires") { single["expires"] = expires }
                if !single.isEmpty {
                    cookieObjects = [single]
                }
            }

            guard !cookieObjects.isEmpty else {
                return .err(code: "invalid_params", message: "Missing cookies payload", data: nil)
            }

            var setCount = 0
            for raw in cookieObjects {
                guard let cookie = v2BrowserCookieFromObject(raw, fallbackURL: cookieContext.fallbackURL) else {
                    return .err(code: "invalid_params", message: "Invalid cookie payload", data: ["cookie": raw])
                }
                if v2BrowserCookieStoreSet(cookieContext.store, cookie: cookie) {
                    setCount += 1
                } else {
                    return .err(code: "timeout", message: "Timed out setting cookie", data: ["name": cookie.name])
                }
            }

            return .ok(v2BrowserPanelFields(ctx, adding: ["set": setCount]))
        }
    }

    private nonisolated func v2BrowserCookiesClear(params: [String: Any]) -> V2CallResult {
        return v2BrowserWithPanelContext(params: params) { ctx in
            let store = v2MainSync {
                ctx.webView.configuration.websiteDataStore.httpCookieStore
            }
            guard let cookies = v2BrowserCookieStoreAll(store) else {
                return .err(code: "timeout", message: "Timed out reading cookies", data: nil)
            }

            let name = v2String(params, "name")
            let domain = v2String(params, "domain")
            let clearAll = params["all"] == nil && name == nil && domain == nil
            let targets = cookies.filter { cookie in
                if clearAll { return true }
                if let name, cookie.name != name { return false }
                if let domain, !cookie.domain.contains(domain) { return false }
                return true
            }

            var removed = 0
            for cookie in targets {
                if v2BrowserCookieStoreDelete(store, cookie: cookie) {
                    removed += 1
                }
            }

            return .ok(v2BrowserPanelFields(ctx, adding: ["cleared": removed]))
        }
    }

    private nonisolated func v2BrowserStorageType(_ params: [String: Any]) -> String {
        v2BrowserControl.storageType(params: params)
    }

    private nonisolated func v2BrowserStorageGet(params: [String: Any]) -> V2CallResult {
        let storageType = v2BrowserStorageType(params)
        let key = v2String(params, "key")
        return v2BrowserWithPanelContext(params: params) { ctx in
            let script = v2BrowserControl.storageGetScript(storageType: storageType, key: key)
            switch v2RunBrowserJavaScript(ctx.webView, surfaceId: ctx.surfaceId, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                guard let dict = value as? [String: Any],
                      let ok = dict["ok"] as? Bool,
                      ok else {
                    return .err(code: "invalid_state", message: "Storage unavailable", data: ["type": storageType])
                }
                return .ok(v2BrowserPanelFields(ctx, adding: [
                    "type": storageType,
                    "key": v2OrNull(key),
                    "value": v2NormalizeJSValue(dict["value"])
                ]))
            }
        }
    }

    private nonisolated func v2BrowserStorageSet(params: [String: Any]) -> V2CallResult {
        let storageType = v2BrowserStorageType(params)
        guard let key = v2String(params, "key") else {
            return .err(code: "invalid_params", message: "Missing key", data: nil)
        }
        guard let value = params["value"] else {
            return .err(code: "invalid_params", message: "Missing value", data: nil)
        }

        return v2BrowserWithPanelContext(params: params) { ctx in
            let valueLiteral = v2JSONLiteral(v2NormalizeJSValue(value))
            let script = v2BrowserControl.storageSetScript(storageType: storageType, key: key, valueLiteral: valueLiteral)
            switch v2RunBrowserJavaScript(ctx.webView, surfaceId: ctx.surfaceId, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                guard let dict = value as? [String: Any],
                      let ok = dict["ok"] as? Bool,
                      ok else {
                    return .err(code: "invalid_state", message: "Storage unavailable", data: ["type": storageType])
                }
                return .ok(v2BrowserPanelFields(ctx, adding: [
                    "type": storageType,
                    "key": key
                ]))
            }
        }
    }

    private nonisolated func v2BrowserStorageClear(params: [String: Any]) -> V2CallResult {
        let storageType = v2BrowserStorageType(params)
        return v2BrowserWithPanelContext(params: params) { ctx in
            let script = v2BrowserControl.storageClearScript(storageType: storageType)
            switch v2RunBrowserJavaScript(ctx.webView, surfaceId: ctx.surfaceId, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                guard let dict = value as? [String: Any],
                      let ok = dict["ok"] as? Bool,
                      ok else {
                    return .err(code: "invalid_state", message: "Storage unavailable", data: ["type": storageType])
                }
                return .ok(v2BrowserPanelFields(ctx, adding: [
                    "type": storageType,
                    "cleared": true
                ]))
            }
        }
    }

    private func v2BrowserTabList(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        var result: V2CallResult = .err(code: "not_found", message: "Workspace not found", data: nil)
        v2MainSync {
            let dockResolution = v2ResolveGlobalDockBrowserTabStore(params: params)
            if dockResolution.handled {
                guard let dock = dockResolution.dock else {
                    result = dockResolution.error ?? .err(code: "not_found", message: "Workspace not found", data: nil)
                    return
                }
                result = .ok(v2BrowserTabListPayload(
                    workspaceId: dock.workspaceId,
                    focusedPanelId: dock.focusedPanelId,
                    panels: orderedPanels(in: dock),
                    paneIdForPanel: { dock.paneId(forPanelId: $0) }
                ))
                return
            }

            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else { return }
            result = .ok(v2BrowserTabListPayload(
                workspaceId: ws.id,
                focusedPanelId: ws.focusedPanelId,
                panels: orderedPanels(in: ws),
                paneIdForPanel: { ws.paneId(forPanelId: $0) }
            ))
        }
        return result
    }

    private func v2BrowserTabNew(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        let urlStr = v2String(params, "url")
        let url = urlStr.flatMap(URL.init(string:))
        guard BrowserAvailabilitySettings.isEnabled() else {
            return v2BrowserDisabledExternalOpenResult(rawURL: urlStr, url: url, tabManager: tabManager)
        }

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to create browser tab", data: nil)
        v2MainSync {
            let dockResolution = v2ResolveGlobalDockBrowserTabStore(params: params)
            if dockResolution.handled {
                guard let dock = dockResolution.dock else {
                    result = dockResolution.error ?? .err(code: "not_found", message: "Workspace not found", data: nil)
                    return
                }
                let paneUUID = v2UUID(params, "pane_id")
                    ?? v2UUID(params, "target_pane_id")
                    ?? (v2UUID(params, "surface_id").flatMap { dock.paneId(forPanelId: $0)?.id })
                    ?? dock.focusedPanelId.flatMap { dock.paneId(forPanelId: $0)?.id }
                    ?? dock.bonsplitController.focusedPaneId?.id
                guard let paneUUID,
                      let pane = dock.bonsplitController.allPaneIds.first(where: { $0.id == paneUUID }) else {
                    result = .err(code: "not_found", message: "Target pane not found", data: nil)
                    return
                }

                guard let panelId = dock.newSurface(
                    kind: .browser,
                    inPane: pane,
                    url: url,
                    focus: true
                ),
                    let panel = dock.browserPanel(for: panelId) else {
                    result = .err(code: "internal_error", message: "Failed to create browser tab", data: nil)
                    return
                }
                result = .ok([
                    "workspace_id": dock.workspaceId.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: dock.workspaceId),
                    "pane_id": pane.id.uuidString,
                    "pane_ref": v2Ref(kind: .pane, uuid: pane.id),
                    "surface_id": panel.id.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: panel.id),
                    "url": panel.currentURL?.absoluteString ?? ""
                ])
                return
            }

            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            let paneUUID = v2UUID(params, "pane_id")
                ?? v2UUID(params, "target_pane_id")
                ?? (v2UUID(params, "surface_id").flatMap { ws.paneId(forPanelId: $0)?.id })
                ?? ws.paneId(forPanelId: ws.focusedPanelId ?? UUID())?.id
                ?? ws.bonsplitController.focusedPaneId?.id
            guard let paneUUID,
                  let pane = ws.bonsplitController.allPaneIds.first(where: { $0.id == paneUUID }) else {
                result = .err(code: "not_found", message: "Target pane not found", data: nil)
                return
            }

            guard let panel = ws.newBrowserSurface(
                inPane: pane,
                url: url,
                focus: true,
                creationPolicy: .automationPreload
            ) else {
                result = .err(code: "internal_error", message: "Failed to create browser tab", data: nil)
                return
            }
            result = .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "pane_id": pane.id.uuidString,
                "pane_ref": v2Ref(kind: .pane, uuid: pane.id),
                "surface_id": panel.id.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: panel.id),
                "url": panel.currentURL?.absoluteString ?? ""
            ])
        }
        return result
    }

    private func v2BrowserTabSwitch(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        var result: V2CallResult = .err(code: "not_found", message: "Browser tab not found", data: nil)
        v2MainSync {
            let dockResolution = v2ResolveGlobalDockBrowserTabStore(params: params)
            if dockResolution.handled {
                guard let dock = dockResolution.dock else {
                    result = dockResolution.error ?? .err(code: "not_found", message: "Workspace not found", data: nil)
                    return
                }
                let browserIds = orderedPanels(in: dock).compactMap { panel -> UUID? in
                    (panel as? BrowserPanel)?.id
                }
                let targetId: UUID? = {
                    if let explicit = v2UUID(params, "target_surface_id") ?? v2UUID(params, "tab_id") {
                        return explicit
                    }
                    if let idx = v2Int(params, "index"), idx >= 0, idx < browserIds.count {
                        return browserIds[idx]
                    }
                    return v2UUID(params, "surface_id")
                }()

                guard let targetId, browserIds.contains(targetId) else {
                    result = .err(code: "not_found", message: "Browser tab not found", data: nil)
                    return
                }

                dock.focusPanel(targetId)
                result = .ok([
                    "workspace_id": dock.workspaceId.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: dock.workspaceId),
                    "surface_id": targetId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: targetId)
                ])
                return
            }

            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }

            let browserIds = orderedPanels(in: ws).compactMap { panel -> UUID? in
                (panel as? BrowserPanel)?.id
            }

            let targetId: UUID? = {
                if let explicit = v2UUID(params, "target_surface_id") ?? v2UUID(params, "tab_id") {
                    return explicit
                }
                if let idx = v2Int(params, "index"), idx >= 0, idx < browserIds.count {
                    return browserIds[idx]
                }
                return v2UUID(params, "surface_id")
            }()

            guard let targetId, browserIds.contains(targetId) else {
                result = .err(code: "not_found", message: "Browser tab not found", data: nil)
                return
            }

            ws.focusPanel(targetId)
            result = .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": targetId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: targetId)
            ])
        }
        return result
    }

    private func v2BrowserTabClose(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        var result: V2CallResult = .err(code: "not_found", message: "Browser tab not found", data: nil)
        v2MainSync {
            let dockResolution = v2ResolveGlobalDockBrowserTabStore(params: params)
            if dockResolution.handled {
                guard let dock = dockResolution.dock else {
                    result = dockResolution.error ?? .err(code: "not_found", message: "Workspace not found", data: nil)
                    return
                }
                let browserIds = orderedPanels(in: dock).compactMap { panel -> UUID? in
                    (panel as? BrowserPanel)?.id
                }
                guard !browserIds.isEmpty else {
                    result = .err(code: "not_found", message: "No browser tabs", data: nil)
                    return
                }

                let targetId: UUID? = {
                    if let explicit = v2UUID(params, "target_surface_id") ?? v2UUID(params, "tab_id") {
                        return explicit
                    }
                    if let idx = v2Int(params, "index"), idx >= 0, idx < browserIds.count {
                        return browserIds[idx]
                    }
                    if let sid = v2UUID(params, "surface_id") {
                        return sid
                    }
                    return dock.focusedPanelId
                }()

                guard let targetId, browserIds.contains(targetId) else {
                    result = .err(code: "not_found", message: "Browser tab not found", data: nil)
                    return
                }

                if dock.panels.count <= 1 {
                    result = .err(code: "invalid_state", message: "Cannot close the last surface", data: nil)
                    return
                }

                let ok = closeGlobalDockBrowserPanel(targetId, in: dock)
                result = ok
                    ? .ok([
                        "workspace_id": dock.workspaceId.uuidString,
                        "workspace_ref": v2Ref(kind: .workspace, uuid: dock.workspaceId),
                        "surface_id": targetId.uuidString,
                        "surface_ref": v2Ref(kind: .surface, uuid: targetId)
                    ])
                    : .err(code: "internal_error", message: "Failed to close browser tab", data: ["surface_id": targetId.uuidString])
                return
            }

            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }

            let browserIds = orderedPanels(in: ws).compactMap { panel -> UUID? in
                (panel as? BrowserPanel)?.id
            }
            guard !browserIds.isEmpty else {
                result = .err(code: "not_found", message: "No browser tabs", data: nil)
                return
            }

            let targetId: UUID? = {
                if let explicit = v2UUID(params, "target_surface_id") ?? v2UUID(params, "tab_id") {
                    return explicit
                }
                if let idx = v2Int(params, "index"), idx >= 0, idx < browserIds.count {
                    return browserIds[idx]
                }
                if let sid = v2UUID(params, "surface_id") {
                    return sid
                }
                return ws.focusedPanelId
            }()

            guard let targetId, browserIds.contains(targetId) else {
                result = .err(code: "not_found", message: "Browser tab not found", data: nil)
                return
            }

            if ws.panels.count <= 1 {
                result = .err(code: "invalid_state", message: "Cannot close the last surface", data: nil)
                return
            }

            let ok = closeSurfaceRecordingHistory(in: ws, surfaceId: targetId, force: true)
            result = ok
                ? .ok([
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": targetId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: targetId)
                ])
                : .err(code: "internal_error", message: "Failed to close browser tab", data: ["surface_id": targetId.uuidString])
        }
        return result
    }

    private nonisolated func v2BrowserConsoleList(params: [String: Any]) -> V2CallResult {
        return v2BrowserWithPanelContext(params: params) { ctx in
            v2BrowserEnsureTelemetryHooks(surfaceId: ctx.surfaceId, webView: ctx.webView)
            let clear = v2Bool(params, "clear") ?? false
            let clearLiteral = clear ? "true" : "false"
            let script = """
            (() => {
              const items = Array.isArray(window.__cmuxConsoleLog) ? window.__cmuxConsoleLog.slice() : [];
              if (\(clearLiteral)) {
                window.__cmuxConsoleLog = [];
              }
              return { ok: true, items };
            })()
            """
            switch v2RunJavaScript(ctx.webView, script: script, timeout: 5.0, world: .page) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                let dict = value as? [String: Any]
                let items = (dict?["items"] as? [Any]) ?? []
                return .ok(v2BrowserPanelFields(ctx, adding: [
                    "entries": items.map(v2NormalizeJSValue),
                    "count": items.count
                ]))
            }
        }
    }

    private nonisolated func v2BrowserConsoleClear(params: [String: Any]) -> V2CallResult {
        var withClear = params
        withClear["clear"] = true
        return v2BrowserConsoleList(params: withClear)
    }

    private nonisolated func v2BrowserErrorsList(params: [String: Any]) -> V2CallResult {
        return v2BrowserWithPanelContext(params: params) { ctx in
            v2BrowserEnsureTelemetryHooks(surfaceId: ctx.surfaceId, webView: ctx.webView)
            let clear = v2Bool(params, "clear") ?? false
            let clearLiteral = clear ? "true" : "false"
            let script = """
            (() => {
              const items = Array.isArray(window.__cmuxErrorLog) ? window.__cmuxErrorLog.slice() : [];
              if (\(clearLiteral)) {
                window.__cmuxErrorLog = [];
              }
              return { ok: true, items };
            })()
            """
            switch v2RunJavaScript(ctx.webView, script: script, timeout: 5.0, world: .page) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                let dict = value as? [String: Any]
                let items = (dict?["items"] as? [Any]) ?? []
                return .ok(v2BrowserPanelFields(ctx, adding: [
                    "errors": items.map(v2NormalizeJSValue),
                    "count": items.count
                ]))
            }
        }
    }

    private nonisolated func v2BrowserHighlight(params: [String: Any]) -> V2CallResult {
        return v2BrowserSelectorAction(params: params, actionName: "highlight") { selectorLiteral in
            """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              const prev = el.style.outline;
              const prevOffset = el.style.outlineOffset;
              el.style.outline = '3px solid #ff9f0a';
              el.style.outlineOffset = '2px';
              setTimeout(() => {
                el.style.outline = prev;
                el.style.outlineOffset = prevOffset;
              }, 1200);
              return { ok: true };
            })()
            """
        }
    }

    private nonisolated func v2BrowserStateSave(params: [String: Any]) -> V2CallResult {
        guard let path = v2String(params, "path") else {
            return .err(code: "invalid_params", message: "Missing path", data: nil)
        }

        return v2BrowserWithPanelContext(params: params) { ctx in
            let storageScript = """
            (() => {
              const readStorage = (st) => {
                const out = {};
                if (!st) return out;
                for (let i = 0; i < st.length; i++) {
                  const k = st.key(i);
                  out[k] = st.getItem(k);
                }
                return out;
              };
              return {
                local: readStorage(window.localStorage),
                session: readStorage(window.sessionStorage)
              };
            })()
            """

            let storageValue: Any
            switch v2RunBrowserJavaScript(ctx.webView, surfaceId: ctx.surfaceId, script: storageScript, timeout: 10.0) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                storageValue = v2NormalizeJSValue(value)
            }

            let store = v2MainSync {
                ctx.webView.configuration.websiteDataStore.httpCookieStore
            }
            let cookies = (v2BrowserCookieStoreAll(store) ?? []).map(v2BrowserCookieDict)
            let stateSnapshot = v2MainSync {
                (
                    url: ctx.browserPanel.currentURL?.absoluteString ?? "",
                    frameSelector: v2BrowserFrameSelectorBySurface[ctx.surfaceId]
                )
            }

            let state: [String: Any] = [
                "url": stateSnapshot.url,
                "cookies": cookies,
                "storage": storageValue,
                "frame_selector": v2OrNull(stateSnapshot.frameSelector)
            ]

            do {
                let data = try JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            } catch {
                return .err(code: "internal_error", message: "Failed to write state file", data: ["path": path, "error": error.localizedDescription])
            }

            return .ok(v2BrowserPanelFields(ctx, adding: [
                "path": path,
                "cookies": cookies.count
            ]))
        }
    }

    private nonisolated func v2BrowserStateLoad(params: [String: Any]) -> V2CallResult {
        guard let path = v2String(params, "path") else {
            return .err(code: "invalid_params", message: "Missing path", data: nil)
        }

        let url = URL(fileURLWithPath: path)
        let raw: [String: Any]
        do {
            let data = try Data(contentsOf: url)
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .err(code: "invalid_params", message: "State file must contain a JSON object", data: ["path": path])
            }
            raw = obj
        } catch {
            return .err(code: "not_found", message: "Failed to read state file", data: ["path": path, "error": error.localizedDescription])
        }

        return v2BrowserWithPanelContext(params: params) { ctx in
            let cookieContext = v2MainSync {
                if let frameSelector = raw["frame_selector"] as? String, !frameSelector.isEmpty {
                    v2BrowserFrameSelectorBySurface[ctx.surfaceId] = frameSelector
                } else {
                    v2BrowserFrameSelectorBySurface.removeValue(forKey: ctx.surfaceId)
                }

                if let urlStr = raw["url"] as? String,
                   !urlStr.isEmpty,
                   let parsed = URL(string: urlStr) {
                    ctx.browserPanel.navigate(to: parsed)
                }

                return (
                    store: ctx.webView.configuration.websiteDataStore.httpCookieStore,
                    fallbackURL: ctx.browserPanel.currentURL
                )
            }
            if let cookieRows = raw["cookies"] as? [[String: Any]] {
                for row in cookieRows {
                    if let cookie = v2BrowserCookieFromObject(row, fallbackURL: cookieContext.fallbackURL) {
                        _ = v2BrowserCookieStoreSet(cookieContext.store, cookie: cookie)
                    }
                }
            }

            if let storage = raw["storage"] as? [String: Any] {
                let storageLiteral = v2JSONLiteral(storage)
                let script = """
                (() => {
                  const payload = \(storageLiteral);
                  const apply = (st, data) => {
                    if (!st || !data || typeof data !== 'object') return;
                    st.clear();
                    for (const [k, v] of Object.entries(data)) {
                      st.setItem(String(k), v == null ? '' : String(v));
                    }
                  };
                  apply(window.localStorage, payload.local);
                  apply(window.sessionStorage, payload.session);
                  return true;
                })()
                """
                _ = v2RunBrowserJavaScript(ctx.webView, surfaceId: ctx.surfaceId, script: script, timeout: 10.0)
            }

            return .ok(v2BrowserPanelFields(ctx, adding: [
                "path": path,
                "loaded": true
            ]))
        }
    }

    private nonisolated func v2BrowserAddInitScript(params: [String: Any]) -> V2CallResult {
        guard let script = v2String(params, "script") ?? v2String(params, "content") else {
            return .err(code: "invalid_params", message: "Missing script", data: nil)
        }
        return v2BrowserWithPanelContext(params: params) { ctx in
            let scriptsCount = v2MainSync {
                var scripts = v2BrowserInitScriptsBySurface[ctx.surfaceId] ?? []
                scripts.append(script)
                v2BrowserInitScriptsBySurface[ctx.surfaceId] = scripts

                let userScript = WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false)
                ctx.webView.configuration.userContentController.addUserScript(userScript)
                return scripts.count
            }
            _ = v2RunBrowserJavaScript(ctx.webView, surfaceId: ctx.surfaceId, script: script, timeout: 10.0)

            return .ok(v2BrowserPanelFields(ctx, adding: ["scripts": scriptsCount]))
        }
    }

    private nonisolated func v2BrowserAddScript(params: [String: Any]) -> V2CallResult {
        guard let script = v2String(params, "script") ?? v2String(params, "content") else {
            return .err(code: "invalid_params", message: "Missing script", data: nil)
        }
        return v2BrowserWithPanelContext(params: params) { ctx in
            switch v2RunBrowserJavaScript(ctx.webView, surfaceId: ctx.surfaceId, script: script, timeout: 10.0) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                return .ok(v2BrowserPanelFields(ctx, adding: ["value": v2NormalizeJSValue(value)]))
            }
        }
    }

    private nonisolated func v2BrowserAddStyle(params: [String: Any]) -> V2CallResult {
        guard let css = v2String(params, "css") ?? v2String(params, "style") ?? v2String(params, "content") else {
            return .err(code: "invalid_params", message: "Missing css/style content", data: nil)
        }
        return v2BrowserWithPanelContext(params: params) { ctx in
            let cssLiteral = v2JSONLiteral(css)
            let source = """
            (() => {
              const el = document.createElement('style');
              el.textContent = String(\(cssLiteral));
              (document.head || document.documentElement || document.body).appendChild(el);
              return true;
            })()
            """

            let stylesCount = v2MainSync {
                var styles = v2BrowserInitStylesBySurface[ctx.surfaceId] ?? []
                styles.append(css)
                v2BrowserInitStylesBySurface[ctx.surfaceId] = styles

                let userScript = WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
                ctx.webView.configuration.userContentController.addUserScript(userScript)
                return styles.count
            }
            _ = v2RunBrowserJavaScript(ctx.webView, surfaceId: ctx.surfaceId, script: source, timeout: 10.0)

            return .ok(v2BrowserPanelFields(ctx, adding: ["styles": stylesCount]))
        }
    }

    private func v2BrowserViewportSet(params _: [String: Any]) -> V2CallResult {
        v2BrowserNotSupported("browser.viewport.set", details: "WKWebView does not provide a per-tab programmable viewport emulation API equivalent to CDP")
    }

    private func v2BrowserGeolocationSet(params _: [String: Any]) -> V2CallResult {
        v2BrowserNotSupported("browser.geolocation.set", details: "WKWebView does not expose per-tab geolocation spoofing hooks equivalent to Playwright/CDP")
    }

    private func v2BrowserOfflineSet(params _: [String: Any]) -> V2CallResult {
        v2BrowserNotSupported("browser.offline.set", details: "WKWebView does not expose reliable per-tab offline emulation")
    }

    private func v2BrowserTraceStart(params _: [String: Any]) -> V2CallResult {
        v2BrowserNotSupported("browser.trace.start", details: "Playwright trace artifacts are not available on WKWebView")
    }

    private func v2BrowserTraceStop(params _: [String: Any]) -> V2CallResult {
        v2BrowserNotSupported("browser.trace.stop", details: "Playwright trace artifacts are not available on WKWebView")
    }

    private func v2BrowserNetworkRoute(params: [String: Any]) -> V2CallResult {
        if let surfaceId = v2UUID(params, "surface_id") {
            v2BrowserRecordUnsupportedRequest(surfaceId: surfaceId, request: ["action": "route", "params": params])
        }
        return v2BrowserNotSupported("browser.network.route", details: "WKWebView does not provide CDP-style request interception/mocking")
    }

    private func v2BrowserNetworkUnroute(params: [String: Any]) -> V2CallResult {
        if let surfaceId = v2UUID(params, "surface_id") {
            v2BrowserRecordUnsupportedRequest(surfaceId: surfaceId, request: ["action": "unroute", "params": params])
        }
        return v2BrowserNotSupported("browser.network.unroute", details: "WKWebView does not provide CDP-style request interception/mocking")
    }

    private func v2BrowserNetworkRequests(params: [String: Any]) -> V2CallResult {
        if let surfaceId = v2UUID(params, "surface_id") {
            let items = v2BrowserUnsupportedNetworkRequestsBySurface[surfaceId] ?? []
            return .err(code: "not_supported", message: "browser.network.requests is not supported on WKWebView", data: [
                "details": "Request interception logs are unavailable without CDP network hooks",
                "recorded_requests": items
            ])
        }
        return v2BrowserNotSupported("browser.network.requests", details: "Request interception logs are unavailable without CDP network hooks")
    }

    private func v2BrowserScreencastStart(params _: [String: Any]) -> V2CallResult {
        v2BrowserNotSupported("browser.screencast.start", details: "WKWebView does not expose CDP screencast streaming")
    }

    private func v2BrowserScreencastStop(params _: [String: Any]) -> V2CallResult {
        v2BrowserNotSupported("browser.screencast.stop", details: "WKWebView does not expose CDP screencast streaming")
    }

    private func v2BrowserInputMouse(params _: [String: Any]) -> V2CallResult {
        v2BrowserNotSupported("browser.input_mouse", details: "Raw CDP mouse injection is unavailable; use browser.click/hover/scroll")
    }

    private func v2BrowserInputKeyboard(params _: [String: Any]) -> V2CallResult {
        v2BrowserNotSupported("browser.input_keyboard", details: "Raw CDP keyboard injection is unavailable; use browser.press/keydown/keyup")
    }

    private func v2BrowserInputTouch(params _: [String: Any]) -> V2CallResult {
        v2BrowserNotSupported("browser.input_touch", details: "Raw CDP touch injection is unavailable on WKWebView")
    }

#if DEBUG
    // MARK: - V2 Debug / Test-only Methods

#if DEBUG
#endif

#if DEBUG

    /// Drives `SidebarDragState.draggedTabId` and `dropIndicator` mutations
    /// across N steps from a starting workspace toward a target neighbor.
    /// External profilers (e.g. the `profile-pr` skill driving `xctrace`)
    /// invoke this between `xctrace record --launch` and `xctrace stop` to
    /// generate a deterministic 60Hz-style drag load without HID synthesis.
    /// Never commits the reorder; calls back with the synthesized step path.
    ///
    /// Runs on the socket worker (see `ControlCommandExecutionPolicy`) so the
    /// inter-tick `Thread.sleep` doesn't block the main actor — every
    /// dragState mutation hops to main via `v2MainSync`.
    private nonisolated func v2DebugSidebarSimulateDrag(params: [String: Any]) -> V2CallResult {
        // Dispatched on the socket worker (see ControlCommandExecutionPolicy) so the
        // inter-tick Thread.sleep doesn't block the main actor. All parameter
        // resolution (including workspace:N -> UUID ref-resolution) and the
        // SidebarDragState mutations hop to main via v2MainSync.

        enum PlanResult {
            case ok(
                windowId: UUID,
                fromTabId: UUID,
                toTabId: UUID,
                tabIds: [UUID],
                fromIndex: Int,
                toIndex: Int,
                durationMs: Int,
                requestedSteps: Int?
            )
            case err(code: String, message: String, data: [String: Any]?)
        }

        let planResult: PlanResult = v2MainSync {
            guard let windowId = v2UUID(params, "window_id") else {
                return .err(code: "invalid_params", message: "Missing or invalid window_id", data: nil)
            }
            // Scope to the requested window. self.tabManager is the controller's
            // primary tabManager; in multi-window runs that's the wrong list for
            // a window_id other than the primary.
            guard let windowTabManager = AppDelegate.shared?.tabManagerFor(windowId: windowId) else {
                return .err(
                    code: "not_found",
                    message: "No TabManager for window_id",
                    data: ["window_id": windowId.uuidString]
                )
            }
            guard let fromTabId = v2UUID(params, "from_tab_id") else {
                return .err(code: "invalid_params", message: "Missing or invalid from_tab_id", data: nil)
            }
            guard let toTabId = v2UUID(params, "to_tab_id") else {
                return .err(code: "invalid_params", message: "Missing or invalid to_tab_id", data: nil)
            }
            let durationMs: Int
            if v2HasNonNullParam(params, "duration_ms") {
                guard let value = v2Int(params, "duration_ms"), value > 0 else {
                    return .err(code: "invalid_params", message: "duration_ms must be a positive integer", data: nil)
                }
                durationMs = value
            } else {
                durationMs = 1000
            }
            let requestedSteps: Int?
            if v2HasNonNullParam(params, "steps") {
                guard let value = v2Int(params, "steps"), value > 0 else {
                    return .err(code: "invalid_params", message: "steps must be a positive integer", data: nil)
                }
                requestedSteps = value
            } else {
                requestedSteps = nil
            }
            guard AppDelegate.shared?.sidebarDragStateRegistry.state(forWindowId: windowId) != nil else {
                return .err(
                    code: "not_found",
                    message: "No mounted sidebar for window_id",
                    data: ["window_id": windowId.uuidString]
                )
            }
            let tabIds = windowTabManager.tabs.map(\.id)
            guard let fromIndex = tabIds.firstIndex(of: fromTabId) else {
                return .err(
                    code: "not_found",
                    message: "from_tab_id not in window's workspace list",
                    data: ["from_tab_id": fromTabId.uuidString]
                )
            }
            guard let toIndex = tabIds.firstIndex(of: toTabId) else {
                return .err(
                    code: "not_found",
                    message: "to_tab_id not in window's workspace list",
                    data: ["to_tab_id": toTabId.uuidString]
                )
            }
            guard fromIndex != toIndex else {
                return .err(code: "invalid_params", message: "from_tab_id and to_tab_id must differ", data: nil)
            }
            return .ok(
                windowId: windowId,
                fromTabId: fromTabId,
                toTabId: toTabId,
                tabIds: tabIds,
                fromIndex: fromIndex,
                toIndex: toIndex,
                durationMs: durationMs,
                requestedSteps: requestedSteps
            )
        }

        let windowId: UUID
        let fromTabId: UUID
        let toTabId: UUID
        let tabIds: [UUID]
        let fromIndex: Int
        let toIndex: Int
        let durationMs: Int
        let requestedSteps: Int?
        switch planResult {
        case let .err(code, message, data):
            return .err(code: code, message: message, data: data)
        case let .ok(w, f, t, ids, fi, ti, dur, steps):
            windowId = w; fromTabId = f; toTabId = t; tabIds = ids
            fromIndex = fi; toIndex = ti; durationMs = dur; requestedSteps = steps
        }

        let stride = fromIndex < toIndex ? 1 : -1
        let pathIndices = Swift.stride(from: fromIndex + stride, through: toIndex, by: stride).map { $0 }
        guard !pathIndices.isEmpty else {
            return .err(code: "invalid_params", message: "Empty drag path", data: nil)
        }
        // Allow requestedSteps > pathIndices.count: profiling at high tick
        // rates (e.g. 60Hz over a short row span) is a documented use case.
        // The resampling formula picks the same indicator value multiple
        // times in that regime, which is exactly the SwiftUI invalidation
        // load the skill measures.
        let steps = max(1, requestedSteps ?? pathIndices.count)
        // Resampler closure: maps step number (0..<steps) -> path index.
        // Not pre-materialized; computed inline in the simulation loop so
        // arbitrarily large --steps (e.g. 60Hz over hours) doesn't allocate
        // a giant [Int] up front.
        let pathCount = pathIndices.count
        let stepDivisor = Double(max(1, steps - 1))
        let resolveStepIndex: (Int) -> Int = { stepNumber in
            let position = Int(round(Double(stepNumber) * Double(pathCount - 1) / stepDivisor))
            return pathIndices[max(0, min(pathCount - 1, position))]
        }
        let stepIntervalMs = max(1, durationMs / steps)
        let edge: SidebarDropEdge = fromIndex < toIndex ? .bottom : .top
        // Cap the response payload's path array so very large --steps don't
        // serialize a giant JSON UUID list. The simulation still runs every
        // requested step; the response is just informational.
        let pathSampleLimit = 64

        // Start the drag. If the sidebar has already unregistered, fail loud
        // instead of silently sleeping through a no-op simulation.
        let startedOK: Bool = v2MainSync {
            guard let dragState = AppDelegate.shared?.sidebarDragStateRegistry.state(forWindowId: windowId) else { return false }
            // Mark the drag as simulator-driven so VerticalTabsSidebar skips
            // starting SidebarDragFailsafeMonitor — it would otherwise post
            // mouse_up_failsafe immediately because no real mouse is pressed.
            dragState.isSimulated = true
            dragState.beginDragging(tabId: fromTabId)
            return true
        }
        guard startedOK else {
            return .err(
                code: "not_found",
                message: "Sidebar unregistered before simulation could start",
                data: ["window_id": windowId.uuidString]
            )
        }

        var aborted = false
        var pathSample: [String] = []
        pathSample.reserveCapacity(min(steps, pathSampleLimit))
        for stepNumber in 0..<steps {
            let tabIndex = resolveStepIndex(stepNumber)
            let targetTabId = tabIds[tabIndex]
            if pathSample.count < pathSampleLimit {
                pathSample.append(targetTabId.uuidString)
            }
            let tickOK: Bool = v2MainSync {
                guard let dragState = AppDelegate.shared?.sidebarDragStateRegistry.state(forWindowId: windowId) else { return false }
                dragState.setDropIndicator(SidebarDropIndicator(tabId: targetTabId, edge: edge))
                return true
            }
            if !tickOK {
                aborted = true
                break
            }
            if stepIntervalMs > 0 {
                Thread.sleep(forTimeInterval: TimeInterval(stepIntervalMs) / 1000.0)
            }
        }

        v2MainSync {
            guard let dragState = AppDelegate.shared?.sidebarDragStateRegistry.state(forWindowId: windowId) else { return }
            dragState.clearDrag()
            dragState.isSimulated = false
        }

        if aborted {
            return .err(
                code: "aborted",
                message: "Sidebar unregistered mid-simulation",
                data: ["window_id": windowId.uuidString]
            )
        }

        var payload: [String: Any] = [
            "window_id": windowId.uuidString,
            "from_tab_id": fromTabId.uuidString,
            "to_tab_id": toTabId.uuidString,
            "steps": steps,
            "step_interval_ms": stepIntervalMs,
            "duration_ms": stepIntervalMs * steps,
            "edge": edge == .top ? "top" : "bottom",
            "path": pathSample
        ]
        if steps > pathSampleLimit {
            payload["path_truncated"] = true
            payload["path_full_size"] = steps
        }
        return .ok(payload)
    }
#endif
#endif

    private struct ReadScreenOptions {
        let surfaceArg: String
        let includeScrollback: Bool
        let lineLimit: Int?
    }

    private struct ReadScreenParseError: Error {
        let message: String
    }

    private func parseReadScreenArgs(_ args: String) -> Result<ReadScreenOptions, ReadScreenParseError> {
        let tokens = args
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        var surfaceArg: String?
        var includeScrollback = false
        var lineLimit: Int?
        var idx = 0

        while idx < tokens.count {
            let token = tokens[idx]
            switch token {
            case "--scrollback":
                includeScrollback = true
                idx += 1
            case "--lines":
                guard idx + 1 < tokens.count, let parsed = Int(tokens[idx + 1]), parsed > 0 else {
                    return .failure(ReadScreenParseError(message: "ERROR: --lines must be greater than 0"))
                }
                lineLimit = parsed
                includeScrollback = true
                idx += 2
            default:
                guard surfaceArg == nil else {
                    return .failure(ReadScreenParseError(message: "ERROR: Usage: read_screen [id|idx] [--scrollback] [--lines <n>]"))
                }
                surfaceArg = token
                idx += 1
            }
        }

        return .success(
            ReadScreenOptions(
                surfaceArg: surfaceArg ?? "",
                includeScrollback: includeScrollback,
                lineLimit: lineLimit
            )
        )
    }

    nonisolated static func tailTerminalLines(_ text: String, maxLines: Int) -> String {
        guard maxLines > 0 else { return "" }
        var newlineCount = 0
        var index = text.endIndex
        while index > text.startIndex {
            let previous = text.index(before: index)
            if text[previous] == "\n" {
                newlineCount += 1
                if newlineCount == maxLines {
                    return String(text[index...])
                }
            }
            index = previous
        }
        return text
    }

    private func readTerminalTextBase64(surfaceArg: String, includeScrollback: Bool = false, lineLimit: Int? = nil) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        let trimmedSurfaceArg = surfaceArg.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = "ERROR: No tab selected"
        v2MainSync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
                return
            }

            let panelId: UUID?
            if trimmedSurfaceArg.isEmpty {
                panelId = tab.focusedPanelId
            } else {
                panelId = resolveSurfaceId(from: trimmedSurfaceArg, tab: tab)
            }

            guard let panelId,
                  let terminalPanel = tab.terminalPanel(for: panelId) else {
                result = "ERROR: Terminal surface not found"
                return
            }

            result = readTerminalTextBase64(
                terminalPanel: terminalPanel,
                includeScrollback: includeScrollback,
                lineLimit: lineLimit
            )
        }
        return result
    }

    private func readScreenText(_ args: String) -> String {
        let options: ReadScreenOptions
        switch parseReadScreenArgs(args) {
        case .success(let parsed):
            options = parsed
        case .failure(let error):
            return error.message
        }

        let response = readTerminalTextBase64(
            surfaceArg: options.surfaceArg,
            includeScrollback: options.includeScrollback,
            lineLimit: options.lineLimit
        )
        guard response.hasPrefix("OK ") else { return response }

        let payload = String(response.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        if payload.isEmpty {
            return ""
        }

        guard let data = Data(base64Encoded: payload) else {
            return "ERROR: Failed to decode terminal text"
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func helpText() -> String {
        var text = """
        Hierarchy: Workspace (sidebar tab) > Pane (split region) > Surface (nested tab) > Panel (terminal/browser)

        Available commands:
          ping                        - Check if server is running
          list_workspaces             - List all workspaces with IDs
          new_workspace               - Create a new workspace
          select_workspace <id|index> - Select workspace by ID or index (0-based)
          current_workspace           - Get current workspace ID
          close_workspace <id>        - Close workspace by ID

        Split & surface commands:
          new_split <direction> [panel]   - Split panel (left/right/up/down)
          drag_surface_to_split <id|idx> <direction> - Move surface into a new split (drag-to-edge)
          new_pane [--type=terminal|browser] [--direction=left|right|up|down] [--url=...]
          new_surface [--type=terminal|browser] [--pane=<pane-id|index>] [--url=...]
          list_surfaces [workspace]       - List surfaces for workspace (current if omitted)
          list_panes                      - List all panes with IDs
          list_pane_surfaces [--pane=<pane-id|index>] - List surfaces in pane
          focus_surface <id|idx>          - Focus surface by ID or index
          focus_pane <pane-id|index>      - Focus a pane
          focus_surface_by_panel <panel_id> - Focus surface by panel ID
          close_surface [id|idx]          - Close surface (collapse split)
          reload_config                   - Reload Ghostty config, cmux settings, and refresh terminals
          refresh_surfaces                - Force refresh all terminals
          surface_health [workspace]      - Check view health of all surfaces

        Input commands:
          send <text>                     - Send text to current terminal
          send_key <key>                  - Send special key (ctrl-c, ctrl-d, ctrl-f, enter, tab, escape)
          send_surface <id|idx> <text>    - Send text to a specific terminal
          send_key_surface <id|idx> <key> - Send special key to a specific terminal
          read_screen [id|idx] [--scrollback] [--lines N] - Read terminal text (plain text)

        Notification commands:
          notify <title>|<subtitle>|<body>   - Notify focused panel
          notify_surface <id|idx> <payload>  - Notify a specific surface
          notify_target <workspace_id> <surface_id> <payload> - Notify by workspace+surface
          notify_target_async <workspace_uuid> <surface_uuid> <payload> - Queue notification by workspace+surface
          list_notifications              - List all notifications
          clear_notifications [--tab=X] [--panel=ID] - Clear notifications (all, per-tab, or per-panel)
          set_app_focus <active|inactive|clear> - Override app focus state
          simulate_app_active             - Trigger app active handler
          set_status <key> <value> [--icon=X] [--color=#hex] [--url=X] [--priority=N] [--format=plain|markdown] [--tab=X] - Set a status entry
          set_agent_lifecycle <key> <unknown|running|idle|needsInput> [--tab=X] [--panel=ID] - Report coding-agent lifecycle for hibernation
          agent_hibernation <on|off> - Enable or disable Agent Hibernation
          report_meta <key> <value> [--icon=X] [--color=#hex] [--url=X] [--priority=N] [--format=plain|markdown] [--tab=X] - Set sidebar metadata entry
          report_meta_block <key> [--priority=N] [--tab=X] -- <markdown> - Set freeform sidebar markdown block
          clear_status <key> [--tab=X] - Remove a status entry
          clear_meta <key> [--tab=X] - Remove sidebar metadata entry
          clear_meta_block <key> [--tab=X] - Remove sidebar markdown block
          list_status [--tab=X]   - List all status entries
          list_meta [--tab=X]     - List sidebar metadata entries
          list_meta_blocks [--tab=X] - List sidebar markdown blocks
          log [--level=X] [--source=X] [--tab=X] -- <message> - Append a log entry
          clear_log [--tab=X]     - Clear log entries
          list_log [--limit=N] [--tab=X] - List log entries
          set_progress <0.0-1.0> [--label=X] [--tab=X] - Set progress bar
          clear_progress [--tab=X] - Clear progress bar
          report_git_branch <branch> [--status=dirty|clean|unknown] [--tab=X] [--panel=Y] - Report git branch
          clear_git_branch [--tab=X] [--panel=Y] - Clear git branch
          report_pr <number> <url> [--label=PR] [--state=open|merged|closed] [--branch=<name>] [--tab=X] [--panel=Y] - Report pull request / review item
          report_review <number> <url> [--label=MR] [--state=open|merged|closed] [--tab=X] [--panel=Y] - Alias for provider-specific review item
          clear_pr [--tab=X] [--panel=Y] - Clear pull request
          report_ports <port1> [port2...] [--tab=X] [--panel=Y] - Report listening ports
          report_tty <tty_name> [--tab=X] [--panel=Y] - Register TTY for batched port scanning
          ports_kick [--tab=X] [--panel=Y] [--reason=command|refresh] - Request batched port scan for panel
          report_shell_state <prompt|running> [--tab=X] [--panel=Y] - Report whether the shell is idle at a prompt or running a command
          report_pr_action <merge|close|reopen|create|checkout|ready|edit|view> [--target=X] [--tab=X] [--panel=Y] - Hint that a PR-affecting command completed in the panel
          report_pwd <path> [--tab=X] [--panel=Y] - Report current working directory
          clear_ports [--tab=X] [--panel=Y] - Clear listening ports
          right_sidebar <toggle|show|hide|focus|set|mode> [mode] [--tab=X] [--window=Y] [--no-focus] - Control right sidebar visibility, mode, and focus
          sidebar_state [--tab=X] - Dump sidebar metadata
          reset_sidebar [--tab=X] - Clear sidebar metadata

        Browser commands:
          open_browser [url]              - Create browser panel with optional URL
          navigate <panel_id> <url>       - Navigate browser to URL
          browser_back <panel_id>         - Go back in browser history
          browser_forward <panel_id>      - Go forward in browser history
          browser_reload <panel_id>       - Reload browser page
          get_url <panel_id>              - Get current URL of browser panel
          focus_webview <panel_id>        - Move keyboard focus into the WKWebView (for tests)
          is_webview_focused <panel_id>   - Return true/false if WKWebView is first responder

          help                            - Show this help
        """
#if DEBUG
        text += """

          focus_notification <workspace|idx> [surface|idx] - Focus via notification flow
          flash_count <id|idx>            - Read flash count for a panel
          reset_flash_counts              - Reset flash counters
          screenshot [label]              - Capture window screenshot
          set_shortcut <name> <combo|clear> - Set a keyboard shortcut (test-only)
          simulate_shortcut <combo>       - Simulate a keyDown shortcut (test-only)
          simulate_type <text>            - Insert text into the current first responder (test-only)
          sleepy_mode <cmd> [val]         - Sleepy Mode: on|off|unlock|preview|theme <t>|mascot <m>|glow <g>|toggle <k>|pets <c x o|clear> (test-only)
          simulate_file_drop <id|idx> <path[|path...]> - Simulate dropping file path(s) on terminal (test-only)
          seed_drag_pasteboard_fileurl    - Seed NSDrag pasteboard with public.file-url (test-only)
          seed_drag_pasteboard_tabtransfer - Seed NSDrag pasteboard with tab transfer type (test-only)
          seed_drag_pasteboard_sidebar_reorder - Seed NSDrag pasteboard with sidebar reorder type (test-only)
          seed_drag_pasteboard_types <types> - Seed NSDrag pasteboard with comma/space-separated types (fileurl, tabtransfer, sidebarreorder, or raw UTI)
          clear_drag_pasteboard           - Clear NSDrag pasteboard (test-only)
          drop_hit_test <x 0-1> <y 0-1> - Hit-test file-drop overlay at normalised coords (test-only)
          drag_hit_chain <x 0-1> <y 0-1> - Return hit-view chain at normalised coords (test-only)
          overlay_hit_gate <event|none> - Return true/false if file-drop overlay would capture hit-testing for event type (test-only)
          overlay_drop_gate [external|local] - Return true/false if file-drop overlay would capture drag destination routing (test-only)
          portal_hit_gate <event|none> - Return true/false if terminal portal should pass hit-testing to SwiftUI drag targets (test-only)
          sidebar_overlay_gate [active|inactive] - Return true/false if sidebar outside-drop overlay would capture (test-only)
          terminal_drop_overlay_probe [deferred|direct] - Trigger focused terminal drop-overlay show path and report animation counts (test-only)
          activate_app                    - Bring app + main window to front (test-only)
          send_workspace <workspace_id> <text> - Send text to a workspace's selected terminal (test-only)
          is_terminal_focused <id|idx>    - Return true/false if terminal surface is first responder (test-only)
          read_terminal_text [id|idx]     - Read visible terminal text (base64, test-only)
          render_stats [id|idx]           - Read terminal render stats (draw counters, test-only)
          layout_debug                    - Dump bonsplit layout + selected panel bounds (test-only)
          bonsplit_underflow_count        - Count bonsplit arranged-subview underflow events (test-only)
          reset_bonsplit_underflow_count  - Reset bonsplit underflow counter (test-only)
          empty_panel_count               - Count EmptyPanelView appearances (test-only)
          reset_empty_panel_count         - Reset EmptyPanelView appearance count (test-only)
        """
#endif
        return text
    }

#if DEBUG
    func setShortcut(_ args: String) -> String {
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            return "ERROR: Usage: set_shortcut <name> <combo|clear>"
        }

        let name = parts[0].lowercased()
        let combo = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)

        let action: KeyboardShortcutSettings.Action?
        switch name {
        case "focus_left", "focusleft":
            action = .focusLeft
        case "focus_right", "focusright":
            action = .focusRight
        case "focus_up", "focusup":
            action = .focusUp
        case "focus_down", "focusdown":
            action = .focusDown
        case "split_right", "splitright":
            action = .splitRight
        case "split_down", "splitdown":
            action = .splitDown
        case "workspace_digits", "workspace_number", "select_workspace_by_number":
            action = .selectWorkspaceByNumber
        case "surface_digits", "surface_number", "select_surface_by_number":
            action = .selectSurfaceByNumber
        default:
            action = nil
        }

        guard let action else {
            return "ERROR: Unknown shortcut name. Supported: focus_left, focus_right, focus_up, focus_down, split_right, split_down, workspace_digits, surface_digits"
        }

        if combo.lowercased() == "clear" || combo.lowercased() == "unbound" || combo.lowercased() == "none" {
            KeyboardShortcutSettings.clearShortcut(for: action)
            return "OK"
        }

        if combo.lowercased() == "default" || combo.lowercased() == "reset" {
            KeyboardShortcutSettings.resetShortcut(for: action)
            return "OK"
        }

        guard let parsed = parseShortcutCombo(combo) else {
            return "ERROR: Invalid combo. Example: cmd+ctrl+h"
        }

        let shortcut = StoredShortcut(
            key: parsed.storedKey,
            command: parsed.modifierFlags.contains(.command),
            shift: parsed.modifierFlags.contains(.shift),
            option: parsed.modifierFlags.contains(.option),
            control: parsed.modifierFlags.contains(.control)
        )
        if action.usesNumberedDigitMatching,
           action.normalizedRecordedShortcut(shortcut) == nil {
            return "ERROR: Numbered shortcuts must use a digit key (1-9). Example: ctrl+1"
        }

        let storedShortcut = action.normalizedRecordedShortcut(shortcut) ?? shortcut
        KeyboardShortcutSettings.setShortcut(storedShortcut, for: action)
        return "OK"
    }

    private func prepareWindowForSyntheticInput(_ window: NSWindow?) {
        guard socketCommandAllowsInAppFocusMutations(),
              let window else { return }
        // Keep socket-driven input simulation focused on the intended window without
        // paying repeated activation/order-front costs for every synthetic key event.
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
        if !window.isKeyWindow || !window.isVisible {
            window.makeKeyAndOrderFront(nil)
        }
    }

    func simulateShortcut(_ args: String) -> String {
        let combo = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !combo.isEmpty else {
            return "ERROR: Usage: simulate_shortcut <combo>"
        }
        guard let parsed = parseShortcutCombo(combo) else {
            return "ERROR: Invalid combo. Example: cmd+ctrl+h"
        }

        // Stamp at socket-handler arrival so event.timestamp includes any wait
        // before the main-thread event dispatch.
        let requestTimestamp = ProcessInfo.processInfo.systemUptime

        var result = "ERROR: Failed to create event"
        v2MainSync {
            // Prefer the current active-tab-manager window so shortcut simulation stays
            // scoped to the intended window even when NSApp.keyWindow is stale.
            let targetWindow: NSWindow? = {
                if let activeTabManager = self.tabManager,
                   let windowId = AppDelegate.shared?.windowId(for: activeTabManager),
                   let window = AppDelegate.shared?.mainWindow(for: windowId) {
                    return window
                }
                return NSApp.keyWindow
                    ?? NSApp.mainWindow
                    ?? NSApp.windows.first(where: { $0.isVisible })
                    ?? NSApp.windows.first
            }()
            prepareWindowForSyntheticInput(targetWindow)
            let windowNumber = targetWindow?.windowNumber ?? 0
            guard let keyDownEvent = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: parsed.modifierFlags,
                timestamp: requestTimestamp,
                windowNumber: windowNumber,
                context: nil,
                characters: parsed.characters,
                charactersIgnoringModifiers: parsed.charactersIgnoringModifiers,
                isARepeat: false,
                keyCode: parsed.keyCode
            ) else {
                result = "ERROR: NSEvent.keyEvent returned nil"
                return
            }
            let keyUpEvent = NSEvent.keyEvent(
                with: .keyUp,
                location: .zero,
                modifierFlags: parsed.modifierFlags,
                timestamp: requestTimestamp + 0.0001,
                windowNumber: windowNumber,
                context: nil,
                characters: parsed.characters,
                charactersIgnoringModifiers: parsed.charactersIgnoringModifiers,
                isARepeat: false,
                keyCode: parsed.keyCode
            )
            // Socket-driven shortcut simulation should reuse the exact same matching logic as the
            // app-level shortcut monitor (so tests are hermetic), while still falling back to the
            // normal responder chain for plain typing.
            if let delegate = AppDelegate.shared, delegate.debugHandleCustomShortcut(event: keyDownEvent) {
                result = "OK"
                return
            }
            NSApp.sendEvent(keyDownEvent)
            if let keyUpEvent {
                NSApp.sendEvent(keyUpEvent)
            }
            result = "OK"
        }
        return result
    }

    func activateApp() -> String {
        v2MainSync {
            _ = AppDelegate.shared?.activateMainWindowFromSocket()
        }
        return "OK"
    }

    private func simulateType(_ args: String) -> String {
        let raw = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            return "ERROR: Usage: simulate_type <text>"
        }

        // Socket commands are line-based; allow callers to express control chars with backslash escapes.
        let text = unescapeSocketText(raw)

        var result = "ERROR: No window"
        v2MainSync {
            // Like simulate_shortcut, prefer a visible window so debug automation doesn't
            // fail during key window transitions.
            guard let window = NSApp.keyWindow
                ?? NSApp.mainWindow
                ?? NSApp.windows.first(where: { $0.isVisible })
                ?? NSApp.windows.first else { return }
            prepareWindowForSyntheticInput(window)
            guard let fr = window.firstResponder else {
                result = "ERROR: No first responder"
                return
            }

            if let client = fr as? NSTextInputClient {
                client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
                result = "OK"
                return
            }

            // Fall back to the responder chain insertText action.
            (fr as? NSResponder)?.insertText(text)
            result = "OK"
        }
        return result
    }

    private func simulateFileDrop(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        let parts = args.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            return "ERROR: Usage: simulate_file_drop <id|idx> <path[|path...]>"
        }

        let target = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let rawPaths = parts[1]
        let paths = rawPaths
            .split(separator: "|")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !paths.isEmpty else {
            return "ERROR: Usage: simulate_file_drop <id|idx> <path[|path...]>"
        }

        var result = "ERROR: Surface not found"
        v2MainSync {
            guard let panel = resolveTerminalPanel(from: target, tabManager: tabManager) else { return }
            result = panel.hostedView.debugSimulateFileDrop(paths: paths)
                ? "OK"
                : "ERROR: Failed to simulate drop"
        }
        return result
    }

    private func seedDragPasteboardFileURL() -> String {
        return seedDragPasteboardTypes("fileurl")
    }

    private func seedDragPasteboardTabTransfer() -> String {
        return seedDragPasteboardTypes("tabtransfer")
    }

    private func seedDragPasteboardSidebarReorder() -> String {
        return seedDragPasteboardTypes("sidebarreorder")
    }

    private func seedDragPasteboardTypes(_ args: String) -> String {
        let raw = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            return "ERROR: Usage: seed_drag_pasteboard_types <type[,type...]>"
        }

        let tokens = raw
            .split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else {
            return "ERROR: Usage: seed_drag_pasteboard_types <type[,type...]>"
        }

        var types: [NSPasteboard.PasteboardType] = []
        for token in tokens {
            guard let mapped = dragPasteboardType(from: token) else {
                return "ERROR: Unknown drag type '\(token)'"
            }
            if !types.contains(mapped) {
                types.append(mapped)
            }
        }

        v2MainSync {
            _ = NSPasteboard(name: .drag).declareTypes(types, owner: nil)
        }
        return "OK"
    }

    private func clearDragPasteboard() -> String {
        v2MainSync {
            _ = NSPasteboard(name: .drag).clearContents()
        }
        return "OK"
    }

    private func overlayHitGate(_ args: String) -> String {
        let token = args.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !token.isEmpty else {
            return "ERROR: Usage: overlay_hit_gate <leftMouseDragged|rightMouseDragged|otherMouseDragged|mouseMoved|mouseEntered|mouseExited|flagsChanged|cursorUpdate|appKitDefined|systemDefined|applicationDefined|periodic|leftMouseDown|leftMouseUp|rightMouseDown|rightMouseUp|otherMouseDown|otherMouseUp|scrollWheel|none>"
        }

        let parsedEvent = parseOverlayEventType(token)
        guard parsedEvent.isKnown else {
            return "ERROR: Unknown event type '\(args.trimmingCharacters(in: .whitespacesAndNewlines))'"
        }
        let eventType = parsedEvent.eventType

        var shouldCapture = false
        v2MainSync {
            let pb = NSPasteboard(name: .drag)
            shouldCapture = DragOverlayRoutingPolicy.shouldCaptureFileDropOverlay(
                pasteboardTypes: pb.types,
                eventType: eventType
            )
        }

        return shouldCapture ? "true" : "false"
    }

    private func overlayDropGate(_ args: String) -> String {
        let token = args.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hasLocalDraggingSource: Bool
        switch token {
        case "", "external":
            hasLocalDraggingSource = false
        case "local":
            hasLocalDraggingSource = true
        default:
            return "ERROR: Usage: overlay_drop_gate [external|local]"
        }

        var shouldCapture = false
        v2MainSync {
            let pb = NSPasteboard(name: .drag)
            shouldCapture = DragOverlayRoutingPolicy.shouldCaptureFileDropDestination(
                pasteboardTypes: pb.types,
                hasLocalDraggingSource: hasLocalDraggingSource
            )
        }
        return shouldCapture ? "true" : "false"
    }

    private func portalHitGate(_ args: String) -> String {
        let token = args.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !token.isEmpty else {
            return "ERROR: Usage: portal_hit_gate <leftMouseDragged|rightMouseDragged|otherMouseDragged|mouseMoved|mouseEntered|mouseExited|flagsChanged|cursorUpdate|appKitDefined|systemDefined|applicationDefined|periodic|leftMouseDown|leftMouseUp|rightMouseDown|rightMouseUp|otherMouseDown|otherMouseUp|scrollWheel|none>"
        }
        let parsedEvent = parseOverlayEventType(token)
        guard parsedEvent.isKnown else {
            return "ERROR: Unknown event type '\(args.trimmingCharacters(in: .whitespacesAndNewlines))'"
        }
        let eventType = parsedEvent.eventType

        var shouldPassThrough = false
        v2MainSync {
            let pb = NSPasteboard(name: .drag)
            shouldPassThrough = DragOverlayRoutingPolicy.shouldPassThroughTerminalPortalHitTesting(
                pasteboardTypes: pb.types,
                eventType: eventType
            )
        }
        return shouldPassThrough ? "true" : "false"
    }

    private func sidebarOverlayGate(_ args: String) -> String {
        let token = args.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hasSidebarDragState: Bool
        switch token {
        case "", "active":
            hasSidebarDragState = true
        case "inactive":
            hasSidebarDragState = false
        default:
            return "ERROR: Usage: sidebar_overlay_gate [active|inactive]"
        }

        var shouldCapture = false
        v2MainSync {
            let pb = NSPasteboard(name: .drag)
            shouldCapture = DragOverlayRoutingPolicy.shouldCaptureSidebarExternalOverlay(
                hasSidebarDragState: hasSidebarDragState,
                pasteboardTypes: pb.types
            )
        }
        return shouldCapture ? "true" : "false"
    }

    private func terminalDropOverlayProbe(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        let token = args.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let useDeferredPath: Bool
        switch token {
        case "", "deferred":
            useDeferredPath = true
        case "direct":
            useDeferredPath = false
        default:
            return "ERROR: Usage: terminal_drop_overlay_probe [deferred|direct]"
        }

        var result = "ERROR: No selected workspace"
        v2MainSync {
            guard let selectedId = tabManager.selectedTabId,
                  let workspace = tabManager.tabs.first(where: { $0.id == selectedId }) else {
                return
            }

            let terminalPanel = workspace.focusedTerminalPanel
                ?? orderedPanels(in: workspace).compactMap { $0 as? TerminalPanel }.first
            guard let terminalPanel else {
                result = "ERROR: No terminal panel available"
                return
            }

            let probe = terminalPanel.hostedView.debugProbeDropOverlayAnimation(
                useDeferredPath: useDeferredPath
            )
            let animated = probe.after > probe.before
            let mode = useDeferredPath ? "deferred" : "direct"
            result = String(
                format: "OK mode=%@ animated=%d before=%d after=%d bounds=%.1fx%.1f",
                mode,
                animated ? 1 : 0,
                probe.before,
                probe.after,
                probe.bounds.width,
                probe.bounds.height
            )
        }
        return result
    }

    private func parseOverlayEventType(_ token: String) -> (isKnown: Bool, eventType: NSEvent.EventType?) {
        switch token {
        case "leftmousedragged":
            return (true, .leftMouseDragged)
        case "rightmousedragged":
            return (true, .rightMouseDragged)
        case "othermousedragged":
            return (true, .otherMouseDragged)
        case "mousemove", "mousemoved":
            return (true, .mouseMoved)
        case "mouseentered":
            return (true, .mouseEntered)
        case "mouseexited":
            return (true, .mouseExited)
        case "flagschanged":
            return (true, .flagsChanged)
        case "cursorupdate":
            return (true, .cursorUpdate)
        case "appkitdefined":
            return (true, .appKitDefined)
        case "systemdefined":
            return (true, .systemDefined)
        case "applicationdefined":
            return (true, .applicationDefined)
        case "periodic":
            return (true, .periodic)
        case "leftmousedown":
            return (true, .leftMouseDown)
        case "leftmouseup":
            return (true, .leftMouseUp)
        case "rightmousedown":
            return (true, .rightMouseDown)
        case "rightmouseup":
            return (true, .rightMouseUp)
        case "othermousedown":
            return (true, .otherMouseDown)
        case "othermouseup":
            return (true, .otherMouseUp)
        case "scrollwheel":
            return (true, .scrollWheel)
        case "none":
            return (true, nil)
        default:
            return (false, nil)
        }
    }

    private func dragPasteboardType(from token: String) -> NSPasteboard.PasteboardType? {
        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "fileurl", "file-url", "public.file-url":
            return .fileURL
        case "tabtransfer", "tab-transfer", "com.splittabbar.tabtransfer":
            return DragOverlayRoutingPolicy.bonsplitTabTransferType
        case "sidebarreorder", "sidebar-reorder", "sidebar_tab_reorder",
            "com.cmux.sidebar-tab-reorder":
            return DragOverlayRoutingPolicy.sidebarTabReorderType
        default:
            // Allow explicit UTI strings for ad-hoc debug probes.
            guard token.contains(".") else { return nil }
            return NSPasteboard.PasteboardType(token)
        }
    }

    /// Hit-tests the file-drop overlay's coordinate-to-terminal mapping.
    /// Takes normalised (0-1) x,y within the content area where (0,0) is the
    /// top-left corner and (1,1) is the bottom-right corner.  Returns the
    /// surface UUID of the terminal under that point, or "none".
    private func dropHitTest(_ args: String) -> String {
        let parts = args.split(separator: " ").map(String.init)
        guard parts.count == 2,
              let nx = Double(parts[0]), let ny = Double(parts[1]),
              (0...1).contains(nx), (0...1).contains(ny) else {
            return "ERROR: Usage: drop_hit_test <x 0-1> <y 0-1>"
        }

        var result = "ERROR: No window"
        v2MainSync {
            guard let window = NSApp.mainWindow
                ?? NSApp.keyWindow
                ?? NSApp.windows.first(where: { win in
                    guard let raw = win.identifier?.rawValue else { return false }
                    return raw == "cmux.main" || raw.hasPrefix("cmux.main.")
                }),
                  let contentView = window.contentView,
                  let themeFrame = contentView.superview else { return }

            // Convert normalized top-left coordinates into a window point.
            let pointInTheme = NSPoint(
                x: contentView.frame.minX + (contentView.bounds.width * nx),
                y: contentView.frame.maxY - (contentView.bounds.height * ny)
            )
            let windowPoint = themeFrame.convert(pointInTheme, to: nil)

            if let overlay = objc_getAssociatedObject(window, &fileDropOverlayKey) as? FileDropOverlayView,
               let terminal = overlay.terminalUnderPoint(windowPoint),
               let surfaceId = terminal.terminalSurface?.id {
                result = surfaceId.uuidString.uppercased()
                return
            }

            result = "none"
        }
        return result
    }

    /// Return the hit-test chain at normalized (0-1) coordinates in the main window's
    /// content area. Used by regression tests to detect root-level drag destinations
    /// shadowing pane-local Bonsplit drop targets.
    private func dragHitChain(_ args: String) -> String {
        let parts = args.split(separator: " ").map(String.init)
        guard parts.count == 2,
              let nx = Double(parts[0]), let ny = Double(parts[1]),
              (0...1).contains(nx), (0...1).contains(ny) else {
            return "ERROR: Usage: drag_hit_chain <x 0-1> <y 0-1>"
        }

        var result = "ERROR: No window"
        v2MainSync {
            guard let window = NSApp.mainWindow
                ?? NSApp.keyWindow
                ?? NSApp.windows.first(where: { win in
                    guard let raw = win.identifier?.rawValue else { return false }
                    return raw == "cmux.main" || raw.hasPrefix("cmux.main.")
                }),
                  let contentView = window.contentView,
                  let themeFrame = contentView.superview else { return }

            let pointInTheme = NSPoint(
                x: contentView.frame.minX + (contentView.bounds.width * nx),
                y: contentView.frame.maxY - (contentView.bounds.height * ny)
            )

            let overlay = objc_getAssociatedObject(window, &fileDropOverlayKey) as? NSView
            if let overlay { overlay.isHidden = true }
            defer { overlay?.isHidden = false }

            guard let hit = themeFrame.hitTest(pointInTheme) else {
                result = "none"
                return
            }

            var chain: [String] = []
            var current: NSView? = hit
            var depth = 0
            while let view = current, depth < 8 {
                chain.append(debugDragHitViewDescriptor(view))
                current = view.superview
                depth += 1
            }
            result = chain.joined(separator: "->")
        }
        return result
    }

    private func debugDragHitViewDescriptor(_ view: NSView) -> String {
        let className = String(describing: type(of: view))
        let pointer = String(describing: Unmanaged.passUnretained(view).toOpaque())
        let types = view.registeredDraggedTypes
        let renderedTypes: String
        if types.isEmpty {
            renderedTypes = "-"
        } else {
            let raw = types.map(\.rawValue)
            renderedTypes = raw.count <= 4
                ? raw.joined(separator: ",")
                : raw.prefix(4).joined(separator: ",") + ",+\(raw.count - 4)"
        }
        return "\(className)@\(pointer){dragTypes=\(renderedTypes)}"
    }

    private func unescapeSocketText(_ input: String) -> String {
        var out = ""
        var escaping = false
        for ch in input {
            if escaping {
                switch ch {
                case "n":
                    out.append("\n")
                case "r":
                    out.append("\r")
                case "t":
                    out.append("\t")
                case "\\":
                    out.append("\\")
                default:
                    out.append("\\")
                    out.append(ch)
                }
                escaping = false
            } else if ch == "\\" {
                escaping = true
            } else {
                out.append(ch)
            }
        }
        if escaping {
            out.append("\\")
        }
        return out
    }

    static func responderChainContains(_ start: NSResponder?, target: NSResponder) -> Bool {
        var r = start
        var hops = 0
        while let cur = r, hops < 64 {
            if cur === target { return true }
            r = cur.nextResponder
            hops += 1
        }
        return false
    }

    func isTerminalFocused(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        let panelArg = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !panelArg.isEmpty else { return "ERROR: Usage: is_terminal_focused <panel_id|idx>" }

        var result = "false"
        v2MainSync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
                result = "false"
                return
            }

            guard let panelId = resolveSurfaceId(from: panelArg, tab: tab),
                  let terminalPanel = tab.terminalPanel(for: panelId) else {
                result = "false"
                return
            }
            result = terminalPanel.hostedView.isSurfaceViewFirstResponder() ? "true" : "false"
        }
        return result
    }

    func readTerminalText(_ args: String) -> String {
        readTerminalTextBase64(surfaceArg: args)
    }

    private struct RenderStatsResponse: Codable {
        let panelId: String
        let drawCount: Int
        let lastDrawTime: Double
        let metalDrawableCount: Int
        let metalLastDrawableTime: Double
        let presentCount: Int
        let lastPresentTime: Double
        let layerClass: String
        let layerContentsKey: String
        let inWindow: Bool
        let windowIsKey: Bool
        let windowOcclusionVisible: Bool
        let appIsActive: Bool
        let isActive: Bool
        let desiredFocus: Bool
        let isFirstResponder: Bool
    }

    func renderStats(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        let panelArg = args.trimmingCharacters(in: .whitespacesAndNewlines)

        var result = "ERROR: No tab selected"
        v2MainSync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
                return
            }

            let panelId: UUID?
            if panelArg.isEmpty {
                panelId = tab.focusedPanelId
            } else {
                panelId = resolveSurfaceId(from: panelArg, tab: tab)
            }

            guard let panelId,
                  let terminalPanel = tab.terminalPanel(for: panelId) else {
                result = "ERROR: Terminal surface not found"
                return
            }

            let stats = terminalPanel.hostedView.debugRenderStats()
            let payload = RenderStatsResponse(
                panelId: panelId.uuidString,
                drawCount: stats.drawCount,
                lastDrawTime: stats.lastDrawTime,
                metalDrawableCount: stats.metalDrawableCount,
                metalLastDrawableTime: stats.metalLastDrawableTime,
                presentCount: stats.presentCount,
                lastPresentTime: stats.lastPresentTime,
                layerClass: stats.layerClass,
                layerContentsKey: stats.layerContentsKey,
                inWindow: stats.inWindow,
                windowIsKey: stats.windowIsKey,
                windowOcclusionVisible: stats.windowOcclusionVisible,
                appIsActive: stats.appIsActive,
                isActive: stats.isActive,
                desiredFocus: stats.desiredFocus,
                isFirstResponder: stats.isFirstResponder
            )

            let encoder = JSONEncoder()
            guard let data = try? encoder.encode(payload),
                  let json = String(data: data, encoding: .utf8) else {
                result = "ERROR: Failed to encode render_stats"
                return
            }

            result = "OK \(json)"
        }

        return result
    }

    private struct ParsedShortcutCombo {
        let storedKey: String
        let keyCode: UInt16
        let modifierFlags: NSEvent.ModifierFlags
        let characters: String
        let charactersIgnoringModifiers: String
    }

    private func parseShortcutCombo(_ combo: String) -> ParsedShortcutCombo? {
        let raw = combo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }

        let parts = raw
            .split(separator: "+")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }

        var flags: NSEvent.ModifierFlags = []
        var keyToken: String?

        for part in parts {
            let lower = part.lowercased()
            switch lower {
            case "cmd", "command", "super":
                flags.insert(.command)
            case "ctrl", "control":
                flags.insert(.control)
            case "opt", "option", "alt":
                flags.insert(.option)
            case "shift":
                flags.insert(.shift)
            default:
                // Treat as the key component.
                if keyToken == nil {
                    keyToken = part
                } else {
                    // Multiple non-modifier tokens is ambiguous.
                    return nil
                }
            }
        }

        guard var keyToken else { return nil }
        keyToken = keyToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyToken.isEmpty else { return nil }

        // Normalize a few named keys.
        let storedKey: String
        let keyCode: UInt16
        let charactersIgnoringModifiers: String

        switch keyToken.lowercased() {
        case "left":
            storedKey = "←"
            keyCode = 123
            charactersIgnoringModifiers = storedKey
        case "right":
            storedKey = "→"
            keyCode = 124
            charactersIgnoringModifiers = storedKey
        case "down":
            storedKey = "↓"
            keyCode = 125
            charactersIgnoringModifiers = storedKey
        case "up":
            storedKey = "↑"
            keyCode = 126
            charactersIgnoringModifiers = storedKey
        case "enter", "return":
            storedKey = "\r"
            keyCode = UInt16(kVK_Return)
            charactersIgnoringModifiers = storedKey
        default:
            let key = keyToken.lowercased()
            guard let code = keyCodeForShortcutKey(key) else { return nil }
            storedKey = key
            keyCode = code

            // Replicate a common system behavior: Ctrl+letter yields a control character in
            // charactersIgnoringModifiers (e.g. Ctrl+H => backspace). This is important for
            // testing keyCode fallback matching.
            if flags.contains(.control),
               key.count == 1,
               let scalar = key.unicodeScalars.first,
               scalar.isASCII,
               scalar.value >= 97, scalar.value <= 122 { // a-z
                let upper = scalar.value - 32
                let controlValue = upper - 64 // 'A' => 1
                charactersIgnoringModifiers = String(UnicodeScalar(controlValue)!)
            } else {
                charactersIgnoringModifiers = storedKey
            }
        }

        // For our shortcut matcher, characters aren't important beyond exercising edge cases.
        let chars = charactersIgnoringModifiers

        return ParsedShortcutCombo(
            storedKey: storedKey,
            keyCode: keyCode,
            modifierFlags: flags,
            characters: chars,
            charactersIgnoringModifiers: charactersIgnoringModifiers
        )
    }

    private func keyCodeForShortcutKey(_ key: String) -> UInt16? {
        // Matches macOS ANSI key codes for common printable keys and a few named specials.
        switch key {
        case "a": return 0   // kVK_ANSI_A
        case "s": return 1   // kVK_ANSI_S
        case "d": return 2   // kVK_ANSI_D
        case "f": return 3   // kVK_ANSI_F
        case "h": return 4   // kVK_ANSI_H
        case "g": return 5   // kVK_ANSI_G
        case "z": return 6   // kVK_ANSI_Z
        case "x": return 7   // kVK_ANSI_X
        case "c": return 8   // kVK_ANSI_C
        case "v": return 9   // kVK_ANSI_V
        case "b": return 11  // kVK_ANSI_B
        case "q": return 12  // kVK_ANSI_Q
        case "w": return 13  // kVK_ANSI_W
        case "e": return 14  // kVK_ANSI_E
        case "r": return 15  // kVK_ANSI_R
        case "y": return 16  // kVK_ANSI_Y
        case "t": return 17  // kVK_ANSI_T
        case "1": return 18  // kVK_ANSI_1
        case "2": return 19  // kVK_ANSI_2
        case "3": return 20  // kVK_ANSI_3
        case "4": return 21  // kVK_ANSI_4
        case "6": return 22  // kVK_ANSI_6
        case "5": return 23  // kVK_ANSI_5
        case "=": return 24  // kVK_ANSI_Equal
        case "9": return 25  // kVK_ANSI_9
        case "7": return 26  // kVK_ANSI_7
        case "-": return 27  // kVK_ANSI_Minus
        case "8": return 28  // kVK_ANSI_8
        case "0": return 29  // kVK_ANSI_0
        case "]": return 30  // kVK_ANSI_RightBracket
        case "o": return 31  // kVK_ANSI_O
        case "u": return 32  // kVK_ANSI_U
        case "[": return 33  // kVK_ANSI_LeftBracket
        case "i": return 34  // kVK_ANSI_I
        case "p": return 35  // kVK_ANSI_P
        case "l": return 37  // kVK_ANSI_L
        case "j": return 38  // kVK_ANSI_J
        case "'": return 39  // kVK_ANSI_Quote
        case "k": return 40  // kVK_ANSI_K
        case ";": return 41  // kVK_ANSI_Semicolon
        case "\\": return 42 // kVK_ANSI_Backslash
        case ",": return 43  // kVK_ANSI_Comma
        case "/": return 44  // kVK_ANSI_Slash
        case "n": return 45  // kVK_ANSI_N
        case "m": return 46  // kVK_ANSI_M
        case ".": return 47  // kVK_ANSI_Period
        case "`": return 50  // kVK_ANSI_Grave
        default:
            return nil
        }
    }
#endif

    #if !DEBUG
    static func responderChainContains(_ start: NSResponder?, target: NSResponder) -> Bool {
        var responder = start
        var hops = 0
        while let current = responder, hops < 64 {
            if current === target { return true }
            responder = current.nextResponder
            hops += 1
        }
        return false
    }
    #endif

    private func listWindows() -> String {
        let summaries = v2MainSync { AppDelegate.shared?.listMainWindowSummaries() } ?? []
        guard !summaries.isEmpty else { return "No windows" }

        let lines = summaries.enumerated().map { idx, item in
            let selected = item.isKeyWindow ? "*" : " "
            let selectedWs = item.selectedWorkspaceId?.uuidString ?? "none"
            return "\(selected) \(idx): \(item.windowId.uuidString) selected_workspace=\(selectedWs) workspaces=\(item.workspaceCount)"
        }
        return lines.joined(separator: "\n")
    }

    private func currentWindow() -> String {
        guard let tabManager else { return "ERROR: TabManager not available" }
        guard let windowId = v2ResolveWindowId(tabManager: tabManager) else { return "ERROR: No active window" }
        return windowId.uuidString
    }

    private func focusWindow(_ arg: String) -> String {
        let trimmed = arg.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let windowId = UUID(uuidString: trimmed) else { return "ERROR: Invalid window id" }

        let ok = v2MainSync { AppDelegate.shared?.focusMainWindow(windowId: windowId) ?? false }
        guard ok else { return "ERROR: Window not found" }

        if let tm = v2MainSync({ AppDelegate.shared?.tabManagerFor(windowId: windowId) }) {
            setActiveTabManager(tm)
        }
        return "OK"
    }

    private func newWindow() -> String {
        guard let windowId = v2MainSync({ AppDelegate.shared?.createMainWindow() }) else {
            return "ERROR: Failed to create window"
        }
        if let tm = v2MainSync({ AppDelegate.shared?.tabManagerFor(windowId: windowId) }) {
            setActiveTabManager(tm)
        }
        return "OK \(windowId.uuidString)"
    }

    private func closeWindow(_ arg: String) -> String {
        let trimmed = arg.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let windowId = UUID(uuidString: trimmed) else { return "ERROR: Invalid window id" }
        let ok = v2MainSync { AppDelegate.shared?.closeMainWindow(windowId: windowId) ?? false }
        return ok ? "OK" : "ERROR: Window not found"
    }

    private func moveWorkspaceToWindow(_ args: String) -> String {
        let parts = args.split(separator: " ").map(String.init)
        guard parts.count >= 2 else { return "ERROR: Usage move_workspace_to_window <workspace_id> <window_id>" }
        guard let wsId = UUID(uuidString: parts[0]) else { return "ERROR: Invalid workspace id" }
        guard let windowId = UUID(uuidString: parts[1]) else { return "ERROR: Invalid window id" }

        var ok = false
        let focus = socketCommandAllowsInAppFocusMutations()
        v2MainSync {
            guard let srcTM = AppDelegate.shared?.tabManagerFor(tabId: wsId),
                  let dstTM = AppDelegate.shared?.tabManagerFor(windowId: windowId),
                  let ws = srcTM.detachWorkspace(tabId: wsId) else {
                ok = false
                return
            }
            dstTM.attachWorkspace(ws, select: focus)
            if focus {
                _ = AppDelegate.shared?.focusMainWindow(windowId: windowId)
                setActiveTabManager(dstTM)
            }
            ok = true
        }

        return ok ? "OK" : "ERROR: Move failed"
    }

    private func listWorkspaces() -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        var result: String = ""
        v2MainSync {
            let tabs = tabManager.tabs.enumerated().map { (index, tab) in
                let selected = tab.id == tabManager.selectedTabId ? "*" : " "
                return "\(selected) \(index): \(tab.id.uuidString) \(tab.title)"
            }
            result = tabs.joined(separator: "\n")
        }
        return result.isEmpty ? "No workspaces" : result
    }

    private func newWorkspace(_ args: String = "") -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        let title: String? = trimmed.isEmpty ? nil : trimmed

        var newTabId: UUID?
        let focus = socketCommandAllowsInAppFocusMutations()
        v2MainSync {
            let workspace = tabManager.addWorkspace(title: title, select: focus, eagerLoadTerminal: !focus)
            newTabId = workspace.id
        }
        return "OK \(newTabId?.uuidString ?? "unknown")"
    }

    /// v1 socket error for a left/up split directed at a mirror workspace
    /// (kept here for the still-app-side v1 `new_split`; the coordinator-side
    /// v1 `new_pane` carries the same wording via its sidebar context).
    private static let v1MirrorDirectionError =
        "ERROR: direction left/up is not supported in a remote tmux mirror workspace"

    private func newSplit(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
        guard !parts.isEmpty else {
            return "ERROR: Invalid direction. Use left, right, up, or down."
        }

        let directionArg = parts[0]
        let panelArg = parts.count > 1 ? parts[1] : ""

        guard let direction = parseSplitDirection(directionArg) else {
            return "ERROR: Invalid direction. Use left, right, up, or down."
        }

        var result = "ERROR: Failed to create split"
        v2MainSync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
                return
            }

            // If panel arg provided, resolve it; otherwise use focused panel
            let surfaceId: UUID?
            if !panelArg.isEmpty {
                surfaceId = resolveSurfaceId(from: panelArg, tab: tab)
                if surfaceId == nil {
                    result = "ERROR: Panel not found"
                    return
                }
            } else {
                surfaceId = tab.focusedPanelId
            }

            guard let targetSurface = surfaceId else {
                result = "ERROR: No surface to split"
                return
            }

            if tab.isRemoteTmuxMirror, direction.insertFirst {
                // Routed tmux `split-window` cannot insert before the target
                // pane; reject before mutating the remote session.
                result = Self.v1MirrorDirectionError
                return
            }

            switch tab.newTerminalSplitOutcome(
                from: targetSurface,
                orientation: direction.orientation,
                insertFirst: direction.insertFirst
            ) {
            case .created(let panel):
                result = "OK \(panel.id.uuidString)"
            case .routedToRemote:
                result = "OK routed-to-remote-tmux"
            case .failed:
                break
            }
        }
        return result
    }

    private func listSurfaces(_ tabArg: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }
        var result = ""
        v2MainSync {
            guard let tab = resolveTab(from: tabArg, tabManager: tabManager) else {
                result = "ERROR: Tab not found"
                return
            }
            let panels = orderedPanels(in: tab)
            let focusedId = tab.focusedPanelId
            let lines = panels.enumerated().map { index, panel in
                let selected = panel.id == focusedId ? "*" : " "
                return "\(selected) \(index): \(panel.id.uuidString)"
            }
            result = lines.isEmpty ? "No surfaces" : lines.joined(separator: "\n")
        }
        return result
    }

    private func focusSurface(_ arg: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }
        let trimmed = arg.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "ERROR: Missing panel id or index" }

        var success = false
        v2MainSync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
                return
            }

            if let uuid = UUID(uuidString: trimmed),
               tab.panels[uuid] != nil {
                guard tab.surfaceIdFromPanelId(uuid) != nil else { return }
                tabManager.focusSurface(tabId: tab.id, surfaceId: uuid)
                success = true
                return
            }

            if let index = Int(trimmed), index >= 0 {
                let panels = orderedPanels(in: tab)
                guard index < panels.count else { return }
                guard tab.surfaceIdFromPanelId(panels[index].id) != nil else { return }
                tabManager.focusSurface(tabId: tab.id, surfaceId: panels[index].id)
                success = true
            }
        }

        return success ? "OK" : "ERROR: Panel not found"
    }

    private func notifyCurrent(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        var result = "OK"
        v2MainSync {
            guard let tabId = tabManager.selectedTabId else {
                result = "ERROR: No tab selected"
                return
            }
            let surfaceId = tabManager.focusedSurfaceId(for: tabId)
            let (title, subtitle, body) = parseNotificationPayload(args)
            deliverNotificationSynchronously(
                tabId: tabId,
                surfaceId: surfaceId,
                title: title,
                subtitle: subtitle,
                body: body
            )
        }
        return result
    }

    private func notifySurface(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "ERROR: Missing surface id or index" }

        let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
        let surfaceArg = parts[0]
        let payload = parts.count > 1 ? parts[1] : ""

        var result = "OK"
        v2MainSync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
                result = "ERROR: No tab selected"
                return
            }
            guard let surfaceId = resolveSurfaceId(from: surfaceArg, tab: tab) else {
                result = "ERROR: Surface not found"
                return
            }
            let (title, subtitle, body) = parseNotificationPayload(payload)
            deliverNotificationSynchronously(
                tabId: tabId,
                surfaceId: surfaceId,
                title: title,
                subtitle: subtitle,
                body: body
            )
        }
        return result
    }

    private func notifyTarget(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "ERROR: Usage: notify_target <workspace_id> <surface_id> <title>|<subtitle>|<body>" }

        let parts = trimmed.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return "ERROR: Usage: notify_target <workspace_id> <surface_id> <title>|<subtitle>|<body>" }

        let tabArg = parts[0]
        let panelArg = parts[1]
        let payload = parts.count > 2 ? parts[2] : ""
        let (title, subtitle, body) = parseNotificationPayload(payload)

        if let workspaceId = UUID(uuidString: tabArg),
           let panelId = UUID(uuidString: panelArg) {
            var result = "OK"
            v2MainSync {
                guard let tab = self.tabForSidebarMutation(id: workspaceId) else {
                    result = "ERROR: Tab not found"
                    return
                }
                guard tab.panels[panelId] != nil else {
                    result = "ERROR: Panel not found"
                    return
                }
                deliverNotificationSynchronously(
                    tabId: workspaceId,
                    surfaceId: panelId,
                    title: title,
                    subtitle: subtitle,
                    body: body
                )
            }
            return result
        }

        var result = "OK"
        v2MainSync {
            let tab: Tab?
            if let tabId = UUID(uuidString: tabArg) {
                tab = tabForSidebarMutation(id: tabId)
            } else {
                tab = resolveTab(from: tabArg, tabManager: tabManager)
            }
            guard let tab else {
                result = "ERROR: Tab not found"
                return
            }
            guard let panelId = UUID(uuidString: panelArg),
                  tab.panels[panelId] != nil else {
                result = "ERROR: Panel not found"
                return
            }
            deliverNotificationSynchronously(
                tabId: tab.id,
                surfaceId: panelId,
                title: title,
                subtitle: subtitle,
                body: body
            )
        }
        return result
    }

    private func notifyTargetQueued(_ args: String) -> String {
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "ERROR: Usage: notify_target_async <workspace_uuid> <surface_uuid> <title>|<subtitle>|<body>"
        }

        let parts = trimmed.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count == 3 else {
            return "ERROR: Usage: notify_target_async <workspace_uuid> <surface_uuid> <title>|<subtitle>|<body>"
        }
        guard let tabId = UUID(uuidString: parts[0]) else {
            return "ERROR: notify_target_async requires workspace_uuid to be a UUID"
        }
        guard let surfaceId = UUID(uuidString: parts[1]) else {
            return "ERROR: notify_target_async requires surface_uuid to be a UUID"
        }

        let payload = parts[2].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty else {
            return "ERROR: Usage: notify_target_async <workspace_uuid> <surface_uuid> <title>|<subtitle>|<body>"
        }
        let (title, subtitle, body) = parseNotificationPayload(payload)
#if DEBUG
        cmuxDebugLog(
            "socket.notifyTargetAsync.enqueue workspace=\(tabId.uuidString.prefix(8)) surface=\(surfaceId.uuidString.prefix(8)) titleLen=\(title.count) subtitleLen=\(subtitle.count) bodyLen=\(body.count) coalesces=0"
        )
#endif
        TerminalMutationBus.shared.enqueueNotification(
            tabId: tabId,
            surfaceId: surfaceId,
            title: title,
            subtitle: subtitle,
            body: body,
            coalesces: false
        )
        return "OK"
    }

    private func listNotifications() -> String {
        var result = ""
        v2MainSync {
            let lines = TerminalNotificationStore.shared.notifications.enumerated().map { index, notification in
                let surfaceText = notification.surfaceId?.uuidString ?? "none"
                let readText = notification.isRead ? "read" : "unread"
                let createdAt = Self.notificationCreatedAtString(notification.createdAt)
                let tabTitle = Self.notificationListTrailingField(AppDelegate.shared?.tabTitle(for: notification.tabId) ?? "")
                return "\(index):\(notification.id.uuidString)|\(notification.tabId.uuidString)|\(surfaceText)|\(readText)|\(notification.title)|\(notification.subtitle)|\(notification.body)|\(createdAt)|\(tabTitle)"
            }
            result = lines.joined(separator: "\n")
        }
        return result.isEmpty ? "No notifications" : result
    }

    private func clearNotifications(_ args: String) -> String {
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            TerminalMutationBus.shared.enqueueClearAllNotifications()
            return "OK"
        }
        let parsed = parseOptions(trimmed)
        guard let tabOption = parsed.options["tab"],
              !tabOption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "ERROR: Usage: clear_notifications [--tab=X] [--panel=ID]"
        }
        let targetResolution = parseSidebarMutationTabTarget(options: parsed.options)
        guard let target = targetResolution.target else {
            return targetResolution.error ?? "ERROR: Tab not found"
        }
        let usage = "clear_notifications [--tab=X] [--panel=ID]"
        let panelResolution = parseOptionalPanelIdOption(options: parsed.options, usage: usage)
        if let error = panelResolution.error {
            return error
        }
        if case .workspace(let tabId) = target {
            if let panelId = panelResolution.panelId {
                TerminalMutationBus.shared.enqueueClearNotifications(forTabId: tabId, surfaceId: panelId)
            } else {
                TerminalMutationBus.shared.enqueueClearNotifications(forTabId: tabId)
            }
        } else {
            let clearBoundary = TerminalMutationBus.shared.markNotificationClearBoundary()
            TerminalMutationBus.shared.enqueueMainActorMutation { [weak self] in
                guard let self, let tab = self.resolveSidebarMutationTab(target) else { return }
                if let panelId = panelResolution.panelId {
                    guard tab.panels.keys.contains(panelId) else { return }
                    TerminalMutationBus.shared.discardPendingNotifications(
                        forTabId: tab.id,
                        surfaceId: panelId,
                        through: clearBoundary
                    )
                    TerminalNotificationStore.shared.clearNotifications(
                        forTabId: tab.id,
                        surfaceId: panelId,
                        discardQueuedNotifications: false
                    )
                } else {
                    TerminalMutationBus.shared.discardPendingNotifications(
                        forTabId: tab.id,
                        through: clearBoundary
                    )
                    TerminalNotificationStore.shared.clearNotifications(
                        forTabId: tab.id,
                        discardQueuedNotifications: false
                    )
                }
            }
        }
        return "OK"
    }

    private func setAppFocusOverride(_ arg: String) -> String {
        let trimmed = arg.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch trimmed {
        case "active", "1", "true":
            AppFocusState.overrideIsFocused = true
            return "OK"
        case "inactive", "0", "false":
            AppFocusState.overrideIsFocused = false
            return "OK"
        case "clear", "none", "":
            AppFocusState.overrideIsFocused = nil
            return "OK"
        default:
            return "ERROR: Expected active, inactive, or clear"
        }
    }

    private func simulateAppDidBecomeActive() -> String {
        v2MainSync {
            AppDelegate.shared?.applicationDidBecomeActive(
                Notification(name: NSApplication.didBecomeActiveNotification)
            )
        }
        return "OK"
    }

#if DEBUG
    /// Drives Sleepy Mode from the debug socket so automation can exercise the
    /// overlay. `on`/`off` force a state, `toggle` flips it, and unknown commands
    /// return an error (so e.g. `unlock` can never accidentally activate it).
    func sleepyModeCommand(_ args: String) -> String {
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
        let cmd = parts.first?.lowercased() ?? ""
        let value = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces).lowercased() : ""
        var isActive = false
        var holding = false
        var unknown = false
        v2MainSync {
            let store = SleepyModeController.shared.store
            switch cmd {
            case "on", "activate", "start":
                SleepyModeController.shared.activate()
            case "off", "deactivate", "stop", "unlock", "wake":
                SleepyModeController.shared.deactivate()
            case "preview":
                SleepyModeController.shared.preview()
            case "theme":
                if let theme = SleepyTheme.allCases.first(where: { $0.rawValue.lowercased() == value }) { store.theme = theme }
            case "mascot":
                if let mascot = SleepyMascot.allCases.first(where: { $0.rawValue.lowercased() == value }) { store.mascot = mascot }
            case "glow":
                if let glow = SleepyGlow.allCases.first(where: { $0.rawValue.lowercased() == value }) { store.glow = glow }
            case "toggle":
                // No scene name: flip Sleepy Mode itself. A scene name flips that toggle.
                switch value {
                case "": SleepyModeController.shared.toggle()
                case "moon": store.showMoon.toggle()
                case "stars": store.showStars.toggle()
                case "zs", "z": store.showZs.toggle()
                case "clock": store.showClock.toggle()
                case "status": store.showStatus.toggle()
                case "pets": store.showPets.toggle()
                default: unknown = true
                }
            case "customcolor":
                let fields = value.split(separator: " ").map(String.init)
                if fields.count == 2 {
                    let hex = fields[1].uppercased()
                    switch fields[0] {
                    case "face": store.customFace = hex
                    case "cap": store.customCap = hex
                    case "blush": store.customBlush = hex
                    case "eyes", "ink": store.customInk = hex
                    case "logo": store.customLogo = hex
                    case "bg", "background": store.customBackground = hex
                    default: break
                    }
                }
            case "pets":
                if value == "clear" {
                    SleepyModeController.shared.agentCensus.debugOverride = nil
                } else {
                    let n = value.split(separator: " ").map { Int($0) ?? 0 }
                    SleepyModeController.shared.agentCensus.debugOverride = SleepyAgentCounts(
                        claude: n.count > 0 ? n[0] : 0,
                        codex: n.count > 1 ? n[1] : 0,
                        opencode: n.count > 2 ? n[2] : 0,
                        pi: n.count > 3 ? n[3] : 0
                    )
                }
            default:
                unknown = true
            }
            isActive = SleepyModeController.shared.isActive
            holding = SleepyModeController.shared.isHoldingPowerAssertions
        }
        if unknown {
            return "ERROR: unknown sleepy_mode command '\(cmd)' (use on/off/toggle/preview/unlock/theme/mascot/glow/pets/customcolor)"
        }
        return "OK \(isActive ? "active" : "inactive") assertions=\(holding)"
    }

    func focusFromNotification(_ args: String) -> String {
        guard let tabManager else { return "ERROR: TabManager not available" }
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
        let tabArg = parts.first ?? ""
        let surfaceArg = parts.count > 1 ? parts[1] : ""

        var result = "OK"
        v2MainSync {
            guard let tab = resolveTab(from: tabArg, tabManager: tabManager) else {
                result = "ERROR: Tab not found"
                return
            }
            let surfaceId = surfaceArg.isEmpty ? nil : resolveSurfaceId(from: surfaceArg, tab: tab)
            if !surfaceArg.isEmpty && surfaceId == nil {
                result = "ERROR: Surface not found"
                return
            }
            if !tabManager.focusTabFromNotification(tab.id, surfaceId: surfaceId) {
                result = "ERROR: Focus failed"
            }
        }
        return result
    }

    func flashCount(_ args: String) -> String {
        guard let tabManager else { return "ERROR: TabManager not available" }
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "ERROR: Missing surface id or index" }

        var result = "ERROR: Surface not found"
        v2MainSync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
                result = "ERROR: No tab selected"
                return
            }
            guard let surfaceId = resolveSurfaceId(from: trimmed, tab: tab) else {
                result = "ERROR: Surface not found"
                return
            }
            let count = GhosttySurfaceScrollView.flashCount(for: surfaceId)
            result = "OK \(count)"
        }
        return result
    }

    func resetFlashCounts() -> String {
        v2MainSync {
            GhosttySurfaceScrollView.resetFlashCounts()
        }
        return "OK"
    }

#if DEBUG
    private struct PanelSnapshotState: Sendable {
        let width: Int
        let height: Int
        let bytesPerRow: Int
        let rgba: Data
    }

    /// Most tests run single-threaded but socket handlers can be invoked concurrently.
    /// Keep snapshot bookkeeping simple and thread-safe.
    private static let panelSnapshotLock = NSLock()
    private static var panelSnapshots: [UUID: PanelSnapshotState] = [:]

    func panelSnapshotReset(_ args: String) -> String {
        guard let tabManager else { return "ERROR: TabManager not available" }
        let panelArg = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !panelArg.isEmpty else { return "ERROR: Usage: panel_snapshot_reset <panel_id|idx>" }

        var result = "ERROR: No tab selected"
        v2MainSync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
                return
            }
            guard let panelId = resolveSurfaceId(from: panelArg, tab: tab) else {
                result = "ERROR: Surface not found"
                return
            }
            Self.panelSnapshotLock.lock()
            Self.panelSnapshots.removeValue(forKey: panelId)
            Self.panelSnapshotLock.unlock()
            result = "OK"
        }

        return result
    }

    private static func makePanelSnapshot(from cgImage: CGImage) -> PanelSnapshotState? {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var data = Data(count: bytesPerRow * height)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        let ok: Bool = data.withUnsafeMutableBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return false }
            guard let ctx = CGContext(
                data: base,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else { return false }
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { return nil }

        return PanelSnapshotState(width: width, height: height, bytesPerRow: bytesPerRow, rgba: data)
    }

    private static func countChangedPixels(previous: PanelSnapshotState, current: PanelSnapshotState) -> Int {
        // Any mismatch means we can't sensibly diff; treat as a fresh snapshot.
        guard previous.width == current.width,
              previous.height == current.height,
              previous.bytesPerRow == current.bytesPerRow else {
            return -1
        }

        let threshold = 8 // ignore tiny per-channel jitter
        var changed = 0

        previous.rgba.withUnsafeBytes { prevRaw in
            current.rgba.withUnsafeBytes { curRaw in
                guard let prev = prevRaw.bindMemory(to: UInt8.self).baseAddress,
                      let cur = curRaw.bindMemory(to: UInt8.self).baseAddress else {
                    return
                }

                let count = min(prevRaw.count, curRaw.count)
                var i = 0
                while i + 3 < count {
                    let dr = abs(Int(prev[i]) - Int(cur[i]))
                    let dg = abs(Int(prev[i + 1]) - Int(cur[i + 1]))
                    let db = abs(Int(prev[i + 2]) - Int(cur[i + 2]))
                    // Skip alpha channel at i+3.
                    if dr + dg + db > threshold {
                        changed += 1
                    }
                    i += 4
                }
            }
        }

        return changed
    }

    func panelSnapshot(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "ERROR: Usage: panel_snapshot <panel_id|idx> [label]" }

        let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
        let panelArg = parts.first ?? ""
        let label = parts.count > 1 ? parts[1] : ""

        // Generate unique ID for this snapshot/screenshot
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "+", with: "_")
        let shortId = UUID().uuidString.prefix(8)
        let snapshotId = "\(timestamp)_\(shortId)"

        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-screenshots")
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let filename = label.isEmpty ? "\(snapshotId).png" : "\(label)_\(snapshotId).png"
        let outputPath = outputDir.appendingPathComponent(filename)

        var result = "ERROR: No tab selected"
        v2MainSync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
                return
            }

            guard let panelId = resolveSurfaceId(from: panelArg, tab: tab),
                  let terminalPanel = tab.terminalPanel(for: panelId) else {
                result = "ERROR: Terminal surface not found"
                return
            }

            // Capture the terminal's IOSurface directly, avoiding Screen Recording permissions.
            let view = terminalPanel.hostedView
            var cgImage = view.debugCopyIOSurfaceCGImage()
            if cgImage == nil {
                // If the surface is mid-attach we may not have contents yet. Nudge a draw and retry once.
                terminalPanel.surface.forceRefresh(reason: "terminalController.debugCopyIOSurfaceRetry")
                cgImage = view.debugCopyIOSurfaceCGImage()
            }
            guard let cgImage else {
                result = "ERROR: Failed to capture panel image"
                return
            }

            guard let current = Self.makePanelSnapshot(from: cgImage) else {
                result = "ERROR: Failed to read panel pixels"
                return
            }

            var changedPixels = -1
            Self.panelSnapshotLock.lock()
            if let previous = Self.panelSnapshots[panelId] {
                changedPixels = Self.countChangedPixels(previous: previous, current: current)
            }
            Self.panelSnapshots[panelId] = current
            Self.panelSnapshotLock.unlock()

            // Save PNG for postmortem debugging.
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
                result = "ERROR: Failed to encode PNG"
                return
            }

            do {
                try pngData.write(to: outputPath)
            } catch {
                result = "ERROR: Failed to write file: \(error.localizedDescription)"
                return
            }

            result = "OK \(panelId.uuidString) \(changedPixels) \(current.width) \(current.height) \(outputPath.path)"
        }

        return result
    }
#endif

    private struct LayoutDebugSelectedPanel: Codable, Sendable {
        let paneId: String
        let paneFrame: PixelRect?
        let selectedTabId: String?
        let panelId: String?
        let panelType: String?
        let inWindow: Bool?
        let hidden: Bool?
        let viewFrame: PixelRect?
        let splitViews: [LayoutDebugSplitView]?
    }

    private struct LayoutDebugSplitView: Codable, Sendable {
        let isVertical: Bool
        let dividerThickness: Double
        let bounds: PixelRect
        let frame: PixelRect?
        let arrangedSubviewFrames: [PixelRect]
        let normalizedDividerPosition: Double?
    }

    private struct LayoutDebugResponse: Codable, Sendable {
        let layout: LayoutSnapshot
        let selectedPanels: [LayoutDebugSelectedPanel]
        let mainWindowNumber: Int?
        let keyWindowNumber: Int?
    }

    func layoutDebug() -> String {
        guard let tabManager else { return "ERROR: TabManager not available" }

        var result = "ERROR: No tab selected"
        v2MainSync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
                return
            }

            let layout = tab.bonsplitController.layoutSnapshot()
            var paneFrames: [String: PixelRect] = [:]
            for pane in layout.panes {
                paneFrames[pane.paneId] = pane.frame
            }

            @MainActor
            func isHiddenOrAncestorHidden(_ view: NSView) -> Bool {
                if view.isHidden { return true }
                var current = view.superview
                while let v = current {
                    if v.isHidden { return true }
                    current = v.superview
                }
                return false
            }

            @MainActor
            func windowFrame(for view: NSView) -> CGRect? {
                guard view.window != nil else { return nil }
                // Prefer the view's frame as laid out by its superview. Some AppKit views
                // (notably scroll views) can temporarily report stale bounds during reparenting.
                if let superview = view.superview {
                    return superview.convert(view.frame, to: nil)
                }
                return view.convert(view.bounds, to: nil)
            }

            @MainActor
            func splitViewInfos(for view: NSView) -> [LayoutDebugSplitView] {
                var infos: [LayoutDebugSplitView] = []
                var current: NSView? = view
                var depth = 0
                while let v = current, depth < 12 {
                    if let sv = v as? NSSplitView {
                        // The split view can be mid-update during bonsplit structural changes; force a layout
                        // pass so our debug snapshot reflects the real state.
                        sv.layoutSubtreeIfNeeded()
                        let isVertical = sv.isVertical
                        let dividerThickness = Double(sv.dividerThickness)
                        let bounds = PixelRect(from: sv.bounds)
                        let frame = windowFrame(for: sv).map { PixelRect(from: $0) }
                        let arranged = sv.arrangedSubviews
                        let arrangedFrames = arranged.compactMap { windowFrame(for: $0).map { PixelRect(from: $0) } }

                        // Approximate divider position from the first arranged subview's size.
                        let totalSize: CGFloat = isVertical ? sv.bounds.width : sv.bounds.height
                        let availableSize = max(totalSize - sv.dividerThickness, 0)
                        var normalized: Double? = nil
                        if availableSize > 0, let first = arranged.first {
                            let dividerPos = isVertical ? first.frame.width : first.frame.height
                            normalized = Double(dividerPos / availableSize)
                        }

                        infos.append(LayoutDebugSplitView(
                            isVertical: isVertical,
                            dividerThickness: dividerThickness,
                            bounds: bounds,
                            frame: frame,
                            arrangedSubviewFrames: arrangedFrames,
                            normalizedDividerPosition: normalized
                        ))
                    }
                    current = v.superview
                    depth += 1
                }
                return infos
            }

            let selectedPanels: [LayoutDebugSelectedPanel] = tab.bonsplitController.allPaneIds.map { paneId in
                let paneIdStr = paneId.id.uuidString
                let paneFrame = paneFrames[paneIdStr]
                let selectedTabId = layout.panes.first(where: { $0.paneId == paneIdStr })?.selectedTabId

	                guard let selectedTab = tab.bonsplitController.selectedTab(inPane: paneId) else {
	                    return LayoutDebugSelectedPanel(
	                        paneId: paneIdStr,
	                        paneFrame: paneFrame,
	                        selectedTabId: selectedTabId,
	                        panelId: nil,
	                        panelType: nil,
	                        inWindow: nil,
	                        hidden: nil,
	                        viewFrame: nil,
	                        splitViews: nil
	                    )
	                }

	                guard let panelId = tab.panelIdFromSurfaceId(selectedTab.id),
	                      let panel = tab.panels[panelId] else {
	                    return LayoutDebugSelectedPanel(
	                        paneId: paneIdStr,
	                        paneFrame: paneFrame,
	                        selectedTabId: selectedTabId,
	                        panelId: nil,
	                        panelType: nil,
	                        inWindow: nil,
	                        hidden: nil,
	                        viewFrame: nil,
	                        splitViews: nil
	                    )
	                }

                if let tp = panel as? TerminalPanel {
                    let viewRect = windowFrame(for: tp.hostedView).map { PixelRect(from: $0) }
                    let splitViews = splitViewInfos(for: tp.hostedView)
		                    return LayoutDebugSelectedPanel(
	                        paneId: paneIdStr,
	                        paneFrame: paneFrame,
	                        selectedTabId: selectedTabId,
	                        panelId: panelId.uuidString,
	                        panelType: tp.panelType.rawValue,
	                        inWindow: tp.surface.isViewInWindow,
	                        hidden: isHiddenOrAncestorHidden(tp.hostedView),
	                        viewFrame: viewRect,
	                        splitViews: splitViews
	                    )
	                }

                if let bp = panel as? BrowserPanel {
                    let viewRect = windowFrame(for: bp.webView).map { PixelRect(from: $0) }
                    let splitViews = splitViewInfos(for: bp.webView)
		                    return LayoutDebugSelectedPanel(
	                        paneId: paneIdStr,
	                        paneFrame: paneFrame,
	                        selectedTabId: selectedTabId,
	                        panelId: panelId.uuidString,
	                        panelType: bp.panelType.rawValue,
	                        inWindow: bp.webView.window != nil,
	                        hidden: isHiddenOrAncestorHidden(bp.webView),
	                        viewFrame: viewRect,
	                        splitViews: splitViews
	                    )
	                }

	                return LayoutDebugSelectedPanel(
	                    paneId: paneIdStr,
	                    paneFrame: paneFrame,
	                    selectedTabId: selectedTabId,
	                    panelId: panelId.uuidString,
	                    panelType: panel.panelType.rawValue,
	                    inWindow: nil,
	                    hidden: nil,
	                    viewFrame: nil,
	                    splitViews: nil
	                )
	            }

            let payload = LayoutDebugResponse(
                layout: layout,
                selectedPanels: selectedPanels,
                mainWindowNumber: NSApp.mainWindow?.windowNumber,
                keyWindowNumber: NSApp.keyWindow?.windowNumber
            )

            let encoder = JSONEncoder()
            guard let data = try? encoder.encode(payload),
                  let json = String(data: data, encoding: .utf8) else {
                result = "ERROR: Failed to encode layout_debug"
                return
            }

            result = "OK \(json)"
        }
        return result
    }

    func emptyPanelCount() -> String {
        var result = "OK 0"
        v2MainSync {
            result = "OK \(DebugUIEventCounters.emptyPanelAppearCount)"
        }
        return result
    }

    func resetEmptyPanelCount() -> String {
        v2MainSync {
            DebugUIEventCounters.resetEmptyPanelAppearCount()
        }
        return "OK"
    }

    func bonsplitUnderflowCount() -> String {
        var result = "OK 0"
        v2MainSync {
#if DEBUG
            result = "OK \(BonsplitDebugCounters.arrangedSubviewUnderflowCount)"
#else
            result = "OK 0"
#endif
        }
        return result
    }

    func resetBonsplitUnderflowCount() -> String {
        v2MainSync {
#if DEBUG
            BonsplitDebugCounters.reset()
#endif
        }
        return "OK"
    }

    func captureScreenshot(_ args: String) -> String {
        // Parse optional label from args
        let label = args.trimmingCharacters(in: .whitespacesAndNewlines)

        // Generate unique ID for this screenshot
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "+", with: "_")
        let shortId = UUID().uuidString.prefix(8)
        let screenshotId = "\(timestamp)_\(shortId)"

        // Determine output path
        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-screenshots")
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let filename = label.isEmpty ? "\(screenshotId).png" : "\(label)_\(screenshotId).png"
        let outputPath = outputDir.appendingPathComponent(filename)

        // Capture the main window on main thread
        var captureError: String?
        v2MainSync {
            let candidateWindows = NSApp.windows.filter { window in
                window.isVisible &&
                !window.isMiniaturized &&
                window.contentView != nil &&
                !window.frame.isEmpty
            }
            let preferredWindow = [NSApp.keyWindow, NSApp.mainWindow]
                .compactMap { $0 }
                .first { candidateWindows.contains($0) }
            let window = preferredWindow ?? candidateWindows.max { lhs, rhs in
                (lhs.frame.width * lhs.frame.height) < (rhs.frame.width * rhs.frame.height)
            } ?? NSApp.mainWindow ?? NSApp.windows.first

            guard let window else {
                captureError = "No window available"
                return
            }

            guard let pngData = self.captureCompositedWindowPNGData(window)
                ?? self.captureAppKitWindowPNGData(window) else {
                captureError = "Failed to create PNG data"
                return
            }

            do {
                try pngData.write(to: outputPath)
            } catch {
                captureError = "Failed to write file: \(error.localizedDescription)"
            }
        }

        if let error = captureError {
            return "ERROR: \(error)"
        }

        // Return OK with screenshot ID and path for easy reference
        return "OK \(screenshotId) \(outputPath.path)"
    }

    private func captureCompositedWindowPNGData(_ window: NSWindow) -> Data? {
        guard let cgImage = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            CGWindowID(window.windowNumber),
            [.boundsIgnoreFraming, .nominalResolution]
        ) else {
            return nil
        }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }

    private func captureAppKitWindowPNGData(_ window: NSWindow) -> Data? {
        guard let contentView = window.contentView else {
            return nil
        }

        let bounds = contentView.bounds
        guard !bounds.isEmpty,
              let bitmap = contentView.bitmapImageRepForCachingDisplay(in: bounds) else {
            return nil
        }
        bitmap.size = bounds.size

        contentView.displayIfNeeded()
        contentView.cacheDisplay(in: bounds, to: bitmap)

        return bitmap.representation(using: .png, properties: [:])
    }
#endif

    func parseSplitDirection(_ value: String) -> SplitDirection? {
        switch value.lowercased() {
        case "left", "l":
            return .left
        case "right", "r":
            return .right
        case "up", "u":
            return .up
        case "down", "d":
            return .down
        default:
            return nil
        }
    }

    private func resolveTab(from arg: String, tabManager: TabManager) -> Tab? {
        let trimmed = arg.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            guard let selected = tabManager.selectedTabId else { return nil }
            return tabManager.tabs.first(where: { $0.id == selected })
        }

        if let uuid = UUID(uuidString: trimmed) {
            return tabManager.tabs.first(where: { $0.id == uuid })
        }

        if let index = Int(trimmed), index >= 0, index < tabManager.tabs.count {
            return tabManager.tabs[index]
        }

        return nil
    }

    func orderedPanels(in tab: Workspace) -> [any Panel] {
        // Single source of truth for spatial (left-to-right, top-to-bottom) panel
        // order lives on `Workspace.orderedPanelIds`, derived from bonsplit's tab
        // ordering. This avoids relying on Dictionary iteration order and keeps the
        // serializer, the reorder gate, and the mobile observer hash consistent.
        tab.orderedPanelIds.compactMap { tab.panels[$0] }
    }

    func resolveTerminalPanel(from arg: String, tabManager: TabManager) -> TerminalPanel? {
        guard let tabId = tabManager.selectedTabId,
              let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
            return nil
        }

        if let uuid = UUID(uuidString: arg) {
            return tab.terminalPanel(for: uuid)
        }

        if let index = Int(arg), index >= 0 {
            let panels = orderedPanels(in: tab)
            guard index < panels.count else { return nil }
            return panels[index] as? TerminalPanel
        }

        return nil
    }

    private func resolveSurfaceId(from arg: String, tab: Workspace) -> UUID? {
        if let uuid = UUID(uuidString: arg), tab.panels[uuid] != nil {
            return uuid
        }

        if let index = Int(arg), index >= 0 {
            let panels = orderedPanels(in: tab)
            guard index < panels.count else { return nil }
            return panels[index].id
        }

        return nil
    }

    private func parseNotificationPayload(_ args: String) -> (String, String, String) {
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ("Notification", "", "") }
        let parts = trimmed.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        let title = parts.count > 0 ? parts[0].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let subtitle = parts.count > 2 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let body = parts.count > 2
            ? parts[2].trimmingCharacters(in: .whitespacesAndNewlines)
            : (parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : "")
        return (title.isEmpty ? "Notification" : title, subtitle, body)
    }

    private func closeWorkspace(_ tabId: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }
        guard let uuid = UUID(uuidString: tabId) else { return "ERROR: Invalid tab ID" }

        var result = "ERROR: Tab not found"
        v2MainSync {
            if let tab = tabManager.tabs.first(where: { $0.id == uuid }) {
                guard tabManager.canCloseWorkspace(tab) else {
                    result = "ERROR: \(workspaceCloseProtectedMessage())"
                    return
                }
                tabManager.closeTab(tab)
                result = "OK"
            }
        }
        return result
    }

    private func selectWorkspace(_ arg: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        var success = false
        v2MainSync {
            // Try as UUID first
            if let uuid = UUID(uuidString: arg) {
                if let tab = tabManager.tabs.first(where: { $0.id == uuid }) {
                    tabManager.selectTab(tab)
                    success = true
                }
            }
            // Try as index
            else if let index = Int(arg), index >= 0, index < tabManager.tabs.count {
                tabManager.selectTab(at: index)
                success = true
            }
        }
        return success ? "OK" : "ERROR: Tab not found"
    }

    private func currentWorkspace() -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        var result: String = ""
        v2MainSync {
            if let id = tabManager.selectedTabId {
                result = id.uuidString
            }
        }
        return result.isEmpty ? "ERROR: No tab selected" : result
    }

    private func sendInput(_ text: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        var success = false
        var error: String?
        v2MainSync {
            guard let selectedId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == selectedId }),
                  let terminalPanel = tab.focusedTerminalPanel else {
                error = "ERROR: No focused terminal"
                return
            }

            // Unescape common escape sequences
            // Note: \n is converted to \r for terminal (Enter key sends \r)
            let unescaped = text
                .replacingOccurrences(of: "\\n", with: "\r")
                .replacingOccurrences(of: "\\r", with: "\r")
                .replacingOccurrences(of: "\\t", with: "\t")

            switch terminalPanel.sendInputResult(unescaped) {
            case .sent:
                terminalPanel.surface.forceRefresh(reason: "terminalController.sendInput")
                success = true
            case .queued:
                success = true
            case .inputQueueFull:
                error = Self.terminalInputQueueFullSocketError
                return
            case .surfaceUnavailable:
                error = Self.terminalSurfaceUnavailableSocketError
                return
            case .processExited:
                error = Self.terminalProcessExitedSocketError
                return
            }
        }
        if let error { return error }
        return success ? "OK" : "ERROR: Failed to send input"
    }

    private func sendInputToWorkspace(_ args: String) -> String {
        guard let tabManager else { return "ERROR: TabManager not available" }
        let parts = args.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return "ERROR: Usage: send_workspace <workspace_id> <text>" }

        let workspaceArg = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let text = parts[1]
        guard let workspaceId = UUID(uuidString: workspaceArg) else {
            return "ERROR: Invalid workspace ID"
        }

        var success = false
        var error: String?
        v2MainSync {
            guard let targetManager = AppDelegate.shared?.tabManagerFor(tabId: workspaceId)
                ?? (tabManager.tabs.contains(where: { $0.id == workspaceId }) ? tabManager : nil) else {
                error = "ERROR: Workspace not found"
                return
            }
            guard let tab = targetManager.tabs.first(where: { $0.id == workspaceId }) else {
                error = "ERROR: Workspace not found"
                return
            }

            guard let terminalPanel = sendableWorkspaceTerminalPanel(in: tab) else {
                error = "ERROR: No selected terminal in workspace"
                return
            }

            let unescaped = text
                .replacingOccurrences(of: "\\n", with: "\r")
                .replacingOccurrences(of: "\\r", with: "\r")
                .replacingOccurrences(of: "\\t", with: "\t")

            switch terminalPanel.sendInputResult(unescaped) {
            case .sent:
                terminalPanel.surface.forceRefresh(reason: "terminalController.sendWorkspace")
                success = true
            case .queued:
                success = true
            case .inputQueueFull:
                error = Self.terminalInputQueueFullSocketError
                return
            case .surfaceUnavailable:
                error = Self.terminalSurfaceUnavailableSocketError
                return
            case .processExited:
                error = Self.terminalProcessExitedSocketError
                return
            }
        }

        if let error { return error }
        return success ? "OK" : "ERROR: Failed to send input"
    }

    private func sendableWorkspaceTerminalPanel(in workspace: Workspace) -> TerminalPanel? {
        func selectedTerminalPanel(in paneId: PaneID) -> TerminalPanel? {
            guard let selectedTab = workspace.bonsplitController.selectedTab(inPane: paneId),
                  let panelId = workspace.panelIdFromSurfaceId(selectedTab.id),
                  let terminalPanel = workspace.panels[panelId] as? TerminalPanel else {
                return nil
            }
            return terminalPanel
        }

        func isSelectedTerminalPanel(_ terminalPanel: TerminalPanel) -> Bool {
            guard let surfaceId = workspace.surfaceIdFromPanelId(terminalPanel.id) else {
                return false
            }
            return workspace.bonsplitController.allPaneIds.contains { paneId in
                workspace.bonsplitController.selectedTab(inPane: paneId)?.id == surfaceId
            }
        }

        if let focusedPane = workspace.bonsplitController.focusedPaneId,
           let terminalPanel = selectedTerminalPanel(in: focusedPane) {
            return terminalPanel
        }

        if let rememberedTerminal = workspace.lastRememberedTerminalPanelForConfigInheritance(),
           isSelectedTerminalPanel(rememberedTerminal) {
            return rememberedTerminal
        }

        for paneId in workspace.bonsplitController.allPaneIds {
            if let terminalPanel = selectedTerminalPanel(in: paneId) {
                return terminalPanel
            }
        }

        return nil
    }

    private func sendInputToSurface(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }
        let parts = args.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return "ERROR: Usage: send_surface <id|idx> <text>" }

        let target = parts[0]
        let text = parts[1]

        var success = false
        var error: String?
        v2MainSync {
            guard let terminalPanel = resolveTerminalPanel(from: target, tabManager: tabManager) else {
                error = "ERROR: Surface not found"
                return
            }
            let unescaped = text
                .replacingOccurrences(of: "\\n", with: "\r")
                .replacingOccurrences(of: "\\r", with: "\r")
                .replacingOccurrences(of: "\\t", with: "\t")

            switch terminalPanel.sendInputResult(unescaped) {
            case .sent:
                terminalPanel.surface.forceRefresh(reason: "terminalController.sendSurface")
                success = true
            case .queued:
                success = true
            case .inputQueueFull:
                error = Self.terminalInputQueueFullSocketError
                return
            case .surfaceUnavailable:
                error = Self.terminalSurfaceUnavailableSocketError
                return
            case .processExited:
                error = Self.terminalProcessExitedSocketError
                return
            }
        }

        if let error { return error }
        return success ? "OK" : "ERROR: Failed to send input"
    }

    private func sendKey(_ keyName: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        var success = false
        var error: String?
        v2MainSync {
            guard let selectedId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == selectedId }),
                  let terminalPanel = tab.focusedTerminalPanel else {
                error = "ERROR: No focused terminal"
                return
            }

            switch terminalPanel.sendNamedKeyResult(keyName) {
            case .sent:
                terminalPanel.surface.forceRefresh(reason: "terminalController.sendKey")
                success = true
            case .queued:
                success = true
            case .unknownKey:
                error = "ERROR: Unknown key '\(keyName)'"
            case .inputQueueFull:
                error = Self.terminalInputQueueFullSocketError
            case .surfaceUnavailable:
                error = Self.terminalSurfaceUnavailableSocketError
            case .processExited:
                error = Self.terminalProcessExitedSocketError
            }
        }
        if let error { return error }
        return success ? "OK" : "ERROR: Failed to send key"
    }

    private func sendKeyToSurface(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }
        let parts = args.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return "ERROR: Usage: send_key_surface <id|idx> <key>" }

        let target = parts[0]
        let keyName = parts[1]

        var success = false
        var error: String?
        v2MainSync {
            guard let terminalPanel = resolveTerminalPanel(from: target, tabManager: tabManager) else {
                error = "ERROR: Surface not found"
                return
            }
            switch terminalPanel.sendNamedKeyResult(keyName) {
            case .sent:
                terminalPanel.surface.forceRefresh(reason: "terminalController.sendKeyToSurface")
                success = true
            case .queued:
                success = true
            case .unknownKey:
                error = "ERROR: Unknown key '\(keyName)'"
            case .inputQueueFull:
                error = Self.terminalInputQueueFullSocketError
            case .surfaceUnavailable:
                error = Self.terminalSurfaceUnavailableSocketError
            case .processExited:
                error = Self.terminalProcessExitedSocketError
            }
        }

        if let error { return error }
        return success ? "OK" : "ERROR: Failed to send key"
    }

    // MARK: - Browser Panel Commands

    // MARK: - Bonsplit Pane Commands

    // MARK: - Option Parsing (sidebar metadata commands)

    private nonisolated static func tokenizeArgs(_ args: String) -> [String] {
        SidebarMetadataArgumentParser().tokenize(args)
    }

    private func parseOptions(_ args: String) -> (positional: [String], options: [String: String]) {
        sidebarMetadataArgumentParser.parseOptions(args)
    }

    private func parseOptionsNoStop(_ args: String) -> (positional: [String], options: [String: String]) {
        sidebarMetadataArgumentParser.parseOptionsNoStop(args)
    }

    private func resolveTabForReport(_ args: String) -> Tab? {
        let parsed = parseOptions(args)
        if let tabArg = parsed.options["tab"], !tabArg.isEmpty {
            // First try the local tabManager if available
            if let tabManager = self.tabManager,
               let tab = resolveTab(from: tabArg, tabManager: tabManager) {
                return tab
            }
            // The tab may belong to a different window — search all contexts.
            if let uuid = UUID(uuidString: tabArg.trimmingCharacters(in: .whitespacesAndNewlines)),
               let otherManager = AppDelegate.shared?.tabManagerFor(tabId: uuid) {
                return otherManager.tabs.first(where: { $0.id == uuid })
            }
            return nil
        }
        // Only require self.tabManager when using the selected tab (no --tab arg)
        guard let tabManager = self.tabManager else { return nil }
        guard let selectedId = tabManager.selectedTabId else { return nil }
        return tabManager.tabs.first(where: { $0.id == selectedId })
    }

    private func parseSidebarMutationTabTarget(
        options: [String: String]
    ) -> (target: SidebarMutationTabTarget?, error: String?) {
        // `SidebarMetadataArgumentParser.parseMutationTabTarget` already returns the
        // `CmuxSidebar.SidebarMutationTabTarget` cases this controller resolves, so
        // forward the parsed target verbatim instead of re-mapping it case-for-case
        // onto a duplicate local enum.
        let resolution = sidebarMetadataArgumentParser.parseMutationTabTarget(options: options)
        return (resolution.target, resolution.error)
    }

    private func resolveSidebarMutationTab(_ target: SidebarMutationTabTarget) -> Tab? {
        switch target {
        case .selected:
            guard let tabManager = self.tabManager,
                  let selectedId = tabManager.selectedTabId else {
                return nil
            }
            return tabManager.tabs.first(where: { $0.id == selectedId })
        case .workspace(let tabId):
            return tabForSidebarMutation(id: tabId)
        case .index(let index):
            guard let tabManager = self.tabManager,
                  index < tabManager.tabs.count else {
                return nil
            }
            return tabManager.tabs[index]
        }
    }

    private func tabForSidebarMutation(id: UUID) -> Tab? {
        if let tab = tabManager?.tabs.first(where: { $0.id == id }) {
            return tab
        }
        if let otherManager = AppDelegate.shared?.tabManagerFor(tabId: id) {
            return otherManager.tabs.first(where: { $0.id == id })
        }
        return nil
    }

    private func parseSidebarMetadataFormat(_ raw: String) -> SidebarMetadataFormat? {
        sidebarMetadataArgumentParser.parseMetadataFormat(raw)
    }

    private func normalizedOptionValue(_ value: String?) -> String? {
        sidebarMetadataArgumentParser.normalizedOptionValue(value)
    }

    private func parseOptionalPanelIdOption(
        options: [String: String],
        usage: String
    ) -> (panelId: UUID?, error: String?) {
        let result = sidebarMetadataArgumentParser.parseOptionalPanelId(options: options, usage: usage)
        return (result.panelId, result.error)
    }

    private func scheduleSidebarMutation(
        target: SidebarMutationTabTarget,
        mutation: @escaping (TerminalController, Tab) -> Void
    ) {
        TerminalMutationBus.shared.enqueueMainActorMutation { [weak self] in
            guard let self, let tab = self.resolveSidebarMutationTab(target) else { return }
            mutation(self, tab)
        }
    }

    private func schedulePanelMetadataMutation(
        args: String,
        options: [String: String],
        missingPanelUsage: String,
        mutation: @escaping (Tab, UUID) -> Void
    ) -> String {
        let rawPanelArg = options["panel"] ?? options["surface"]
        let surfaceIdFromOptions: UUID?
        if let rawPanelArg {
            if rawPanelArg.isEmpty {
                return "ERROR: Missing panel id — usage: \(missingPanelUsage)"
            }
            guard let surfaceId = UUID(uuidString: rawPanelArg) else {
                return "ERROR: Invalid panel id '\(rawPanelArg)'"
            }
            surfaceIdFromOptions = surfaceId
        } else {
            surfaceIdFromOptions = nil
        }

        if let tabArg = options["tab"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !tabArg.isEmpty,
           UUID(uuidString: tabArg) == nil,
           Int(tabArg) == nil {
            return "ERROR: Tab not found"
        }

        if let scope = Self.explicitSocketScope(options: options) {
            TerminalMutationBus.shared.enqueueMainActorMutation { [weak self] in
                guard let self,
                      let tab = self.tabForSidebarMutation(id: scope.workspaceId) else {
                    return
                }
                let validSurfaceIds = Set(tab.panels.keys)
                tab.pruneSurfaceMetadata(validSurfaceIds: validSurfaceIds)
                guard validSurfaceIds.contains(scope.panelId) else { return }
                mutation(tab, scope.panelId)
            }
            return "OK"
        }

        TerminalMutationBus.shared.enqueueMainActorMutation { [weak self] in
            guard let self,
                  let tab = self.resolveTabForReport(args) else {
                return
            }
            let validSurfaceIds = Set(tab.panels.keys)
            tab.pruneSurfaceMetadata(validSurfaceIds: validSurfaceIds)
            guard let surfaceId = surfaceIdFromOptions ?? tab.focusedPanelId else { return }
            guard validSurfaceIds.contains(surfaceId) else { return }
            mutation(tab, surfaceId)
        }
        return "OK"
    }

    private func upsertSidebarMetadata(_ args: String, missingError: String) -> String {
        let parsed = parseOptionsNoStop(args)
        guard parsed.positional.count >= 2 else { return missingError }

        let key = parsed.positional[0]
        let value = parsed.positional[1...].joined(separator: " ")
        let icon = normalizedOptionValue(parsed.options["icon"])
        let color = normalizedOptionValue(parsed.options["color"])

        let formatRaw = normalizedOptionValue(parsed.options["format"]) ?? SidebarMetadataFormat.plain.rawValue
        guard let format = parseSidebarMetadataFormat(formatRaw) else {
            return "ERROR: Invalid metadata format '\(formatRaw)' — use: plain, markdown"
        }

        let priority: Int
        if let rawPriority = normalizedOptionValue(parsed.options["priority"]) {
            guard let parsedPriority = Int(rawPriority) else {
                return "ERROR: Invalid metadata priority '\(rawPriority)' — must be an integer"
            }
            priority = max(-9999, min(9999, parsedPriority))
        } else {
            priority = 0
        }

        let parsedURL: URL?
        if let rawURL = normalizedOptionValue(parsed.options["url"] ?? parsed.options["link"]) {
            guard let candidate = URL(string: rawURL),
                  let scheme = candidate.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else {
                return "ERROR: Invalid metadata URL '\(rawURL)' — expected http(s) URL"
            }
            parsedURL = candidate
        } else {
            parsedURL = nil
        }

        let targetResolution = parseSidebarMutationTabTarget(options: parsed.options)
        guard let target = targetResolution.target else {
            return targetResolution.error ?? "ERROR: No tab selected"
        }
        let panelResolution = parseOptionalPanelIdOption(
            options: parsed.options,
            usage: "set_status <key> <value> [--icon=X] [--color=#hex] [--url=X] [--priority=N] [--format=plain|markdown] [--tab=X] [--panel=ID]"
        )
        if let error = panelResolution.error {
            return error
        }

        let pidValue: pid_t? = {
            if let rawPid = normalizedOptionValue(parsed.options["pid"]),
               let p = Int32(rawPid), p > 0 {
                return p
            }
            return nil
        }()

        scheduleSidebarMutation(target: target) { _, tab in
            if let panelId = panelResolution.panelId, !tab.panels.keys.contains(panelId) {
                return
            }
            guard Self.shouldReplaceStatusEntry(
                current: tab.statusEntries[key],
                key: key,
                value: value,
                icon: icon,
                color: color,
                url: parsedURL,
                priority: priority,
                format: format
            ) else {
                // Still update PID tracking even if the status display hasn't changed.
                if let pidValue {
                    tab.recordAgentPID(key: key, pid: pidValue, panelId: panelResolution.panelId)
                }
                return
            }
            tab.statusEntries[key] = SidebarStatusEntry(
                key: key,
                value: value,
                icon: icon,
                color: color,
                url: parsedURL,
                priority: priority,
                format: format,
                timestamp: Date()
            )
            if let pidValue {
                tab.recordAgentPID(key: key, pid: pidValue, panelId: panelResolution.panelId)
            }
        }
        return "OK"
    }

    private func clearSidebarMetadata(_ args: String, usage: String) -> String {
        let parsed = parseOptions(args)
        guard let key = parsed.positional.first, parsed.positional.count == 1 else {
            return "ERROR: Missing metadata key — usage: \(usage)"
        }

        let targetResolution = parseSidebarMutationTabTarget(options: parsed.options)
        guard let target = targetResolution.target else {
            return targetResolution.error ?? "ERROR: No tab selected"
        }

        scheduleSidebarMutation(target: target) { _, tab in
            _ = tab.statusEntries.removeValue(forKey: key)
            tab.clearAgentPID(key: key)
        }
        return "OK"
    }

    private func isAllowedAgentLifecycleKey(
        _ key: String,
        target: SidebarMutationTabTarget,
        panelId: UUID?
    ) -> Bool {
        if AgentHibernationLifecycleStatusKeys.isAllowed(key) {
            return true
        }
        guard let tab = resolveSidebarMutationTab(target),
              CmuxVaultAgentRegistration.isValidID(key) else {
            return false
        }
        let registry = CmuxVaultAgentRegistry.load(
            workingDirectory: agentLifecycleRegistryWorkingDirectory(tab: tab, panelId: panelId)
        )
        return registry.registration(id: key) != nil
    }

    private func agentLifecycleRegistryWorkingDirectory(tab: Tab, panelId: UUID?) -> String? {
        let candidates = [
            panelId.flatMap { tab.panelDirectories[$0] },
            tab.focusedPanelId.flatMap { tab.panelDirectories[$0] },
            tab.currentDirectory,
        ]
        return candidates.compactMap(normalizedOptionValue).first
    }

    private func sidebarMetadataLine(_ entry: SidebarStatusEntry) -> String {
        var line = "\(entry.key)=\(entry.value)"
        if let icon = entry.icon { line += " icon=\(icon)" }
        if let color = entry.color { line += " color=\(color)" }
        if let url = entry.url { line += " url=\(url.absoluteString)" }
        if entry.priority != 0 { line += " priority=\(entry.priority)" }
        if entry.format != .plain { line += " format=\(entry.format.rawValue)" }
        return line
    }

    private func listSidebarMetadata(_ args: String, emptyMessage: String) -> String {
        var result = ""
        v2MainSync {
            guard let tab = resolveTabForReport(args) else {
                result = "ERROR: Tab not found"
                return
            }
            let entries = tab.sidebarStatusEntriesInDisplayOrder()
            if entries.isEmpty {
                result = emptyMessage
                return
            }
            result = entries.map(sidebarMetadataLine).joined(separator: "\n")
        }
        return result
    }

    private func splitMetadataBlockArgs(_ args: String) -> (optionsPart: String, markdownPart: String?) {
        sidebarMetadataArgumentParser.splitMetadataBlockArgs(args)
    }

    private func sidebarMetadataBlockLine(_ block: SidebarMetadataBlock) -> String {
        var line = "\(block.key)=\(block.markdown.replacingOccurrences(of: "\n", with: "\\n"))"
        if block.priority != 0 { line += " priority=\(block.priority)" }
        return line
    }

#if DEBUG
    func parseRightSidebarRemoteRequestForTesting(_ commandLine: String) -> Result<RightSidebarRemoteRequest, RightSidebarRemoteParseError> {
        let trimmed = commandLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.first?.lowercased() == "right_sidebar" else {
            return .failure(.init(message: "ERROR: Usage: right_sidebar <toggle|show|hide|focus|set|mode>"))
        }
        return RightSidebarRemoteRequest.parse(tokens: Self.tokenizeArgs(parts.count > 1 ? parts[1] : ""))
    }

    func rightSidebarCommandAllowsInAppFocusMutationsForTesting(_ commandLine: String) -> Bool {
        let trimmed = commandLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.first?.lowercased() == "right_sidebar" else { return false }
        return Self.rightSidebarCommandAllowsInAppFocusMutations(args: parts.count > 1 ? parts[1] : "")
    }
#endif

    private func viewDepth(of view: NSView, maxDepth: Int = 128) -> Int {
        var depth = 0
        var current: NSView? = view
        while let v = current, depth < maxDepth {
            current = v.superview
            depth += 1
        }
        return depth
    }

    private func isPortalHosted(_ view: NSView) -> Bool {
        var current: NSView? = view
        while let v = current {
            if v is WindowTerminalHostView { return true }
            current = v.superview
        }
        return false
    }

    // MARK: - Mobile Host V2 Methods

    @MainActor
    func mobileHostHandleRPC(_ request: MobileHostRPCRequest) async -> MobileHostRPCResult {
        // The mobile data-plane RPC speaks `MobileHostRPCRequest` /
        // `MobileHostRPCResult` and dispatches directly to the app-side
        // `v2Mobile*` bodies. It deliberately does NOT route through the v2
        // control-socket `ControlCommandCoordinator` (whose native result type is
        // `ControlCallResult`): doing so would force a
        // `MobileHostRPCRequest → ControlRequest → ControlCallResult →
        // MobileHostRPCResult` type round-trip with no behavior change. The v2
        // control socket shares the same bodies through `handleMobileHost`, so the
        // wire bytes stay identical across both entrypoints without a bridge here.
        let result: V2CallResult
        switch request.method {
        case "mobile.host.status":
            result = v2MobileHostStatus(params: request.params, includePrivateMetadata: false)
        case "mobile.attach_ticket.create":
            result = await v2MobileAttachTicketCreate(params: request.params)
        case "mobile.workspace.list", "workspace.list":
            result = v2MobileWorkspaceList(params: request.params)
        case "workspace.create":
            result = v2MobileWorkspaceCreate(params: request.params)
        case "mobile.terminal.create", "terminal.create":
            result = v2MobileTerminalCreate(params: request.params)
        case "mobile.terminal.input", "terminal.input":
            result = v2MobileTerminalInput(params: request.params)
        case "mobile.terminal.paste", "terminal.paste":
            result = v2MobileTerminalPaste(params: request.params)
        case "mobile.terminal.paste_image", "terminal.paste_image":
            result = v2MobileTerminalPasteImage(params: request.params)
        case "mobile.terminal.replay", "terminal.replay":
            result = v2MobileTerminalReplay(params: request.params)
        case "mobile.terminal.viewport", "terminal.viewport":
            result = v2MobileTerminalViewport(params: request.params)
        case "mobile.terminal.scroll", "terminal.scroll":
            result = v2MobileTerminalScroll(params: request.params)
        case "mobile.terminal.mouse", "terminal.mouse":
            result = v2MobileTerminalMouse(params: request.params)
        case "workspace.action":
            result = v2MobileWorkspaceAction(params: request.params)
        case let method where method.hasPrefix("mobile.chat."):
            result = await v2MobileChatDispatch(method: method, params: request.params)
        case "workspace.close":
            result = v2MobileWorkspaceClose(params: request.params)
        case "workspace.group.collapse":
            result = v2MobileWorkspaceGroupSetCollapsed(params: request.params, isCollapsed: true)
        case "workspace.group.expand":
            result = v2MobileWorkspaceGroupSetCollapsed(params: request.params, isCollapsed: false)
        case "notification.dismiss":
            result = v2MobileNotificationDismiss(params: request.params)
        case "notification.reconcile":
            result = v2MobileNotificationReconcile(params: request.params)
        case "dogfood.feedback.submit":
            result = await v2MobileDogfoodFeedbackSubmit(params: request.params)
        default:
            result = .err(code: "method_not_found", message: "Unknown mobile method", data: [
                "method": request.method
            ])
        }
        return mobileHostResult(result)
    }

    /// Privileged agent feedback sink (the Mac↔phone feedback loop).
    ///
    /// Reads `{ text, terminal_text, build_stamp, diagnostic_blob_base64 }` off
    /// the wire and hands them to ``DogfoodFeedbackService`` (in the
    /// `CmuxFeedback` package), which caps the fields, rejects an oversized
    /// base64 blob without decoding, and writes a self-contained bundle
    /// directory under `~/.cache/cmux-dogfood-feedback/<ISO8601>_<shortid>/`
    /// (a `bundle.json` manifest plus the decoded `diagnostic.log`) off the main
    /// actor. This method owns only the trust-boundary privilege check and the
    /// wire mapping; the validation, allocation caps, and filesystem I/O live in
    /// the service.
    ///
    /// It is protected by the same-account Stack-auth authorization the rest of
    /// the mobile data plane enforces, so it never accepts an unauthenticated
    /// caller. The phone only ever routes here for `@manaflow.ai` users on an
    /// active connection, so this exists in Release builds too (the team can
    /// dogfood beta/prod), and only a Mac that runs the watcher acts on it.
    func v2MobileDogfoodFeedbackSubmit(params: [String: Any]) async -> V2CallResult {
        // Privilege check at the trust boundary: the mobile data plane only
        // accepts same-account connections, so the caller is this Mac's own Stack
        // account. The service re-enforces the @manaflow.ai gate, but we resolve
        // the authenticated email here because it requires the main-actor
        // `MobileHostService`. (The phone also gates the route on `@manaflow.ai`
        // + `dogfood.v1`, but the Mac is the real boundary.)
        let localEmail = await MobileHostService.shared.currentAuthenticatedLocalUserEmail()
        let submission = DogfoodFeedbackSubmission(
            text: v2RawString(params, "text") ?? "",
            terminalText: v2RawString(params, "terminal_text") ?? "",
            buildStamp: v2RawString(params, "build_stamp") ?? "",
            diagnosticBlobBase64: v2RawString(params, "diagnostic_blob_base64") ?? ""
        )
        let outcome = await DogfoodFeedbackService().submit(submission, authenticatedEmail: localEmail)
        switch outcome {
        case let .written(bundlePath, diagnosticLogBytes):
            return .ok([
                "ok": true,
                "bundle_path": bundlePath,
                "diagnostic_log_bytes": diagnosticLogBytes,
            ])
        case .unauthorized:
            return .err(
                code: "unauthorized",
                message: "Feedback agent sink is restricted to privileged accounts",
                data: nil
            )
        case let .invalidParams(reason):
            return .err(code: "invalid_params", message: reason, data: nil)
        case .internalError:
            return .err(
                code: "internal_error",
                message: "Failed to persist dogfood feedback bundle",
                data: nil
            )
        }
    }

    /// Publish a `terminal.set_font` event to connected iOS device(s) so the
    /// mirrored terminal live-zooms its font (the grid reflows automatically on
    /// the phone). Drives the same iOS apply path as a pinch/zoom step, just
    /// initiated from the Mac for automation (`cmux mobile set-font <size>`).
    ///
    /// Params: `{ "font_size": Number, optional "surface_id": String,
    /// optional "workspace_id": String }`. When `surface_id` is omitted the
    /// phone applies the size to every mounted surface. `nonisolated` because it
    /// only touches the Sendable connection registry via
    /// ``MobileHostService/emitEvent(topic:payload:)``.
    nonisolated func v2MobileTerminalSetFont(params: [String: Any]) -> V2CallResult {
        guard let fontSize = v2Double(params, "font_size") else {
            return .err(
                code: "invalid_params",
                message: "Missing or invalid font_size",
                data: nil
            )
        }
        guard fontSize.isFinite, fontSize > 0 else {
            return .err(
                code: "invalid_params",
                message: "font_size must be a positive number of points",
                data: ["font_size": fontSize]
            )
        }
        var payload: [String: Any] = ["font_size": fontSize]
        if let surfaceID = v2RawString(params, "surface_id") {
            payload["surface_id"] = surfaceID
        }
        if let workspaceID = v2RawString(params, "workspace_id") {
            payload["workspace_id"] = workspaceID
        }
        let hasSubscribers = MobileHostService.hasEventSubscribers(topic: "terminal.set_font")
        MobileHostService.emitEvent(topic: "terminal.set_font", payload: payload)
        return .ok([
            "ok": true,
            "font_size": fontSize,
            "delivered": hasSubscribers,
        ])
    }

    /// Mobile-gated wrapper over ``v2WorkspaceAction(params:)``.
    func v2MobileWorkspaceAction(params: [String: Any]) -> V2CallResult {
        let rawAction = v2RawString(params, "action")
        guard Self.mobileAllowsWorkspaceAction(rawAction) else {
            return .err(
                code: "method_not_found",
                message: "Unsupported workspace action for mobile",
                data: ["action": v2OrNull(rawAction)]
            )
        }
        // Reject a present-but-malformed workspace_id like the other mobile
        // handlers, then require it to actually be present and resolvable: this
        // is a mutating action, so it must target an explicit workspace and never
        // fall back to the Mac's currently selected workspace (which
        // v2WorkspaceAction would otherwise do for a missing workspace_id).
        if let error = mobileWorkspaceIDValidationError(params: params) {
            return error
        }
        guard v2UUID(params, "workspace_id") != nil else {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }
        return v2WorkspaceAction(params: params)
    }

    private func mobileHostResult(_ result: V2CallResult) -> MobileHostRPCResult {
        switch result {
        case let .ok(payload):
            return .ok(payload)
        case let .err(code, message, data):
            let safeMessage = code == "internal_error" ? "Mobile host operation failed" : message
            let safeData = code == "internal_error" ? nil : data
            return .failure(MobileHostRPCError(code: code, message: safeMessage, data: safeData))
        }
    }

    func v2MobileHostStatus(
        params: [String: Any],
        includePrivateMetadata: Bool = true
    ) -> V2CallResult {
        let status = MobileHostService.shared.statusSnapshot()
        // Single source of truth shared with the mobile listener's public-status
        // paths, so the advertised capabilities can never drift. Includes
        // workspace.actions.v1 (the mobile-gated pin/unpin/rename handler), which
        // the iOS client uses to show or hide rename/pin.
        let capabilities = MobileHostService.mobileHostCapabilities
        guard includePrivateMetadata else {
            return .ok(MobileHostService.publicStatusPayload(
                routesPayload: status.routes.map(\.mobileHostJSONObject)
            ))
        }

        let tabManager = v2ResolveTabManager(params: params)
        let workspaceCount = tabManager?.tabs.count ?? 0

        return .ok([
            "mac_device_id": MobileHostIdentity.deviceID(),
            "mac_display_name": v2OrNull(MobileHostIdentity.displayName()),
            "host_service": status.payload,
            "workspace_count": workspaceCount,
            "terminal_fidelity": "render_grid",
            "capabilities": capabilities,
        ])
    }

    #if DEBUG
    #endif

    @MainActor
    func v2MobileAttachTicketCreate(params: [String: Any]) async -> V2CallResult {
        let ttl = TimeInterval(max(30, min(v2Int(params, "ttl_seconds") ?? 600, 3600)))
        let routeID = v2OptionalTrimmedRawString(params, "route_id")
            ?? v2OptionalTrimmedRawString(params, "routeID")
        let routeKind = v2OptionalTrimmedRawString(params, "route_kind")
            ?? v2OptionalTrimmedRawString(params, "routeKind")
        let scope = v2OptionalTrimmedRawString(params, "scope")
        // scope=mac mints a Mac-wide ticket that grants access to every
        // workspace on the host. Without this, the ticket gets pinned to
        // the workspace selected at QR-generation time, and tapping any
        // other workspace from the paired iPhone falls back to Stack
        // Auth verification, which is brittle on real-world networks.
        let isMacScope = scope?.lowercased() == "mac"

        if let error = mobileWorkspaceIDValidationError(params: params) {
            return error
        }
        if let error = mobileTerminalAliasValidationError(params: params) {
            return error
        }

        let resolvedWorkspaceID: String
        let resolvedTerminalID: String?
        if isMacScope {
            resolvedWorkspaceID = ""
            resolvedTerminalID = nil
        } else {
            guard let resolved = mobileResolveWorkspaceAndSurface(params: params, requireTerminal: false) else {
                return .err(code: "not_found", message: "Workspace not found", data: nil)
            }
            let terminalPanel: TerminalPanel?
            if let surfaceId = resolved.surfaceId {
                guard let panel = resolved.workspace.terminalPanel(for: surfaceId) else {
                    return .err(
                        code: "invalid_request",
                        message: "terminal_id does not reference a terminal",
                        data: nil
                    )
                }
                terminalPanel = panel
            } else {
                terminalPanel = nil
            }
            resolvedWorkspaceID = resolved.workspace.id.uuidString
            resolvedTerminalID = terminalPanel?.id.uuidString
        }

        do {
            let payload = try await MobileHostService.shared.createAttachTicket(
                workspaceID: resolvedWorkspaceID,
                terminalID: resolvedTerminalID,
                ttl: ttl,
                routeID: routeID,
                routeKind: routeKind
            )
            return .ok(payload)
        } catch MobileAttachTicketStoreError.noRoutes {
            return .err(
                code: "unavailable",
                message: "Mobile host routes are not available yet",
                data: nil
            )
        } catch MobileAttachTicketStoreError.routeUnavailable {
            var data: [String: Any] = [:]
            if let routeID {
                data["route_id"] = routeID
            }
            if let routeKind {
                data["route_kind"] = routeKind
            }
            return .err(
                code: "unavailable",
                message: "Requested mobile host route is not available",
                data: data.isEmpty ? nil : data
            )
        } catch {
            return .err(
                code: "internal_error",
                message: "Failed to create mobile attach ticket",
                data: ["error": String(describing: error)]
            )
        }
    }

    enum MobileTerminalAliasUUID {
        case missing
        case value(UUID)
        case invalid
        case conflict
    }

    func mobileTerminalAliasUUID(params: [String: Any]) -> MobileTerminalAliasUUID {
        var selected: UUID?
        var sawAlias = false
        for key in ["surface_id", "terminal_id", "tab_id"] {
            guard v2HasNonNullParam(params, key) else {
                continue
            }
            sawAlias = true
            guard let candidate = v2UUID(params, key) else {
                return .invalid
            }
            if let selected, selected != candidate {
                return .conflict
            }
            selected = selected ?? candidate
        }
        if let selected {
            return .value(selected)
        }
        return sawAlias ? .invalid : .missing
    }

    private func mobileTerminalAliasValidationError(params: [String: Any]) -> V2CallResult? {
        switch mobileTerminalAliasUUID(params: params) {
        case .missing, .value:
            return nil
        case .invalid:
            return .err(code: "invalid_params", message: "Missing or invalid terminal_id", data: nil)
        case .conflict:
            return .err(code: "invalid_params", message: "Conflicting terminal identifiers", data: nil)
        }
    }

    private func mobileWorkspaceIDValidationError(params: [String: Any]) -> V2CallResult? {
        guard v2HasNonNullParam(params, "workspace_id"),
              v2UUID(params, "workspace_id") == nil else {
            return nil
        }
        return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
    }

    func clearAllMobileViewportReports(reason: String) {
        guard !mobileViewportReportsBySurfaceID.isEmpty ||
            !mobileViewportReportCleanupTimersBySurfaceID.isEmpty else {
            return
        }

        for timer in mobileViewportReportCleanupTimersBySurfaceID.values {
            timer.cancel()
        }
        let surfaceIDs = Array(mobileViewportReportsBySurfaceID.keys)
        mobileViewportReportsBySurfaceID.removeAll()
        mobileViewportReportCleanupTimersBySurfaceID.removeAll()

        for surfaceID in surfaceIDs {
            terminalPanel(surfaceID: surfaceID)?.surface.clearMobileViewportLimit(reason: reason)
        }
    }

    #if DEBUG
    func debugResetMobileViewportReportsForTesting() {
        clearAllMobileViewportReports(reason: "mobile.viewport.testReset")
    }

    func debugSetMobileViewportReportForTesting(
        surfaceID: UUID,
        clientID: String,
        columns: Int,
        rows: Int,
        updatedAt: Date = Date()
    ) {
        var reports = mobileViewportReportsBySurfaceID[surfaceID] ?? [:]
        reports[clientID] = MobileViewportReport(
            columns: columns,
            rows: rows,
            updatedAt: updatedAt
        )
        mobileViewportReportsBySurfaceID[surfaceID] = reports
    }

    func debugMobileViewportReportClientIDsForTesting(surfaceID: UUID) -> Set<String>? {
        guard let reports = mobileViewportReportsBySurfaceID[surfaceID] else {
            return nil
        }
        return Set(reports.keys)
    }
    #endif

    private func terminalPanel(surfaceID: UUID) -> TerminalPanel? {
        guard let located = AppDelegate.shared?.locateSurface(surfaceId: surfaceID),
              let workspace = located.tabManager.tabs.first(where: { $0.id == located.workspaceId }) else {
            return nil
        }
        return workspace.terminalPanel(for: surfaceID)
    }

    // Restored: still used by the v1 close-workspace path (its v2
    // counterpart moved to ControlCommandCoordinator).
    private func workspaceCloseProtectedMessage() -> String {
        String(
            localized: "workspace.closeProtected.message",
            defaultValue: "Pinned workspaces can't be closed while pinned. Unpin the workspace first."
        )
    }

    func v2MobileTerminalCreate(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "Workspace context is unavailable", data: nil)
        }
        if let error = mobileWorkspaceIDValidationError(params: params) {
            return error
        }
        guard let workspace = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        }
        guard let paneId = workspace.bonsplitController.focusedPaneId ?? workspace.bonsplitController.allPaneIds.first else {
            return .err(code: "not_found", message: "Pane not found", data: nil)
        }
        guard let terminal = workspace.newTerminalSurface(
            inPane: paneId,
            focus: false,
            autoRefreshMetadata: false,
            preserveFocusWhenUnfocused: false, inheritWorkingDirectoryFallback: true
        ) else {
            return .err(code: "internal_error", message: "Failed to create terminal", data: nil)
        }
        // workspace.updated emit is handled by MobileWorkspaceListObserver.
        return v2MobileWorkspaceList(
            params: params,
            tabManager: tabManager,
            createdTerminalID: terminal.id.uuidString
        )
    }

    func v2MobileTerminalReplay(params: [String: Any]) -> V2CallResult {
        if let error = mobileWorkspaceIDValidationError(params: params) {
            return error
        }
        if let error = mobileTerminalAliasValidationError(params: params) {
            return error
        }
        guard let resolved = mobileResolveWorkspaceAndSurface(params: params, requireTerminal: true),
              let surfaceId = resolved.surfaceId,
              let terminalPanel = resolved.workspace.terminalPanel(for: surfaceId) else {
            #if DEBUG
            cmuxDebugLog("mobile.terminal.replay NOT_FOUND surface=\(v2RawString(params, "surface_id") ?? "nil")")
            #endif
            return .err(code: "not_found", message: "Terminal surface not found", data: nil)
        }
        let state = MobileTerminalByteTee.shared.replayState(surfaceID: surfaceId)
        let seq = state?.seq ?? 0
        let renderGrid = mobileTerminalRenderGridFrame(
            terminalPanel: terminalPanel,
            surfaceID: surfaceId,
            seq: seq
        )
        #if DEBUG
        cmuxDebugLog("mobile.terminal.replay surface=\(surfaceId.uuidString.prefix(8)) renderGrid=\(renderGrid != nil) seq=\(seq) hasState=\(state != nil)")
        #endif
        var payload: [String: Any] = [
            "workspace_id": resolved.workspace.id.uuidString,
            "surface_id": surfaceId.uuidString,
            "seq": seq,
        ]
        if let renderGrid,
           let renderGridObject = try? renderGrid.jsonObject() {
            payload["columns"] = renderGrid.columns
            payload["rows"] = renderGrid.rows
            payload["render_grid"] = renderGridObject
        } else {
            let snapshotData = readTerminalTextFromVTExportForSnapshot(
                terminalPanel: terminalPanel,
                bindingAction: "write_active_file:copy,vt",
                lineLimit: nil,
                normalizeLineEndings: false
            )?.data(using: .utf8) ?? Data()
            let data = state?.data ?? Data()
            if let surface = terminalPanel.surface.liveSurfaceForGhosttyAccess(reason: "mobileTerminalReplay") {
                let size = ghostty_surface_size(surface)
                payload["columns"] = max(Int(size.columns), 1)
                payload["rows"] = max(Int(size.rows), 1)
            }
            if !snapshotData.isEmpty {
                payload["snapshot_format"] = "ghostty.active.vt"
                payload["snapshot_data_b64"] = snapshotData.base64EncodedString()
            } else if !data.isEmpty {
                payload["data_b64"] = data.base64EncodedString()
            }
        }
        return .ok(payload)
    }

    /// Record (or clear) a paired device's reported terminal grid, recompute
    /// the smallest grid across all attached devices, cap this surface to it
    /// (drawing the macOS viewport border when the pane is larger), and return
    /// the resulting effective grid so the device can pin + letterbox its own
    /// render to match. This is the iOS/macOS half of the tmux-style shared
    /// resize: the smallest attached viewport wins and every device shows the
    /// same cols×rows with a clear border around the live area.
    func v2MobileTerminalViewport(params: [String: Any]) -> V2CallResult {
        if let error = mobileWorkspaceIDValidationError(params: params) {
            return error
        }
        if let error = mobileTerminalAliasValidationError(params: params) {
            return error
        }
        guard let resolved = mobileResolveWorkspaceAndSurface(params: params, requireTerminal: true),
              let surfaceId = resolved.surfaceId,
              let terminalPanel = resolved.workspace.terminalPanel(for: surfaceId) else {
            return .err(code: "not_found", message: "Terminal surface not found", data: nil)
        }

        if v2Bool(params, "clear") == true {
            if let clientID = v2String(params, "client_id") {
                clearMobileViewportReport(
                    surfaceID: terminalPanel.id,
                    clientID: clientID,
                    reason: "mobile.terminal.viewport.clear"
                )
            }
        } else {
            applyMobileViewportReport(params: params, terminalPanel: terminalPanel, sticky: true)
        }

        var payload: [String: Any] = [
            "workspace_id": resolved.workspace.id.uuidString,
            "surface_id": surfaceId.uuidString,
        ]
        if let surface = terminalPanel.surface.liveSurfaceForGhosttyAccess(reason: "mobileTerminalViewport") {
            let size = ghostty_surface_size(surface)
            payload["columns"] = max(Int(size.columns), 1)
            payload["rows"] = max(Int(size.rows), 1)
        }
        return .ok(payload)
    }

    /// Forward a phone scroll gesture to the real surface so libghostty handles
    /// it per-mode (scrollback in the normal screen, mouse-wheel to the program
    /// in the alt screen). The producer already exports the live `vp_top`, so
    /// the resulting viewport mirrors back to the phone; nudge an emit since a
    /// pure scroll with no PTY output may not fire a render/tick on its own.
    func v2MobileTerminalScroll(params: [String: Any]) -> V2CallResult {
        if let error = mobileWorkspaceIDValidationError(params: params) {
            return error
        }
        if let error = mobileTerminalAliasValidationError(params: params) {
            return error
        }
        guard let resolved = mobileResolveWorkspaceAndSurface(params: params, requireTerminal: true),
              let surfaceId = resolved.surfaceId,
              let terminalPanel = resolved.workspace.terminalPanel(for: surfaceId) else {
            return .err(code: "not_found", message: "Terminal surface not found", data: nil)
        }
        let deltaLines = (params["delta_lines"] as? NSNumber)?.doubleValue ?? 0
        let col = (params["col"] as? NSNumber)?.intValue ?? 0
        let row = (params["row"] as? NSNumber)?.intValue ?? 0
        if deltaLines != 0 {
            terminalPanel.surface.mobileScroll(deltaLines: deltaLines, col: max(0, col), row: max(0, row))
            MobileTerminalRenderObserver.shared.noteTerminalBytes(surfaceID: terminalPanel.id)
        }
        return .ok(mobileTerminalScrollResponsePayload(
            workspaceID: resolved.workspace.id,
            terminalPanel: terminalPanel,
            surfaceID: surfaceId,
            params: params
        ))
    }

    func v2MobileTerminalMouse(params: [String: Any]) -> V2CallResult {
        if let error = mobileWorkspaceIDValidationError(params: params) {
            return error
        }
        if let error = mobileTerminalAliasValidationError(params: params) {
            return error
        }
        guard let resolved = mobileResolveWorkspaceAndSurface(params: params, requireTerminal: true),
              let surfaceId = resolved.surfaceId,
              let terminalPanel = resolved.workspace.terminalPanel(for: surfaceId) else {
            return .err(code: "not_found", message: "Terminal surface not found", data: nil)
        }
        let col = (params["col"] as? NSNumber)?.intValue ?? 0
        let row = (params["row"] as? NSNumber)?.intValue ?? 0
        terminalPanel.surface.mobileClick(col: max(0, col), row: max(0, row))
        MobileTerminalRenderObserver.shared.noteTerminalBytes(surfaceID: terminalPanel.id)
        return .ok([
            "workspace_id": resolved.workspace.id.uuidString,
            "surface_id": surfaceId.uuidString,
        ])
    }

    func v2MobileTerminalInput(params: [String: Any]) -> V2CallResult {
        guard let text = v2RawString(params, "text"), !text.isEmpty else {
            return .err(code: "invalid_params", message: "Missing text", data: nil)
        }
        if let error = mobileWorkspaceIDValidationError(params: params) {
            return error
        }
        if let error = mobileTerminalAliasValidationError(params: params) {
            return error
        }
        guard let resolved = mobileResolveWorkspaceAndSurface(params: params, requireTerminal: true),
              let surfaceId = resolved.surfaceId,
              let terminalPanel = resolved.workspace.terminalPanel(for: surfaceId) else {
            return .err(code: "not_found", message: "Terminal surface not found", data: nil)
        }

        applyMobileViewportReport(params: params, terminalPanel: terminalPanel)

        #if DEBUG
        let sendStart = ProcessInfo.processInfo.systemUptime
        #endif
        let sendResult = terminalPanel.surface.sendInputResult(text)
        switch sendResult {
        case .sent:
            terminalPanel.surface.forceRefresh(reason: "mobileHost.terminalInput")
        case .queued:
            break
        case .inputQueueFull:
            return .err(code: "input_queue_full", message: Self.terminalInputQueueFullMessage, data: ["surface_id": surfaceId.uuidString])
        case .surfaceUnavailable:
            return .err(code: "surface_unavailable", message: Self.terminalSurfaceUnavailableMessage, data: ["surface_id": surfaceId.uuidString])
        case .processExited:
            return .err(code: "process_exited", message: Self.terminalProcessExitedMessage, data: ["surface_id": surfaceId.uuidString])
        }
        #if DEBUG
        let sendMs = (ProcessInfo.processInfo.systemUptime - sendStart) * 1000.0
        cmuxDebugLog(
            "mobile.terminal.input workspace=\(resolved.workspace.id.uuidString.prefix(8)) surface=\(surfaceId.uuidString.prefix(8)) queued=\(sendResult == .queued ? 1 : 0) chars=\(text.count) ms=\(String(format: "%.2f", sendMs))"
        )
        #endif
        var payload: [String: Any] = [
            "workspace_id": resolved.workspace.id.uuidString,
            "surface_id": terminalPanel.id.uuidString,
            "queued": sendResult == .queued,
        ]
        if let seq = MobileTerminalByteTee.shared.currentSequence(surfaceID: surfaceId) {
            payload["terminal_seq"] = seq
        }
        return .ok(payload)
    }

    /// Handle `terminal.paste_image`: a paired client (the iOS app) forwards an
    /// image it pasted as base64 bytes. We materialize it to a temp file on the
    /// Mac and inject the shell-escaped path as terminal input, exactly the way a
    /// local clipboard-image paste does, so the running TUI (e.g. Claude Code)
    /// attaches the image from the path.
    func v2MobileTerminalPasteImage(params: [String: Any]) -> V2CallResult {
        guard let base64 = v2RawString(params, "image_base64"),
              let imageData = Data(base64Encoded: base64), !imageData.isEmpty else {
            return .err(code: "invalid_params", message: "Missing or invalid image_base64", data: nil)
        }
        let format = v2RawString(params, "image_format") ?? "png"
        if let error = mobileWorkspaceIDValidationError(params: params) {
            return error
        }
        if let error = mobileTerminalAliasValidationError(params: params) {
            return error
        }
        guard let resolved = mobileResolveWorkspaceAndSurface(params: params, requireTerminal: true),
              let surfaceId = resolved.surfaceId,
              let terminalPanel = resolved.workspace.terminalPanel(for: surfaceId) else {
            return .err(code: "not_found", message: "Terminal surface not found", data: nil)
        }

        applyMobileViewportReport(params: params, terminalPanel: terminalPanel)

        guard let escapedPath = GhosttyApp.terminalPasteboard.saveImageData(imageData, fileExtension: format) else {
            return .err(code: "invalid_params", message: "Image payload was empty or exceeded the size limit", data: nil)
        }

        let sendResult = terminalPanel.surface.sendInputResult(escapedPath)
        switch sendResult {
        case .sent:
            terminalPanel.surface.forceRefresh(reason: "mobileHost.terminalPasteImage")
        case .queued:
            break
        case .inputQueueFull:
            return .err(code: "input_queue_full", message: Self.terminalInputQueueFullMessage, data: ["surface_id": surfaceId.uuidString])
        case .surfaceUnavailable:
            return .err(code: "surface_unavailable", message: Self.terminalSurfaceUnavailableMessage, data: ["surface_id": surfaceId.uuidString])
        case .processExited:
            return .err(code: "process_exited", message: Self.terminalProcessExitedMessage, data: ["surface_id": surfaceId.uuidString])
        }
        #if DEBUG
        cmuxDebugLog(
            "mobile.terminal.paste_image workspace=\(resolved.workspace.id.uuidString.prefix(8)) surface=\(surfaceId.uuidString.prefix(8)) bytes=\(imageData.count) format=\(format)"
        )
        #endif
        return .ok([
            "workspace_id": resolved.workspace.id.uuidString,
            "surface_id": terminalPanel.id.uuidString,
            "queued": sendResult == .queued,
        ])
    }

    /// Deliver a composed block from the mobile composer as a bracketed paste
    /// followed by an optional single submit key.
    ///
    /// This mirrors the macOS TextBox composer dispatch
    /// (`[.pasteText(payload), .namedKey(submitKey)]`): the text goes through
    /// `sendText` (libghostty `ghostty_surface_text`), which bracketed-pastes it
    /// (`ESC[200~ … ESC[201~` when DECSET 2004 is active) so the agent's line
    /// editor inserts the whole, possibly multi-line, block as literal text
    /// instead of treating every interior newline as a submit. A single named
    /// submit key then commits it once. The `terminal.input` path is wrong for a
    /// composed block: `parsedSocketInputEvents` rewrites every `\n`/`\r` to a
    /// raw CR, so an N-line message fragments into N submissions.
    ///
    /// `submit_key` is optional: `return`/`enter` (default) or `ctrl+enter`
    /// submit; `none` pastes without submitting so the composer can keep editing.
    func v2MobileTerminalPaste(params: [String: Any]) -> V2CallResult {
        guard let text = v2RawString(params, "text"), !text.isEmpty else {
            return .err(code: "invalid_params", message: "Missing text", data: nil)
        }
        // Resolve the optional submit key up front so an unsupported value fails
        // before any text is pasted (no partial application). The phone sends
        // `return` as the default submit *intent*; the agent-aware upgrade to
        // `ctrl+enter` happens below once the surface (and its agent context) is
        // resolved, because only the Mac knows which agent is running.
        let submitKeyRaw = (v2String(params, "submit_key") ?? "return").lowercased()
        var submitKeyName: String?
        var submitKeyWasReturnIntent = false
        switch submitKeyRaw {
        case "", "return", "enter":
            submitKeyName = "return"
            submitKeyWasReturnIntent = true
        case "ctrl+enter":
            submitKeyName = "ctrl+enter"
        case "none":
            submitKeyName = nil
        default:
            return .err(code: "invalid_params", message: "Unsupported submit_key", data: ["submit_key": submitKeyRaw])
        }
        if let error = mobileWorkspaceIDValidationError(params: params) {
            return error
        }
        if let error = mobileTerminalAliasValidationError(params: params) {
            return error
        }
        guard let resolved = mobileResolveWorkspaceAndSurface(params: params, requireTerminal: true),
              let surfaceId = resolved.surfaceId,
              let terminalPanel = resolved.workspace.terminalPanel(for: surfaceId) else {
            return .err(code: "not_found", message: "Terminal surface not found", data: nil)
        }

        // Mirror the macOS TextBox composer's submit-key selection
        // (`TextBoxInput.dispatchEvents`): Claude Code needs `ctrl+enter` to
        // submit a multi-line block, while plain `return` submits a newline mid
        // prompt. The phone cannot know the running agent, so it always asks for
        // `return`; upgrade that intent here when the surface is Claude and the
        // composed text spans multiple lines. Explicit `ctrl+enter`/`none` from
        // the client are honored as-is.
        if submitKeyWasReturnIntent,
           text.contains("\n") || text.contains("\r"),
           TextBoxAgentDetection.isClaudeCode(
               context: WorkspaceContentView.terminalAgentContext(panel: terminalPanel, workspace: resolved.workspace)
           ) {
            submitKeyName = "ctrl+enter"
        }

        applyMobileViewportReport(params: params, terminalPanel: terminalPanel)

        // Send through the TerminalPanel explicit-input wrappers (not the raw
        // surface): they run `resumeForExplicitInputIfNeeded()` first, waking a
        // hibernated agent terminal the same way local typing does, so a mobile
        // composer submit cannot write into a cold surface.
        guard terminalPanel.sendText(text) else {
            return .err(code: "surface_unavailable", message: Self.terminalSurfaceUnavailableMessage, data: ["surface_id": surfaceId.uuidString])
        }

        // The paste text is already accepted by the surface above. From here on a
        // submit-key failure must NOT surface as an RPC error: the client treats
        // any error as "nothing was sent" and keeps the composer draft, so a
        // retry would paste the whole block a second time. Report partial
        // success instead — `submitted: false` plus `submit_error` — so the
        // client clears the draft (the text is sitting at the prompt) and can
        // tell the user the submit keypress is still needed.
        var submitted = false
        var submitError: String?
        if let submitKeyName {
            let keyResult = terminalPanel.sendNamedKeyResult(submitKeyName)
            if keyResult.accepted {
                submitted = true
            } else {
                switch keyResult {
                case .inputQueueFull:
                    submitError = "input_queue_full"
                case .surfaceUnavailable:
                    submitError = "surface_unavailable"
                case .processExited:
                    submitError = "process_exited"
                case .unknownKey, .sent, .queued:
                    // .sent / .queued are accepted results and unreachable in this
                    // else-branch; grouped here only to keep the switch exhaustive.
                    submitError = "unknown_key"
                }
            }
        }

        terminalPanel.surface.forceRefresh(reason: "mobileHost.terminalPaste")

        #if DEBUG
        cmuxDebugLog(
            "mobile.terminal.paste workspace=\(resolved.workspace.id.uuidString.prefix(8)) surface=\(surfaceId.uuidString.prefix(8)) chars=\(text.count) submitted=\(submitted ? 1 : 0)"
        )
        #endif

        var payload: [String: Any] = [
            "workspace_id": resolved.workspace.id.uuidString,
            "surface_id": terminalPanel.id.uuidString,
            "submitted": submitted,
        ]
        if let submitError {
            payload["submit_error"] = submitError
        }
        if let seq = MobileTerminalByteTee.shared.currentSequence(surfaceID: surfaceId) {
            payload["terminal_seq"] = seq
        }
        return .ok(payload)
    }

    private func applyMobileViewportReport(
        params: [String: Any],
        terminalPanel: TerminalPanel,
        sticky: Bool = false
    ) {
        guard let clientID = v2String(params, "client_id"),
              let rawColumns = v2Int(params, "viewport_columns"),
              let rawRows = v2Int(params, "viewport_rows") else {
            return
        }

        let columns = min(max(rawColumns, 20), 300)
        let rows = min(max(rawRows, 5), 120)
        let now = Date()
        var reports = mobileViewportReportsBySurfaceID[terminalPanel.id] ?? [:]
        reports = reports.filter { _, report in
            report.sticky || now.timeIntervalSince(report.updatedAt) <= Self.mobileViewportReportTTL
        }
        reports[clientID] = MobileViewportReport(
            columns: columns,
            rows: rows,
            updatedAt: now,
            sticky: sticky
        )
        mobileViewportReportsBySurfaceID[terminalPanel.id] = reports
        scheduleMobileViewportReportCleanup(surfaceID: terminalPanel.id, reports: reports)

        guard let minColumns = reports.values.map(\.columns).min(),
              let minRows = reports.values.map(\.rows).min() else {
            return
        }
        terminalPanel.surface.applyMobileViewportLimit(
            columns: minColumns,
            rows: minRows,
            reason: "mobile.terminal.input"
        )
    }

    /// Remove a single client's viewport report for a surface (dedicated
    /// `mobile.terminal.viewport` clear, or a disconnect), then recompute the
    /// remaining min and re-apply or clear the surface's viewport limit so the
    /// macOS border reflects only the devices still attached.
    private func clearMobileViewportReport(surfaceID: UUID, clientID: String, reason: String) {
        guard var reports = mobileViewportReportsBySurfaceID[surfaceID],
              reports.removeValue(forKey: clientID) != nil else {
            return
        }
        if reports.isEmpty {
            mobileViewportReportsBySurfaceID[surfaceID] = nil
            mobileViewportReportCleanupTimersBySurfaceID[surfaceID]?.cancel()
            mobileViewportReportCleanupTimersBySurfaceID[surfaceID] = nil
            terminalPanel(surfaceID: surfaceID)?.surface.clearMobileViewportLimit(reason: reason)
            return
        }
        mobileViewportReportsBySurfaceID[surfaceID] = reports
        scheduleMobileViewportReportCleanup(surfaceID: surfaceID, reports: reports)
        if let minColumns = reports.values.map(\.columns).min(),
           let minRows = reports.values.map(\.rows).min() {
            terminalPanel(surfaceID: surfaceID)?.surface.applyMobileViewportLimit(
                columns: minColumns,
                rows: minRows,
                reason: reason
            )
        }
    }

    /// Drop every viewport report owned by the given client IDs across all
    /// surfaces. Called when a mobile connection closes so a disconnected
    /// device stops pinning the grid even though it never sent an explicit
    /// clear. Sticky reports rely on this signal instead of the TTL.
    func clearMobileViewportReports(clientIDs: Set<String>, reason: String) {
        guard !clientIDs.isEmpty else { return }
        for surfaceID in Array(mobileViewportReportsBySurfaceID.keys) {
            for clientID in clientIDs {
                clearMobileViewportReport(surfaceID: surfaceID, clientID: clientID, reason: reason)
            }
        }
    }

    private func scheduleMobileViewportReportCleanup(
        surfaceID: UUID,
        reports: [String: MobileViewportReport]
    ) {
        mobileViewportReportCleanupTimersBySurfaceID[surfaceID]?.cancel()
        // Sticky reports live for the connection lifetime, so they never drive
        // a TTL timer; only non-sticky (input-piggyback) reports expire.
        guard let nextExpiry = reports.values
            .filter({ !$0.sticky })
            .map({ $0.updatedAt.addingTimeInterval(Self.mobileViewportReportTTL) })
            .min() else {
            mobileViewportReportCleanupTimersBySurfaceID[surfaceID] = nil
            return
        }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        let millisecondsUntilExpiry = max(1, Int((nextExpiry.timeIntervalSinceNow + 1) * 1000))
        timer.schedule(deadline: .now() + .milliseconds(millisecondsUntilExpiry))
        timer.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.pruneMobileViewportReports(surfaceID: surfaceID, reason: "mobile.viewport.reportsExpired")
            }
        }
        mobileViewportReportCleanupTimersBySurfaceID[surfaceID] = timer
        timer.resume()
    }

    private func pruneMobileViewportReports(surfaceID: UUID, reason: String) {
        let now = Date()
        guard var reports = mobileViewportReportsBySurfaceID[surfaceID] else {
            mobileViewportReportCleanupTimersBySurfaceID[surfaceID]?.cancel()
            mobileViewportReportCleanupTimersBySurfaceID[surfaceID] = nil
            return
        }

        reports = reports.filter { _, report in
            report.sticky || now.timeIntervalSince(report.updatedAt) <= Self.mobileViewportReportTTL
        }

        guard !reports.isEmpty else {
            mobileViewportReportsBySurfaceID[surfaceID] = nil
            mobileViewportReportCleanupTimersBySurfaceID[surfaceID]?.cancel()
            mobileViewportReportCleanupTimersBySurfaceID[surfaceID] = nil
            terminalPanel(surfaceID: surfaceID)?.surface.clearMobileViewportLimit(reason: reason)
            return
        }

        mobileViewportReportsBySurfaceID[surfaceID] = reports
        if let minColumns = reports.values.map(\.columns).min(),
           let minRows = reports.values.map(\.rows).min() {
            terminalPanel(surfaceID: surfaceID)?.surface.applyMobileViewportLimit(
                columns: minColumns,
                rows: minRows,
                reason: reason
            )
        }
        scheduleMobileViewportReportCleanup(surfaceID: surfaceID, reports: reports)
    }

    func mobileResolveWorkspaceAndSurface(
        params: [String: Any],
        requireTerminal: Bool
    ) -> (tabManager: TabManager, workspace: Workspace, surfaceId: UUID?)? {
        guard let tabManager = v2ResolveTabManager(params: params),
              let workspace = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
            return nil
        }

        let requestedSurfaceId = v2UUID(params, "surface_id")
            ?? v2UUID(params, "terminal_id")
            ?? v2UUID(params, "tab_id")

        let surfaceId: UUID?
        if let requestedSurfaceId {
            guard workspace.panels[requestedSurfaceId] != nil else {
                return nil
            }
            surfaceId = requestedSurfaceId
        } else if requireTerminal {
            surfaceId = workspace.focusedTerminalPanel?.id
                ?? mobileTerminalPanels(in: workspace).first?.id
        } else {
            surfaceId = nil
        }

        // A session-restored / never-foregrounded terminal has its libghostty
        // surface created lazily — today only on the first keystroke (via the
        // input path's `requestBackgroundSurfaceStartIfNeeded`). The mobile
        // render-grid producer only reads a *live* surface, so such a terminal
        // shows blank on the phone until the user types. When a mobile client
        // resolves a terminal to read or drive, materialize the surface
        // headlessly so attaching alone loads it. Idempotent and a no-op once
        // the surface exists.
        if requireTerminal,
           let surfaceId,
           let panel = workspace.terminalPanel(for: surfaceId) {
            panel.surface.requestBackgroundSurfaceStartIfNeeded()
        }

        return (tabManager, workspace, surfaceId)
    }

    func mobileTerminalPanels(in workspace: Workspace) -> [TerminalPanel] {
        // Use the workspace's spatial (left-to-right, top-to-bottom) panel order
        // so the phone's terminal dropdown matches the on-screen bonsplit layout,
        // rather than focused-first/UUID order. `is_focused` in the payload still
        // tells the phone which terminal is active.
        orderedPanels(in: workspace).compactMap { $0 as? TerminalPanel }
    }

    func mobileNonEmpty(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    deinit {
        if let browserDownloadObserver {
            NotificationCenter.default.removeObserver(browserDownloadObserver)
        }
        // No stop() here: the controller is an app-lifetime singleton, so
        // deinit never runs; listener teardown is applicationWillTerminate's
        // synchronous stop() on the main actor.
    }
}

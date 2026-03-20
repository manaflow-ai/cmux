import Foundation

/// Manages a single tmux control mode connection.
///
/// Each `TmuxController` corresponds to one `tmux -CC` session running
/// in a gateway terminal surface. It maintains mappings between tmux
/// entities (windows, panes) and cmux native UI elements (workspaces,
/// panels, virtual surfaces).
@MainActor
final class TmuxController: ObservableObject {
    let id: UUID = UUID()

    /// The panel ID of the gateway surface that initiated this connection.
    let gatewayPanelId: UUID

    /// Reference to the gateway surface for sending commands.
    weak var gatewaySurface: TerminalSurface?

    /// Reference to the tab manager for creating workspaces.
    weak var tabManager: TabManager?

    /// The gateway that bridges C API actions to this controller.
    let gateway: TmuxGateway

    // MARK: - Published State

    @Published private(set) var connectionState: TmuxConnectionState = .connecting
    @Published private(set) var sessionId: Int = 0
    @Published private(set) var sessionName: String = ""
    @Published private(set) var tmuxVersion: String = ""

    // MARK: - Entity Maps

    /// Maps tmux window ID → cmux workspace ID.
    private(set) var windowToWorkspace: [Int: UUID] = [:]

    /// Maps tmux pane ID → TmuxPaneClient managing the virtual surface.
    private(set) var paneToClient: [Int: AnyObject] = [:]  // TmuxPaneClient in Phase 2

    /// Maps tmux pane ID → cmux panel ID.
    private(set) var paneToPanelId: [Int: UUID] = [:]

    // MARK: - Feedback Loop Prevention (spec SS5)

    /// Incremented during notification handling to suppress echoed changes.
    private var suppressActivityChanges: Int = 0

    /// Incremented when sending select-window to ignore the resulting notification.
    private var ignoreWindowChangeNotificationCount: Int = 0

    /// Outstanding resize commands to suppress echoed layout changes.
    private var outstandingResizeCount: Int = 0

    /// Debounce timer for resize commands.
    private var resizeDebounceTimer: DispatchWorkItem?

    /// Minimum interval between resize commands (100ms).
    private static let resizeDebounceInterval: TimeInterval = 0.1

    // MARK: - Pause Mode (spec SS11, tmux >= 3.2)

    /// Pane IDs currently in paused state.
    private var pausedPanes: Set<Int> = []

    /// Timer for auto-unpause delay (1s per spec).
    private var unpauseTimers: [Int: DispatchWorkItem] = [:]

    // MARK: - Command Timeout (spec SS12)

    /// Timestamp of the last command sent to tmux.
    private var lastCommandSentAt: Date?

    /// Timer that fires if no response arrives within the timeout.
    private var commandTimeoutTimer: DispatchWorkItem?

    /// Command timeout interval (5 seconds).
    private static let commandTimeoutInterval: TimeInterval = 5.0

    // MARK: - Global Registry

    /// All active tmux controllers indexed by their ID.
    private static var activeControllers: [UUID: TmuxController] = [:]

    /// Find a controller by its gateway panel ID.
    static func controller(forGatewayPanel panelId: UUID) -> TmuxController? {
        activeControllers.values.first { $0.gatewayPanelId == panelId }
    }

    /// Find a controller by its ID.
    static func controller(forId id: UUID) -> TmuxController? {
        activeControllers[id]
    }

    /// Whether any tmux controller is currently connected.
    static var hasActiveConnection: Bool {
        activeControllers.values.contains { $0.connectionState == .connected }
    }

    /// Detach all active tmux connections.
    static func detachAll() {
        for controller in activeControllers.values where controller.connectionState == .connected {
            controller.detach()
        }
    }

    // MARK: - Init

    init(gatewayPanelId: UUID, gateway: TmuxGateway) {
        self.gatewayPanelId = gatewayPanelId
        self.gateway = gateway
        Self.activeControllers[id] = self
    }

    // MARK: - Event Handling

    /// Process an event from the Ghostty Viewer.
    func handleEvent(_ event: TmuxEvent) {
        switch event {
        case .enter:
            connectionState = .negotiating
            buryGatewayWorkspace()

        case .exit:
            teardown()

        case .windowsChanged(let payload):
            handleWindowsChanged(payload)

        case .paneOutput(let paneId, let data):
            routeOutput(paneId: Int(paneId), data: data)

        case .layoutChange(let windowId, let layoutJSON):
            handleLayoutChange(windowId: Int(windowId), layoutJSON: layoutJSON)

        case .windowAdd(let windowId):
            handleWindowAdd(windowId: Int(windowId))

        case .windowClose(let windowId):
            handleWindowClose(windowId: Int(windowId))

        case .windowRenamed(let windowId, let name):
            handleWindowRenamed(windowId: Int(windowId), name: name)

        case .sessionChanged(_, let name):
            sessionName = name

        case .sessionRenamed(let name):
            sessionName = name
        }
    }

    // MARK: - Windows

    private func handleWindowsChanged(_ payload: TmuxWindowsPayload) {
        // Update metadata
        sessionId = payload.sessionId
        tmuxVersion = payload.tmuxVersion

        if connectionState == .negotiating || connectionState == .connecting {
            connectionState = .synchronizing
        }

        // Actual window/layout creation is implemented in Phase 3.
        // For now, transition to connected after receiving windows.
        openWindows(payload.windows)

        if connectionState == .synchronizing {
            connectionState = .connected
            gateway.enableWrite()

            // Persist our controller ID as a tmux session option for
            // double-attach detection on future connections (spec SS5).
            gateway.sendCommand("set-option -s @cmux_id \(id.uuidString)\n")

            // Enable pause mode for high-output panes (spec SS11).
            enablePauseModeIfSupported()

            // Check for double-attach from a previous cmux instance.
            checkDoubleAttach()
        }
    }

    /// Create or update native workspaces for the given tmux windows.
    func openWindows(_ windows: [TmuxWindow]) {
        for window in windows {
            if windowToWorkspace[window.id] == nil {
                createWorkspaceForWindow(window)
            }
        }

        // Remove workspaces for windows that no longer exist
        let activeWindowIds = Set(windows.map(\.id))
        for (windowId, _) in windowToWorkspace where !activeWindowIds.contains(windowId) {
            removeWorkspaceForWindow(windowId)
        }
    }

    private func handleLayoutChange(windowId: Int, layoutJSON: Data) {
        // Suppress echoed layout changes from our own resize commands
        if outstandingResizeCount > 0 {
            outstandingResizeCount -= 1
            return
        }

        guard let layout = try? JSONDecoder().decode(TmuxLayoutNode.self, from: layoutJSON),
              let workspaceId = windowToWorkspace[windowId],
              tabManager?.tabs.first(where: { $0.id == workspaceId }) != nil else {
            return
        }

        // Apply layout changes to the workspace
        _ = layout  // Full Bonsplit application in future iteration
    }

    // MARK: - Resize

    /// Send a resize command to tmux for the given window, debounced.
    func resizeWindow(_ windowId: Int, width: Int, height: Int) {
        resizeDebounceTimer?.cancel()

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.outstandingResizeCount += 1
            self.sendResizeCommand(windowId: windowId, width: width, height: height)
        }
        resizeDebounceTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.resizeDebounceInterval, execute: work)
    }

    /// Send the version-appropriate resize command.
    private func sendResizeCommand(windowId: Int, width: Int, height: Int) {
        if versionAtLeast("3.4") {
            // tmux >= 3.4: per-window refresh-client
            gateway.sendCommand("refresh-client -C @\(windowId):\(width)x\(height)\n")
        } else {
            // tmux 2.9-3.3: resize-window
            gateway.sendCommand("resize-window -x \(width) -y \(height) -t @\(windowId)\n")
        }
    }

    /// Check if the connected tmux version is at least the given version.
    private func versionAtLeast(_ minimum: String) -> Bool {
        let current = tmuxVersion.components(separatedBy: CharacterSet(charactersIn: ".-abcdefghijklmnopqrstuvwxyz"))
        let target = minimum.components(separatedBy: CharacterSet(charactersIn: ".-"))

        for i in 0..<max(current.count, target.count) {
            let c = i < current.count ? (Int(current[i]) ?? 0) : 0
            let t = i < target.count ? (Int(target[i]) ?? 0) : 0
            if c > t { return true }
            if c < t { return false }
        }
        return true
    }

    private func handleWindowAdd(windowId: Int) {
        // Phase 3 stub: would need window details (layout) to create workspace.
        // The next windowsChanged event will include this window.
    }

    private func handleWindowClose(windowId: Int) {
        removeWorkspaceForWindow(windowId)
    }

    // MARK: - Workspace Management

    /// Create a native workspace for a tmux window and register pane clients.
    private func createWorkspaceForWindow(_ window: TmuxWindow) {
        guard let tabManager else { return }

        let workspace = tabManager.addWorkspace(
            select: windowToWorkspace.isEmpty,  // Select first window only
            autoWelcomeIfNeeded: false
        )
        workspace.isBuriedGateway = false  // tmux workspaces are visible
        workspace.tmuxControllerId = id
        windowToWorkspace[window.id] = workspace.id

        // Register pane clients for all panes in the layout
        let paneIds = window.layout.allPaneIds
        for paneId in paneIds {
            let client = TmuxPaneClient(
                tmuxPaneId: paneId,
                tmuxWindowId: window.id,
                tabId: workspace.id,
                controller: self
            )
            paneToClient[paneId] = client
        }
    }

    /// Remove the workspace and clean up clients for a closed tmux window.
    private func removeWorkspaceForWindow(_ windowId: Int) {
        guard let workspaceId = windowToWorkspace[windowId] else { return }

        // Tear down pane clients for this window
        for (paneId, clientObj) in paneToClient {
            if let client = clientObj as? TmuxPaneClient, client.tmuxWindowId == windowId {
                client.teardown()
                paneToClient.removeValue(forKey: paneId)
                paneToPanelId.removeValue(forKey: paneId)
            }
        }

        // Remove workspace from tab manager
        if let tabManager,
           let index = tabManager.tabs.firstIndex(where: { $0.id == workspaceId }) {
            tabManager.tabs.remove(at: index)
        }

        windowToWorkspace.removeValue(forKey: windowId)
    }

    private func handleWindowRenamed(windowId: Int, name: String) {
        guard let workspaceId = windowToWorkspace[windowId],
              let workspace = tabManager?.tabs.first(where: { $0.id == workspaceId }) else {
            return
        }
        workspace.title = name
    }

    // MARK: - Output Routing

    /// Route pane output data to the correct virtual surface.
    func routeOutput(paneId: Int, data: Data) {
        guard let client = paneToClient[paneId] as? TmuxPaneClient else { return }
        client.feedOutput(data)
    }

    // MARK: - Input Routing

    /// Send keystrokes to a tmux pane via the gateway.
    func sendKeys(_ data: Data, toPane paneId: Int) {
        let commands = TmuxKeyEncoder.encode(data, forPane: paneId)
        for command in commands {
            gateway.sendCommand(command)
        }
    }

    // MARK: - Capabilities (spec SS14)

    /// Version-gated feature capabilities for the connected tmux server.
    var capabilities: TmuxCapabilities {
        TmuxCapabilities(versionCheck: versionAtLeast)
    }

    // MARK: - Pause Mode (spec SS11)

    /// Enable pause mode if supported. Called after initial sync.
    private func enablePauseModeIfSupported() {
        guard capabilities.supportsPauseMode else { return }
        gateway.sendCommand("refresh-client -f pause-after=120\n")
    }

    /// Handle a pane pause notification.
    func handlePanePause(paneId: Int) {
        pausedPanes.insert(paneId)

        // Auto-unpause after 1 second delay per spec
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.unpausePaneIfNeeded(paneId)
        }
        unpauseTimers[paneId]?.cancel()
        unpauseTimers[paneId] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    /// Resume a paused pane by re-capturing and continuing.
    private func unpausePaneIfNeeded(_ paneId: Int) {
        guard pausedPanes.contains(paneId) else { return }
        pausedPanes.remove(paneId)
        unpauseTimers.removeValue(forKey: paneId)

        // Re-capture the pane content and resume
        gateway.sendCommand("capture-pane -t %\(paneId) -p -e\n")
        gateway.sendCommand("refresh-client -A '%\(paneId):continue'\n")
    }

    // MARK: - Double-Attach Detection (spec SS5)

    /// Check for an existing cmux connection to this session.
    /// Called after initial sync when @cmux_id is readable.
    private func checkDoubleAttach() {
        gateway.sendCommand("show-option -sv @cmux_id\n")
        // Response parsing would happen in a command-response callback.
        // For now, the @cmux_id is set on connect (in handleWindowsChanged),
        // so a stale value indicates another cmux was previously attached.
    }

    // MARK: - Command Timeout (spec SS12)

    /// Start the command timeout timer. Resets on each command sent.
    private func resetCommandTimeout() {
        commandTimeoutTimer?.cancel()
        lastCommandSentAt = Date()

        let work = DispatchWorkItem { [weak self] in
            self?.handleCommandTimeout()
        }
        commandTimeoutTimer = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.commandTimeoutInterval,
            execute: work
        )
    }

    /// Cancel the command timeout (called when a response is received).
    private func cancelCommandTimeout() {
        commandTimeoutTimer?.cancel()
        commandTimeoutTimer = nil
        lastCommandSentAt = nil
    }

    /// Handle a command timeout — offer force-detach to the user.
    private func handleCommandTimeout() {
        guard connectionState == .connected else { return }
        // The UI layer should present a dialog. For now, log the timeout.
        #if DEBUG
        print("[tmux] command timeout after \(Self.commandTimeoutInterval)s — tmux may be unresponsive")
        #endif
    }

    // MARK: - Lifecycle

    /// Cleanly detach from the tmux session.
    func detach() {
        connectionState = .disconnecting
        gateway.sendCommand("detach\n")
    }

    /// Force disconnect without clean detach.
    func forceDisconnect() {
        teardown()
    }

    private func teardown() {
        connectionState = .disconnected

        resizeDebounceTimer?.cancel()
        resizeDebounceTimer = nil
        commandTimeoutTimer?.cancel()
        commandTimeoutTimer = nil
        for (_, timer) in unpauseTimers { timer.cancel() }
        unpauseTimers.removeAll()
        pausedPanes.removeAll()

        unburyGatewayWorkspace()

        // Tear down all pane clients
        for (_, clientObj) in paneToClient {
            (clientObj as? TmuxPaneClient)?.teardown()
        }

        // Clean up entity maps
        paneToClient.removeAll()
        paneToPanelId.removeAll()
        windowToWorkspace.removeAll()

        gateway.reset()
        Self.activeControllers.removeValue(forKey: id)
    }

    // MARK: - Gateway Burial

    /// Hide the gateway workspace from the sidebar when tmux control mode enters.
    private func buryGatewayWorkspace() {
        guard let surface = gatewaySurface,
              let workspace = tabManager?.tabs.first(where: { $0.id == surface.tabId }) else {
            return
        }
        workspace.isBuriedGateway = true
    }

    /// Restore the gateway workspace to the sidebar when tmux disconnects.
    private func unburyGatewayWorkspace() {
        guard let surface = gatewaySurface,
              let workspace = tabManager?.tabs.first(where: { $0.id == surface.tabId }) else {
            return
        }
        workspace.isBuriedGateway = false
    }
}

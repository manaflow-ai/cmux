import AppKit
import Carbon.HIToolbox
import Foundation
import Bonsplit
import WebKit

/// Unix socket-based controller for programmatic terminal control
/// Allows automated testing and external control of terminal tabs
@MainActor
class TerminalController {
    static let shared = TerminalController()

    private nonisolated(unsafe) var socketPath = "/tmp/cmux.sock"
    private nonisolated(unsafe) var serverSocket: Int32 = -1
    private nonisolated(unsafe) var isRunning = false
    private nonisolated(unsafe) var acceptLoopAlive = false
    private var clientHandlers: [Int32: Thread] = [:]
    private var tabManager: TabManager?
    private var accessMode: SocketControlMode = .cmuxOnly
    private let myPid = getpid()
    private nonisolated(unsafe) static var socketCommandPolicyDepth: Int = 0
    private nonisolated(unsafe) static var socketCommandFocusAllowanceStack: [Bool] = []
    private nonisolated static let socketCommandPolicyLock = NSLock()

    private static let focusIntentV1Commands: Set<String> = [
        "focus_window",
        "select_workspace",
        "focus_surface",
        "focus_pane",
        "focus_surface_by_panel",
        "focus_webview",
        "focus_notification",
        "activate_app"
    ]

    private static let focusIntentV2Methods: Set<String> = [
        "window.focus",
        "workspace.select",
        "workspace.next",
        "workspace.previous",
        "workspace.last",
        "surface.focus",
        "pane.focus",
        "pane.last",
        "browser.focus_webview",
        "browser.focus",
        "browser.tab.switch",
        "debug.command_palette.toggle",
        "debug.notification.focus",
        "debug.app.activate"
    ]

    private enum V2HandleKind: String, CaseIterable {
        case window
        case workspace
        case pane
        case surface
    }

    private var v2NextHandleOrdinal: [V2HandleKind: Int] = [
        .window: 1,
        .workspace: 1,
        .pane: 1,
        .surface: 1,
    ]
    private var v2RefByUUID: [V2HandleKind: [UUID: String]] = [
        .window: [:],
        .workspace: [:],
        .pane: [:],
        .surface: [:],
    ]
    private var v2UUIDByRef: [V2HandleKind: [String: UUID]] = [
        .window: [:],
        .workspace: [:],
        .pane: [:],
        .surface: [:],
    ]

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

    private var v2BrowserNextElementOrdinal: Int = 1
    private var v2BrowserElementRefs: [String: V2BrowserElementRefEntry] = [:]
    private var v2BrowserFrameSelectorBySurface: [UUID: String] = [:]
    private var v2BrowserInitScriptsBySurface: [UUID: [String]] = [:]
    private var v2BrowserInitStylesBySurface: [UUID: [String]] = [:]
    private var v2BrowserDialogQueueBySurface: [UUID: [V2BrowserPendingDialog]] = [:]
    private var v2BrowserDownloadEventsBySurface: [UUID: [[String: Any]]] = [:]
    private var v2BrowserUnsupportedNetworkRequestsBySurface: [UUID: [[String: Any]]] = [:]

    private init() {}

    nonisolated static func shouldSuppressSocketCommandActivation() -> Bool {
        socketCommandPolicyLock.lock()
        defer { socketCommandPolicyLock.unlock() }
        return socketCommandPolicyDepth > 0
    }

    nonisolated static func socketCommandAllowsInAppFocusMutations() -> Bool {
        allowsInAppFocusMutationsForActiveSocketCommand()
    }

    private nonisolated static func allowsInAppFocusMutationsForActiveSocketCommand() -> Bool {
        socketCommandPolicyLock.lock()
        defer { socketCommandPolicyLock.unlock() }
        return socketCommandFocusAllowanceStack.last ?? false
    }

    private static func socketCommandAllowsInAppFocusMutations(commandKey: String, isV2: Bool) -> Bool {
        if isV2 {
            return focusIntentV2Methods.contains(commandKey)
        }
        return focusIntentV1Commands.contains(commandKey)
    }

    private func withSocketCommandPolicy<T>(commandKey: String, isV2: Bool, _ body: () -> T) -> T {
        let allowsFocusMutation = Self.socketCommandAllowsInAppFocusMutations(commandKey: commandKey, isV2: isV2)
        Self.socketCommandPolicyLock.lock()
        Self.socketCommandPolicyDepth += 1
        Self.socketCommandFocusAllowanceStack.append(allowsFocusMutation)
        Self.socketCommandPolicyLock.unlock()
        defer {
            Self.socketCommandPolicyLock.lock()
            if !Self.socketCommandFocusAllowanceStack.isEmpty {
                _ = Self.socketCommandFocusAllowanceStack.popLast()
            }
            Self.socketCommandPolicyDepth = max(0, Self.socketCommandPolicyDepth - 1)
            Self.socketCommandPolicyLock.unlock()
        }
        return body()
    }

    private func socketCommandAllowsInAppFocusMutations() -> Bool {
        Self.allowsInAppFocusMutationsForActiveSocketCommand()
    }

    private func v2FocusAllowed(requested: Bool = true) -> Bool {
        requested && socketCommandAllowsInAppFocusMutations()
    }

    private func v2MaybeFocusWindow(for tabManager: TabManager) {
        guard socketCommandAllowsInAppFocusMutations(),
              let windowId = v2ResolveWindowId(tabManager: tabManager) else { return }
        _ = AppDelegate.shared?.focusMainWindow(windowId: windowId)
        setActiveTabManager(tabManager)
    }

    private func v2MaybeSelectWorkspace(_ tabManager: TabManager, workspace: Workspace) {
        guard socketCommandAllowsInAppFocusMutations() else { return }
        if tabManager.selectedTabId != workspace.id {
            tabManager.selectWorkspace(workspace)
        }
    }

    nonisolated static func shouldReplaceStatusEntry(
        current: SidebarStatusEntry?,
        key: String,
        value: String,
        icon: String?,
        color: String?
    ) -> Bool {
        guard let current else { return true }
        return current.key != key || current.value != value || current.icon != icon || current.color != color
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

    nonisolated static func shouldReplacePorts(current: [Int]?, next: [Int]) -> Bool {
        let currentSorted = Array(Set(current ?? [])).sorted()
        let nextSorted = Array(Set(next)).sorted()
        return currentSorted != nextSorted
    }

    private struct SocketSurfaceKey: Hashable {
        let workspaceId: UUID
        let panelId: UUID
    }

    private final class SocketFastPathState: @unchecked Sendable {
        private let queue = DispatchQueue(label: "com.cmux.socket-fast-path")
        private var lastReportedDirectories: [SocketSurfaceKey: String] = [:]
        private let maxTrackedDirectories = 4096

        func shouldPublishDirectory(workspaceId: UUID, panelId: UUID, directory: String) -> Bool {
            let key = SocketSurfaceKey(workspaceId: workspaceId, panelId: panelId)
            return queue.sync {
                if lastReportedDirectories[key] == directory {
                    return false
                }
                if lastReportedDirectories.count >= maxTrackedDirectories {
                    lastReportedDirectories.removeAll(keepingCapacity: true)
                }
                lastReportedDirectories[key] = directory
                return true
            }
        }
    }

    private static let socketFastPathState = SocketFastPathState()

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

    /// Update which window's TabManager receives socket commands.
    /// This is used when the user switches between multiple terminal windows.
    func setActiveTabManager(_ tabManager: TabManager?) {
        self.tabManager = tabManager
    }

    // MARK: - Process Ancestry Check

    /// Get the peer PID of a connected Unix domain socket using LOCAL_PEERPID.
    private nonisolated func getPeerPid(_ socket: Int32) -> pid_t? {
        var pid: pid_t = 0
        var pidSize = socklen_t(MemoryLayout<pid_t>.size)
        let result = getsockopt(socket, SOL_LOCAL, LOCAL_PEERPID, &pid, &pidSize)
        if result != 0 || pid <= 0 {
            return nil
        }
        return pid
    }

    /// Check if the peer has the same UID as this process using LOCAL_PEERCRED.
    /// This works even after the peer has disconnected (unlike LOCAL_PEERPID).
    private func peerHasSameUID(_ socket: Int32) -> Bool {
        var cred = xucred()
        var credLen = socklen_t(MemoryLayout<xucred>.size)
        let result = getsockopt(socket, SOL_LOCAL, LOCAL_PEERCRED, &cred, &credLen)
        guard result == 0 else { return false }
        return cred.cr_uid == getuid()
    }

    /// Check if `pid` is a descendant of this process by walking the process tree.
    func isDescendant(_ pid: pid_t) -> Bool {
        var current = pid
        // Walk up to 128 levels to avoid infinite loops from kernel bugs
        for _ in 0..<128 {
            if current == myPid {
                return true
            }
            if current <= 1 {
                return false
            }
            let parent = parentPid(of: current)
            if parent == current || parent < 0 {
                return false
            }
            current = parent
        }
        return false
    }

    /// Get the parent PID of a process using sysctl.
    private func parentPid(of pid: pid_t) -> pid_t {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else {
            return -1
        }
        return info.kp_eproc.e_ppid
    }

    func start(tabManager: TabManager, socketPath: String, accessMode: SocketControlMode) {
        self.tabManager = tabManager
        self.accessMode = accessMode

        if isRunning {
            if self.socketPath == socketPath && acceptLoopAlive {
                self.accessMode = accessMode
                applySocketPermissions()
                return
            }
            stop()
        }

        self.socketPath = socketPath

        // Remove existing socket file
        unlink(socketPath)

        // Create socket
        serverSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            print("TerminalController: Failed to create socket")
            return
        }

        // Bind to path
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                let pathBuf = UnsafeMutableRawPointer(pathPtr).assumingMemoryBound(to: CChar.self)
                strcpy(pathBuf, ptr)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(serverSocket, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard bindResult >= 0 else {
            print("TerminalController: Failed to bind socket")
            close(serverSocket)
            return
        }

        applySocketPermissions()

        // Listen
        guard listen(serverSocket, 5) >= 0 else {
            print("TerminalController: Failed to listen on socket")
            close(serverSocket)
            return
        }

        isRunning = true
        print("TerminalController: Listening on \(socketPath)")

        // Wire batched port scanner results back to workspace state.
        PortScanner.shared.onPortsUpdated = { [weak self] workspaceId, panelId, ports in
            MainActor.assumeIsolated {
                guard let self, let tabManager = self.tabManager else { return }
                guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) else { return }
                let validSurfaceIds = Set(workspace.panels.keys)
                guard validSurfaceIds.contains(panelId) else { return }
                let nextPorts = Array(Set(ports)).sorted()
                let currentPorts = workspace.surfaceListeningPorts[panelId] ?? []
                guard currentPorts != nextPorts else { return }
                if nextPorts.isEmpty {
                    workspace.surfaceListeningPorts.removeValue(forKey: panelId)
                } else {
                    workspace.surfaceListeningPorts[panelId] = nextPorts
                }
                workspace.recomputeListeningPorts()
            }
        }

        // Accept connections in background thread
        Thread.detachNewThread { [weak self] in
            self?.acceptLoop()
        }
    }

    nonisolated func stop() {
        isRunning = false
        if serverSocket >= 0 {
            close(serverSocket)
            serverSocket = -1
        }
        unlink(socketPath)
    }

    private func applySocketPermissions() {
        let permissions = mode_t(accessMode.socketFilePermissions)
        if chmod(socketPath, permissions) != 0 {
            print("TerminalController: Failed to set socket permissions to \(String(permissions, radix: 8)) for \(socketPath)")
        }
    }

    private func writeSocketResponse(_ response: String, to socket: Int32) {
        let payload = response + "\n"
        payload.withCString { ptr in
            _ = write(socket, ptr, strlen(ptr))
        }
    }

    private func passwordAuthRequiredResponse(for command: String) -> String {
        let message = "Authentication required. Send auth <password> first."
        guard command.hasPrefix("{"),
              let data = command.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else {
            return "ERROR: Authentication required — send auth <password> first"
        }
        let id = dict["id"]
        return v2Error(id: id, code: "auth_required", message: message)
    }

    private func passwordLoginV1ResponseIfNeeded(for command: String, authenticated: inout Bool) -> String? {
        let lowered = command.lowercased()
        guard lowered == "auth" || lowered.hasPrefix("auth ") else {
            return nil
        }
        guard SocketControlPasswordStore.hasConfiguredPassword() else {
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
        guard SocketControlPasswordStore.verify(password: provided) else {
            return "ERROR: Invalid password"
        }
        authenticated = true
        return "OK: Authenticated"
    }

    private func passwordLoginV2ResponseIfNeeded(for command: String, authenticated: inout Bool) -> String? {
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

        guard SocketControlPasswordStore.hasConfiguredPassword() else {
            return v2Error(
                id: id,
                code: "auth_unconfigured",
                message: "Password mode is enabled but no socket password is configured in Settings."
            )
        }

        guard SocketControlPasswordStore.verify(password: provided) else {
            return v2Error(id: id, code: "auth_failed", message: "Invalid password")
        }
        authenticated = true
        return v2Ok(id: id, result: ["authenticated": true])
    }

    private func authResponseIfNeeded(for command: String, authenticated: inout Bool) -> String? {
        guard accessMode.requiresPasswordAuth else {
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

    private nonisolated func acceptLoop() {
        acceptLoopAlive = true
        defer {
            acceptLoopAlive = false
            isRunning = false
        }

        var consecutiveFailures = 0
        while isRunning {
            var clientAddr = sockaddr_un()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)

            let clientSocket = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    accept(serverSocket, sockaddrPtr, &clientAddrLen)
                }
            }

            guard clientSocket >= 0 else {
                if isRunning {
                    consecutiveFailures += 1
                    print("TerminalController: Accept failed (\(consecutiveFailures) consecutive)")
                    if consecutiveFailures >= 50 {
                        print("TerminalController: Too many consecutive accept failures, exiting accept loop")
                        break
                    }
                    usleep(10_000) // 10ms backoff
                }
                continue
            }

            consecutiveFailures = 0

            // Capture peer PID immediately — before the client can disconnect.
            // ncat --send-only closes the connection right after writing, so by
            // the time a new thread starts the peer may already be gone.
            let peerPid = getPeerPid(clientSocket)

            // Handle client in new thread
            Thread.detachNewThread { [weak self] in
                self?.handleClient(clientSocket, peerPid: peerPid)
            }
        }
    }

    private func handleClient(_ socket: Int32, peerPid: pid_t? = nil) {
        defer { close(socket) }

        // In cmuxOnly mode, verify the connecting process is a descendant of cmux.
        // Other modes allow external clients and apply separate auth controls.
        if accessMode == .cmuxOnly {
            // Use pre-captured peer PID if available (captured in accept loop before
            // the peer can disconnect), falling back to live lookup.
            let pid = peerPid ?? getPeerPid(socket)
            if let pid {
                guard isDescendant(pid) else {
                    let msg = "ERROR: Access denied — only processes started inside cmux can connect\n"
                    msg.withCString { ptr in _ = write(socket, ptr, strlen(ptr)) }
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
                guard peerHasSameUID(socket) else {
                    let msg = "ERROR: Unable to verify client process\n"
                    msg.withCString { ptr in _ = write(socket, ptr, strlen(ptr)) }
                    return
                }
            }
        }

        var buffer = [UInt8](repeating: 0, count: 4096)
        var pending = ""
        var authenticated = false

        while isRunning {
            let bytesRead = read(socket, &buffer, buffer.count - 1)
            guard bytesRead > 0 else { break }

            let chunk = String(bytes: buffer[0..<bytesRead], encoding: .utf8) ?? ""
            pending.append(chunk)

            while let newlineIndex = pending.firstIndex(of: "\n") {
                let line = String(pending[..<newlineIndex])
                pending = String(pending[pending.index(after: newlineIndex)...])
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }

                if let authResponse = authResponseIfNeeded(for: trimmed, authenticated: &authenticated) {
                    writeSocketResponse(authResponse, to: socket)
                    continue
                }

                let response = processCommand(trimmed)
                writeSocketResponse(response, to: socket)
            }
        }
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

        #if DEBUG
        let startedAt = ProcessInfo.processInfo.systemUptime
        #endif

        let response = withSocketCommandPolicy(commandKey: cmd, isV2: false) {
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
	            return newWorkspace()

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

        case "list_notifications":
            return listNotifications()

        case "clear_notifications":
            return clearNotifications()

        case "set_app_focus":
            return setAppFocusOverride(args)

        case "simulate_app_active":
            return simulateAppDidBecomeActive()

        case "set_status":
            return setStatus(args)

        case "clear_status":
            return clearStatus(args)

        case "list_status":
            return listStatus(args)

        case "log":
            return appendLog(args)

        case "clear_log":
            return clearLog(args)

        case "list_log":
            return listLog(args)

        case "set_progress":
            return setProgress(args)

        case "clear_progress":
            return clearProgress(args)

        case "report_git_branch":
            return reportGitBranch(args)

        case "clear_git_branch":
            return clearGitBranch(args)

        case "report_ports":
            return reportPorts(args)

        case "clear_ports":
            return clearPorts(args)

        case "report_tty":
            return reportTTY(args)

        case "ports_kick":
            return portsKick(args)

        case "report_pwd":
            return reportPwd(args)

        case "sidebar_state":
            return sidebarState(args)

        case "reset_sidebar":
            return resetSidebar(args)

        case "read_screen":
            return readScreenText(args)


#if DEBUG
        case "set_shortcut":
            return setShortcut(args)

        case "simulate_shortcut":
            return simulateShortcut(args)

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

        case "activate_app":
            return activateApp()

        case "is_terminal_focused":
            return isTerminalFocused(args)

        case "read_terminal_text":
            return readTerminalText(args)

        case "render_stats":
            return renderStats(args)

        case "layout_debug":
            return layoutDebug()

        case "bonsplit_underflow_count":
            return bonsplitUnderflowCount()

        case "reset_bonsplit_underflow_count":
            return resetBonsplitUnderflowCount()

        case "empty_panel_count":
            return emptyPanelCount()

        case "reset_empty_panel_count":
            return resetEmptyPanelCount()

        case "focus_notification":
            return focusFromNotification(args)

        case "flash_count":
            return flashCount(args)

        case "reset_flash_counts":
            return resetFlashCounts()

        case "panel_snapshot":
            return panelSnapshot(args)

        case "panel_snapshot_reset":
            return panelSnapshotReset(args)

        case "screenshot":
            return captureScreenshot(args)
#endif

        case "help":
            return helpText()

        // Browser panel commands
        case "open_browser":
            return openBrowser(args)

        case "navigate":
            return navigateBrowser(args)

        case "browser_back":
            return browserBack(args)

        case "browser_forward":
            return browserForward(args)

        case "browser_reload":
            return browserReload(args)

        case "get_url":
            return getUrl(args)

        case "focus_webview":
            return focusWebView(args)

        case "is_webview_focused":
            return isWebViewFocused(args)

        case "list_panes":
            return listPanes()

        case "list_pane_surfaces":
            return listPaneSurfaces(args)

	        case "focus_pane":
	            return focusPane(args)

	        case "focus_surface_by_panel":
	            return focusSurfaceByPanel(args)

	        case "drag_surface_to_split":
	            return dragSurfaceToSplit(args)

	        case "new_pane":
	            return newPane(args)

        case "new_surface":
            return newSurface(args)

        case "close_surface":
            return closeSurface(args)

        case "refresh_surfaces":
            return refreshSurfaces()

        case "surface_health":
            return surfaceHealth(args)

        default:
            return "ERROR: Unknown command '\(cmd)'. Use 'help' for available commands."
        }
        }

        #if DEBUG
        if cmd == "new_workspace" || cmd == "send" || cmd == "send_surface" {
            let elapsedMs = (ProcessInfo.processInfo.systemUptime - startedAt) * 1000.0
            let status = response.hasPrefix("OK") ? "ok" : "err"
            dlog(
                "socket.v1 cmd=\(cmd) status=\(status) ms=\(String(format: "%.2f", elapsedMs)) main=\(Thread.isMainThread ? 1 : 0)"
            )
        }
        #endif

        return response
    }

    // MARK: - V2 JSON Socket Protocol

    private func processV2Command(_ jsonLine: String) -> String {
        // v1 access-mode gating applies to v2 as well. We can't know which v2 method maps
        // to which v1 command without parsing, so parse first and then apply allow-list.

        guard let data = jsonLine.data(using: .utf8) else {
            return v2Encode(["ok": false, "error": ["code": "invalid_utf8", "message": "Invalid UTF-8"]])
        }

        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            return v2Encode(["ok": false, "error": ["code": "parse_error", "message": "Invalid JSON"]])
        }

        guard let dict = object as? [String: Any] else {
            return v2Encode(["ok": false, "error": ["code": "invalid_request", "message": "Expected JSON object"]])
        }

        let id: Any? = dict["id"]
        let method = (dict["method"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let params = dict["params"] as? [String: Any] ?? [:]

        guard !method.isEmpty else {
            return v2Error(id: id, code: "invalid_request", message: "Missing method")
        }

        v2MainSync { self.v2RefreshKnownRefs() }


        #if DEBUG
        let startedAt = ProcessInfo.processInfo.systemUptime
        #endif

        let response = withSocketCommandPolicy(commandKey: method, isV2: true) {
            switch method {
        case "system.ping":
            return v2Ok(id: id, result: ["pong": true])
        case "system.capabilities":
            return v2Ok(id: id, result: v2Capabilities())

        case "system.identify":
            return v2Ok(id: id, result: v2Identify(params: params))
        case "auth.login":
            return v2Ok(
                id: id,
                result: [
                    "authenticated": true,
                    "required": accessMode.requiresPasswordAuth
                ]
            )

        // Windows
        case "window.list":
            return v2Result(id: id, self.v2WindowList(params: params))
        case "window.current":
            return v2Result(id: id, self.v2WindowCurrent(params: params))
        case "window.focus":
            return v2Result(id: id, self.v2WindowFocus(params: params))
        case "window.create":
            return v2Result(id: id, self.v2WindowCreate(params: params))
        case "window.close":
            return v2Result(id: id, self.v2WindowClose(params: params))

        // Workspaces
        case "workspace.list":
            return v2Result(id: id, self.v2WorkspaceList(params: params))
        case "workspace.create":
            return v2Result(id: id, self.v2WorkspaceCreate(params: params))
        case "workspace.select":
            return v2Result(id: id, self.v2WorkspaceSelect(params: params))
        case "workspace.current":
            return v2Result(id: id, self.v2WorkspaceCurrent(params: params))
        case "workspace.close":
            return v2Result(id: id, self.v2WorkspaceClose(params: params))
        case "workspace.move_to_window":
            return v2Result(id: id, self.v2WorkspaceMoveToWindow(params: params))
        case "workspace.reorder":
            return v2Result(id: id, self.v2WorkspaceReorder(params: params))
        case "workspace.rename":
            return v2Result(id: id, self.v2WorkspaceRename(params: params))
        case "workspace.action":
            return v2Result(id: id, self.v2WorkspaceAction(params: params))
        case "workspace.next":
            return v2Result(id: id, self.v2WorkspaceNext(params: params))
        case "workspace.previous":
            return v2Result(id: id, self.v2WorkspacePrevious(params: params))
        case "workspace.last":
            return v2Result(id: id, self.v2WorkspaceLast(params: params))


        // Surfaces / input
        case "surface.list":
            return v2Result(id: id, self.v2SurfaceList(params: params))
        case "surface.current":
            return v2Result(id: id, self.v2SurfaceCurrent(params: params))
        case "surface.focus":
            return v2Result(id: id, self.v2SurfaceFocus(params: params))
        case "surface.split":
            return v2Result(id: id, self.v2SurfaceSplit(params: params))
        case "surface.create":
            return v2Result(id: id, self.v2SurfaceCreate(params: params))
        case "surface.close":
            return v2Result(id: id, self.v2SurfaceClose(params: params))
        case "surface.move":
            return v2Result(id: id, self.v2SurfaceMove(params: params))
        case "surface.reorder":
            return v2Result(id: id, self.v2SurfaceReorder(params: params))
        case "surface.action":
            return v2Result(id: id, self.v2TabAction(params: params))
        case "tab.action":
            return v2Result(id: id, self.v2TabAction(params: params))
        case "surface.drag_to_split":
            return v2Result(id: id, self.v2SurfaceDragToSplit(params: params))
        case "surface.refresh":
            return v2Result(id: id, self.v2SurfaceRefresh(params: params))
        case "surface.health":
            return v2Result(id: id, self.v2SurfaceHealth(params: params))
        case "surface.send_text":
            return v2Result(id: id, self.v2SurfaceSendText(params: params))
        case "surface.send_key":
            return v2Result(id: id, self.v2SurfaceSendKey(params: params))
        case "surface.clear_history":
            return v2Result(id: id, self.v2SurfaceClearHistory(params: params))
        case "surface.trigger_flash":
            return v2Result(id: id, self.v2SurfaceTriggerFlash(params: params))

        // Panes
        case "pane.list":
            return v2Result(id: id, self.v2PaneList(params: params))
        case "pane.focus":
            return v2Result(id: id, self.v2PaneFocus(params: params))
        case "pane.surfaces":
            return v2Result(id: id, self.v2PaneSurfaces(params: params))
        case "pane.create":
            return v2Result(id: id, self.v2PaneCreate(params: params))
        case "pane.resize":
            return v2Result(id: id, self.v2PaneResize(params: params))
        case "pane.swap":
            return v2Result(id: id, self.v2PaneSwap(params: params))
        case "pane.break":
            return v2Result(id: id, self.v2PaneBreak(params: params))
        case "pane.join":
            return v2Result(id: id, self.v2PaneJoin(params: params))
        case "pane.last":
            return v2Result(id: id, self.v2PaneLast(params: params))

        // Notifications
        case "notification.create":
            return v2Result(id: id, self.v2NotificationCreate(params: params))
        case "notification.create_for_surface":
            return v2Result(id: id, self.v2NotificationCreateForSurface(params: params))
        case "notification.create_for_target":
            return v2Result(id: id, self.v2NotificationCreateForTarget(params: params))
        case "notification.list":
            return v2Ok(id: id, result: self.v2NotificationList())
        case "notification.clear":
            return v2Result(id: id, self.v2NotificationClear())

        // App focus
        case "app.focus_override.set":
            return v2Result(id: id, self.v2AppFocusOverride(params: params))
        case "app.simulate_active":
            return v2Result(id: id, self.v2AppSimulateActive())

        // Browser
        case "browser.open_split":
            return v2Result(id: id, self.v2BrowserOpenSplit(params: params))
        case "browser.navigate":
            return v2Result(id: id, self.v2BrowserNavigate(params: params))
        case "browser.back":
            return v2Result(id: id, self.v2BrowserBack(params: params))
        case "browser.forward":
            return v2Result(id: id, self.v2BrowserForward(params: params))
        case "browser.reload":
            return v2Result(id: id, self.v2BrowserReload(params: params))
        case "browser.url.get":
            return v2Result(id: id, self.v2BrowserGetURL(params: params))
        case "browser.focus_webview":
            return v2Result(id: id, self.v2BrowserFocusWebView(params: params))
        case "browser.is_webview_focused":
            return v2Result(id: id, self.v2BrowserIsWebViewFocused(params: params))
        case "browser.snapshot":
            return v2Result(id: id, self.v2BrowserSnapshot(params: params))
        case "browser.eval":
            return v2Result(id: id, self.v2BrowserEval(params: params))
        case "browser.wait":
            return v2Result(id: id, self.v2BrowserWait(params: params))
        case "browser.click":
            return v2Result(id: id, self.v2BrowserClick(params: params))
        case "browser.dblclick":
            return v2Result(id: id, self.v2BrowserDblClick(params: params))
        case "browser.hover":
            return v2Result(id: id, self.v2BrowserHover(params: params))
        case "browser.focus":
            return v2Result(id: id, self.v2BrowserFocusElement(params: params))
        case "browser.type":
            return v2Result(id: id, self.v2BrowserType(params: params))
        case "browser.fill":
            return v2Result(id: id, self.v2BrowserFill(params: params))
        case "browser.press":
            return v2Result(id: id, self.v2BrowserPress(params: params))
        case "browser.keydown":
            return v2Result(id: id, self.v2BrowserKeyDown(params: params))
        case "browser.keyup":
            return v2Result(id: id, self.v2BrowserKeyUp(params: params))
        case "browser.check":
            return v2Result(id: id, self.v2BrowserCheck(params: params, checked: true))
        case "browser.uncheck":
            return v2Result(id: id, self.v2BrowserCheck(params: params, checked: false))
        case "browser.select":
            return v2Result(id: id, self.v2BrowserSelect(params: params))
        case "browser.scroll":
            return v2Result(id: id, self.v2BrowserScroll(params: params))
        case "browser.scroll_into_view":
            return v2Result(id: id, self.v2BrowserScrollIntoView(params: params))
        case "browser.screenshot":
            return v2Result(id: id, self.v2BrowserScreenshot(params: params))
        case "browser.get.text":
            return v2Result(id: id, self.v2BrowserGetText(params: params))
        case "browser.get.html":
            return v2Result(id: id, self.v2BrowserGetHTML(params: params))
        case "browser.get.value":
            return v2Result(id: id, self.v2BrowserGetValue(params: params))
        case "browser.get.attr":
            return v2Result(id: id, self.v2BrowserGetAttr(params: params))
        case "browser.get.title":
            return v2Result(id: id, self.v2BrowserGetTitle(params: params))
        case "browser.get.count":
            return v2Result(id: id, self.v2BrowserGetCount(params: params))
        case "browser.get.box":
            return v2Result(id: id, self.v2BrowserGetBox(params: params))
        case "browser.get.styles":
            return v2Result(id: id, self.v2BrowserGetStyles(params: params))
        case "browser.is.visible":
            return v2Result(id: id, self.v2BrowserIsVisible(params: params))
        case "browser.is.enabled":
            return v2Result(id: id, self.v2BrowserIsEnabled(params: params))
        case "browser.is.checked":
            return v2Result(id: id, self.v2BrowserIsChecked(params: params))
        case "browser.find.role":
            return v2Result(id: id, self.v2BrowserFindRole(params: params))
        case "browser.find.text":
            return v2Result(id: id, self.v2BrowserFindText(params: params))
        case "browser.find.label":
            return v2Result(id: id, self.v2BrowserFindLabel(params: params))
        case "browser.find.placeholder":
            return v2Result(id: id, self.v2BrowserFindPlaceholder(params: params))
        case "browser.find.alt":
            return v2Result(id: id, self.v2BrowserFindAlt(params: params))
        case "browser.find.title":
            return v2Result(id: id, self.v2BrowserFindTitle(params: params))
        case "browser.find.testid":
            return v2Result(id: id, self.v2BrowserFindTestId(params: params))
        case "browser.find.first":
            return v2Result(id: id, self.v2BrowserFindFirst(params: params))
        case "browser.find.last":
            return v2Result(id: id, self.v2BrowserFindLast(params: params))
        case "browser.find.nth":
            return v2Result(id: id, self.v2BrowserFindNth(params: params))
        case "browser.frame.select":
            return v2Result(id: id, self.v2BrowserFrameSelect(params: params))
        case "browser.frame.main":
            return v2Result(id: id, self.v2BrowserFrameMain(params: params))
        case "browser.dialog.accept":
            return v2Result(id: id, self.v2BrowserDialogRespond(params: params, accept: true))
        case "browser.dialog.dismiss":
            return v2Result(id: id, self.v2BrowserDialogRespond(params: params, accept: false))
        case "browser.download.wait":
            return v2Result(id: id, self.v2BrowserDownloadWait(params: params))
        case "browser.cookies.get":
            return v2Result(id: id, self.v2BrowserCookiesGet(params: params))
        case "browser.cookies.set":
            return v2Result(id: id, self.v2BrowserCookiesSet(params: params))
        case "browser.cookies.clear":
            return v2Result(id: id, self.v2BrowserCookiesClear(params: params))
        case "browser.storage.get":
            return v2Result(id: id, self.v2BrowserStorageGet(params: params))
        case "browser.storage.set":
            return v2Result(id: id, self.v2BrowserStorageSet(params: params))
        case "browser.storage.clear":
            return v2Result(id: id, self.v2BrowserStorageClear(params: params))
        case "browser.tab.new":
            return v2Result(id: id, self.v2BrowserTabNew(params: params))
        case "browser.tab.list":
            return v2Result(id: id, self.v2BrowserTabList(params: params))
        case "browser.tab.switch":
            return v2Result(id: id, self.v2BrowserTabSwitch(params: params))
        case "browser.tab.close":
            return v2Result(id: id, self.v2BrowserTabClose(params: params))
        case "browser.console.list":
            return v2Result(id: id, self.v2BrowserConsoleList(params: params))
        case "browser.console.clear":
            return v2Result(id: id, self.v2BrowserConsoleClear(params: params))
        case "browser.errors.list":
            return v2Result(id: id, self.v2BrowserErrorsList(params: params))
        case "browser.highlight":
            return v2Result(id: id, self.v2BrowserHighlight(params: params))
        case "browser.state.save":
            return v2Result(id: id, self.v2BrowserStateSave(params: params))
        case "browser.state.load":
            return v2Result(id: id, self.v2BrowserStateLoad(params: params))
        case "browser.addinitscript":
            return v2Result(id: id, self.v2BrowserAddInitScript(params: params))
        case "browser.addscript":
            return v2Result(id: id, self.v2BrowserAddScript(params: params))
        case "browser.addstyle":
            return v2Result(id: id, self.v2BrowserAddStyle(params: params))
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
        case "surface.read_text":
            return v2Result(id: id, self.v2SurfaceReadText(params: params))


#if DEBUG
        // Debug / test-only
        case "debug.shortcut.set":
            return v2Result(id: id, self.v2DebugShortcutSet(params: params))
        case "debug.shortcut.simulate":
            return v2Result(id: id, self.v2DebugShortcutSimulate(params: params))
        case "debug.type":
            return v2Result(id: id, self.v2DebugType(params: params))
        case "debug.app.activate":
            return v2Result(id: id, self.v2DebugActivateApp())
        case "debug.command_palette.toggle":
            return v2Result(id: id, self.v2DebugToggleCommandPalette(params: params))
        case "debug.command_palette.rename_tab.open":
            return v2Result(id: id, self.v2DebugOpenCommandPaletteRenameTabInput(params: params))
        case "debug.command_palette.visible":
            return v2Result(id: id, self.v2DebugCommandPaletteVisible(params: params))
        case "debug.command_palette.selection":
            return v2Result(id: id, self.v2DebugCommandPaletteSelection(params: params))
        case "debug.command_palette.results":
            return v2Result(id: id, self.v2DebugCommandPaletteResults(params: params))
        case "debug.command_palette.rename_input.interact":
            return v2Result(id: id, self.v2DebugCommandPaletteRenameInputInteraction(params: params))
        case "debug.command_palette.rename_input.delete_backward":
            return v2Result(id: id, self.v2DebugCommandPaletteRenameInputDeleteBackward(params: params))
        case "debug.command_palette.rename_input.selection":
            return v2Result(id: id, self.v2DebugCommandPaletteRenameInputSelection(params: params))
        case "debug.command_palette.rename_input.select_all":
            return v2Result(id: id, self.v2DebugCommandPaletteRenameInputSelectAll(params: params))
        case "debug.browser.address_bar_focused":
            return v2Result(id: id, self.v2DebugBrowserAddressBarFocused(params: params))
        case "debug.sidebar.visible":
            return v2Result(id: id, self.v2DebugSidebarVisible(params: params))
        case "debug.terminal.is_focused":
            return v2Result(id: id, self.v2DebugIsTerminalFocused(params: params))
        case "debug.terminal.read_text":
            return v2Result(id: id, self.v2DebugReadTerminalText(params: params))
        case "debug.terminal.render_stats":
            return v2Result(id: id, self.v2DebugRenderStats(params: params))
        case "debug.layout":
            return v2Result(id: id, self.v2DebugLayout())
        case "debug.bonsplit_underflow.count":
            return v2Result(id: id, self.v2DebugBonsplitUnderflowCount())
        case "debug.bonsplit_underflow.reset":
            return v2Result(id: id, self.v2DebugResetBonsplitUnderflowCount())
        case "debug.empty_panel.count":
            return v2Result(id: id, self.v2DebugEmptyPanelCount())
        case "debug.empty_panel.reset":
            return v2Result(id: id, self.v2DebugResetEmptyPanelCount())
        case "debug.notification.focus":
            return v2Result(id: id, self.v2DebugFocusNotification(params: params))
        case "debug.flash.count":
            return v2Result(id: id, self.v2DebugFlashCount(params: params))
        case "debug.flash.reset":
            return v2Result(id: id, self.v2DebugResetFlashCounts())
        case "debug.panel_snapshot":
            return v2Result(id: id, self.v2DebugPanelSnapshot(params: params))
        case "debug.panel_snapshot.reset":
            return v2Result(id: id, self.v2DebugPanelSnapshotReset(params: params))
        case "debug.window.screenshot":
            return v2Result(id: id, self.v2DebugScreenshot(params: params))
#endif

        default:
            return v2Error(id: id, code: "method_not_found", message: "Unknown method")
        }
        }

        #if DEBUG
        if method == "workspace.create" || method == "surface.send_text" {
            let elapsedMs = (ProcessInfo.processInfo.systemUptime - startedAt) * 1000.0
            let status = response.contains("\"ok\":true") ? "ok" : "err"
            dlog(
                "socket.v2 method=\(method) status=\(status) ms=\(String(format: "%.2f", elapsedMs)) main=\(Thread.isMainThread ? 1 : 0)"
            )
        }
        #endif

        return response
    }

    private func v2Capabilities() -> [String: Any] {
        var methods: [String] = [
            "system.ping",
            "system.capabilities",
            "system.identify",
            "auth.login",
            "window.list",
            "window.current",
            "window.focus",
            "window.create",
            "window.close",
            "workspace.list",
            "workspace.create",
            "workspace.select",
            "workspace.current",
            "workspace.close",
            "workspace.move_to_window",
            "workspace.reorder",
            "workspace.rename",
            "workspace.action",
            "workspace.next",
            "workspace.previous",
            "workspace.last",
            "surface.list",
            "surface.current",
            "surface.focus",
            "surface.split",
            "surface.create",
            "surface.close",
            "surface.drag_to_split",
            "surface.move",
            "surface.reorder",
            "surface.action",
            "tab.action",
            "surface.refresh",
            "surface.health",
            "surface.send_text",
            "surface.send_key",
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
            "notification.create_for_surface",
            "notification.create_for_target",
            "notification.list",
            "notification.clear",
            "app.focus_override.set",
            "app.simulate_active",
            "browser.open_split",
            "browser.navigate",
            "browser.back",
            "browser.forward",
            "browser.reload",
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
        methods.append(contentsOf: [
            "debug.shortcut.set",
            "debug.shortcut.simulate",
            "debug.type",
            "debug.app.activate",
            "debug.command_palette.toggle",
            "debug.command_palette.rename_tab.open",
            "debug.command_palette.visible",
            "debug.command_palette.selection",
            "debug.command_palette.results",
            "debug.command_palette.rename_input.interact",
            "debug.command_palette.rename_input.delete_backward",
            "debug.command_palette.rename_input.selection",
            "debug.command_palette.rename_input.select_all",
            "debug.browser.address_bar_focused",
            "debug.sidebar.visible",
            "debug.terminal.is_focused",
            "debug.terminal.read_text",
            "debug.terminal.render_stats",
            "debug.layout",
            "debug.bonsplit_underflow.count",
            "debug.bonsplit_underflow.reset",
            "debug.empty_panel.count",
            "debug.empty_panel.reset",
            "debug.notification.focus",
            "debug.flash.count",
            "debug.flash.reset",
            "debug.panel_snapshot",
            "debug.panel_snapshot.reset",
            "debug.window.screenshot",
        ])
#endif

        return [
            "protocol": "cmux-socket",
            "version": 2,
            "socket_path": socketPath,
            "access_mode": accessMode.rawValue,
            "methods": methods.sorted()
        ]
    }

    private func v2Identify(params: [String: Any]) -> [String: Any] {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return [
                "socket_path": socketPath,
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

        return [
            "socket_path": socketPath,
            "focused": focused.isEmpty ? NSNull() : focused,
            "caller": v2OrNull(resolvedCaller)
        ]
    }

    // MARK: - V2 Helpers (encoding + result plumbing)
    // MARK: - V2 Helpers (encoding + result plumbing)

    private func v2OrNull(_ value: Any?) -> Any {
        // Avoid relying on `?? NSNull()` inference (Swift toolchains can disagree).
        if let value { return value }
        return NSNull()
    }

    private func v2MainSync<T>(_ body: () -> T) -> T {
        if Thread.isMainThread {
            return body()
        }
        return DispatchQueue.main.sync(execute: body)
    }

    private func v2Ok(id: Any?, result: Any) -> String {
        return v2Encode([
            "id": v2OrNull(id),
            "ok": true,
            "result": result
        ])
    }

    private func v2Error(id: Any?, code: String, message: String, data: Any? = nil) -> String {
        var err: [String: Any] = ["code": code, "message": message]
        if let data {
            err["data"] = data
        }
        return v2Encode([
            "id": v2OrNull(id),
            "ok": false,
            "error": err
        ])
    }

    private enum V2CallResult {
        case ok(Any)
        case err(code: String, message: String, data: Any?)
    }

    private func v2Result(id: Any?, _ res: V2CallResult) -> String {
        switch res {
        case .ok(let payload):
            return v2Ok(id: id, result: payload)
        case .err(let code, let message, let data):
            return v2Error(id: id, code: code, message: message, data: data)
        }
    }

    private func v2Encode(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: []),
              var s = String(data: data, encoding: .utf8) else {
            return "{\"ok\":false,\"error\":{\"code\":\"encode_error\",\"message\":\"Failed to encode JSON\"}}"
        }

        // Ensure single-line responses for the line-oriented socket protocol.
        s = s.replacingOccurrences(of: "\n", with: "\\n")
        return s
    }

    private func v2EnsureHandleRef(kind: V2HandleKind, uuid: UUID) -> String {
        if let existing = v2RefByUUID[kind]?[uuid] {
            return existing
        }
        let next = v2NextHandleOrdinal[kind] ?? 1
        let ref = "\(kind.rawValue):\(next)"
        var byUUID = v2RefByUUID[kind] ?? [:]
        var byRef = v2UUIDByRef[kind] ?? [:]
        byUUID[uuid] = ref
        byRef[ref] = uuid
        v2RefByUUID[kind] = byUUID
        v2UUIDByRef[kind] = byRef
        v2NextHandleOrdinal[kind] = next + 1
        return ref
    }

    private func v2ResolveHandleRef(_ handle: String) -> UUID? {
        for kind in V2HandleKind.allCases {
            if let id = v2UUIDByRef[kind]?[handle] {
                return id
            }
        }
        // Tab refs are aliases for surface refs in tab-facing APIs.
        let trimmed = handle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("tab:"),
           let ordinal = Int(trimmed.replacingOccurrences(of: "tab:", with: "")),
           let id = v2UUIDByRef[.surface]?["surface:\(ordinal)"] {
            return id
        }
        return nil
    }

    private func v2Ref(kind: V2HandleKind, uuid: UUID?) -> Any {
        guard let uuid else { return NSNull() }
        return v2EnsureHandleRef(kind: kind, uuid: uuid)
    }

    private func v2TabRef(uuid: UUID?) -> Any {
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
            }
        }
    }

    // MARK: - V2 Param Parsing

    private func v2String(_ params: [String: Any], _ key: String) -> String? {
        guard let raw = params[key] as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func v2ActionKey(_ params: [String: Any], _ key: String = "action") -> String? {
        guard let action = v2String(params, key) else { return nil }
        return action.lowercased().replacingOccurrences(of: "-", with: "_")
    }

    private func v2RawString(_ params: [String: Any], _ key: String) -> String? {
        params[key] as? String
    }

    private func v2UUID(_ params: [String: Any], _ key: String) -> UUID? {
        guard let s = v2String(params, key) else { return nil }
        if let uuid = UUID(uuidString: s) {
            return uuid
        }
        return v2ResolveHandleRef(s)
    }

    private func v2UUIDAny(_ raw: Any?) -> UUID? {
        guard let s = raw as? String else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let uuid = UUID(uuidString: trimmed) {
            return uuid
        }
        return v2ResolveHandleRef(trimmed)
    }
    private func v2Bool(_ params: [String: Any], _ key: String) -> Bool? {
        if let b = params[key] as? Bool { return b }
        if let n = params[key] as? NSNumber { return n.boolValue }
        if let s = params[key] as? String {
            switch s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "yes", "on":
                return true
            case "0", "false", "no", "off":
                return false
            default:
                return nil
            }
        }
        return nil
    }

    private func v2LocatePane(_ paneUUID: UUID) -> (windowId: UUID, tabManager: TabManager, workspace: Workspace, paneId: PaneID)? {
        guard let app = AppDelegate.shared else { return nil }
        let windows = app.listMainWindowSummaries()
        for item in windows {
            guard let tm = app.tabManagerFor(windowId: item.windowId) else { continue }
            for ws in tm.tabs {
                if let paneId = ws.bonsplitController.allPaneIds.first(where: { $0.id == paneUUID }) {
                    return (item.windowId, tm, ws, paneId)
                }
            }
        }
        return nil
    }
    private func v2Int(_ params: [String: Any], _ key: String) -> Int? {
        if let i = params[key] as? Int { return i }
        if let n = params[key] as? NSNumber { return n.intValue }
        if let s = params[key] as? String { return Int(s) }
        return nil
    }

    private func v2PanelType(_ params: [String: Any], _ key: String) -> PanelType? {
        guard let s = v2String(params, key) else { return nil }
        return PanelType(rawValue: s.lowercased())
    }

    // MARK: - V2 Context Resolution

    private func v2ResolveTabManager(params: [String: Any]) -> TabManager? {
        // Prefer explicit window_id routing. Fall back to global lookup by workspace_id/surface_id/tab_id,
        // and finally to the active window's TabManager.
        if let windowId = v2UUID(params, "window_id") {
            return v2MainSync { AppDelegate.shared?.tabManagerFor(windowId: windowId) }
        }
        if let wsId = v2UUID(params, "workspace_id") {
            if let tm = v2MainSync({ AppDelegate.shared?.tabManagerFor(tabId: wsId) }) {
                return tm
            }
        }
        if let surfaceId = v2UUID(params, "surface_id") ?? v2UUID(params, "tab_id") {
            if let tm = v2MainSync({ AppDelegate.shared?.locateSurface(surfaceId: surfaceId)?.tabManager }) {
                return tm
            }
        }
        return tabManager
    }

    private func v2ResolveWindowId(tabManager: TabManager?) -> UUID? {
        guard let tabManager else { return nil }
        return v2MainSync { AppDelegate.shared?.windowId(for: tabManager) }
    }

    // MARK: - V2 Window Methods

    private func v2WindowList(params _: [String: Any]) -> V2CallResult {
        let windows = v2MainSync { AppDelegate.shared?.listMainWindowSummaries() } ?? []
        let payload: [[String: Any]] = windows.enumerated().map { index, item in
            return [
                "id": item.windowId.uuidString,
                "ref": v2Ref(kind: .window, uuid: item.windowId),
                "index": index,
                "key": item.isKeyWindow,
                "visible": item.isVisible,
                "workspace_count": item.workspaceCount,
                "selected_workspace_id": v2OrNull(item.selectedWorkspaceId?.uuidString),
                "selected_workspace_ref": v2Ref(kind: .workspace, uuid: item.selectedWorkspaceId)
            ]
        }
        return .ok(["windows": payload])
    }

    private func v2WindowCurrent(params _: [String: Any]) -> V2CallResult {
        guard let tabManager else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let windowId = v2ResolveWindowId(tabManager: tabManager) else {
            return .err(code: "not_found", message: "Current window not found", data: nil)
        }
        return .ok([
            "window_id": windowId.uuidString,
            "window_ref": v2Ref(kind: .window, uuid: windowId)
        ])
    }

    private func v2WindowFocus(params: [String: Any]) -> V2CallResult {
        guard let windowId = v2UUID(params, "window_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid window_id", data: nil)
        }
        let ok = v2MainSync { AppDelegate.shared?.focusMainWindow(windowId: windowId) ?? false }
        return ok
            ? .ok([
                "window_id": windowId.uuidString,
                "window_ref": v2Ref(kind: .window, uuid: windowId)
            ])
            : .err(code: "not_found", message: "Window not found", data: [
                "window_id": windowId.uuidString,
                "window_ref": v2Ref(kind: .window, uuid: windowId)
            ])
    }

    private func v2WindowCreate(params _: [String: Any]) -> V2CallResult {
        guard let windowId = v2MainSync({ AppDelegate.shared?.createMainWindow() }) else {
            return .err(code: "internal_error", message: "Failed to create window", data: nil)
        }
        // Keep active routing stable unless this command is explicitly focus-intent.
        if socketCommandAllowsInAppFocusMutations(),
           let tm = v2MainSync({ AppDelegate.shared?.tabManagerFor(windowId: windowId) }) {
            setActiveTabManager(tm)
        }
        return .ok([
            "window_id": windowId.uuidString,
            "window_ref": v2Ref(kind: .window, uuid: windowId)
        ])
    }

    private func v2WindowClose(params: [String: Any]) -> V2CallResult {
        guard let windowId = v2UUID(params, "window_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid window_id", data: nil)
        }
        let ok = v2MainSync { AppDelegate.shared?.closeMainWindow(windowId: windowId) ?? false }
        return ok
            ? .ok([
                "window_id": windowId.uuidString,
                "window_ref": v2Ref(kind: .window, uuid: windowId)
            ])
            : .err(code: "not_found", message: "Window not found", data: [
                "window_id": windowId.uuidString,
                "window_ref": v2Ref(kind: .window, uuid: windowId)
            ])
    }

    // MARK: - V2 Workspace Methods

    private func v2WorkspaceList(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        var workspaces: [[String: Any]] = []
        v2MainSync {
            workspaces = tabManager.tabs.enumerated().map { index, ws in
                return [
                    "id": ws.id.uuidString,
                    "ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "index": index,
                    "title": ws.title,
                    "selected": ws.id == tabManager.selectedTabId,
                    "pinned": ws.isPinned
                ]
            }
        }

        let windowId = v2ResolveWindowId(tabManager: tabManager)
        return .ok([
            "window_id": v2OrNull(windowId?.uuidString),
            "window_ref": v2Ref(kind: .window, uuid: windowId),
            "workspaces": workspaces
        ])
    }
    private func v2WorkspaceCreate(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        var newId: UUID?
        let shouldFocus = v2FocusAllowed()
        #if DEBUG
        let startedAt = ProcessInfo.processInfo.systemUptime
        #endif
        v2MainSync {
            let ws = tabManager.addWorkspace(select: shouldFocus)
            newId = ws.id
        }
        #if DEBUG
        let elapsedMs = (ProcessInfo.processInfo.systemUptime - startedAt) * 1000.0
        dlog(
            "socket.workspace.create focus=\(shouldFocus ? 1 : 0) ms=\(String(format: "%.2f", elapsedMs)) main=\(Thread.isMainThread ? 1 : 0)"
        )
        #endif

        guard let newId else {
            return .err(code: "internal_error", message: "Failed to create workspace", data: nil)
        }
        let windowId = v2ResolveWindowId(tabManager: tabManager)
        return .ok([
            "window_id": v2OrNull(windowId?.uuidString),
            "window_ref": v2Ref(kind: .window, uuid: windowId),
            "workspace_id": newId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: newId)
        ])
    }
    private func v2WorkspaceSelect(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let wsId = v2UUID(params, "workspace_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }

        var success = false
        v2MainSync {
            if let ws = tabManager.tabs.first(where: { $0.id == wsId }) {
                v2MaybeFocusWindow(for: tabManager)
                v2MaybeSelectWorkspace(tabManager, workspace: ws)
                success = true
            }
        }

        let windowId = v2ResolveWindowId(tabManager: tabManager)
        return success
            ? .ok([
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "workspace_id": wsId.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: wsId)
            ])
            : .err(code: "not_found", message: "Workspace not found", data: [
                "workspace_id": wsId.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: wsId)
            ])
    }
    private func v2WorkspaceCurrent(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        var wsId: UUID?
        v2MainSync {
            wsId = tabManager.selectedTabId
        }
        guard let wsId else {
            return .err(code: "not_found", message: "No workspace selected", data: nil)
        }
        let windowId = v2ResolveWindowId(tabManager: tabManager)
        return .ok([
            "window_id": v2OrNull(windowId?.uuidString),
            "window_ref": v2Ref(kind: .window, uuid: windowId),
            "workspace_id": wsId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: wsId)
        ])
    }
    private func v2WorkspaceClose(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let wsId = v2UUID(params, "workspace_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }

        var found = false
        v2MainSync {
            if let ws = tabManager.tabs.first(where: { $0.id == wsId }) {
                tabManager.closeWorkspace(ws)
                found = true
            }
        }

        let windowId = v2ResolveWindowId(tabManager: tabManager)
        return found
            ? .ok([
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "workspace_id": wsId.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: wsId)
            ])
            : .err(code: "not_found", message: "Workspace not found", data: [
                "workspace_id": wsId.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: wsId)
            ])
    }
    private func v2WorkspaceMoveToWindow(params: [String: Any]) -> V2CallResult {
        guard let wsId = v2UUID(params, "workspace_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }
        guard let windowId = v2UUID(params, "window_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid window_id", data: nil)
        }
        let focus = v2FocusAllowed(requested: v2Bool(params, "focus") ?? true)

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to move workspace", data: nil)
        v2MainSync {
            guard let srcTM = AppDelegate.shared?.tabManagerFor(tabId: wsId) else {
                result = .err(code: "not_found", message: "Workspace not found", data: ["workspace_id": wsId.uuidString])
                return
            }
            guard let dstTM = AppDelegate.shared?.tabManagerFor(windowId: windowId) else {
                result = .err(code: "not_found", message: "Window not found", data: ["window_id": windowId.uuidString])
                return
            }
            guard let ws = srcTM.detachWorkspace(tabId: wsId) else {
                result = .err(code: "not_found", message: "Workspace not found", data: ["workspace_id": wsId.uuidString])
                return
            }

            dstTM.attachWorkspace(ws, select: focus)
            if focus {
                _ = AppDelegate.shared?.focusMainWindow(windowId: windowId)
                setActiveTabManager(dstTM)
            }
            result = .ok([
                "workspace_id": wsId.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: wsId),
                "window_id": windowId.uuidString,
                "window_ref": v2Ref(kind: .window, uuid: windowId)
            ])
        }
        return result
    }
    private func v2WorkspaceReorder(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let workspaceId = v2UUID(params, "workspace_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }

        let index = v2Int(params, "index")
        let beforeId = v2UUID(params, "before_workspace_id")
        let afterId = v2UUID(params, "after_workspace_id")

        let targetCount = (index != nil ? 1 : 0) + (beforeId != nil ? 1 : 0) + (afterId != nil ? 1 : 0)
        if targetCount != 1 {
            return .err(
                code: "invalid_params",
                message: "Specify exactly one target: index, before_workspace_id, or after_workspace_id",
                data: nil
            )
        }

        var moved = false
        var newIndex: Int?
        v2MainSync {
            if let index {
                moved = tabManager.reorderWorkspace(tabId: workspaceId, toIndex: index)
            } else {
                moved = tabManager.reorderWorkspace(tabId: workspaceId, before: beforeId, after: afterId)
            }
            newIndex = tabManager.tabs.firstIndex(where: { $0.id == workspaceId })
        }

        guard moved else {
            return .err(code: "not_found", message: "Workspace not found", data: ["workspace_id": workspaceId.uuidString])
        }

        let windowId = v2ResolveWindowId(tabManager: tabManager)
        return .ok([
            "workspace_id": workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
            "window_id": v2OrNull(windowId?.uuidString),
            "window_ref": v2Ref(kind: .window, uuid: windowId),
            "index": v2OrNull(newIndex)
        ])
    }
    private func v2WorkspaceRename(params: [String: Any]) -> V2CallResult {
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

        let title = titleRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        var renamed = false
        v2MainSync {
            guard tabManager.tabs.contains(where: { $0.id == workspaceId }) else { return }
            tabManager.setCustomTitle(tabId: workspaceId, title: title)
            renamed = true
        }

        guard renamed else {
            return .err(code: "not_found", message: "Workspace not found", data: [
                "workspace_id": workspaceId.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId)
            ])
        }

        let windowId = v2ResolveWindowId(tabManager: tabManager)
        return .ok([
            "workspace_id": workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
            "window_id": v2OrNull(windowId?.uuidString),
            "window_ref": v2Ref(kind: .window, uuid: windowId),
            "title": title
        ])
    }
    private func v2WorkspaceNext(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        var result: V2CallResult = .err(code: "not_found", message: "No workspace selected", data: nil)
        v2MainSync {
            guard tabManager.selectedTabId != nil else { return }
            v2MaybeFocusWindow(for: tabManager)
            tabManager.selectNextTab()
            guard let workspaceId = tabManager.selectedTabId else { return }
            let windowId = v2ResolveWindowId(tabManager: tabManager)
            result = .ok([
                "workspace_id": workspaceId.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId)
            ])
        }
        return result
    }

    private func v2WorkspacePrevious(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        var result: V2CallResult = .err(code: "not_found", message: "No workspace selected", data: nil)
        v2MainSync {
            guard tabManager.selectedTabId != nil else { return }
            v2MaybeFocusWindow(for: tabManager)
            tabManager.selectPreviousTab()
            guard let workspaceId = tabManager.selectedTabId else { return }
            let windowId = v2ResolveWindowId(tabManager: tabManager)
            result = .ok([
                "workspace_id": workspaceId.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId)
            ])
        }
        return result
    }

    private func v2WorkspaceLast(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        var result: V2CallResult = .err(code: "not_found", message: "No previous workspace in history", data: nil)
        v2MainSync {
            guard let before = tabManager.selectedTabId else { return }
            v2MaybeFocusWindow(for: tabManager)
            tabManager.navigateBack()
            guard let after = tabManager.selectedTabId, after != before else { return }
            let windowId = v2ResolveWindowId(tabManager: tabManager)
            result = .ok([
                "workspace_id": after.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: after),
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId)
            ])
        }
        return result
    }

    private func v2WorkspaceAction(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let action = v2ActionKey(params) else {
            return .err(code: "invalid_params", message: "Missing action", data: nil)
        }

        let supportedActions = [
            "pin", "unpin", "rename", "clear_name",
            "move_up", "move_down", "move_top",
            "close_others", "close_above", "close_below",
            "mark_read", "mark_unread"
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

            default:
                result = .err(code: "invalid_params", message: "Unknown workspace action", data: [
                    "action": action,
                    "supported_actions": supportedActions
                ])
            }
        }

        return result
    }

    private func v2TabAction(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let action = v2ActionKey(params) else {
            return .err(code: "invalid_params", message: "Missing action", data: nil)
        }

        let supportedActions = [
            "rename", "clear_name",
            "close_left", "close_right", "close_others",
            "new_terminal_right", "new_browser_right",
            "reload", "duplicate",
            "pin", "unpin", "mark_read", "mark_unread"
        ]

        var result: V2CallResult = .err(code: "invalid_params", message: "Unknown tab action", data: [
            "action": action,
            "supported_actions": supportedActions
        ])

        v2MainSync {
            guard let workspace = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            let allowFocusMutation = v2FocusAllowed()

            let surfaceId = v2UUID(params, "surface_id") ?? v2UUID(params, "tab_id") ?? workspace.focusedPanelId
            guard let surfaceId else {
                result = .err(code: "not_found", message: "No focused tab", data: nil)
                return
            }
            guard workspace.panels[surfaceId] != nil else {
                result = .err(code: "not_found", message: "Tab not found", data: [
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "tab_id": surfaceId.uuidString,
                    "tab_ref": v2TabRef(uuid: surfaceId)
                ])
                return
            }

            let windowId = v2ResolveWindowId(tabManager: tabManager)

            @MainActor
            func finish(_ extras: [String: Any] = [:]) {
                var payload: [String: Any] = [
                    "action": action,
                    "window_id": v2OrNull(windowId?.uuidString),
                    "window_ref": v2Ref(kind: .window, uuid: windowId),
                    "workspace_id": workspace.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: workspace.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "tab_id": surfaceId.uuidString,
                    "tab_ref": v2TabRef(uuid: surfaceId)
                ]
                if let paneId = workspace.paneId(forPanelId: surfaceId)?.id {
                    payload["pane_id"] = paneId.uuidString
                    payload["pane_ref"] = v2Ref(kind: .pane, uuid: paneId)
                } else {
                    payload["pane_id"] = NSNull()
                    payload["pane_ref"] = NSNull()
                }
                for (key, value) in extras {
                    payload[key] = value
                }
                result = .ok(payload)
            }

            @MainActor
            func insertionIndexToRight(anchorTabId: TabID, inPane paneId: PaneID) -> Int {
                let tabs = workspace.bonsplitController.tabs(inPane: paneId)
                guard let anchorIndex = tabs.firstIndex(where: { $0.id == anchorTabId }) else { return tabs.count }
                let pinnedCount = tabs.reduce(into: 0) { count, tab in
                    if let panelId = workspace.panelIdFromSurfaceId(tab.id),
                       workspace.isPanelPinned(panelId) {
                        count += 1
                    }
                }
                let rawTarget = min(anchorIndex + 1, tabs.count)
                return max(rawTarget, pinnedCount)
            }

            @MainActor
            func closeTabs(_ tabIds: [TabID]) -> (closed: Int, skippedPinned: Int) {
                var closed = 0
                var skippedPinned = 0
                for tabId in tabIds {
                    guard let panelId = workspace.panelIdFromSurfaceId(tabId) else { continue }
                    if workspace.isPanelPinned(panelId) {
                        skippedPinned += 1
                        continue
                    }
                    if workspace.panels.count <= 1 {
                        break
                    }
                    if workspace.closePanel(panelId, force: true) {
                        closed += 1
                    }
                }
                return (closed, skippedPinned)
            }

            switch action {
            case "rename":
                guard let titleRaw = v2String(params, "title"),
                      !titleRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    result = .err(code: "invalid_params", message: "Missing or invalid title", data: nil)
                    return
                }
                let title = titleRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                workspace.setPanelCustomTitle(panelId: surfaceId, title: title)
                finish(["title": title])

            case "clear_name":
                workspace.setPanelCustomTitle(panelId: surfaceId, title: nil)
                finish()

            case "pin":
                workspace.setPanelPinned(panelId: surfaceId, pinned: true)
                finish(["pinned": true])

            case "unpin":
                workspace.setPanelPinned(panelId: surfaceId, pinned: false)
                finish(["pinned": false])

            case "mark_read", "mark_as_read":
                workspace.markPanelRead(surfaceId)
                finish()

            case "mark_unread", "mark_as_unread":
                workspace.markPanelUnread(surfaceId)
                finish()

            case "reload", "reload_tab":
                guard let browserPanel = workspace.browserPanel(for: surfaceId) else {
                    result = .err(code: "invalid_state", message: "Reload is only available for browser tabs", data: nil)
                    return
                }
                browserPanel.reload()
                finish()

            case "duplicate", "duplicate_tab":
                guard let anchorTabId = workspace.surfaceIdFromPanelId(surfaceId),
                      let paneId = workspace.paneId(forPanelId: surfaceId),
                      let browserPanel = workspace.browserPanel(for: surfaceId) else {
                    result = .err(code: "invalid_state", message: "Duplicate is only available for browser tabs", data: nil)
                    return
                }

                let targetIndex = insertionIndexToRight(anchorTabId: anchorTabId, inPane: paneId)
                guard let newPanel = workspace.newBrowserSurface(
                    inPane: paneId,
                    url: browserPanel.currentURL,
                    focus: allowFocusMutation
                ) else {
                    result = .err(code: "internal_error", message: "Failed to duplicate tab", data: nil)
                    return
                }
                _ = workspace.reorderSurface(panelId: newPanel.id, toIndex: targetIndex)
                finish([
                    "created_surface_id": newPanel.id.uuidString,
                    "created_surface_ref": v2Ref(kind: .surface, uuid: newPanel.id),
                    "created_tab_id": newPanel.id.uuidString,
                    "created_tab_ref": v2TabRef(uuid: newPanel.id)
                ])

            case "new_terminal_right", "new_terminal_to_right", "new_terminal_tab_to_right":
                guard let anchorTabId = workspace.surfaceIdFromPanelId(surfaceId),
                      let paneId = workspace.paneId(forPanelId: surfaceId) else {
                    result = .err(code: "not_found", message: "Tab pane not found", data: nil)
                    return
                }

                let targetIndex = insertionIndexToRight(anchorTabId: anchorTabId, inPane: paneId)
                guard let newPanel = workspace.newTerminalSurface(inPane: paneId, focus: allowFocusMutation) else {
                    result = .err(code: "internal_error", message: "Failed to create tab", data: nil)
                    return
                }
                _ = workspace.reorderSurface(panelId: newPanel.id, toIndex: targetIndex)
                finish([
                    "created_surface_id": newPanel.id.uuidString,
                    "created_surface_ref": v2Ref(kind: .surface, uuid: newPanel.id),
                    "created_tab_id": newPanel.id.uuidString,
                    "created_tab_ref": v2TabRef(uuid: newPanel.id)
                ])

            case "new_browser_right", "new_browser_to_right", "new_browser_tab_to_right":
                guard let anchorTabId = workspace.surfaceIdFromPanelId(surfaceId),
                      let paneId = workspace.paneId(forPanelId: surfaceId) else {
                    result = .err(code: "not_found", message: "Tab pane not found", data: nil)
                    return
                }

                let urlRaw = v2String(params, "url")
                let url = urlRaw.flatMap { URL(string: $0) }
                if urlRaw != nil && url == nil {
                    result = .err(code: "invalid_params", message: "Invalid URL", data: ["url": v2OrNull(urlRaw)])
                    return
                }

                let targetIndex = insertionIndexToRight(anchorTabId: anchorTabId, inPane: paneId)
                guard let newPanel = workspace.newBrowserSurface(inPane: paneId, url: url, focus: allowFocusMutation) else {
                    result = .err(code: "internal_error", message: "Failed to create tab", data: nil)
                    return
                }
                _ = workspace.reorderSurface(panelId: newPanel.id, toIndex: targetIndex)
                finish([
                    "created_surface_id": newPanel.id.uuidString,
                    "created_surface_ref": v2Ref(kind: .surface, uuid: newPanel.id),
                    "created_tab_id": newPanel.id.uuidString,
                    "created_tab_ref": v2TabRef(uuid: newPanel.id)
                ])

            case "close_left", "close_to_left":
                guard let anchorTabId = workspace.surfaceIdFromPanelId(surfaceId),
                      let paneId = workspace.paneId(forPanelId: surfaceId) else {
                    result = .err(code: "not_found", message: "Tab pane not found", data: nil)
                    return
                }
                let tabs = workspace.bonsplitController.tabs(inPane: paneId)
                guard let index = tabs.firstIndex(where: { $0.id == anchorTabId }) else {
                    result = .err(code: "not_found", message: "Tab not found in pane", data: nil)
                    return
                }
                let targetIds = Array(tabs.prefix(index).map(\.id))
                let closeResult = closeTabs(targetIds)
                finish(["closed": closeResult.closed, "skipped_pinned": closeResult.skippedPinned])

            case "close_right", "close_to_right":
                guard let anchorTabId = workspace.surfaceIdFromPanelId(surfaceId),
                      let paneId = workspace.paneId(forPanelId: surfaceId) else {
                    result = .err(code: "not_found", message: "Tab pane not found", data: nil)
                    return
                }
                let tabs = workspace.bonsplitController.tabs(inPane: paneId)
                guard let index = tabs.firstIndex(where: { $0.id == anchorTabId }) else {
                    result = .err(code: "not_found", message: "Tab not found in pane", data: nil)
                    return
                }
                let targetIds = (index + 1 < tabs.count) ? Array(tabs.suffix(from: index + 1).map(\.id)) : []
                let closeResult = closeTabs(targetIds)
                finish(["closed": closeResult.closed, "skipped_pinned": closeResult.skippedPinned])

            case "close_others", "close_other_tabs":
                guard let anchorTabId = workspace.surfaceIdFromPanelId(surfaceId),
                      let paneId = workspace.paneId(forPanelId: surfaceId) else {
                    result = .err(code: "not_found", message: "Tab pane not found", data: nil)
                    return
                }
                let targetIds = workspace.bonsplitController.tabs(inPane: paneId)
                    .map(\.id)
                    .filter { $0 != anchorTabId }
                let closeResult = closeTabs(targetIds)
                finish(["closed": closeResult.closed, "skipped_pinned": closeResult.skippedPinned])

            default:
                result = .err(code: "invalid_params", message: "Unknown tab action", data: [
                    "action": action,
                    "supported_actions": supportedActions
                ])
            }
        }

        return result
    }

    // MARK: - V2 Surface Methods

    private func v2ResolveWorkspace(params: [String: Any], tabManager: TabManager) -> Workspace? {
        if let wsId = v2UUID(params, "workspace_id") {
            return tabManager.tabs.first(where: { $0.id == wsId })
        }
        if let surfaceId = v2UUID(params, "surface_id") ?? v2UUID(params, "tab_id") {
            return tabManager.tabs.first(where: { $0.panels[surfaceId] != nil })
        }
        guard let wsId = tabManager.selectedTabId else { return nil }
        return tabManager.tabs.first(where: { $0.id == wsId })
    }

    private func v2SurfaceList(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        var payload: [String: Any]?
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else { return }

            // Map panel_id -> pane_id and index/selection within that pane.
            var paneByPanelId: [UUID: UUID] = [:]
            var indexInPaneByPanelId: [UUID: Int] = [:]
            var selectedInPaneByPanelId: [UUID: Bool] = [:]
            for paneId in ws.bonsplitController.allPaneIds {
                let tabs = ws.bonsplitController.tabs(inPane: paneId)
                let selected = ws.bonsplitController.selectedTab(inPane: paneId)
                for (idx, tab) in tabs.enumerated() {
                    guard let panelId = ws.panelIdFromSurfaceId(tab.id) else { continue }
                    paneByPanelId[panelId] = paneId.id
                    indexInPaneByPanelId[panelId] = idx
                    selectedInPaneByPanelId[panelId] = (tab.id == selected?.id)
                }
            }

            let focusedSurfaceId = ws.focusedPanelId
            let panels = orderedPanels(in: ws)
            let surfaces: [[String: Any]] = panels.enumerated().map { index, panel in
                let paneUUID = paneByPanelId[panel.id]
                var item: [String: Any] = [
                    "id": panel.id.uuidString,
                    "ref": v2Ref(kind: .surface, uuid: panel.id),
                    "index": index,
                    "type": panel.panelType.rawValue,
                    "title": ws.panelTitle(panelId: panel.id) ?? panel.displayTitle,
                    "focused": panel.id == focusedSurfaceId,
                    "pane_id": v2OrNull(paneUUID?.uuidString),
                    "pane_ref": v2Ref(kind: .pane, uuid: paneUUID),
                    "index_in_pane": v2OrNull(indexInPaneByPanelId[panel.id]),
                    "selected_in_pane": v2OrNull(selectedInPaneByPanelId[panel.id])
                ]
                return item
            }

            payload = [
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surfaces": surfaces
            ]
        }

        guard let payload else {
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        }
        var out = payload
        let windowId = v2ResolveWindowId(tabManager: tabManager)
        out["window_id"] = v2OrNull(windowId?.uuidString)
        out["window_ref"] = v2Ref(kind: .window, uuid: windowId)
        return .ok(out)
    }

    private func v2SurfaceCurrent(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        var payload: [String: Any]?
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else { return }

            // Focus can be transiently nil during startup/reparenting; fall back to first
            // ordered panel so callers always get a usable current surface.
            let surfaceId = ws.focusedPanelId ?? orderedPanels(in: ws).first?.id
            let paneId = surfaceId.flatMap { ws.paneId(forPanelId: $0)?.id }
            let windowId = v2ResolveWindowId(tabManager: tabManager)

            payload = [
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "pane_id": v2OrNull(paneId?.uuidString),
                "pane_ref": v2Ref(kind: .pane, uuid: paneId),
                "surface_id": v2OrNull(surfaceId?.uuidString),
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "surface_type": v2OrNull(surfaceId.flatMap { ws.panels[$0]?.panelType.rawValue })
            ]
        }

        guard let payload else {
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        }
        return .ok(payload)
    }

    private func v2SurfaceFocus(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let surfaceId = v2UUID(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid surface_id", data: nil)
        }

        var result: V2CallResult = .err(code: "not_found", message: "Surface not found", data: ["surface_id": surfaceId.uuidString])
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }

            v2MaybeFocusWindow(for: tabManager)
            v2MaybeSelectWorkspace(tabManager, workspace: ws)

            guard ws.panels[surfaceId] != nil else {
                result = .err(code: "not_found", message: "Surface not found", data: ["surface_id": surfaceId.uuidString])
                return
            }

            ws.focusPanel(surfaceId)
            result = .ok(["workspace_id": ws.id.uuidString, "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id), "surface_id": surfaceId.uuidString, "surface_ref": v2Ref(kind: .surface, uuid: surfaceId), "window_id": v2OrNull(v2ResolveWindowId(tabManager: tabManager)?.uuidString), "window_ref": v2Ref(kind: .window, uuid: v2ResolveWindowId(tabManager: tabManager))])
        }
        return result
    }

    private func v2SurfaceSplit(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let directionStr = v2String(params, "direction"),
              let direction = parseSplitDirection(directionStr) else {
            return .err(code: "invalid_params", message: "Missing or invalid direction (left|right|up|down)", data: nil)
        }

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to create split", data: nil)
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            v2MaybeFocusWindow(for: tabManager)
            v2MaybeSelectWorkspace(tabManager, workspace: ws)

            let targetSurfaceId: UUID? = v2UUID(params, "surface_id") ?? ws.focusedPanelId
            guard let targetSurfaceId else {
                result = .err(code: "not_found", message: "No focused surface", data: nil)
                return
            }
            guard ws.panels[targetSurfaceId] != nil else {
                result = .err(code: "not_found", message: "Surface not found", data: ["surface_id": targetSurfaceId.uuidString])
                return
            }

            if let newId = tabManager.newSplit(
                tabId: ws.id,
                surfaceId: targetSurfaceId,
                direction: direction,
                focus: v2FocusAllowed()
            ) {
                let paneUUID = ws.paneId(forPanelId: newId)?.id
                let windowId = v2ResolveWindowId(tabManager: tabManager)
                result = .ok([
                    "window_id": v2OrNull(windowId?.uuidString),
                    "window_ref": v2Ref(kind: .window, uuid: windowId),
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "pane_id": v2OrNull(paneUUID?.uuidString),
                    "pane_ref": v2Ref(kind: .pane, uuid: paneUUID),
                    "surface_id": newId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: newId),
                    "type": v2OrNull(ws.panels[newId]?.panelType.rawValue)
                ])
            } else {
                result = .err(code: "internal_error", message: "Failed to create split", data: nil)
            }
        }
        return result
    }
    private func v2SurfaceCreate(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        let panelType = v2PanelType(params, "type") ?? .terminal
        let urlStr = v2String(params, "url")
        let url = urlStr.flatMap { URL(string: $0) }

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to create surface", data: nil)
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            v2MaybeFocusWindow(for: tabManager)
            v2MaybeSelectWorkspace(tabManager, workspace: ws)

            let paneUUID = v2UUID(params, "pane_id")
            let paneId: PaneID? = {
                if let paneUUID {
                    return ws.bonsplitController.allPaneIds.first(where: { $0.id == paneUUID })
                }
                return ws.bonsplitController.focusedPaneId
            }()

            guard let paneId else {
                result = .err(code: "not_found", message: "Pane not found", data: nil)
                return
            }

            let newPanelId: UUID?
            if panelType == .browser {
                newPanelId = ws.newBrowserSurface(inPane: paneId, url: url, focus: v2FocusAllowed())?.id
            } else {
                newPanelId = ws.newTerminalSurface(inPane: paneId, focus: v2FocusAllowed())?.id
            }

            guard let newPanelId else {
                result = .err(code: "internal_error", message: "Failed to create surface", data: nil)
                return
            }

            let windowId = v2ResolveWindowId(tabManager: tabManager)
            result = .ok([
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "pane_id": paneId.id.uuidString,
                "pane_ref": v2Ref(kind: .pane, uuid: paneId.id),
                "surface_id": newPanelId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: newPanelId),
                "type": panelType.rawValue
            ])
        }
        return result
    }

    private func v2SurfaceClose(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to close surface", data: nil)
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }

            let surfaceId = v2UUID(params, "surface_id") ?? ws.focusedPanelId
            guard let surfaceId else {
                result = .err(code: "not_found", message: "No focused surface", data: nil)
                return
            }

            guard ws.panels[surfaceId] != nil else {
                result = .err(code: "not_found", message: "Surface not found", data: ["surface_id": surfaceId.uuidString])
                return
            }

            if ws.panels.count <= 1 {
                result = .err(code: "invalid_state", message: "Cannot close the last surface", data: nil)
                return
            }

            // Socket API must be non-interactive: bypass close-confirmation gating.
            ws.closePanel(surfaceId, force: true)
            result = .ok(["workspace_id": ws.id.uuidString, "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id), "surface_id": surfaceId.uuidString, "surface_ref": v2Ref(kind: .surface, uuid: surfaceId), "window_id": v2OrNull(v2ResolveWindowId(tabManager: tabManager)?.uuidString), "window_ref": v2Ref(kind: .window, uuid: v2ResolveWindowId(tabManager: tabManager))])
        }
        return result
    }

    private func v2SurfaceDragToSplit(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let surfaceId = v2UUID(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid surface_id", data: nil)
        }
        guard let directionStr = v2String(params, "direction"),
              let direction = parseSplitDirection(directionStr) else {
            return .err(code: "invalid_params", message: "Missing or invalid direction (left|right|up|down)", data: nil)
        }

        let orientation: SplitOrientation = direction.isHorizontal ? .horizontal : .vertical
        let insertFirst = (direction == .left || direction == .up)

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to move surface", data: nil)
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            guard let bonsplitTabId = ws.surfaceIdFromPanelId(surfaceId) else {
                result = .err(code: "not_found", message: "Surface not found", data: ["surface_id": surfaceId.uuidString])
                return
            }
            guard let newPaneId = ws.bonsplitController.splitPane(
                orientation: orientation,
                movingTab: bonsplitTabId,
                insertFirst: insertFirst
            ) else {
                result = .err(code: "internal_error", message: "Failed to split pane", data: nil)
                return
            }
            let windowId = v2ResolveWindowId(tabManager: tabManager)
            result = .ok([
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "pane_id": newPaneId.id.uuidString,
                "pane_ref": v2Ref(kind: .pane, uuid: newPaneId.id)
            ])
        }
        return result
    }

    private func v2SurfaceMove(params: [String: Any]) -> V2CallResult {
        guard let surfaceId = v2UUID(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid surface_id", data: nil)
        }

        let requestedPaneUUID = v2UUID(params, "pane_id")
        let requestedWorkspaceUUID = v2UUID(params, "workspace_id")
        let requestedWindowUUID = v2UUID(params, "window_id")
        let beforeSurfaceId = v2UUID(params, "before_surface_id")
        let afterSurfaceId = v2UUID(params, "after_surface_id")
        let explicitIndex = v2Int(params, "index")
        let focus = v2FocusAllowed(requested: v2Bool(params, "focus") ?? true)

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
                v2MaybeFocusWindow(for: targetTabManager)
                v2MaybeSelectWorkspace(targetTabManager, workspace: targetWorkspace)
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

    private func v2SurfaceReorder(params: [String: Any]) -> V2CallResult {
        guard let surfaceId = v2UUID(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid surface_id", data: nil)
        }

        let index = v2Int(params, "index")
        let beforeSurfaceId = v2UUID(params, "before_surface_id")
        let afterSurfaceId = v2UUID(params, "after_surface_id")
        let targetCount = (index != nil ? 1 : 0) + (beforeSurfaceId != nil ? 1 : 0) + (afterSurfaceId != nil ? 1 : 0)
        if targetCount != 1 {
            return .err(code: "invalid_params", message: "Specify exactly one of index, before_surface_id, or after_surface_id", data: nil)
        }

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to reorder surface", data: nil)
        v2MainSync {
            guard let app = AppDelegate.shared,
                  let located = app.locateSurface(surfaceId: surfaceId),
                  let ws = located.tabManager.tabs.first(where: { $0.id == located.workspaceId }),
                  let sourcePane = ws.paneId(forPanelId: surfaceId) else {
                result = .err(code: "not_found", message: "Surface not found", data: ["surface_id": surfaceId.uuidString])
                return
            }

            let targetIndex: Int
            if let index {
                targetIndex = index
            } else if let beforeSurfaceId {
                guard let anchorPane = ws.paneId(forPanelId: beforeSurfaceId),
                      anchorPane == sourcePane,
                      let anchorIndex = ws.indexInPane(forPanelId: beforeSurfaceId) else {
                    result = .err(code: "invalid_params", message: "Anchor surface must be in the same pane", data: nil)
                    return
                }
                targetIndex = anchorIndex
            } else if let afterSurfaceId {
                guard let anchorPane = ws.paneId(forPanelId: afterSurfaceId),
                      anchorPane == sourcePane,
                      let anchorIndex = ws.indexInPane(forPanelId: afterSurfaceId) else {
                    result = .err(code: "invalid_params", message: "Anchor surface must be in the same pane", data: nil)
                    return
                }
                targetIndex = anchorIndex + 1
            } else {
                result = .err(code: "invalid_params", message: "Missing reorder target", data: nil)
                return
            }

            guard ws.reorderSurface(panelId: surfaceId, toIndex: targetIndex) else {
                result = .err(code: "internal_error", message: "Failed to reorder surface", data: nil)
                return
            }

            result = .ok([
                "window_id": located.windowId.uuidString,
                "window_ref": v2Ref(kind: .window, uuid: located.windowId),
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "pane_id": sourcePane.id.uuidString,
                "pane_ref": v2Ref(kind: .pane, uuid: sourcePane.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId)
            ])
        }

        return result
    }
    private func v2SurfaceRefresh(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        var result: V2CallResult = .ok(["refreshed": 0])
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            var refreshedCount = 0
            for panel in ws.panels.values {
                if let terminalPanel = panel as? TerminalPanel {
                    terminalPanel.surface.forceRefresh()
                    refreshedCount += 1
                }
            }
            let windowId = v2ResolveWindowId(tabManager: tabManager)
            result = .ok(["window_id": v2OrNull(windowId?.uuidString), "window_ref": v2Ref(kind: .window, uuid: windowId), "workspace_id": ws.id.uuidString, "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id), "refreshed": refreshedCount])
        }
        return result
    }

    private func v2SurfaceHealth(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        var payload: [String: Any]?
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else { return }
            let panels = orderedPanels(in: ws)
            let items: [[String: Any]] = panels.enumerated().map { index, panel in
                var inWindow: Any = NSNull()
                if let tp = panel as? TerminalPanel {
                    inWindow = tp.surface.isViewInWindow
                } else if let bp = panel as? BrowserPanel {
                    inWindow = bp.webView.window != nil
                }
                return [
                    "index": index,
                    "id": panel.id.uuidString,
                    "ref": v2Ref(kind: .surface, uuid: panel.id),
                    "type": panel.panelType.rawValue,
                    "in_window": inWindow
                ]
            }
            let windowId = v2ResolveWindowId(tabManager: tabManager)
            payload = [
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surfaces": items,
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId)
            ]
        }

        guard let payload else {
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        }
        return .ok(payload)
    }

    private func v2SurfaceSendText(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let text = params["text"] as? String else {
            return .err(code: "invalid_params", message: "Missing text", data: nil)
        }

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to send text", data: nil)
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            let surfaceId = v2UUID(params, "surface_id") ?? ws.focusedPanelId
            guard let surfaceId else {
                result = .err(code: "not_found", message: "No focused surface", data: nil)
                return
            }
            guard let terminalPanel = ws.terminalPanel(for: surfaceId) else {
                result = .err(code: "invalid_params", message: "Surface is not a terminal", data: ["surface_id": surfaceId.uuidString])
                return
            }
            #if DEBUG
            let sendStart = ProcessInfo.processInfo.systemUptime
            #endif
            let queued: Bool
            if let surface = terminalPanel.surface.surface {
                sendSocketText(text, surface: surface)
                // Ensure we present a new frame after injecting input so snapshot-based tests (and
                // socket-driven agents) can observe the updated terminal without requiring a focus
                // change to trigger a draw.
                terminalPanel.surface.forceRefresh()
                queued = false
            } else {
                // Avoid blocking the main actor waiting for view/surface attachment.
                terminalPanel.sendText(text)
                terminalPanel.surface.requestBackgroundSurfaceStartIfNeeded()
                queued = true
            }
            #if DEBUG
            let sendMs = (ProcessInfo.processInfo.systemUptime - sendStart) * 1000.0
            dlog(
                "socket.surface.send_text workspace=\(ws.id.uuidString.prefix(8)) surface=\(surfaceId.uuidString.prefix(8)) queued=\(queued ? 1 : 0) chars=\(text.count) ms=\(String(format: "%.2f", sendMs))"
            )
            #endif
            result = .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "queued": queued,
                "window_id": v2OrNull(v2ResolveWindowId(tabManager: tabManager)?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: v2ResolveWindowId(tabManager: tabManager))
            ])
        }
        return result
    }

    private func v2SurfaceSendKey(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let key = v2String(params, "key") else {
            return .err(code: "invalid_params", message: "Missing key", data: nil)
        }

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to send key", data: nil)
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            let surfaceId = v2UUID(params, "surface_id") ?? ws.focusedPanelId
            guard let surfaceId else {
                result = .err(code: "not_found", message: "No focused surface", data: nil)
                return
            }
            guard let terminalPanel = ws.terminalPanel(for: surfaceId) else {
                result = .err(code: "invalid_params", message: "Surface is not a terminal", data: ["surface_id": surfaceId.uuidString])
                return
            }
            guard let surface = terminalPanel.surface.surface else {
                result = .err(code: "internal_error", message: "Surface not ready", data: ["surface_id": surfaceId.uuidString])
                return
            }
            guard sendNamedKey(surface, keyName: key) else {
                result = .err(code: "invalid_params", message: "Unknown key", data: ["key": key])
                return
            }
            terminalPanel.surface.forceRefresh()
            result = .ok(["workspace_id": ws.id.uuidString, "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id), "surface_id": surfaceId.uuidString, "surface_ref": v2Ref(kind: .surface, uuid: surfaceId), "window_id": v2OrNull(v2ResolveWindowId(tabManager: tabManager)?.uuidString), "window_ref": v2Ref(kind: .window, uuid: v2ResolveWindowId(tabManager: tabManager))])
        }
        return result
    }

    private func v2SurfaceClearHistory(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to clear history", data: nil)
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            let surfaceId = v2UUID(params, "surface_id") ?? ws.focusedPanelId
            guard let surfaceId else {
                result = .err(code: "not_found", message: "No focused surface", data: nil)
                return
            }
            guard let terminalPanel = ws.terminalPanel(for: surfaceId) else {
                result = .err(code: "invalid_params", message: "Surface is not a terminal", data: ["surface_id": surfaceId.uuidString])
                return
            }

            guard terminalPanel.performBindingAction("clear_screen") else {
                result = .err(code: "not_supported", message: "clear_screen binding action is unavailable", data: nil)
                return
            }

            terminalPanel.surface.forceRefresh()
            let windowId = v2ResolveWindowId(tabManager: tabManager)
            result = .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId)
            ])
        }

        return result
    }

    private func v2SurfaceReadText(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        var includeScrollback = v2Bool(params, "scrollback") ?? false
        let lineLimit = v2Int(params, "lines")
        if let lineLimit, lineLimit <= 0 {
            return .err(code: "invalid_params", message: "lines must be greater than 0", data: nil)
        }
        if lineLimit != nil {
            includeScrollback = true
        }

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to read terminal text", data: nil)
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }

            let surfaceId = v2UUID(params, "surface_id") ?? ws.focusedPanelId
            guard let surfaceId else {
                result = .err(code: "not_found", message: "No focused surface", data: nil)
                return
            }
            guard let terminalPanel = ws.terminalPanel(for: surfaceId) else {
                result = .err(code: "invalid_params", message: "Surface is not a terminal", data: ["surface_id": surfaceId.uuidString])
                return
            }

            let response = readTerminalTextBase64(
                terminalPanel: terminalPanel,
                includeScrollback: includeScrollback,
                lineLimit: lineLimit
            )
            guard response.hasPrefix("OK ") else {
                result = .err(code: "internal_error", message: response, data: nil)
                return
            }
            let base64 = String(response.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
            let decoded = Data(base64Encoded: base64).flatMap { String(data: $0, encoding: .utf8) }
            guard let text = decoded ?? (base64.isEmpty ? "" : nil) else {
                result = .err(code: "internal_error", message: "Failed to decode terminal text", data: nil)
                return
            }

            let windowId = v2ResolveWindowId(tabManager: tabManager)
            result = .ok([
                "text": text,
                "base64": base64,
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId)
            ])
        }
        return result
    }

    private func readTerminalTextBase64(terminalPanel: TerminalPanel, includeScrollback: Bool = false, lineLimit: Int? = nil) -> String {
        guard let surface = terminalPanel.surface.surface else { return "ERROR: Terminal surface not found" }

        let pointTag: ghostty_point_tag_e = includeScrollback ? GHOSTTY_POINT_SCREEN : GHOSTTY_POINT_VIEWPORT
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
            rectangle: true
        )
        var text = ghostty_text_s()

        guard ghostty_surface_read_text(surface, selection, &text) else {
            return "ERROR: Failed to read terminal text"
        }
        defer {
            ghostty_surface_free_text(surface, &text)
        }

        let rawData: Data
        if let ptr = text.text, text.text_len > 0 {
            rawData = Data(bytes: ptr, count: Int(text.text_len))
        } else {
            rawData = Data()
        }

        var output = String(decoding: rawData, as: UTF8.self)
        if let lineLimit {
            output = tailTerminalLines(output, maxLines: lineLimit)
        }

        let base64 = output.data(using: .utf8)?.base64EncodedString() ?? ""
        return "OK \(base64)"
    }

    private struct PasteboardItemSnapshot {
        let representations: [(type: NSPasteboard.PasteboardType, data: Data)]
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

    private func snapshotPasteboardItems(_ pasteboard: NSPasteboard) -> [PasteboardItemSnapshot] {
        guard let items = pasteboard.pasteboardItems else { return [] }
        return items.map { item in
            let representations = item.types.compactMap { type -> (type: NSPasteboard.PasteboardType, data: Data)? in
                guard let data = item.data(forType: type) else { return nil }
                return (type: type, data: data)
            }
            return PasteboardItemSnapshot(representations: representations)
        }
    }

    private func restorePasteboardItems(
        _ snapshots: [PasteboardItemSnapshot],
        to pasteboard: NSPasteboard
    ) {
        _ = pasteboard.clearContents()
        guard !snapshots.isEmpty else { return }

        let restoredItems = snapshots.compactMap { snapshot -> NSPasteboardItem? in
            guard !snapshot.representations.isEmpty else { return nil }
            let item = NSPasteboardItem()
            for representation in snapshot.representations {
                item.setData(representation.data, forType: representation.type)
            }
            return item
        }
        guard !restoredItems.isEmpty else { return }
        _ = pasteboard.writeObjects(restoredItems)
    }

    private func readGeneralPasteboardString(_ pasteboard: NSPasteboard) -> String? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
           let firstURL = urls.first,
           firstURL.isFileURL {
            return firstURL.path
        }
        if let value = pasteboard.string(forType: .string) {
            return value
        }
        return pasteboard.string(forType: NSPasteboard.PasteboardType("public.utf8-plain-text"))
    }

    private func readTerminalTextFromVTExportForSnapshot(
        terminalPanel: TerminalPanel,
        lineLimit: Int?
    ) -> String? {
        // read_text strips style state; VT export keeps ANSI escape sequences.
        let pasteboard = NSPasteboard.general
        let snapshot = snapshotPasteboardItems(pasteboard)
        defer {
            restorePasteboardItems(snapshot, to: pasteboard)
        }

        let initialChangeCount = pasteboard.changeCount
        guard terminalPanel.performBindingAction("write_screen_file:copy,vt") else {
            return nil
        }
        guard pasteboard.changeCount != initialChangeCount else {
            return nil
        }
        guard let exportedPath = Self.normalizedExportedScreenPath(readGeneralPasteboardString(pasteboard)) else {
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
              var output = String(data: data, encoding: .utf8) else {
            return nil
        }
        if let lineLimit {
            output = tailTerminalLines(output, maxLines: lineLimit)
        }
        return output
    }

    func readTerminalTextForSnapshot(
        terminalPanel: TerminalPanel,
        includeScrollback: Bool = false,
        lineLimit: Int? = nil
    ) -> String? {
        if includeScrollback,
           let vtOutput = readTerminalTextFromVTExportForSnapshot(
               terminalPanel: terminalPanel,
               lineLimit: lineLimit
           ) {
            return vtOutput
        }

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

    private func v2SurfaceTriggerFlash(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to trigger flash", data: nil)
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }

            // Only explicit focus-intent commands may mutate selection state.
            v2MaybeFocusWindow(for: tabManager)
            v2MaybeSelectWorkspace(tabManager, workspace: ws)

            let surfaceId = v2UUID(params, "surface_id") ?? ws.focusedPanelId
            guard let surfaceId else {
                result = .err(code: "not_found", message: "No focused surface", data: nil)
                return
            }
            guard ws.panels[surfaceId] != nil else {
                result = .err(code: "not_found", message: "Surface not found", data: ["surface_id": surfaceId.uuidString])
                return
            }

            ws.triggerFocusFlash(panelId: surfaceId)
            result = .ok(["workspace_id": ws.id.uuidString, "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id), "surface_id": surfaceId.uuidString, "surface_ref": v2Ref(kind: .surface, uuid: surfaceId), "window_id": v2OrNull(v2ResolveWindowId(tabManager: tabManager)?.uuidString), "window_ref": v2Ref(kind: .window, uuid: v2ResolveWindowId(tabManager: tabManager))])
        }
        return result
    }

    // MARK: - V2 Pane Methods

    private func v2PaneList(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        var payload: [String: Any]?
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else { return }

            let focusedPaneId = ws.bonsplitController.focusedPaneId
            let panes: [[String: Any]] = ws.bonsplitController.allPaneIds.enumerated().map { index, paneId in
                let tabs = ws.bonsplitController.tabs(inPane: paneId)
                let surfaceUUIDs: [UUID] = tabs.compactMap { ws.panelIdFromSurfaceId($0.id) }
                let selectedTab = ws.bonsplitController.selectedTab(inPane: paneId)
                let selectedSurfaceUUID = selectedTab.flatMap { ws.panelIdFromSurfaceId($0.id) }
                return [
                    "id": paneId.id.uuidString,
                    "ref": v2Ref(kind: .pane, uuid: paneId.id),
                    "index": index,
                    "focused": paneId == focusedPaneId,
                    "surface_ids": surfaceUUIDs.map { $0.uuidString },
                    "surface_refs": surfaceUUIDs.map { v2Ref(kind: .surface, uuid: $0) },
                    "selected_surface_id": v2OrNull(selectedSurfaceUUID?.uuidString),
                    "selected_surface_ref": v2Ref(kind: .surface, uuid: selectedSurfaceUUID),
                    "surface_count": surfaceUUIDs.count
                ]
            }

            let windowId = v2ResolveWindowId(tabManager: tabManager)
            payload = [
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "panes": panes,
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId)
            ]
        }

        guard let payload else {
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        }
        return .ok(payload)
    }
    private func v2PaneFocus(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let paneUUID = v2UUID(params, "pane_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid pane_id", data: nil)
        }

        var result: V2CallResult = .err(code: "not_found", message: "Pane not found", data: ["pane_id": paneUUID.uuidString])
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            guard let paneId = ws.bonsplitController.allPaneIds.first(where: { $0.id == paneUUID }) else {
                result = .err(code: "not_found", message: "Pane not found", data: ["pane_id": paneUUID.uuidString])
                return
            }
            v2MaybeFocusWindow(for: tabManager)
            v2MaybeSelectWorkspace(tabManager, workspace: ws)
            ws.bonsplitController.focusPane(paneId)
            let windowId = v2ResolveWindowId(tabManager: tabManager)
            result = .ok(["window_id": v2OrNull(windowId?.uuidString), "window_ref": v2Ref(kind: .window, uuid: windowId), "workspace_id": ws.id.uuidString, "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id), "pane_id": paneId.id.uuidString, "pane_ref": v2Ref(kind: .pane, uuid: paneId.id)])
        }
        return result
    }

    private func v2PaneSurfaces(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        var payload: [String: Any]?
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else { return }

            let paneUUID = v2UUID(params, "pane_id")
            let paneId: PaneID? = {
                if let paneUUID {
                    return ws.bonsplitController.allPaneIds.first(where: { $0.id == paneUUID })
                }
                return ws.bonsplitController.focusedPaneId
            }()
            guard let paneId else { return }

            let selectedTab = ws.bonsplitController.selectedTab(inPane: paneId)
            let tabs = ws.bonsplitController.tabs(inPane: paneId)

            let surfaces: [[String: Any]] = tabs.enumerated().map { index, tab in
                let panelId = ws.panelIdFromSurfaceId(tab.id)
                let panel = panelId.flatMap { ws.panels[$0] }
                return [
                    "id": v2OrNull(panelId?.uuidString),
                    "ref": v2Ref(kind: .surface, uuid: panelId),
                    "index": index,
                    "title": tab.title,
                    "type": v2OrNull(panel?.panelType.rawValue),
                    "selected": tab.id == selectedTab?.id
                ]
            }

            let windowId = v2ResolveWindowId(tabManager: tabManager)
            payload = [
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "pane_id": paneId.id.uuidString,
                "pane_ref": v2Ref(kind: .pane, uuid: paneId.id),
                "surfaces": surfaces,
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId)
            ]
        }

        guard let payload else {
            return .err(code: "not_found", message: "Pane or workspace not found", data: nil)
        }
        return .ok(payload)
    }
    private func v2PaneCreate(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let directionStr = v2String(params, "direction"),
              let direction = parseSplitDirection(directionStr) else {
            return .err(code: "invalid_params", message: "Missing or invalid direction (left|right|up|down)", data: nil)
        }

        let panelType = v2PanelType(params, "type") ?? .terminal
        let urlStr = v2String(params, "url")
        let url = urlStr.flatMap { URL(string: $0) }

        let orientation = direction.orientation
        let insertFirst = direction.insertFirst

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to create pane", data: nil)
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            v2MaybeFocusWindow(for: tabManager)
            v2MaybeSelectWorkspace(tabManager, workspace: ws)
            guard let focusedPanelId = ws.focusedPanelId else {
                result = .err(code: "not_found", message: "No focused surface to split", data: nil)
                return
            }

            let newPanelId: UUID?
            if panelType == .browser {
                newPanelId = ws.newBrowserSplit(
                    from: focusedPanelId,
                    orientation: orientation,
                    insertFirst: insertFirst,
                    url: url,
                    focus: v2FocusAllowed()
                )?.id
            } else {
                newPanelId = ws.newTerminalSplit(
                    from: focusedPanelId,
                    orientation: orientation,
                    insertFirst: insertFirst,
                    focus: v2FocusAllowed()
                )?.id
            }

            guard let newPanelId else {
                result = .err(code: "internal_error", message: "Failed to create pane", data: nil)
                return
            }
            let paneUUID = ws.paneId(forPanelId: newPanelId)?.id
            let windowId = v2ResolveWindowId(tabManager: tabManager)
            result = .ok([
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "pane_id": v2OrNull(paneUUID?.uuidString),
                "pane_ref": v2Ref(kind: .pane, uuid: paneUUID),
                "surface_id": newPanelId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: newPanelId),
                "type": panelType.rawValue
            ])
        }
        return result
    }

    private enum V2PaneResizeDirection: String {
        case left
        case right
        case up
        case down

        var splitOrientation: String {
            switch self {
            case .left, .right:
                return "horizontal"
            case .up, .down:
                return "vertical"
            }
        }

        /// A split controls the target pane's right/bottom edge when target is first child,
        /// and left/top edge when target is second child.
        var requiresPaneInFirstChild: Bool {
            switch self {
            case .right, .down:
                return true
            case .left, .up:
                return false
            }
        }

        /// Positive value moves divider toward second child (right/down).
        var dividerDeltaSign: CGFloat {
            requiresPaneInFirstChild ? 1 : -1
        }
    }

    private struct V2PaneResizeCandidate {
        let splitId: UUID
        let orientation: String
        let paneInFirstChild: Bool
        let dividerPosition: CGFloat
        let axisPixels: CGFloat
    }

    private struct V2PaneResizeTrace {
        let containsTarget: Bool
        let bounds: CGRect
    }

    private func v2PaneResizeCollectCandidates(
        node: ExternalTreeNode,
        targetPaneId: String,
        candidates: inout [V2PaneResizeCandidate]
    ) -> V2PaneResizeTrace {
        switch node {
        case .pane(let pane):
            let bounds = CGRect(
                x: pane.frame.x,
                y: pane.frame.y,
                width: pane.frame.width,
                height: pane.frame.height
            )
            return V2PaneResizeTrace(containsTarget: pane.id == targetPaneId, bounds: bounds)

        case .split(let split):
            let first = v2PaneResizeCollectCandidates(
                node: split.first,
                targetPaneId: targetPaneId,
                candidates: &candidates
            )
            let second = v2PaneResizeCollectCandidates(
                node: split.second,
                targetPaneId: targetPaneId,
                candidates: &candidates
            )

            let combinedBounds = first.bounds.union(second.bounds)
            let containsTarget = first.containsTarget || second.containsTarget

            if containsTarget,
               let splitUUID = UUID(uuidString: split.id) {
                let orientation = split.orientation.lowercased()
                let axisPixels: CGFloat = orientation == "horizontal"
                    ? combinedBounds.width
                    : combinedBounds.height
                candidates.append(V2PaneResizeCandidate(
                    splitId: splitUUID,
                    orientation: orientation,
                    paneInFirstChild: first.containsTarget,
                    dividerPosition: CGFloat(split.dividerPosition),
                    axisPixels: max(axisPixels, 1)
                ))
            }

            return V2PaneResizeTrace(containsTarget: containsTarget, bounds: combinedBounds)
        }
    }

    private func v2PaneResize(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        let directionRaw = (v2String(params, "direction") ?? "").lowercased()
        let amount = v2Int(params, "amount") ?? 1
        guard let direction = V2PaneResizeDirection(rawValue: directionRaw), amount > 0 else {
            return .err(code: "invalid_params", message: "direction must be one of left|right|up|down and amount must be > 0", data: nil)
        }

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to resize pane", data: nil)
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }

            let paneUUID = v2UUID(params, "pane_id") ?? ws.bonsplitController.focusedPaneId?.id
            guard let paneUUID else {
                result = .err(code: "not_found", message: "No focused pane", data: nil)
                return
            }
            guard ws.bonsplitController.allPaneIds.contains(where: { $0.id == paneUUID }) else {
                result = .err(code: "not_found", message: "Pane not found", data: ["pane_id": paneUUID.uuidString])
                return
            }

            let tree = ws.bonsplitController.treeSnapshot()
            var candidates: [V2PaneResizeCandidate] = []
            let trace = v2PaneResizeCollectCandidates(
                node: tree,
                targetPaneId: paneUUID.uuidString,
                candidates: &candidates
            )
            guard trace.containsTarget else {
                result = .err(code: "not_found", message: "Pane not found in split tree", data: ["pane_id": paneUUID.uuidString])
                return
            }

            let orientationMatches = candidates.filter { $0.orientation == direction.splitOrientation }
            guard !orientationMatches.isEmpty else {
                result = .err(
                    code: "invalid_state",
                    message: "No \(direction.splitOrientation) split ancestor for pane",
                    data: ["pane_id": paneUUID.uuidString, "direction": direction.rawValue]
                )
                return
            }

            guard let candidate = orientationMatches.first(where: { $0.paneInFirstChild == direction.requiresPaneInFirstChild }) else {
                result = .err(
                    code: "invalid_state",
                    message: "Pane has no adjacent border in direction \(direction.rawValue)",
                    data: ["pane_id": paneUUID.uuidString, "direction": direction.rawValue]
                )
                return
            }

            let delta = CGFloat(amount) / candidate.axisPixels
            let requested = candidate.dividerPosition + (direction.dividerDeltaSign * delta)
            let clamped = min(max(requested, 0.1), 0.9)
            guard ws.bonsplitController.setDividerPosition(clamped, forSplit: candidate.splitId, fromExternal: true) else {
                result = .err(
                    code: "internal_error",
                    message: "Failed to set split divider position",
                    data: ["split_id": candidate.splitId.uuidString]
                )
                return
            }

            let windowId = v2ResolveWindowId(tabManager: tabManager)
            result = .ok([
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "pane_id": paneUUID.uuidString,
                "pane_ref": v2Ref(kind: .pane, uuid: paneUUID),
                "split_id": candidate.splitId.uuidString,
                "direction": direction.rawValue,
                "amount": amount,
                "old_divider_position": candidate.dividerPosition,
                "new_divider_position": clamped
            ])
        }
        return result
    }

    private func v2PaneSwap(params: [String: Any]) -> V2CallResult {
        guard let sourcePaneUUID = v2UUID(params, "pane_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid pane_id", data: nil)
        }
        guard let targetPaneUUID = v2UUID(params, "target_pane_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid target_pane_id", data: nil)
        }
        if sourcePaneUUID == targetPaneUUID {
            return .err(code: "invalid_params", message: "pane_id and target_pane_id must be different", data: nil)
        }
        let focus = v2FocusAllowed(requested: v2Bool(params, "focus") ?? true)

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to swap panes", data: nil)
        v2MainSync {
            guard let located = v2LocatePane(sourcePaneUUID) else {
                result = .err(code: "not_found", message: "Source pane not found", data: ["pane_id": sourcePaneUUID.uuidString])
                return
            }
            guard let targetPane = located.workspace.bonsplitController.allPaneIds.first(where: { $0.id == targetPaneUUID }) else {
                result = .err(code: "not_found", message: "Target pane not found in source workspace", data: ["target_pane_id": targetPaneUUID.uuidString])
                return
            }
            let workspace = located.workspace
            let sourcePane = located.paneId

            guard let selectedSourceTab = workspace.bonsplitController.selectedTab(inPane: sourcePane),
                  let selectedTargetTab = workspace.bonsplitController.selectedTab(inPane: targetPane),
                  let sourceSurfaceId = workspace.panelIdFromSurfaceId(selectedSourceTab.id),
                  let targetSurfaceId = workspace.panelIdFromSurfaceId(selectedTargetTab.id) else {
                result = .err(code: "invalid_state", message: "Both panes must have a selected surface", data: nil)
                return
            }

            // Keep pane identities stable during swap when one side has a single surface.
            var sourcePlaceholder: UUID?
            var targetPlaceholder: UUID?
            if workspace.bonsplitController.tabs(inPane: sourcePane).count <= 1 {
                sourcePlaceholder = workspace.newTerminalSurface(inPane: sourcePane, focus: false)?.id
                if sourcePlaceholder == nil {
                    result = .err(code: "internal_error", message: "Failed to create source placeholder surface", data: nil)
                    return
                }
            }
            if workspace.bonsplitController.tabs(inPane: targetPane).count <= 1 {
                targetPlaceholder = workspace.newTerminalSurface(inPane: targetPane, focus: false)?.id
                if targetPlaceholder == nil {
                    result = .err(code: "internal_error", message: "Failed to create target placeholder surface", data: nil)
                    return
                }
            }

            guard workspace.moveSurface(panelId: sourceSurfaceId, toPane: targetPane, focus: false) else {
                result = .err(code: "internal_error", message: "Failed moving source surface into target pane", data: nil)
                return
            }
            guard workspace.moveSurface(panelId: targetSurfaceId, toPane: sourcePane, focus: false) else {
                result = .err(code: "internal_error", message: "Failed moving target surface into source pane", data: nil)
                return
            }

            if let sourcePlaceholder {
                _ = workspace.closePanel(sourcePlaceholder, force: true)
            }
            if let targetPlaceholder {
                _ = workspace.closePanel(targetPlaceholder, force: true)
            }

            if focus {
                workspace.bonsplitController.focusPane(targetPane)
            }
            let windowId = located.windowId
            result = .ok([
                "window_id": windowId.uuidString,
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "workspace_id": workspace.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: workspace.id),
                "pane_id": sourcePane.id.uuidString,
                "pane_ref": v2Ref(kind: .pane, uuid: sourcePane.id),
                "target_pane_id": targetPane.id.uuidString,
                "target_pane_ref": v2Ref(kind: .pane, uuid: targetPane.id),
                "source_surface_id": sourceSurfaceId.uuidString,
                "source_surface_ref": v2Ref(kind: .surface, uuid: sourceSurfaceId),
                "target_surface_id": targetSurfaceId.uuidString,
                "target_surface_ref": v2Ref(kind: .surface, uuid: targetSurfaceId)
            ])
        }
        return result
    }

    private func v2PaneBreak(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        let focus = v2FocusAllowed(requested: v2Bool(params, "focus") ?? true)

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to break pane", data: nil)
        v2MainSync {
            guard let sourceWorkspace = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }

            let sourcePaneUUID = v2UUID(params, "pane_id")
            let sourcePane: PaneID? = {
                if let sourcePaneUUID {
                    return sourceWorkspace.bonsplitController.allPaneIds.first(where: { $0.id == sourcePaneUUID })
                }
                return sourceWorkspace.bonsplitController.focusedPaneId
            }()

            let surfaceId: UUID? = {
                if let explicitSurface = v2UUID(params, "surface_id") { return explicitSurface }
                if let sourcePane,
                   let selected = sourceWorkspace.bonsplitController.selectedTab(inPane: sourcePane) {
                    return sourceWorkspace.panelIdFromSurfaceId(selected.id)
                }
                return sourceWorkspace.focusedPanelId
            }()
            guard let surfaceId else {
                result = .err(code: "not_found", message: "No source surface to break", data: nil)
                return
            }
            guard sourceWorkspace.panels[surfaceId] != nil else {
                result = .err(code: "not_found", message: "Surface not found", data: ["surface_id": surfaceId.uuidString])
                return
            }
            let sourceIndex = sourceWorkspace.indexInPane(forPanelId: surfaceId)
            let sourcePaneForRollback = sourceWorkspace.paneId(forPanelId: surfaceId)

            guard let detached = sourceWorkspace.detachSurface(panelId: surfaceId) else {
                result = .err(code: "internal_error", message: "Failed to detach source surface", data: nil)
                return
            }

            let destinationWorkspace = tabManager.addWorkspace(select: focus)
            guard let destinationPane = destinationWorkspace.bonsplitController.focusedPaneId
                ?? destinationWorkspace.bonsplitController.allPaneIds.first else {
                if let sourcePaneForRollback {
                    _ = sourceWorkspace.attachDetachedSurface(
                        detached,
                        inPane: sourcePaneForRollback,
                        atIndex: sourceIndex,
                        focus: focus
                    )
                }
                result = .err(code: "internal_error", message: "Destination workspace has no pane", data: nil)
                return
            }

            guard destinationWorkspace.attachDetachedSurface(detached, inPane: destinationPane, focus: focus) != nil else {
                if let sourcePaneForRollback {
                    _ = sourceWorkspace.attachDetachedSurface(
                        detached,
                        inPane: sourcePaneForRollback,
                        atIndex: sourceIndex,
                        focus: focus
                    )
                }
                result = .err(code: "internal_error", message: "Failed to attach surface to new workspace", data: nil)
                return
            }
            let windowId = v2ResolveWindowId(tabManager: tabManager)
            result = .ok([
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "workspace_id": destinationWorkspace.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: destinationWorkspace.id),
                "pane_id": destinationPane.id.uuidString,
                "pane_ref": v2Ref(kind: .pane, uuid: destinationPane.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId)
            ])
        }
        return result
    }

    private func v2PaneJoin(params: [String: Any]) -> V2CallResult {
        guard let targetPaneUUID = v2UUID(params, "target_pane_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid target_pane_id", data: nil)
        }

        var surfaceId = v2UUID(params, "surface_id")
        if surfaceId == nil, let sourcePaneUUID = v2UUID(params, "pane_id") {
            guard let sourceLocated = v2LocatePane(sourcePaneUUID),
                  let selected = sourceLocated.workspace.bonsplitController.selectedTab(inPane: sourceLocated.paneId),
                  let selectedSurface = sourceLocated.workspace.panelIdFromSurfaceId(selected.id) else {
                return .err(code: "not_found", message: "Unable to resolve selected surface in source pane", data: [
                    "pane_id": sourcePaneUUID.uuidString
                ])
            }
            surfaceId = selectedSurface
        }
        guard let surfaceId else {
            return .err(code: "invalid_params", message: "Missing surface_id (or pane_id with selected surface)", data: nil)
        }

        var moveParams: [String: Any] = [
            "surface_id": surfaceId.uuidString,
            "pane_id": targetPaneUUID.uuidString
        ]
        if let focus = v2Bool(params, "focus") {
            moveParams["focus"] = focus
        }
        return v2SurfaceMove(params: moveParams)
    }

    private func v2PaneLast(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        var result: V2CallResult = .err(code: "not_found", message: "No alternate pane available", data: nil)
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            guard let focused = ws.bonsplitController.focusedPaneId else {
                result = .err(code: "not_found", message: "No focused pane", data: nil)
                return
            }
            guard let target = ws.bonsplitController.allPaneIds.first(where: { $0.id != focused.id }) else {
                result = .err(code: "not_found", message: "No alternate pane available", data: nil)
                return
            }

            ws.bonsplitController.focusPane(target)
            let selectedSurfaceId = ws.bonsplitController.selectedTab(inPane: target).flatMap { ws.panelIdFromSurfaceId($0.id) }
            let windowId = v2ResolveWindowId(tabManager: tabManager)
            result = .ok([
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "pane_id": target.id.uuidString,
                "pane_ref": v2Ref(kind: .pane, uuid: target.id),
                "surface_id": v2OrNull(selectedSurfaceId?.uuidString),
                "surface_ref": v2Ref(kind: .surface, uuid: selectedSurfaceId)
            ])
        }
        return result
    }

    // MARK: - V2 Notification Methods

    private func v2NotificationCreate(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        let title = (params["title"] as? String) ?? "Notification"
        let subtitle = (params["subtitle"] as? String) ?? ""
        let body = (params["body"] as? String) ?? ""

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to notify", data: nil)
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            let surfaceId = ws.focusedPanelId
            TerminalNotificationStore.shared.addNotification(
                tabId: ws.id,
                surfaceId: surfaceId,
                title: title,
                subtitle: subtitle,
                body: body
            )
            result = .ok(["workspace_id": ws.id.uuidString, "surface_id": v2OrNull(surfaceId?.uuidString)])
        }
        return result
    }

    private func v2NotificationCreateForSurface(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let surfaceId = v2UUID(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid surface_id", data: nil)
        }

        let title = (params["title"] as? String) ?? "Notification"
        let subtitle = (params["subtitle"] as? String) ?? ""
        let body = (params["body"] as? String) ?? ""

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to notify", data: nil)
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            guard ws.panels[surfaceId] != nil else {
                result = .err(code: "not_found", message: "Surface not found", data: ["surface_id": surfaceId.uuidString])
                return
            }
            TerminalNotificationStore.shared.addNotification(
                tabId: ws.id,
                surfaceId: surfaceId,
                title: title,
                subtitle: subtitle,
                body: body
            )
            result = .ok(["workspace_id": ws.id.uuidString, "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id), "surface_id": surfaceId.uuidString, "surface_ref": v2Ref(kind: .surface, uuid: surfaceId), "window_id": v2OrNull(v2ResolveWindowId(tabManager: tabManager)?.uuidString), "window_ref": v2Ref(kind: .window, uuid: v2ResolveWindowId(tabManager: tabManager))])
        }
        return result
    }

    private func v2NotificationCreateForTarget(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let wsId = v2UUID(params, "workspace_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }
        guard let surfaceId = v2UUID(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid surface_id", data: nil)
        }

        let title = (params["title"] as? String) ?? "Notification"
        let subtitle = (params["subtitle"] as? String) ?? ""
        let body = (params["body"] as? String) ?? ""

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to notify", data: nil)
        v2MainSync {
            guard let ws = tabManager.tabs.first(where: { $0.id == wsId }) else {
                result = .err(code: "not_found", message: "Workspace not found", data: ["workspace_id": wsId.uuidString])
                return
            }
            guard ws.panels[surfaceId] != nil else {
                result = .err(code: "not_found", message: "Surface not found", data: ["surface_id": surfaceId.uuidString])
                return
            }
            TerminalNotificationStore.shared.addNotification(
                tabId: ws.id,
                surfaceId: surfaceId,
                title: title,
                subtitle: subtitle,
                body: body
            )
            result = .ok(["workspace_id": ws.id.uuidString, "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id), "surface_id": surfaceId.uuidString, "surface_ref": v2Ref(kind: .surface, uuid: surfaceId), "window_id": v2OrNull(v2ResolveWindowId(tabManager: tabManager)?.uuidString), "window_ref": v2Ref(kind: .window, uuid: v2ResolveWindowId(tabManager: tabManager))])
        }
        return result
    }

    private func v2NotificationList() -> [String: Any] {
        var items: [[String: Any]] = []
        DispatchQueue.main.sync {
            items = TerminalNotificationStore.shared.notifications.map { n in
                return [
                    "id": n.id.uuidString,
                    "workspace_id": n.tabId.uuidString,
                    "surface_id": v2OrNull(n.surfaceId?.uuidString),
                    "is_read": n.isRead,
                    "title": n.title,
                    "subtitle": n.subtitle,
                    "body": n.body
                ]
            }
        }
        return ["notifications": items]
    }

    private func v2NotificationClear() -> V2CallResult {
        DispatchQueue.main.sync {
            TerminalNotificationStore.shared.clearAll()
        }
        return .ok([:])
    }

    // MARK: - V2 App Focus Methods

    private func v2AppFocusOverride(params: [String: Any]) -> V2CallResult {
        // Accept either:
        // - state: "active" | "inactive" | "clear"
        // - focused: true/false/null
        if let state = v2String(params, "state")?.lowercased() {
            switch state {
            case "active":
                AppFocusState.overrideIsFocused = true
            case "inactive":
                AppFocusState.overrideIsFocused = false
            case "clear", "none":
                AppFocusState.overrideIsFocused = nil
            default:
                return .err(code: "invalid_params", message: "Invalid state (active|inactive|clear)", data: ["state": state])
            }
        } else if params.keys.contains("focused") {
            if let focused = v2Bool(params, "focused") {
                AppFocusState.overrideIsFocused = focused
            } else {
                AppFocusState.overrideIsFocused = nil
            }
        } else {
            return .err(code: "invalid_params", message: "Missing state or focused", data: nil)
        }

        let overrideVal: Any = v2OrNull(AppFocusState.overrideIsFocused.map { $0 as Any })
        return .ok(["override": overrideVal])
    }

    private func v2AppSimulateActive() -> V2CallResult {
        v2MainSync {
            AppDelegate.shared?.applicationDidBecomeActive(
                Notification(name: NSApplication.didBecomeActiveNotification)
            )
        }
        return .ok([:])
    }

    // MARK: - V2 Browser Methods

    private func v2BrowserWithPanel(
        params: [String: Any],
        _ body: (_ tabManager: TabManager, _ workspace: Workspace, _ surfaceId: UUID, _ browserPanel: BrowserPanel) -> V2CallResult
    ) -> V2CallResult {
        var result: V2CallResult = .err(code: "internal_error", message: "Browser operation failed", data: nil)
        v2MainSync {
            guard let tabManager = v2ResolveTabManager(params: params) else {
                result = .err(code: "unavailable", message: "TabManager not available", data: nil)
                return
            }
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            let surfaceId = v2UUID(params, "surface_id") ?? ws.focusedPanelId
            guard let surfaceId else {
                result = .err(code: "not_found", message: "No focused browser surface", data: nil)
                return
            }
            guard let browserPanel = ws.browserPanel(for: surfaceId) else {
                result = .err(code: "invalid_params", message: "Surface is not a browser", data: ["surface_id": surfaceId.uuidString])
                return
            }
            result = body(tabManager, ws, surfaceId, browserPanel)
        }
        return result
    }

    private func v2JSONLiteral(_ value: Any) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: [value], options: []),
           let text = String(data: data, encoding: .utf8),
           text.count >= 2 {
            return String(text.dropFirst().dropLast())
        }
        if let s = value as? String {
            return "\"\(s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
        }
        return "null"
    }

    private func v2NormalizeJSValue(_ value: Any?) -> Any {
        guard let value else { return NSNull() }
        if value is NSNull { return NSNull() }
        if let v = value as? String { return v }
        if let v = value as? NSNumber { return v }
        if let v = value as? Bool { return v }
        if let dict = value as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, v) in dict {
                out[k] = v2NormalizeJSValue(v)
            }
            return out
        }
        if let arr = value as? [Any] {
            return arr.map { v2NormalizeJSValue($0) }
        }
        return String(describing: value)
    }

    private enum V2JavaScriptResult {
        case success(Any?)
        case failure(String)
    }

    private func v2RunJavaScript(_ webView: WKWebView, script: String, timeout: TimeInterval = 5.0) -> V2JavaScriptResult {
        var done = false
        var resultValue: Any?
        var resultError: String?

        webView.evaluateJavaScript(script) { value, error in
            if let error {
                resultError = error.localizedDescription
            } else {
                resultValue = value
            }
            done = true
        }

        let deadline = Date().addingTimeInterval(timeout)
        while !done && Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }

        if !done {
            return .failure("Timed out waiting for JavaScript result")
        }
        if let resultError {
            return .failure(resultError)
        }
        return .success(resultValue)
    }

    private func v2BrowserSelector(_ params: [String: Any]) -> String? {
        v2String(params, "selector")
            ?? v2String(params, "sel")
            ?? v2String(params, "element_ref")
            ?? v2String(params, "ref")
    }

    private func v2BrowserNotSupported(_ method: String, details: String) -> V2CallResult {
        .err(code: "not_supported", message: "\(method) is not supported on WKWebView", data: ["details": details])
    }

    private func v2BrowserAllocateElementRef(surfaceId: UUID, selector: String) -> String {
        let ref = "@e\(v2BrowserNextElementOrdinal)"
        v2BrowserNextElementOrdinal += 1
        v2BrowserElementRefs[ref] = V2BrowserElementRefEntry(surfaceId: surfaceId, selector: selector)
        return ref
    }

    private func v2BrowserResolveSelector(_ rawSelector: String, surfaceId: UUID) -> String? {
        let trimmed = rawSelector.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let refKey: String? = {
            if trimmed.hasPrefix("@e") { return trimmed }
            if trimmed.hasPrefix("e"), Int(trimmed.dropFirst()) != nil { return "@\(trimmed)" }
            return nil
        }()

        if let refKey {
            guard let entry = v2BrowserElementRefs[refKey], entry.surfaceId == surfaceId else { return nil }
            return entry.selector
        }
        return trimmed
    }

    private func v2BrowserCurrentFrameSelector(surfaceId: UUID) -> String? {
        v2BrowserFrameSelectorBySurface[surfaceId]
    }

    private func v2RunBrowserJavaScript(
        _ webView: WKWebView,
        surfaceId: UUID,
        script: String,
        timeout: TimeInterval = 5.0
    ) -> V2JavaScriptResult {
        guard let frameSelector = v2BrowserCurrentFrameSelector(surfaceId: surfaceId) else {
            return v2RunJavaScript(webView, script: script, timeout: timeout)
        }

        let selectorLiteral = v2JSONLiteral(frameSelector)
        let scriptLiteral = v2JSONLiteral(script)
        let wrapped = """
        (() => {
          let __cmuxDoc = document;
          try {
            const __cmuxFrame = document.querySelector(\(selectorLiteral));
            if (__cmuxFrame && __cmuxFrame.contentDocument) {
              __cmuxDoc = __cmuxFrame.contentDocument;
            }
          } catch (_) {}

          const __cmuxEvalInFrame = function() {
            const document = __cmuxDoc;
            return eval(\(scriptLiteral));
          };
          return __cmuxEvalInFrame();
        })()
        """
        return v2RunJavaScript(webView, script: wrapped, timeout: timeout)
    }

    private func v2BrowserRecordUnsupportedRequest(surfaceId: UUID, request: [String: Any]) {
        var logs = v2BrowserUnsupportedNetworkRequestsBySurface[surfaceId] ?? []
        logs.append(request)
        if logs.count > 256 {
            logs.removeFirst(logs.count - 256)
        }
        v2BrowserUnsupportedNetworkRequestsBySurface[surfaceId] = logs
    }

    private func v2BrowserPendingDialogs(surfaceId: UUID) -> [[String: Any]] {
        let queue = v2BrowserDialogQueueBySurface[surfaceId] ?? []
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
        _ = v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: injector)

        for script in scripts {
            _ = v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script)
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
            _ = v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: styleScript)
        }
    }

    private func v2BrowserWaitForCondition(
        _ conditionScript: String,
        webView: WKWebView,
        surfaceId: UUID? = nil,
        timeout: TimeInterval = 5.0,
        pollInterval: TimeInterval = 0.05
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let wrapped = "(() => { try { return !!(\(conditionScript)); } catch (_) { return false; } })()"
            let jsResult: V2JavaScriptResult
            if let surfaceId {
                jsResult = v2RunBrowserJavaScript(webView, surfaceId: surfaceId, script: wrapped, timeout: max(0.5, pollInterval + 0.25))
            } else {
                jsResult = v2RunJavaScript(webView, script: wrapped, timeout: max(0.5, pollInterval + 0.25))
            }
            if case let .success(value) = jsResult,
               let ok = value as? Bool,
               ok {
                return true
            }
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(pollInterval))
        }
        return false
    }

    private func v2PNGData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private func v2BrowserOpenSplit(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        let urlStr = v2String(params, "url")
        let url = urlStr.flatMap { URL(string: $0) }

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to create browser", data: nil)
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
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

            var createdSplit = true
            var placementStrategy = "split_right"
            let createdPanel: BrowserPanel?
            if let targetPane = ws.preferredBrowserTargetPane(fromPanelId: sourceSurfaceId) {
                createdPanel = ws.newBrowserSurface(inPane: targetPane, url: url, focus: v2FocusAllowed())
                createdSplit = false
                placementStrategy = "reuse_right_sibling"
            } else {
                createdPanel = ws.newBrowserSplit(
                    from: sourceSurfaceId,
                    orientation: .horizontal,
                    url: url,
                    focus: v2FocusAllowed()
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
                "placement_strategy": placementStrategy
            ])
        }
        return result
    }

    private func v2BrowserNavigate(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let surfaceId = v2UUID(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid surface_id", data: nil)
        }
        guard let url = v2String(params, "url") else {
            return .err(code: "invalid_params", message: "Missing url", data: nil)
        }

        var result: V2CallResult = .err(code: "not_found", message: "Surface not found or not a browser", data: ["surface_id": surfaceId.uuidString])
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager),
                  let browserPanel = ws.browserPanel(for: surfaceId) else { return }
            browserPanel.navigateSmart(url)
            var payload: [String: Any] = [
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "window_id": v2OrNull(v2ResolveWindowId(tabManager: tabManager)?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: v2ResolveWindowId(tabManager: tabManager))
            ]
            v2BrowserAppendPostSnapshot(params: params, surfaceId: surfaceId, payload: &payload)
            result = .ok(payload)
        }
        return result
    }

    private func v2BrowserBack(params: [String: Any]) -> V2CallResult {
        return v2BrowserNavSimple(params: params, action: "back")
    }

    private func v2BrowserForward(params: [String: Any]) -> V2CallResult {
        return v2BrowserNavSimple(params: params, action: "forward")
    }

    private func v2BrowserReload(params: [String: Any]) -> V2CallResult {
        return v2BrowserNavSimple(params: params, action: "reload")
    }

    private func v2BrowserNotFoundDiagnostics(
        surfaceId: UUID,
        browserPanel: BrowserPanel,
        selector: String
    ) -> [String: Any] {
        let selectorLiteral = v2JSONLiteral(selector)
        let script = """
        (() => {
          const __selector = \(selectorLiteral);
          const __normalize = (s) => String(s || '').replace(/\\s+/g, ' ').trim();
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
          const __describe = (el) => {
            const tag = String(el.tagName || '').toLowerCase();
            const id = __normalize(el.id || '');
            const klass = __normalize(el.className || '').split(/\\s+/).filter(Boolean).slice(0, 2).join('.');
            let out = tag || 'element';
            if (id) out += '#' + id;
            if (klass) out += '.' + klass;
            return out;
          };
          try {
            const __nodes = Array.from(document.querySelectorAll(__selector));
            const __visible = __nodes.filter(__isVisible);
            const __sample = __nodes.slice(0, 6).map((el, idx) => ({
              index: idx,
              descriptor: __describe(el),
              role: __normalize(el.getAttribute('role') || ''),
              visible: __isVisible(el),
              text: __normalize(el.innerText || el.textContent || '').slice(0, 120)
            }));
            const __snapshotExcerpt = __sample.map((row) => {
              const suffix = row.text ? ` \"${row.text}\"` : '';
              return `- ${row.descriptor}${suffix}`;
            }).join('\\n');
            return {
              ok: true,
              selector: __selector,
              count: __nodes.length,
              visible_count: __visible.length,
              sample: __sample,
              snapshot_excerpt: __snapshotExcerpt,
              title: __normalize(document.title || ''),
              url: String(location.href || ''),
              body_excerpt: document.body ? __normalize(document.body.innerText || '').slice(0, 400) : ''
            };
          } catch (err) {
            return {
              ok: false,
              selector: __selector,
              error: 'invalid_selector',
              details: String((err && err.message) || err || '')
            };
          }
        })()
        """

        switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script, timeout: 4.0) {
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

    private func v2BrowserElementNotFoundResult(
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

        let message: String
        if count > 0 && visibleCount == 0 {
            message = "Element \"\(selector)\" is present but not visible."
        } else if count > 1 {
            message = "Selector \"\(selector)\" matched multiple elements."
        } else {
            message = "Element \"\(selector)\" not found or not visible. Run 'browser snapshot' to see current page elements."
        }

        return .err(code: "not_found", message: message, data: data)
    }

    private func v2BrowserAppendPostSnapshot(
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

    private func v2BrowserSelectorAction(
        params: [String: Any],
        actionName: String,
        scriptBuilder: (_ selectorLiteral: String) -> String
    ) -> V2CallResult {
        guard let selectorRaw = v2BrowserSelector(params) else {
            return .err(code: "invalid_params", message: "Missing selector", data: nil)
        }

        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            guard let selector = v2BrowserResolveSelector(selectorRaw, surfaceId: surfaceId) else {
                return .err(code: "not_found", message: "Element reference not found", data: ["selector": selectorRaw])
            }
            let script = scriptBuilder(v2JSONLiteral(selector))
            let retryAttempts = max(1, v2Int(params, "retry_attempts") ?? 3)

            for attempt in 1...retryAttempts {
                switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script) {
                case .failure(let message):
                    return .err(code: "js_error", message: message, data: ["action": actionName, "selector": selector])
                case .success(let value):
                    if let dict = value as? [String: Any],
                       let ok = dict["ok"] as? Bool,
                       ok {
                        var payload: [String: Any] = [
                            "workspace_id": ws.id.uuidString,
                            "surface_id": surfaceId.uuidString,
                            "action": actionName,
                            "attempts": attempt
                        ]
                        payload["workspace_ref"] = v2Ref(kind: .workspace, uuid: ws.id)
                        payload["surface_ref"] = v2Ref(kind: .surface, uuid: surfaceId)
                        if let resultValue = dict["value"] {
                            payload["value"] = v2NormalizeJSValue(resultValue)
                        }
                        v2BrowserAppendPostSnapshot(params: params, surfaceId: surfaceId, payload: &payload)
                        return .ok(payload)
                    }

                    let errorText = (value as? [String: Any])?["error"] as? String
                    if errorText == "not_found", attempt < retryAttempts {
                        _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.08))
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

    private func v2BrowserEval(params: [String: Any]) -> V2CallResult {
        guard let script = v2String(params, "script") else {
            return .err(code: "invalid_params", message: "Missing script", data: nil)
        }
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script, timeout: 10.0) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                return .ok([
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "value": v2NormalizeJSValue(value)
                ])
            }
        }
    }

    private func v2BrowserSnapshot(params: [String: Any]) -> V2CallResult {
        let interactiveOnly = v2Bool(params, "interactive") ?? false
        let includeCursor = v2Bool(params, "cursor") ?? false
        let compact = v2Bool(params, "compact") ?? false
        let maxDepth = max(0, v2Int(params, "max_depth") ?? v2Int(params, "maxDepth") ?? 12)
        let scopeSelector = v2String(params, "selector")

        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
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

            switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script, timeout: 10.0) {
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
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
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

    private func v2BrowserWait(params: [String: Any]) -> V2CallResult {
        let timeoutMs = max(1, v2Int(params, "timeout_ms") ?? 5_000)
        let timeout = Double(timeoutMs) / 1000.0

        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            let conditionScript: String = {
                if let selector = v2BrowserSelector(params) {
                    let literal = v2JSONLiteral(selector)
                    return "document.querySelector(\(literal)) !== null"
                }
                if let urlContains = v2String(params, "url_contains") {
                    let literal = v2JSONLiteral(urlContains)
                    return "String(location.href || '').includes(\(literal))"
                }
                if let textContains = v2String(params, "text_contains") {
                    let literal = v2JSONLiteral(textContains)
                    return "(document.body && String(document.body.innerText || '').includes(\(literal)))"
                }
                if let loadState = v2String(params, "load_state") {
                    let literal = v2JSONLiteral(loadState.lowercased())
                    return "String(document.readyState || '').toLowerCase() === \(literal)"
                }
                if let fn = v2String(params, "function") {
                    return "(() => { return !!(\(fn)); })()"
                }
                return "document.readyState === 'complete'"
            }()

            let ok = v2BrowserWaitForCondition(conditionScript, webView: browserPanel.webView, surfaceId: surfaceId, timeout: timeout)
            if !ok {
                return .err(code: "timeout", message: "Condition not met before timeout", data: ["timeout_ms": timeoutMs])
            }
            return .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "waited": true
            ])
        }
    }

    private func v2BrowserClick(params: [String: Any]) -> V2CallResult {
        v2BrowserSelectorAction(params: params, actionName: "click") { selectorLiteral in
            """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              el.scrollIntoView({ block: 'nearest', inline: 'nearest' });
              if (typeof el.click === 'function') {
                el.click();
              } else {
                el.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, view: window, detail: 1 }));
              }
              return { ok: true };
            })()
            """
        }
    }

    private func v2BrowserDblClick(params: [String: Any]) -> V2CallResult {
        v2BrowserSelectorAction(params: params, actionName: "dblclick") { selectorLiteral in
            """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              el.scrollIntoView({ block: 'nearest', inline: 'nearest' });
              el.dispatchEvent(new MouseEvent('dblclick', { bubbles: true, cancelable: true, view: window, detail: 2 }));
              return { ok: true };
            })()
            """
        }
    }

    private func v2BrowserHover(params: [String: Any]) -> V2CallResult {
        v2BrowserSelectorAction(params: params, actionName: "hover") { selectorLiteral in
            """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              el.scrollIntoView({ block: 'nearest', inline: 'nearest' });
              el.dispatchEvent(new MouseEvent('mouseover', { bubbles: true, cancelable: true, view: window }));
              el.dispatchEvent(new MouseEvent('mouseenter', { bubbles: true, cancelable: true, view: window }));
              return { ok: true };
            })()
            """
        }
    }

    private func v2BrowserFocusElement(params: [String: Any]) -> V2CallResult {
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

    private func v2BrowserType(params: [String: Any]) -> V2CallResult {
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
                el.value = (el.value || '') + chunk;
                el.dispatchEvent(new Event('input', { bubbles: true }));
                el.dispatchEvent(new Event('change', { bubbles: true }));
              } else {
                el.textContent = (el.textContent || '') + chunk;
              }
              return { ok: true };
            })()
            """
        }
    }

    private func v2BrowserFill(params: [String: Any]) -> V2CallResult {
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
              const value = String(\(textLiteral));
              if ('value' in el) {
                el.value = value;
                el.dispatchEvent(new Event('input', { bubbles: true }));
                el.dispatchEvent(new Event('change', { bubbles: true }));
              } else {
                el.textContent = value;
              }
              return { ok: true };
            })()
            """
        }
    }

    private func v2BrowserPress(params: [String: Any]) -> V2CallResult {
        guard let key = v2String(params, "key") else {
            return .err(code: "invalid_params", message: "Missing key", data: nil)
        }

        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            let keyLiteral = v2JSONLiteral(key)
            let script = """
            (() => {
              const target = document.activeElement || document.body || document.documentElement;
              if (!target) return { ok: false, error: 'not_found' };
              const k = String(\(keyLiteral));
              target.dispatchEvent(new KeyboardEvent('keydown', { key: k, bubbles: true, cancelable: true }));
              target.dispatchEvent(new KeyboardEvent('keypress', { key: k, bubbles: true, cancelable: true }));
              target.dispatchEvent(new KeyboardEvent('keyup', { key: k, bubbles: true, cancelable: true }));
              return { ok: true };
            })()
            """
            switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success:
                var payload: [String: Any] = [
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId)
                ]
                v2BrowserAppendPostSnapshot(params: params, surfaceId: surfaceId, payload: &payload)
                return .ok(payload)
            }
        }
    }

    private func v2BrowserKeyDown(params: [String: Any]) -> V2CallResult {
        guard let key = v2String(params, "key") else {
            return .err(code: "invalid_params", message: "Missing key", data: nil)
        }
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            let keyLiteral = v2JSONLiteral(key)
            let script = """
            (() => {
              const target = document.activeElement || document.body || document.documentElement;
              if (!target) return { ok: false, error: 'not_found' };
              const k = String(\(keyLiteral));
              target.dispatchEvent(new KeyboardEvent('keydown', { key: k, bubbles: true, cancelable: true }));
              return { ok: true };
            })()
            """
            switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success:
                var payload: [String: Any] = [
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId)
                ]
                v2BrowserAppendPostSnapshot(params: params, surfaceId: surfaceId, payload: &payload)
                return .ok(payload)
            }
        }
    }

    private func v2BrowserKeyUp(params: [String: Any]) -> V2CallResult {
        guard let key = v2String(params, "key") else {
            return .err(code: "invalid_params", message: "Missing key", data: nil)
        }
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            let keyLiteral = v2JSONLiteral(key)
            let script = """
            (() => {
              const target = document.activeElement || document.body || document.documentElement;
              if (!target) return { ok: false, error: 'not_found' };
              const k = String(\(keyLiteral));
              target.dispatchEvent(new KeyboardEvent('keyup', { key: k, bubbles: true, cancelable: true }));
              return { ok: true };
            })()
            """
            switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success:
                var payload: [String: Any] = [
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId)
                ]
                v2BrowserAppendPostSnapshot(params: params, surfaceId: surfaceId, payload: &payload)
                return .ok(payload)
            }
        }
    }

    private func v2BrowserCheck(params: [String: Any], checked: Bool) -> V2CallResult {
        v2BrowserSelectorAction(params: params, actionName: checked ? "check" : "uncheck") { selectorLiteral in
            """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              if (!('checked' in el)) return { ok: false, error: 'not_checkable' };
              el.checked = \(checked ? "true" : "false");
              el.dispatchEvent(new Event('input', { bubbles: true }));
              el.dispatchEvent(new Event('change', { bubbles: true }));
              return { ok: true };
            })()
            """
        }
    }

    private func v2BrowserSelect(params: [String: Any]) -> V2CallResult {
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
              el.value = String(\(valueLiteral));
              el.dispatchEvent(new Event('input', { bubbles: true }));
              el.dispatchEvent(new Event('change', { bubbles: true }));
              return { ok: true };
            })()
            """
        }
    }

    private func v2BrowserScroll(params: [String: Any]) -> V2CallResult {
        let dx = v2Int(params, "dx") ?? 0
        let dy = v2Int(params, "dy") ?? 0
        let selectorRaw = v2BrowserSelector(params)

        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
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

            switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script) {
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
                            browserPanel: browserPanel
                        )
                    }
                    return .err(code: "not_found", message: "Element not found", data: ["selector": selector ?? ""])
                }
                var payload: [String: Any] = [
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId)
                ]
                v2BrowserAppendPostSnapshot(params: params, surfaceId: surfaceId, payload: &payload)
                return .ok(payload)
            }
        }
    }

    private func v2BrowserScrollIntoView(params: [String: Any]) -> V2CallResult {
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

    private func v2BrowserScreenshot(params: [String: Any]) -> V2CallResult {
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            var done = false
            var imageData: Data?
            browserPanel.takeSnapshot { image in
                imageData = image.flatMap { self.v2PNGData(from: $0) }
                done = true
            }

            let deadline = Date().addingTimeInterval(5.0)
            while !done && Date() < deadline {
                _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }

            guard done else {
                return .err(code: "timeout", message: "Timed out waiting for snapshot", data: nil)
            }
            guard let imageData else {
                return .err(code: "internal_error", message: "Failed to capture snapshot", data: nil)
            }

            return .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "png_base64": imageData.base64EncodedString()
            ])
        }
    }

    private func v2BrowserGetText(params: [String: Any]) -> V2CallResult {
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

    private func v2BrowserGetHTML(params: [String: Any]) -> V2CallResult {
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

    private func v2BrowserGetValue(params: [String: Any]) -> V2CallResult {
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

    private func v2BrowserGetAttr(params: [String: Any]) -> V2CallResult {
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
        v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "title": browserPanel.pageTitle
            ])
        }
    }

    private func v2BrowserGetCount(params: [String: Any]) -> V2CallResult {
        guard let selectorRaw = v2BrowserSelector(params) else {
            return .err(code: "invalid_params", message: "Missing selector", data: nil)
        }
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            guard let selector = v2BrowserResolveSelector(selectorRaw, surfaceId: surfaceId) else {
                return .err(code: "not_found", message: "Element reference not found", data: ["selector": selectorRaw])
            }
            let selectorLiteral = v2JSONLiteral(selector)
            let script = "document.querySelectorAll(\(selectorLiteral)).length"
            switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                let count = (value as? NSNumber)?.intValue ?? 0
                return .ok([
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "count": count
                ])
            }
        }
    }

    private func v2BrowserGetBox(params: [String: Any]) -> V2CallResult {
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

    private func v2BrowserGetStyles(params: [String: Any]) -> V2CallResult {
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

    private func v2BrowserIsVisible(params: [String: Any]) -> V2CallResult {
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

    private func v2BrowserIsEnabled(params: [String: Any]) -> V2CallResult {
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

    private func v2BrowserIsChecked(params: [String: Any]) -> V2CallResult {
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


    private func v2BrowserNavSimple(params: [String: Any], action: String) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let surfaceId = v2UUID(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid surface_id", data: nil)
        }

        var result: V2CallResult = .err(code: "not_found", message: "Surface not found or not a browser", data: ["surface_id": surfaceId.uuidString])
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager),
                  let browserPanel = ws.browserPanel(for: surfaceId) else { return }
            switch action {
            case "back":
                browserPanel.goBack()
            case "forward":
                browserPanel.goForward()
            case "reload":
                browserPanel.reload()
            default:
                break
            }
            var payload: [String: Any] = [
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "window_id": v2OrNull(v2ResolveWindowId(tabManager: tabManager)?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: v2ResolveWindowId(tabManager: tabManager))
            ]
            v2BrowserAppendPostSnapshot(params: params, surfaceId: surfaceId, payload: &payload)
            result = .ok(payload)
        }
        return result
    }

    private func v2BrowserGetURL(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let surfaceId = v2UUID(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid surface_id", data: nil)
        }

        var result: V2CallResult = .err(code: "not_found", message: "Surface not found or not a browser", data: ["surface_id": surfaceId.uuidString])
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager),
                  let browserPanel = ws.browserPanel(for: surfaceId) else { return }
            result = .ok([
                "workspace_id": ws.id.uuidString,
                "surface_id": surfaceId.uuidString,
                "url": browserPanel.currentURL?.absoluteString ?? ""
            ])
        }
        return result
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
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager),
                  let browserPanel = ws.browserPanel(for: surfaceId) else { return }

            v2MaybeFocusWindow(for: tabManager)
            v2MaybeSelectWorkspace(tabManager, workspace: ws)

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
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager),
                  let browserPanel = ws.browserPanel(for: surfaceId) else { return }
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

    private func v2BrowserFindWithScript(
        params: [String: Any],
        actionName: String,
        finderBody: String,
        metadata: [String: Any] = [:]
    ) -> V2CallResult {
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            let script = """
            (() => {
              const __cmuxCssPath = (el) => {
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
                  let siblings = cur.parentElement ? Array.from(cur.parentElement.children).filter((n) => String(n.tagName || '').toLowerCase() === tag) : [];
                  if (siblings.length > 1) {
                    const pos = siblings.indexOf(cur) + 1;
                    part += `:nth-of-type(${pos})`;
                  }
                  parts.unshift(part);
                  cur = cur.parentElement;
                }
                return parts.join(' > ');
              };

              const __cmuxFound = (() => {
            \(finderBody)
              })();
              if (!__cmuxFound) return { ok: false, error: 'not_found' };
              const selector = __cmuxCssPath(__cmuxFound);
              if (!selector) return { ok: false, error: 'not_found' };
              return {
                ok: true,
                selector,
                tag: String(__cmuxFound.tagName || '').toLowerCase(),
                text: String(__cmuxFound.textContent || '').trim()
              };
            })()
            """

            switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script) {
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
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
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

    private func v2BrowserFindRole(params: [String: Any]) -> V2CallResult {
        guard let role = (v2String(params, "role") ?? v2String(params, "value"))?.lowercased() else {
            return .err(code: "invalid_params", message: "Missing role", data: nil)
        }
        let name = v2String(params, "name")?.lowercased()
        let exact = v2Bool(params, "exact") ?? false
        let roleLiteral = v2JSONLiteral(role)
        let nameLiteral = name.map(v2JSONLiteral) ?? "null"
        let exactLiteral = exact ? "true" : "false"

        let finder = """
                const __targetRole = String(\(roleLiteral)).toLowerCase();
                const __targetName = \(nameLiteral);
                const __exact = \(exactLiteral);
                const __implicitRole = (el) => {
                  const tag = String(el.tagName || '').toLowerCase();
                  if (tag === 'button') return 'button';
                  if (tag === 'a' && el.hasAttribute('href')) return 'link';
                  if (tag === 'input') {
                    const type = String(el.getAttribute('type') || 'text').toLowerCase();
                    if (type === 'checkbox') return 'checkbox';
                    if (type === 'radio') return 'radio';
                    if (type === 'submit' || type === 'button') return 'button';
                    return 'textbox';
                  }
                  if (tag === 'textarea') return 'textbox';
                  if (tag === 'select') return 'combobox';
                  return null;
                };
                const __nameFor = (el) => {
                  const aria = String(el.getAttribute('aria-label') || '').trim();
                  if (aria) return aria.toLowerCase();
                  const labelledBy = String(el.getAttribute('aria-labelledby') || '').trim();
                  if (labelledBy) {
                    const text = labelledBy.split(/\\s+/).map((id) => document.getElementById(id)).filter(Boolean).map((n) => String(n.textContent || '').trim()).join(' ').trim();
                    if (text) return text.toLowerCase();
                  }
                  const txt = String(el.innerText || el.textContent || '').trim();
                  if (txt) return txt.toLowerCase();
                  if ('value' in el) {
                    const v = String(el.value || '').trim();
                    if (v) return v.toLowerCase();
                  }
                  return '';
                };
                const __nodes = Array.from(document.querySelectorAll('*'));
                return __nodes.find((el) => {
                  const explicit = String(el.getAttribute('role') || '').toLowerCase();
                  const resolved = explicit || __implicitRole(el) || '';
                  if (resolved !== __targetRole) return false;
                  if (__targetName == null) return true;
                  const currentName = __nameFor(el);
                  return __exact ? (currentName === __targetName) : currentName.includes(__targetName);
                }) || null;
        """

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

    private func v2BrowserFindText(params: [String: Any]) -> V2CallResult {
        guard let text = (v2String(params, "text") ?? v2String(params, "value"))?.lowercased() else {
            return .err(code: "invalid_params", message: "Missing text", data: nil)
        }
        let exact = v2Bool(params, "exact") ?? false
        let textLiteral = v2JSONLiteral(text)
        let exactLiteral = exact ? "true" : "false"

        let finder = """
                const __target = String(\(textLiteral));
                const __exact = \(exactLiteral);
                const __norm = (s) => String(s || '').replace(/\\s+/g, ' ').trim().toLowerCase();
                const __nodes = Array.from(document.querySelectorAll('body *'));
                return __nodes.find((el) => {
                  const v = __norm(el.innerText || el.textContent || '');
                  if (!v) return false;
                  return __exact ? (v === __target) : v.includes(__target);
                }) || null;
        """

        return v2BrowserFindWithScript(
            params: params,
            actionName: "find.text",
            finderBody: finder,
            metadata: ["text": text, "exact": exact]
        )
    }

    private func v2BrowserFindLabel(params: [String: Any]) -> V2CallResult {
        guard let label = (v2String(params, "label") ?? v2String(params, "text") ?? v2String(params, "value"))?.lowercased() else {
            return .err(code: "invalid_params", message: "Missing label", data: nil)
        }
        let exact = v2Bool(params, "exact") ?? false
        let labelLiteral = v2JSONLiteral(label)
        let exactLiteral = exact ? "true" : "false"

        let finder = """
                const __target = String(\(labelLiteral));
                const __exact = \(exactLiteral);
                const __norm = (s) => String(s || '').replace(/\\s+/g, ' ').trim().toLowerCase();
                const __labels = Array.from(document.querySelectorAll('label'));
                const __label = __labels.find((el) => {
                  const v = __norm(el.innerText || el.textContent || '');
                  return __exact ? (v === __target) : v.includes(__target);
                });
                if (!__label) return null;
                const htmlFor = String(__label.getAttribute('for') || '').trim();
                if (htmlFor) {
                  return document.getElementById(htmlFor);
                }
                return __label.querySelector('input,textarea,select,button,[contenteditable="true"]');
        """

        return v2BrowserFindWithScript(
            params: params,
            actionName: "find.label",
            finderBody: finder,
            metadata: ["label": label, "exact": exact]
        )
    }

    private func v2BrowserFindPlaceholder(params: [String: Any]) -> V2CallResult {
        guard let placeholder = (v2String(params, "placeholder") ?? v2String(params, "text") ?? v2String(params, "value"))?.lowercased() else {
            return .err(code: "invalid_params", message: "Missing placeholder", data: nil)
        }
        let exact = v2Bool(params, "exact") ?? false
        let placeholderLiteral = v2JSONLiteral(placeholder)
        let exactLiteral = exact ? "true" : "false"

        let finder = """
                const __target = String(\(placeholderLiteral));
                const __exact = \(exactLiteral);
                const __nodes = Array.from(document.querySelectorAll('[placeholder]'));
                return __nodes.find((el) => {
                  const p = String(el.getAttribute('placeholder') || '').trim().toLowerCase();
                  if (!p) return false;
                  return __exact ? (p === __target) : p.includes(__target);
                }) || null;
        """

        return v2BrowserFindWithScript(
            params: params,
            actionName: "find.placeholder",
            finderBody: finder,
            metadata: ["placeholder": placeholder, "exact": exact]
        )
    }

    private func v2BrowserFindAlt(params: [String: Any]) -> V2CallResult {
        guard let alt = (v2String(params, "alt") ?? v2String(params, "text") ?? v2String(params, "value"))?.lowercased() else {
            return .err(code: "invalid_params", message: "Missing alt text", data: nil)
        }
        let exact = v2Bool(params, "exact") ?? false
        let altLiteral = v2JSONLiteral(alt)
        let exactLiteral = exact ? "true" : "false"

        let finder = """
                const __target = String(\(altLiteral));
                const __exact = \(exactLiteral);
                const __nodes = Array.from(document.querySelectorAll('[alt]'));
                return __nodes.find((el) => {
                  const a = String(el.getAttribute('alt') || '').trim().toLowerCase();
                  if (!a) return false;
                  return __exact ? (a === __target) : a.includes(__target);
                }) || null;
        """

        return v2BrowserFindWithScript(
            params: params,
            actionName: "find.alt",
            finderBody: finder,
            metadata: ["alt": alt, "exact": exact]
        )
    }

    private func v2BrowserFindTitle(params: [String: Any]) -> V2CallResult {
        guard let title = (v2String(params, "title") ?? v2String(params, "text") ?? v2String(params, "value"))?.lowercased() else {
            return .err(code: "invalid_params", message: "Missing title", data: nil)
        }
        let exact = v2Bool(params, "exact") ?? false
        let titleLiteral = v2JSONLiteral(title)
        let exactLiteral = exact ? "true" : "false"

        let finder = """
                const __target = String(\(titleLiteral));
                const __exact = \(exactLiteral);
                const __nodes = Array.from(document.querySelectorAll('[title]'));
                return __nodes.find((el) => {
                  const t = String(el.getAttribute('title') || '').trim().toLowerCase();
                  if (!t) return false;
                  return __exact ? (t === __target) : t.includes(__target);
                }) || null;
        """

        return v2BrowserFindWithScript(
            params: params,
            actionName: "find.title",
            finderBody: finder,
            metadata: ["title": title, "exact": exact]
        )
    }

    private func v2BrowserFindTestId(params: [String: Any]) -> V2CallResult {
        guard let testId = v2String(params, "testid") ?? v2String(params, "test_id") ?? v2String(params, "value") else {
            return .err(code: "invalid_params", message: "Missing testid", data: nil)
        }
        let testIdLiteral = v2JSONLiteral(testId)

        let finder = """
                const __target = String(\(testIdLiteral));
                const __selectors = ['[data-testid]', '[data-test-id]', '[data-test]'];
                for (const sel of __selectors) {
                  const nodes = Array.from(document.querySelectorAll(sel));
                  const found = nodes.find((el) => {
                    return String(el.getAttribute('data-testid') || el.getAttribute('data-test-id') || el.getAttribute('data-test') || '') === __target;
                  });
                  if (found) return found;
                }
                return null;
        """

        return v2BrowserFindWithScript(
            params: params,
            actionName: "find.testid",
            finderBody: finder,
            metadata: ["testid": testId]
        )
    }

    private func v2BrowserFindFirst(params: [String: Any]) -> V2CallResult {
        guard let selectorRaw = v2BrowserSelector(params) else {
            return .err(code: "invalid_params", message: "Missing selector", data: nil)
        }
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            guard let selector = v2BrowserResolveSelector(selectorRaw, surfaceId: surfaceId) else {
                return .err(code: "not_found", message: "Element reference not found", data: ["selector": selectorRaw])
            }
            let selectorLiteral = v2JSONLiteral(selector)
            let script = """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              return { ok: true, selector: \(selectorLiteral), text: String(el.textContent || '').trim() };
            })()
            """
            switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script) {
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
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
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

    private func v2BrowserFindLast(params: [String: Any]) -> V2CallResult {
        guard let selectorRaw = v2BrowserSelector(params) else {
            return .err(code: "invalid_params", message: "Missing selector", data: nil)
        }
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            guard let selector = v2BrowserResolveSelector(selectorRaw, surfaceId: surfaceId) else {
                return .err(code: "not_found", message: "Element reference not found", data: ["selector": selectorRaw])
            }
            let selectorLiteral = v2JSONLiteral(selector)
            let script = """
            (() => {
              const list = document.querySelectorAll(\(selectorLiteral));
              if (!list || list.length === 0) return { ok: false, error: 'not_found' };
              const idx = list.length - 1;
              const el = list[idx];
              const finalSelector = `${\(selectorLiteral)}:nth-of-type(${idx + 1})`;
              return { ok: true, selector: finalSelector, text: String(el.textContent || '').trim() };
            })()
            """
            switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script) {
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
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
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

    private func v2BrowserFindNth(params: [String: Any]) -> V2CallResult {
        guard let selectorRaw = v2BrowserSelector(params) else {
            return .err(code: "invalid_params", message: "Missing selector", data: nil)
        }
        guard let index = v2Int(params, "index") ?? v2Int(params, "nth") else {
            return .err(code: "invalid_params", message: "Missing index", data: nil)
        }

        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            guard let selector = v2BrowserResolveSelector(selectorRaw, surfaceId: surfaceId) else {
                return .err(code: "not_found", message: "Element reference not found", data: ["selector": selectorRaw])
            }
            let selectorLiteral = v2JSONLiteral(selector)
            let script = """
            (() => {
              const list = Array.from(document.querySelectorAll(\(selectorLiteral)));
              if (!list.length) return { ok: false, error: 'not_found' };
              let idx = \(index);
              if (idx < 0) idx = list.length + idx;
              if (idx < 0 || idx >= list.length) return { ok: false, error: 'not_found' };
              const el = list[idx];
              const nth = idx + 1;
              const finalSelector = `${\(selectorLiteral)}:nth-of-type(${nth})`;
              return { ok: true, selector: finalSelector, index: idx, text: String(el.textContent || '').trim() };
            })()
            """
            switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script) {
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
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
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

    private func v2BrowserFrameSelect(params: [String: Any]) -> V2CallResult {
        guard let selectorRaw = v2BrowserSelector(params) else {
            return .err(code: "invalid_params", message: "Missing selector", data: nil)
        }

        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
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
            switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                if let dict = value as? [String: Any],
                   let ok = dict["ok"] as? Bool,
                   ok {
                    v2BrowserFrameSelectorBySurface[surfaceId] = selector
                    return .ok([
                        "workspace_id": ws.id.uuidString,
                        "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                        "surface_id": surfaceId.uuidString,
                        "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                        "frame_selector": selector
                    ])
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
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, _ in
            v2BrowserFrameSelectorBySurface.removeValue(forKey: surfaceId)
            return .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "frame_selector": NSNull()
            ])
        }
    }

    private func v2BrowserEnsureTelemetryHooks(surfaceId: UUID, browserPanel: BrowserPanel) {
        let script = """
        (() => {
          if (window.__cmuxHooksInstalled) return true;
          window.__cmuxHooksInstalled = true;

          window.__cmuxConsoleLog = window.__cmuxConsoleLog || [];
          const __pushConsole = (level, args) => {
            try {
              const text = Array.from(args || []).map((x) => {
                if (typeof x === 'string') return x;
                try { return JSON.stringify(x); } catch (_) { return String(x); }
              }).join(' ');
              window.__cmuxConsoleLog.push({ level, text, timestamp_ms: Date.now() });
              if (window.__cmuxConsoleLog.length > 512) {
                window.__cmuxConsoleLog.splice(0, window.__cmuxConsoleLog.length - 512);
              }
            } catch (_) {}
          };

          const methods = ['log', 'info', 'warn', 'error', 'debug'];
          for (const m of methods) {
            const orig = (window.console && window.console[m]) ? window.console[m].bind(window.console) : null;
            window.console[m] = function(...args) {
              __pushConsole(m, args);
              if (orig) return orig(...args);
            };
          }

          window.__cmuxErrorLog = window.__cmuxErrorLog || [];
          window.addEventListener('error', (ev) => {
            try {
              const message = String((ev && ev.message) || '');
              const source = String((ev && ev.filename) || '');
              const line = Number((ev && ev.lineno) || 0);
              const col = Number((ev && ev.colno) || 0);
              window.__cmuxErrorLog.push({ message, source, line, column: col, timestamp_ms: Date.now() });
              if (window.__cmuxErrorLog.length > 512) {
                window.__cmuxErrorLog.splice(0, window.__cmuxErrorLog.length - 512);
              }
            } catch (_) {}
          });
          window.addEventListener('unhandledrejection', (ev) => {
            try {
              const reason = ev && ev.reason;
              const message = typeof reason === 'string' ? reason : (reason && reason.message ? String(reason.message) : String(reason));
              window.__cmuxErrorLog.push({ message, source: 'unhandledrejection', line: 0, column: 0, timestamp_ms: Date.now() });
              if (window.__cmuxErrorLog.length > 512) {
                window.__cmuxErrorLog.splice(0, window.__cmuxErrorLog.length - 512);
              }
            } catch (_) {}
          });

          window.__cmuxDialogQueue = window.__cmuxDialogQueue || [];
          window.__cmuxDialogDefaults = window.__cmuxDialogDefaults || { confirm: false, prompt: null };
          const __pushDialog = (type, message, defaultText) => {
            window.__cmuxDialogQueue.push({
              type,
              message: String(message || ''),
              default_text: defaultText == null ? null : String(defaultText),
              timestamp_ms: Date.now()
            });
            if (window.__cmuxDialogQueue.length > 128) {
              window.__cmuxDialogQueue.splice(0, window.__cmuxDialogQueue.length - 128);
            }
          };

          window.alert = function(message) {
            __pushDialog('alert', message, null);
          };
          window.confirm = function(message) {
            __pushDialog('confirm', message, null);
            return !!window.__cmuxDialogDefaults.confirm;
          };
          window.prompt = function(message, defaultValue) {
            __pushDialog('prompt', message, defaultValue == null ? null : defaultValue);
            const v = window.__cmuxDialogDefaults.prompt;
            if (v === null || v === undefined) {
              return defaultValue == null ? '' : String(defaultValue);
            }
            return String(v);
          };

          return true;
        })()
        """

        _ = v2RunJavaScript(browserPanel.webView, script: script, timeout: 5.0)
    }

    private func v2BrowserDialogRespond(params: [String: Any], accept: Bool) -> V2CallResult {
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            v2BrowserEnsureTelemetryHooks(surfaceId: surfaceId, browserPanel: browserPanel)
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

            switch v2RunJavaScript(browserPanel.webView, script: script, timeout: 5.0) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                guard let dict = value as? [String: Any],
                      let ok = dict["ok"] as? Bool,
                      ok else {
                    let pending = v2BrowserPendingDialogs(surfaceId: surfaceId)
                    return .err(code: "not_found", message: "No pending dialog", data: ["pending": pending])
                }

                return .ok([
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "accepted": accept,
                    "dialog": v2NormalizeJSValue(dict["dialog"]),
                    "remaining": v2OrNull(dict["remaining"])
                ])
            }
        }
    }

    private func v2BrowserDownloadWait(params: [String: Any]) -> V2CallResult {
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, _ in
            let timeoutMs = max(1, v2Int(params, "timeout_ms") ?? v2Int(params, "timeout") ?? 10_000)
            let timeout = Double(timeoutMs) / 1000.0
            let path = v2String(params, "path")

            if let path {
                let deadline = Date().addingTimeInterval(timeout)
                let fm = FileManager.default
                while Date() < deadline {
                    if fm.fileExists(atPath: path),
                       let attrs = try? fm.attributesOfItem(atPath: path),
                       let size = attrs[.size] as? NSNumber,
                       size.intValue > 0 {
                        return .ok([
                            "workspace_id": ws.id.uuidString,
                            "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                            "surface_id": surfaceId.uuidString,
                            "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                            "path": path,
                            "downloaded": true
                        ])
                    }
                    _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
                }
                return .err(code: "timeout", message: "Timed out waiting for download file", data: ["path": path, "timeout_ms": timeoutMs])
            }

            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                let entries = v2BrowserDownloadEventsBySurface[surfaceId] ?? []
                if let first = entries.first {
                    var remaining = entries
                    remaining.removeFirst()
                    v2BrowserDownloadEventsBySurface[surfaceId] = remaining
                    return .ok([
                        "workspace_id": ws.id.uuidString,
                        "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                        "surface_id": surfaceId.uuidString,
                        "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                        "download": first
                    ])
                }
                _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
            return .err(code: "timeout", message: "No download event observed", data: ["timeout_ms": timeoutMs])
        }
    }

    private func v2BrowserCookieDict(_ cookie: HTTPCookie) -> [String: Any] {
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

    private func v2BrowserCookieStoreAll(_ store: WKHTTPCookieStore, timeout: TimeInterval = 3.0) -> [HTTPCookie]? {
        var done = false
        var cookies: [HTTPCookie] = []
        store.getAllCookies { items in
            cookies = items
            done = true
        }
        let deadline = Date().addingTimeInterval(timeout)
        while !done && Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return done ? cookies : nil
    }

    private func v2BrowserCookieStoreSet(_ store: WKHTTPCookieStore, cookie: HTTPCookie, timeout: TimeInterval = 3.0) -> Bool {
        var done = false
        store.setCookie(cookie) {
            done = true
        }
        let deadline = Date().addingTimeInterval(timeout)
        while !done && Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return done
    }

    private func v2BrowserCookieStoreDelete(_ store: WKHTTPCookieStore, cookie: HTTPCookie, timeout: TimeInterval = 3.0) -> Bool {
        var done = false
        store.delete(cookie) {
            done = true
        }
        let deadline = Date().addingTimeInterval(timeout)
        while !done && Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return done
    }

    private func v2BrowserCookieFromObject(_ raw: [String: Any], fallbackURL: URL?) -> HTTPCookie? {
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

    private func v2BrowserCookiesGet(params: [String: Any]) -> V2CallResult {
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            let store = browserPanel.webView.configuration.websiteDataStore.httpCookieStore
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

            return .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "cookies": cookies.map(v2BrowserCookieDict)
            ])
        }
    }

    private func v2BrowserCookiesSet(params: [String: Any]) -> V2CallResult {
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            let store = browserPanel.webView.configuration.websiteDataStore.httpCookieStore
            let fallbackURL = browserPanel.currentURL

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
                guard let cookie = v2BrowserCookieFromObject(raw, fallbackURL: fallbackURL) else {
                    return .err(code: "invalid_params", message: "Invalid cookie payload", data: ["cookie": raw])
                }
                if v2BrowserCookieStoreSet(store, cookie: cookie) {
                    setCount += 1
                } else {
                    return .err(code: "timeout", message: "Timed out setting cookie", data: ["name": cookie.name])
                }
            }

            return .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "set": setCount
            ])
        }
    }

    private func v2BrowserCookiesClear(params: [String: Any]) -> V2CallResult {
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            let store = browserPanel.webView.configuration.websiteDataStore.httpCookieStore
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

            return .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "cleared": removed
            ])
        }
    }

    private func v2BrowserStorageType(_ params: [String: Any]) -> String {
        let type = (v2String(params, "storage") ?? v2String(params, "type") ?? "local").lowercased()
        return (type == "session") ? "session" : "local"
    }

    private func v2BrowserStorageGet(params: [String: Any]) -> V2CallResult {
        let storageType = v2BrowserStorageType(params)
        let key = v2String(params, "key")
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            let typeLiteral = v2JSONLiteral(storageType)
            let keyLiteral = key.map(v2JSONLiteral) ?? "null"
            let script = """
            (() => {
              const type = String(\(typeLiteral));
              const key = \(keyLiteral);
              const st = type === 'session' ? window.sessionStorage : window.localStorage;
              if (!st) return { ok: false, error: 'not_available' };
              if (key == null) {
                const out = {};
                for (let i = 0; i < st.length; i++) {
                  const k = st.key(i);
                  out[k] = st.getItem(k);
                }
                return { ok: true, value: out };
              }
              return { ok: true, value: st.getItem(String(key)) };
            })()
            """
            switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                guard let dict = value as? [String: Any],
                      let ok = dict["ok"] as? Bool,
                      ok else {
                    return .err(code: "invalid_state", message: "Storage unavailable", data: ["type": storageType])
                }
                return .ok([
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "type": storageType,
                    "key": v2OrNull(key),
                    "value": v2NormalizeJSValue(dict["value"])
                ])
            }
        }
    }

    private func v2BrowserStorageSet(params: [String: Any]) -> V2CallResult {
        let storageType = v2BrowserStorageType(params)
        guard let key = v2String(params, "key") else {
            return .err(code: "invalid_params", message: "Missing key", data: nil)
        }
        guard let value = params["value"] else {
            return .err(code: "invalid_params", message: "Missing value", data: nil)
        }

        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            let typeLiteral = v2JSONLiteral(storageType)
            let keyLiteral = v2JSONLiteral(key)
            let valueLiteral = v2JSONLiteral(v2NormalizeJSValue(value))
            let script = """
            (() => {
              const type = String(\(typeLiteral));
              const key = String(\(keyLiteral));
              const value = \(valueLiteral);
              const st = type === 'session' ? window.sessionStorage : window.localStorage;
              if (!st) return { ok: false, error: 'not_available' };
              st.setItem(key, value == null ? '' : String(value));
              return { ok: true };
            })()
            """
            switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                guard let dict = value as? [String: Any],
                      let ok = dict["ok"] as? Bool,
                      ok else {
                    return .err(code: "invalid_state", message: "Storage unavailable", data: ["type": storageType])
                }
                return .ok([
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "type": storageType,
                    "key": key
                ])
            }
        }
    }

    private func v2BrowserStorageClear(params: [String: Any]) -> V2CallResult {
        let storageType = v2BrowserStorageType(params)
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            let typeLiteral = v2JSONLiteral(storageType)
            let script = """
            (() => {
              const type = String(\(typeLiteral));
              const st = type === 'session' ? window.sessionStorage : window.localStorage;
              if (!st) return { ok: false, error: 'not_available' };
              st.clear();
              return { ok: true };
            })()
            """
            switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                guard let dict = value as? [String: Any],
                      let ok = dict["ok"] as? Bool,
                      ok else {
                    return .err(code: "invalid_state", message: "Storage unavailable", data: ["type": storageType])
                }
                return .ok([
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "type": storageType,
                    "cleared": true
                ])
            }
        }
    }

    private func v2BrowserTabList(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        var payload: [String: Any]?
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else { return }
            let browserPanels = orderedPanels(in: ws).compactMap { panel -> BrowserPanel? in
                panel as? BrowserPanel
            }
            let tabs: [[String: Any]] = browserPanels.enumerated().map { index, panel in
                [
                    "id": panel.id.uuidString,
                    "ref": v2Ref(kind: .surface, uuid: panel.id),
                    "index": index,
                    "title": ws.panelTitle(panelId: panel.id) ?? panel.displayTitle,
                    "url": panel.currentURL?.absoluteString ?? "",
                    "focused": panel.id == ws.focusedPanelId,
                    "pane_id": v2OrNull(ws.paneId(forPanelId: panel.id)?.id.uuidString),
                    "pane_ref": v2Ref(kind: .pane, uuid: ws.paneId(forPanelId: panel.id)?.id)
                ]
            }
            payload = [
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": v2OrNull(ws.focusedPanelId?.uuidString),
                "surface_ref": v2Ref(kind: .surface, uuid: ws.focusedPanelId),
                "tabs": tabs
            ]
        }

        guard let payload else {
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        }
        return .ok(payload)
    }

    private func v2BrowserTabNew(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        let url = v2String(params, "url").flatMap(URL.init(string:))
        var result: V2CallResult = .err(code: "internal_error", message: "Failed to create browser tab", data: nil)
        v2MainSync {
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

            guard let panel = ws.newBrowserSurface(inPane: pane, url: url, focus: v2FocusAllowed()) else {
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

            let ok = ws.closePanel(targetId, force: true)
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

    private func v2BrowserConsoleList(params: [String: Any]) -> V2CallResult {
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            v2BrowserEnsureTelemetryHooks(surfaceId: surfaceId, browserPanel: browserPanel)
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
            switch v2RunJavaScript(browserPanel.webView, script: script, timeout: 5.0) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                let dict = value as? [String: Any]
                let items = (dict?["items"] as? [Any]) ?? []
                return .ok([
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "entries": items.map(v2NormalizeJSValue),
                    "count": items.count
                ])
            }
        }
    }

    private func v2BrowserConsoleClear(params: [String: Any]) -> V2CallResult {
        var withClear = params
        withClear["clear"] = true
        return v2BrowserConsoleList(params: withClear)
    }

    private func v2BrowserErrorsList(params: [String: Any]) -> V2CallResult {
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            v2BrowserEnsureTelemetryHooks(surfaceId: surfaceId, browserPanel: browserPanel)
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
            switch v2RunJavaScript(browserPanel.webView, script: script, timeout: 5.0) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                let dict = value as? [String: Any]
                let items = (dict?["items"] as? [Any]) ?? []
                return .ok([
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "errors": items.map(v2NormalizeJSValue),
                    "count": items.count
                ])
            }
        }
    }

    private func v2BrowserHighlight(params: [String: Any]) -> V2CallResult {
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

    private func v2BrowserStateSave(params: [String: Any]) -> V2CallResult {
        guard let path = v2String(params, "path") else {
            return .err(code: "invalid_params", message: "Missing path", data: nil)
        }

        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
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
            switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: storageScript, timeout: 10.0) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                storageValue = v2NormalizeJSValue(value)
            }

            let store = browserPanel.webView.configuration.websiteDataStore.httpCookieStore
            let cookies = (v2BrowserCookieStoreAll(store) ?? []).map(v2BrowserCookieDict)

            let state: [String: Any] = [
                "url": browserPanel.currentURL?.absoluteString ?? "",
                "cookies": cookies,
                "storage": storageValue,
                "frame_selector": v2OrNull(v2BrowserFrameSelectorBySurface[surfaceId])
            ]

            do {
                let data = try JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            } catch {
                return .err(code: "internal_error", message: "Failed to write state file", data: ["path": path, "error": error.localizedDescription])
            }

            return .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "path": path,
                "cookies": cookies.count
            ])
        }
    }

    private func v2BrowserStateLoad(params: [String: Any]) -> V2CallResult {
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

        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            if let frameSelector = raw["frame_selector"] as? String, !frameSelector.isEmpty {
                v2BrowserFrameSelectorBySurface[surfaceId] = frameSelector
            } else {
                v2BrowserFrameSelectorBySurface.removeValue(forKey: surfaceId)
            }

            if let urlStr = raw["url"] as? String,
               !urlStr.isEmpty,
               let parsed = URL(string: urlStr) {
                browserPanel.navigate(to: parsed)
            }

            if let cookieRows = raw["cookies"] as? [[String: Any]] {
                let store = browserPanel.webView.configuration.websiteDataStore.httpCookieStore
                for row in cookieRows {
                    if let cookie = v2BrowserCookieFromObject(row, fallbackURL: browserPanel.currentURL) {
                        _ = v2BrowserCookieStoreSet(store, cookie: cookie)
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
                _ = v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script, timeout: 10.0)
            }

            return .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "path": path,
                "loaded": true
            ])
        }
    }

    private func v2BrowserAddInitScript(params: [String: Any]) -> V2CallResult {
        guard let script = v2String(params, "script") ?? v2String(params, "content") else {
            return .err(code: "invalid_params", message: "Missing script", data: nil)
        }
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            var scripts = v2BrowserInitScriptsBySurface[surfaceId] ?? []
            scripts.append(script)
            v2BrowserInitScriptsBySurface[surfaceId] = scripts

            let userScript = WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            browserPanel.webView.configuration.userContentController.addUserScript(userScript)
            _ = v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script, timeout: 10.0)

            return .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "scripts": scripts.count
            ])
        }
    }

    private func v2BrowserAddScript(params: [String: Any]) -> V2CallResult {
        guard let script = v2String(params, "script") ?? v2String(params, "content") else {
            return .err(code: "invalid_params", message: "Missing script", data: nil)
        }
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script, timeout: 10.0) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                return .ok([
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "value": v2NormalizeJSValue(value)
                ])
            }
        }
    }

    private func v2BrowserAddStyle(params: [String: Any]) -> V2CallResult {
        guard let css = v2String(params, "css") ?? v2String(params, "style") ?? v2String(params, "content") else {
            return .err(code: "invalid_params", message: "Missing css/style content", data: nil)
        }
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            var styles = v2BrowserInitStylesBySurface[surfaceId] ?? []
            styles.append(css)
            v2BrowserInitStylesBySurface[surfaceId] = styles

            let cssLiteral = v2JSONLiteral(css)
            let source = """
            (() => {
              const el = document.createElement('style');
              el.textContent = String(\(cssLiteral));
              (document.head || document.documentElement || document.body).appendChild(el);
              return true;
            })()
            """

            let userScript = WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            browserPanel.webView.configuration.userContentController.addUserScript(userScript)
            _ = v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: source, timeout: 10.0)

            return .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "styles": styles.count
            ])
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

    private func v2DebugShortcutSet(params: [String: Any]) -> V2CallResult {
        guard let name = v2String(params, "name"),
              let combo = v2String(params, "combo") else {
            return .err(code: "invalid_params", message: "Missing name/combo", data: nil)
        }
        let resp = setShortcut("\(name) \(combo)")
        return resp == "OK"
            ? .ok([:])
            : .err(code: "internal_error", message: resp, data: nil)
    }

    private func v2DebugShortcutSimulate(params: [String: Any]) -> V2CallResult {
        guard let combo = v2String(params, "combo") else {
            return .err(code: "invalid_params", message: "Missing combo", data: nil)
        }
        let resp = simulateShortcut(combo)
        return resp == "OK"
            ? .ok([:])
            : .err(code: "internal_error", message: resp, data: nil)
    }

    private func v2DebugType(params: [String: Any]) -> V2CallResult {
        guard let text = params["text"] as? String else {
            return .err(code: "invalid_params", message: "Missing text", data: nil)
        }

        var result: V2CallResult = .err(code: "internal_error", message: "No window", data: nil)
        DispatchQueue.main.sync {
            guard let window = NSApp.keyWindow
                ?? NSApp.mainWindow
                ?? NSApp.windows.first(where: { $0.isVisible })
                ?? NSApp.windows.first else {
                result = .err(code: "not_found", message: "No window", data: nil)
                return
            }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            guard let fr = window.firstResponder else {
                result = .err(code: "not_found", message: "No first responder", data: nil)
                return
            }
            if let client = fr as? NSTextInputClient {
                client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
                result = .ok([:])
                return
            }
            (fr as? NSResponder)?.insertText(text)
            result = .ok([:])
        }
        return result
    }

    private func v2DebugActivateApp() -> V2CallResult {
        let resp = activateApp()
        return resp == "OK" ? .ok([:]) : .err(code: "internal_error", message: resp, data: nil)
    }

    private func v2DebugToggleCommandPalette(params: [String: Any]) -> V2CallResult {
        let requestedWindowId = v2UUID(params, "window_id")
        var result: V2CallResult = .ok([:])
        DispatchQueue.main.sync {
            let targetWindow: NSWindow?
            if let requestedWindowId {
                guard let window = AppDelegate.shared?.mainWindow(for: requestedWindowId) else {
                    result = .err(
                        code: "not_found",
                        message: "Window not found",
                        data: ["window_id": requestedWindowId.uuidString, "window_ref": v2Ref(kind: .window, uuid: requestedWindowId)]
                    )
                    return
                }
                targetWindow = window
            } else {
                targetWindow = NSApp.keyWindow ?? NSApp.mainWindow
            }
            NotificationCenter.default.post(name: .commandPaletteToggleRequested, object: targetWindow)
        }
        return result
    }

    private func v2DebugOpenCommandPaletteRenameTabInput(params: [String: Any]) -> V2CallResult {
        let requestedWindowId = v2UUID(params, "window_id")
        var result: V2CallResult = .ok([:])
        DispatchQueue.main.sync {
            let targetWindow: NSWindow?
            if let requestedWindowId {
                guard let window = AppDelegate.shared?.mainWindow(for: requestedWindowId) else {
                    result = .err(
                        code: "not_found",
                        message: "Window not found",
                        data: [
                            "window_id": requestedWindowId.uuidString,
                            "window_ref": v2Ref(kind: .window, uuid: requestedWindowId)
                        ]
                    )
                    return
                }
                targetWindow = window
            } else {
                targetWindow = NSApp.keyWindow ?? NSApp.mainWindow
            }
            NotificationCenter.default.post(name: .commandPaletteRenameTabRequested, object: targetWindow)
        }
        return result
    }

    private func v2DebugCommandPaletteVisible(params: [String: Any]) -> V2CallResult {
        guard let windowId = v2UUID(params, "window_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid window_id", data: nil)
        }
        var visible = false
        DispatchQueue.main.sync {
            visible = AppDelegate.shared?.isCommandPaletteVisible(windowId: windowId) ?? false
        }
        return .ok([
            "window_id": windowId.uuidString,
            "window_ref": v2Ref(kind: .window, uuid: windowId),
            "visible": visible
        ])
    }

    private func v2DebugCommandPaletteSelection(params: [String: Any]) -> V2CallResult {
        guard let windowId = v2UUID(params, "window_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid window_id", data: nil)
        }
        var visible = false
        var selectedIndex = 0
        DispatchQueue.main.sync {
            visible = AppDelegate.shared?.isCommandPaletteVisible(windowId: windowId) ?? false
            selectedIndex = AppDelegate.shared?.commandPaletteSelectionIndex(windowId: windowId) ?? 0
        }
        return .ok([
            "window_id": windowId.uuidString,
            "window_ref": v2Ref(kind: .window, uuid: windowId),
            "visible": visible,
            "selected_index": max(0, selectedIndex)
        ])
    }

    private func v2DebugCommandPaletteResults(params: [String: Any]) -> V2CallResult {
        guard let windowId = v2UUID(params, "window_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid window_id", data: nil)
        }
        let requestedLimit = params["limit"] as? Int
        let limit = max(1, min(100, requestedLimit ?? 20))

        var visible = false
        var selectedIndex = 0
        var snapshot = CommandPaletteDebugSnapshot.empty

        DispatchQueue.main.sync {
            visible = AppDelegate.shared?.isCommandPaletteVisible(windowId: windowId) ?? false
            selectedIndex = AppDelegate.shared?.commandPaletteSelectionIndex(windowId: windowId) ?? 0
            snapshot = AppDelegate.shared?.commandPaletteSnapshot(windowId: windowId) ?? .empty
        }

        let rows = Array(snapshot.results.prefix(limit)).map { row in
            [
                "command_id": row.commandId,
                "title": row.title,
                "shortcut_hint": v2OrNull(row.shortcutHint),
                "trailing_label": v2OrNull(row.trailingLabel),
                "score": row.score
            ] as [String: Any]
        }

        return .ok([
            "window_id": windowId.uuidString,
            "window_ref": v2Ref(kind: .window, uuid: windowId),
            "visible": visible,
            "selected_index": max(0, selectedIndex),
            "query": snapshot.query,
            "mode": snapshot.mode,
            "results": rows
        ])
    }

    private func v2DebugCommandPaletteRenameInputInteraction(params: [String: Any]) -> V2CallResult {
        let requestedWindowId = v2UUID(params, "window_id")
        var result: V2CallResult = .ok([:])
        DispatchQueue.main.sync {
            let targetWindow: NSWindow?
            if let requestedWindowId {
                guard let window = AppDelegate.shared?.mainWindow(for: requestedWindowId) else {
                    result = .err(
                        code: "not_found",
                        message: "Window not found",
                        data: [
                            "window_id": requestedWindowId.uuidString,
                            "window_ref": v2Ref(kind: .window, uuid: requestedWindowId)
                        ]
                    )
                    return
                }
                targetWindow = window
            } else {
                targetWindow = NSApp.keyWindow ?? NSApp.mainWindow
            }
            NotificationCenter.default.post(name: .commandPaletteRenameInputInteractionRequested, object: targetWindow)
        }
        return result
    }

    private func v2DebugCommandPaletteRenameInputDeleteBackward(params: [String: Any]) -> V2CallResult {
        let requestedWindowId = v2UUID(params, "window_id")
        var result: V2CallResult = .ok([:])
        DispatchQueue.main.sync {
            let targetWindow: NSWindow?
            if let requestedWindowId {
                guard let window = AppDelegate.shared?.mainWindow(for: requestedWindowId) else {
                    result = .err(
                        code: "not_found",
                        message: "Window not found",
                        data: [
                            "window_id": requestedWindowId.uuidString,
                            "window_ref": v2Ref(kind: .window, uuid: requestedWindowId)
                        ]
                    )
                    return
                }
                targetWindow = window
            } else {
                targetWindow = NSApp.keyWindow ?? NSApp.mainWindow
            }
            NotificationCenter.default.post(name: .commandPaletteRenameInputDeleteBackwardRequested, object: targetWindow)
        }
        return result
    }

    private func v2DebugCommandPaletteRenameInputSelection(params: [String: Any]) -> V2CallResult {
        guard let windowId = v2UUID(params, "window_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid window_id", data: nil)
        }

        var result: V2CallResult = .ok([
            "window_id": windowId.uuidString,
            "window_ref": v2Ref(kind: .window, uuid: windowId),
            "focused": false,
            "selection_location": 0,
            "selection_length": 0,
            "text_length": 0
        ])

        DispatchQueue.main.sync {
            guard let window = AppDelegate.shared?.mainWindow(for: windowId) else {
                result = .err(
                    code: "not_found",
                    message: "Window not found",
                    data: ["window_id": windowId.uuidString, "window_ref": v2Ref(kind: .window, uuid: windowId)]
                )
                return
            }
            guard let editor = window.firstResponder as? NSTextView, editor.isFieldEditor else {
                return
            }
            let selectedRange = editor.selectedRange()
            let textLength = (editor.string as NSString).length
            result = .ok([
                "window_id": windowId.uuidString,
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "focused": true,
                "selection_location": max(0, selectedRange.location),
                "selection_length": max(0, selectedRange.length),
                "text_length": max(0, textLength)
            ])
        }

        return result
    }

    private func v2DebugCommandPaletteRenameInputSelectAll(params: [String: Any]) -> V2CallResult {
        if let rawEnabled = params["enabled"] {
            guard let enabled = rawEnabled as? Bool else {
                return .err(
                    code: "invalid_params",
                    message: "enabled must be a bool",
                    data: ["enabled": rawEnabled]
                )
            }
            DispatchQueue.main.sync {
                UserDefaults.standard.set(
                    enabled,
                    forKey: CommandPaletteRenameSelectionSettings.selectAllOnFocusKey
                )
            }
        }

        var enabled = CommandPaletteRenameSelectionSettings.defaultSelectAllOnFocus
        DispatchQueue.main.sync {
            enabled = CommandPaletteRenameSelectionSettings.selectAllOnFocusEnabled()
        }

        return .ok([
            "enabled": enabled
        ])
    }

    private func v2DebugBrowserAddressBarFocused(params: [String: Any]) -> V2CallResult {
        let requestedSurfaceId = v2UUID(params, "surface_id") ?? v2UUID(params, "panel_id")
        var focusedSurfaceId: UUID?
        DispatchQueue.main.sync {
            focusedSurfaceId = AppDelegate.shared?.focusedBrowserAddressBarPanelId()
        }

        var payload: [String: Any] = [
            "focused_surface_id": v2OrNull(focusedSurfaceId?.uuidString),
            "focused_surface_ref": v2Ref(kind: .surface, uuid: focusedSurfaceId),
            "focused_panel_id": v2OrNull(focusedSurfaceId?.uuidString),
            "focused_panel_ref": v2Ref(kind: .surface, uuid: focusedSurfaceId),
            "focused": focusedSurfaceId != nil
        ]

        if let requestedSurfaceId {
            payload["surface_id"] = requestedSurfaceId.uuidString
            payload["surface_ref"] = v2Ref(kind: .surface, uuid: requestedSurfaceId)
            payload["panel_id"] = requestedSurfaceId.uuidString
            payload["panel_ref"] = v2Ref(kind: .surface, uuid: requestedSurfaceId)
            payload["focused"] = (focusedSurfaceId == requestedSurfaceId)
        }

        return .ok(payload)
    }

    private func v2DebugSidebarVisible(params: [String: Any]) -> V2CallResult {
        guard let windowId = v2UUID(params, "window_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid window_id", data: nil)
        }
        var visibility: Bool?
        DispatchQueue.main.sync {
            visibility = AppDelegate.shared?.sidebarVisibility(windowId: windowId)
        }
        guard let visible = visibility else {
            return .err(
                code: "not_found",
                message: "Window not found",
                data: ["window_id": windowId.uuidString, "window_ref": v2Ref(kind: .window, uuid: windowId)]
            )
        }
        return .ok([
            "window_id": windowId.uuidString,
            "window_ref": v2Ref(kind: .window, uuid: windowId),
            "visible": visible
        ])
    }

    private func v2DebugIsTerminalFocused(params: [String: Any]) -> V2CallResult {
        guard let surfaceId = v2String(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing surface_id", data: nil)
        }
        let resp = isTerminalFocused(surfaceId)
        if resp.hasPrefix("ERROR") {
            return .err(code: "internal_error", message: resp, data: nil)
        }
        return .ok(["focused": resp.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "true"])
    }

    private func v2DebugReadTerminalText(params: [String: Any]) -> V2CallResult {
        let surfaceArg = v2String(params, "surface_id") ?? ""
        let resp = readTerminalText(surfaceArg)
        guard resp.hasPrefix("OK ") else {
            return .err(code: "internal_error", message: resp, data: nil)
        }
        let b64 = String(resp.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        return .ok(["base64": b64])
    }

    private func v2DebugRenderStats(params: [String: Any]) -> V2CallResult {
        let surfaceArg = v2String(params, "surface_id") ?? ""
        let resp = renderStats(surfaceArg)
        guard resp.hasPrefix("OK ") else {
            return .err(code: "internal_error", message: resp, data: nil)
        }
        let jsonStr = String(resp.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = jsonStr.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return .err(code: "internal_error", message: "render_stats JSON decode failed", data: ["payload": String(jsonStr.prefix(200))])
        }
        return .ok(["stats": obj])
    }

    private func v2DebugLayout() -> V2CallResult {
        let resp = layoutDebug()
        guard resp.hasPrefix("OK ") else {
            return .err(code: "internal_error", message: resp, data: nil)
        }
        let jsonStr = String(resp.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = jsonStr.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return .err(code: "internal_error", message: "layout_debug JSON decode failed", data: ["payload": String(jsonStr.prefix(200))])
        }
        return .ok(["layout": obj])
    }

    private func v2DebugBonsplitUnderflowCount() -> V2CallResult {
        let resp = bonsplitUnderflowCount()
        guard resp.hasPrefix("OK ") else { return .err(code: "internal_error", message: resp, data: nil) }
        let n = Int(resp.split(separator: " ").last ?? "0") ?? 0
        return .ok(["count": n])
    }

    private func v2DebugResetBonsplitUnderflowCount() -> V2CallResult {
        let resp = resetBonsplitUnderflowCount()
        return resp == "OK" ? .ok([:]) : .err(code: "internal_error", message: resp, data: nil)
    }

    private func v2DebugEmptyPanelCount() -> V2CallResult {
        let resp = emptyPanelCount()
        guard resp.hasPrefix("OK ") else { return .err(code: "internal_error", message: resp, data: nil) }
        let n = Int(resp.split(separator: " ").last ?? "0") ?? 0
        return .ok(["count": n])
    }

    private func v2DebugResetEmptyPanelCount() -> V2CallResult {
        let resp = resetEmptyPanelCount()
        return resp == "OK" ? .ok([:]) : .err(code: "internal_error", message: resp, data: nil)
    }

    private func v2DebugFocusNotification(params: [String: Any]) -> V2CallResult {
        guard let wsId = v2String(params, "workspace_id") else {
            return .err(code: "invalid_params", message: "Missing workspace_id", data: nil)
        }
        let surfaceId = v2String(params, "surface_id")
        let args = surfaceId != nil ? "\(wsId) \(surfaceId!)" : wsId
        let resp = focusFromNotification(args)
        return resp == "OK" ? .ok([:]) : .err(code: "internal_error", message: resp, data: nil)
    }

    private func v2DebugFlashCount(params: [String: Any]) -> V2CallResult {
        guard let surfaceId = v2String(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing surface_id", data: nil)
        }
        let resp = flashCount(surfaceId)
        guard resp.hasPrefix("OK ") else { return .err(code: "internal_error", message: resp, data: nil) }
        let n = Int(resp.split(separator: " ").last ?? "0") ?? 0
        return .ok(["count": n])
    }

    private func v2DebugResetFlashCounts() -> V2CallResult {
        let resp = resetFlashCounts()
        return resp == "OK" ? .ok([:]) : .err(code: "internal_error", message: resp, data: nil)
    }

    private func v2DebugPanelSnapshot(params: [String: Any]) -> V2CallResult {
        guard let surfaceId = v2String(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing surface_id", data: nil)
        }
        let label = v2String(params, "label") ?? ""
        let args = label.isEmpty ? surfaceId : "\(surfaceId) \(label)"
        let resp = panelSnapshot(args)
        guard resp.hasPrefix("OK ") else { return .err(code: "internal_error", message: resp, data: nil) }
        let payload = String(resp.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = payload.split(separator: " ", maxSplits: 4).map(String.init)
        guard parts.count == 5 else {
            return .err(code: "internal_error", message: "panel_snapshot parse failed", data: ["payload": payload])
        }
        return .ok([
            "surface_id": parts[0],
            "changed_pixels": Int(parts[1]) ?? -1,
            "width": Int(parts[2]) ?? 0,
            "height": Int(parts[3]) ?? 0,
            "path": parts[4]
        ])
    }

    private func v2DebugPanelSnapshotReset(params: [String: Any]) -> V2CallResult {
        guard let surfaceId = v2String(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing surface_id", data: nil)
        }
        let resp = panelSnapshotReset(surfaceId)
        return resp == "OK" ? .ok([:]) : .err(code: "internal_error", message: resp, data: nil)
    }

    private func v2DebugScreenshot(params: [String: Any]) -> V2CallResult {
        let label = v2String(params, "label") ?? ""
        let resp = captureScreenshot(label)
        guard resp.hasPrefix("OK ") else {
            return .err(code: "internal_error", message: resp, data: nil)
        }
        let payload = String(resp.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = payload.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            return .err(code: "internal_error", message: "screenshot parse failed", data: ["payload": payload])
        }
        return .ok([
            "screenshot_id": parts[0],
            "path": parts[1]
        ])
    }
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

    private func tailTerminalLines(_ text: String, maxLines: Int) -> String {
        guard maxLines > 0 else { return "" }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > maxLines else { return text }
        return lines.suffix(maxLines).joined(separator: "\n")
    }

    private func readTerminalTextBase64(surfaceArg: String, includeScrollback: Bool = false, lineLimit: Int? = nil) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        let trimmedSurfaceArg = surfaceArg.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = "ERROR: No tab selected"
        DispatchQueue.main.sync {
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
          auth <password>             - Authenticate this connection (required in password mode)
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
          refresh_surfaces                - Force refresh all terminals
          surface_health [workspace]      - Check view health of all surfaces

        Input commands:
          send <text>                     - Send text to current terminal
          send_key <key>                  - Send special key (ctrl-c, ctrl-d, enter, tab, escape)
          send_surface <id|idx> <text>    - Send text to a specific terminal
          send_key_surface <id|idx> <key> - Send special key to a specific terminal
          read_screen [id|idx] [--scrollback] [--lines N] - Read terminal text (plain text)

        Notification commands:
          notify <title>|<subtitle>|<body>   - Notify focused panel
          notify_surface <id|idx> <payload>  - Notify a specific surface
          notify_target <workspace_id> <surface_id> <payload> - Notify by workspace+surface
          list_notifications              - List all notifications
          clear_notifications             - Clear all notifications
          set_app_focus <active|inactive|clear> - Override app focus state
          simulate_app_active             - Trigger app active handler
          set_status <key> <value> [--icon=X] [--color=#hex] [--tab=X] - Set a status entry
          clear_status <key> [--tab=X] - Remove a status entry
          list_status [--tab=X]   - List all status entries
          log [--level=X] [--source=X] [--tab=X] -- <message> - Append a log entry
          clear_log [--tab=X]     - Clear log entries
          list_log [--limit=N] [--tab=X] - List log entries
          set_progress <0.0-1.0> [--label=X] [--tab=X] - Set progress bar
          clear_progress [--tab=X] - Clear progress bar
          report_git_branch <branch> [--status=dirty] [--tab=X] [--panel=Y] - Report git branch
          clear_git_branch [--tab=X] [--panel=Y] - Clear git branch
          report_ports <port1> [port2...] [--tab=X] [--panel=Y] - Report listening ports
          report_tty <tty_name> [--tab=X] [--panel=Y] - Register TTY for batched port scanning
          ports_kick [--tab=X] [--panel=Y] - Request batched port scan for panel
          report_pwd <path> [--tab=X] [--panel=Y] - Report current working directory
          clear_ports [--tab=X] [--panel=Y] - Clear listening ports
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
    private func debugShortcutName(for action: KeyboardShortcutSettings.Action) -> String {
        let snakeCase = action.rawValue.replacingOccurrences(
            of: "([a-z0-9])([A-Z])",
            with: "$1_$2",
            options: .regularExpression
        )
        return snakeCase.lowercased()
    }

    private func debugShortcutAction(named rawName: String) -> KeyboardShortcutSettings.Action? {
        let normalized = rawName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")

        for action in KeyboardShortcutSettings.Action.allCases {
            let snakeCaseName = debugShortcutName(for: action)
            if normalized == snakeCaseName || normalized == snakeCaseName.replacingOccurrences(of: "_", with: "") {
                return action
            }
        }
        return nil
    }

    private func debugShortcutSupportedNames() -> String {
        KeyboardShortcutSettings.Action.allCases
            .map(debugShortcutName(for:))
            .sorted()
            .joined(separator: ", ")
    }

    private func setShortcut(_ args: String) -> String {
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            return "ERROR: Usage: set_shortcut <name> <combo|clear>"
        }

        let name = parts[0]
        let combo = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)

        guard let action = debugShortcutAction(named: name) else {
            return "ERROR: Unknown shortcut name. Supported: \(debugShortcutSupportedNames())"
        }

        if combo.lowercased() == "clear" || combo.lowercased() == "default" || combo.lowercased() == "reset" {
            UserDefaults.standard.removeObject(forKey: action.defaultsKey)
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
        guard let data = try? JSONEncoder().encode(shortcut) else {
            return "ERROR: Failed to encode shortcut"
        }
        UserDefaults.standard.set(data, forKey: action.defaultsKey)
        return "OK"
    }

	    private func simulateShortcut(_ args: String) -> String {
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
	        DispatchQueue.main.sync {
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
	            if let targetWindow {
	                NSApp.activate(ignoringOtherApps: true)
	                targetWindow.makeKeyAndOrderFront(nil)
	            }
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

    private func activateApp() -> String {
        DispatchQueue.main.sync {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.unhide(nil)
            let hasMainTerminalWindow = NSApp.windows.contains { window in
                guard let raw = window.identifier?.rawValue else { return false }
                return raw == "cmux.main" || raw.hasPrefix("cmux.main.")
            }

            if !hasMainTerminalWindow {
                AppDelegate.shared?.openNewMainWindow(nil)
            }

            if let window = NSApp.mainWindow
                ?? NSApp.keyWindow
                ?? NSApp.windows.first(where: { win in
                    guard let raw = win.identifier?.rawValue else { return false }
                    return raw == "cmux.main" || raw.hasPrefix("cmux.main.")
                })
                ?? NSApp.windows.first {
                window.makeKeyAndOrderFront(nil)
            }
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
        DispatchQueue.main.sync {
            // Like simulate_shortcut, prefer a visible window so debug automation doesn't
            // fail during key window transitions.
            guard let window = NSApp.keyWindow
                ?? NSApp.mainWindow
                ?? NSApp.windows.first(where: { $0.isVisible })
                ?? NSApp.windows.first else { return }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            guard let fr = window.firstResponder else {
                result = "ERROR: No first responder"
                return
            }

            if let client = fr as? NSTextInputClient {
                client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
                result = "OK"
                return
            }

            // If workspace handoff temporarily leaves a non-terminal first responder,
            // route debug typing to the selected terminal's focused panel directly.
            if let tabManager,
               let tabId = tabManager.selectedTabId,
               let tab = tabManager.tabs.first(where: { $0.id == tabId }),
               let panelId = tab.focusedPanelId,
               let terminalPanel = tab.terminalPanel(for: panelId),
               !terminalPanel.hostedView.isSurfaceViewFirstResponder() {
                // Match Enter semantics expected by tests/debug tooling when bypassing AppKit.
                let directText = text.replacingOccurrences(of: "\n", with: "\r")
                terminalPanel.surface.sendText(directText)
                result = "OK"
                return
            }

            // Fall back to the responder-chain insertText action.
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
        DispatchQueue.main.sync {
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

        DispatchQueue.main.sync {
            _ = NSPasteboard(name: .drag).declareTypes(types, owner: nil)
        }
        return "OK"
    }

    private func clearDragPasteboard() -> String {
        DispatchQueue.main.sync {
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
        DispatchQueue.main.sync {
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
        DispatchQueue.main.sync {
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
        DispatchQueue.main.sync {
            let pb = NSPasteboard(name: .drag)
            shouldPassThrough = DragOverlayRoutingPolicy.shouldPassThroughPortalHitTesting(
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
        DispatchQueue.main.sync {
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
        DispatchQueue.main.sync {
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
        DispatchQueue.main.sync {
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
        DispatchQueue.main.sync {
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

    private static func responderChainContains(_ start: NSResponder?, target: NSResponder) -> Bool {
        var r = start
        var hops = 0
        while let cur = r, hops < 64 {
            if cur === target { return true }
            r = cur.nextResponder
            hops += 1
        }
        return false
    }

    private func isTerminalFocused(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        let panelArg = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !panelArg.isEmpty else { return "ERROR: Usage: is_terminal_focused <panel_id|idx>" }

        var result = "false"
        DispatchQueue.main.sync {
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

    private func readTerminalText(_ args: String) -> String {
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

    private func renderStats(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        let panelArg = args.trimmingCharacters(in: .whitespacesAndNewlines)

        var result = "ERROR: No tab selected"
        DispatchQueue.main.sync {
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
        case "esc", "escape":
            storedKey = "\u{1b}"
            keyCode = UInt16(kVK_Escape)
            charactersIgnoringModifiers = storedKey
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
        case "backspace", "delete", "del":
            storedKey = "\u{7f}"
            keyCode = UInt16(kVK_Delete)
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
    private static func responderChainContains(_ start: NSResponder?, target: NSResponder) -> Bool {
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
        if socketCommandAllowsInAppFocusMutations(),
           let tm = v2MainSync({ AppDelegate.shared?.tabManagerFor(windowId: windowId) }) {
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
        DispatchQueue.main.sync {
            let tabs = tabManager.tabs.enumerated().map { (index, tab) in
                let selected = tab.id == tabManager.selectedTabId ? "*" : " "
                return "\(selected) \(index): \(tab.id.uuidString) \(tab.title)"
            }
            result = tabs.joined(separator: "\n")
        }
        return result.isEmpty ? "No workspaces" : result
    }

    private func newWorkspace() -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        var newTabId: UUID?
        let focus = socketCommandAllowsInAppFocusMutations()
        #if DEBUG
        let startedAt = ProcessInfo.processInfo.systemUptime
        #endif
        DispatchQueue.main.sync {
            let workspace = tabManager.addTab(select: focus)
            newTabId = workspace.id
        }
        #if DEBUG
        let elapsedMs = (ProcessInfo.processInfo.systemUptime - startedAt) * 1000.0
        dlog(
            "socket.new_workspace focus=\(focus ? 1 : 0) ms=\(String(format: "%.2f", elapsedMs)) main=\(Thread.isMainThread ? 1 : 0)"
        )
        #endif
        return "OK \(newTabId?.uuidString ?? "unknown")"
    }

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
        DispatchQueue.main.sync {
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

            if let newPanelId = tabManager.newSplit(
                tabId: tabId,
                surfaceId: targetSurface,
                direction: direction,
                focus: socketCommandAllowsInAppFocusMutations()
            ) {
                result = "OK \(newPanelId.uuidString)"
            }
        }
        return result
    }

    private func listSurfaces(_ tabArg: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }
        var result = ""
        DispatchQueue.main.sync {
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
        DispatchQueue.main.sync {
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
        DispatchQueue.main.sync {
            guard let tabId = tabManager.selectedTabId else {
                result = "ERROR: No tab selected"
                return
            }
            let surfaceId = tabManager.focusedSurfaceId(for: tabId)
            let (title, subtitle, body) = parseNotificationPayload(args)
            TerminalNotificationStore.shared.addNotification(
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
        DispatchQueue.main.sync {
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
            TerminalNotificationStore.shared.addNotification(
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

        var result = "OK"
        DispatchQueue.main.sync {
            guard let tab = resolveTab(from: tabArg, tabManager: tabManager) else {
                result = "ERROR: Tab not found"
                return
            }
            guard let panelId = UUID(uuidString: panelArg),
                  tab.panels[panelId] != nil else {
                result = "ERROR: Panel not found"
                return
            }
            let (title, subtitle, body) = parseNotificationPayload(payload)
            TerminalNotificationStore.shared.addNotification(
                tabId: tab.id,
                surfaceId: panelId,
                title: title,
                subtitle: subtitle,
                body: body
            )
        }
        return result
    }

    private func listNotifications() -> String {
        var result = ""
        DispatchQueue.main.sync {
            let lines = TerminalNotificationStore.shared.notifications.enumerated().map { index, notification in
                let surfaceText = notification.surfaceId?.uuidString ?? "none"
                let readText = notification.isRead ? "read" : "unread"
                return "\(index):\(notification.id.uuidString)|\(notification.tabId.uuidString)|\(surfaceText)|\(readText)|\(notification.title)|\(notification.subtitle)|\(notification.body)"
            }
            result = lines.joined(separator: "\n")
        }
        return result.isEmpty ? "No notifications" : result
    }

    private func clearNotifications() -> String {
        DispatchQueue.main.sync {
            TerminalNotificationStore.shared.clearAll()
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
        DispatchQueue.main.sync {
            AppDelegate.shared?.applicationDidBecomeActive(
                Notification(name: NSApplication.didBecomeActiveNotification)
            )
        }
        return "OK"
    }

#if DEBUG
    private func focusFromNotification(_ args: String) -> String {
        guard let tabManager else { return "ERROR: TabManager not available" }
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
        let tabArg = parts.first ?? ""
        let surfaceArg = parts.count > 1 ? parts[1] : ""

        var result = "OK"
        DispatchQueue.main.sync {
            guard let tab = resolveTab(from: tabArg, tabManager: tabManager) else {
                result = "ERROR: Tab not found"
                return
            }
            let surfaceId = surfaceArg.isEmpty ? nil : resolveSurfaceId(from: surfaceArg, tab: tab)
            if !surfaceArg.isEmpty && surfaceId == nil {
                result = "ERROR: Surface not found"
                return
            }
            tabManager.focusTabFromNotification(tab.id, surfaceId: surfaceId)
        }
        return result
    }

    private func flashCount(_ args: String) -> String {
        guard let tabManager else { return "ERROR: TabManager not available" }
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "ERROR: Missing surface id or index" }

        var result = "ERROR: Surface not found"
        DispatchQueue.main.sync {
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

    private func resetFlashCounts() -> String {
        DispatchQueue.main.sync {
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

    private func panelSnapshotReset(_ args: String) -> String {
        guard let tabManager else { return "ERROR: TabManager not available" }
        let panelArg = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !panelArg.isEmpty else { return "ERROR: Usage: panel_snapshot_reset <panel_id|idx>" }

        var result = "ERROR: No tab selected"
        DispatchQueue.main.sync {
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

    private func panelSnapshot(_ args: String) -> String {
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
        DispatchQueue.main.sync {
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
                terminalPanel.surface.forceRefresh()
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

    private func layoutDebug() -> String {
        guard let tabManager else { return "ERROR: TabManager not available" }

        var result = "ERROR: No tab selected"
        DispatchQueue.main.sync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
                return
            }

            let layout = tab.bonsplitController.layoutSnapshot()
            var paneFrames: [String: PixelRect] = [:]
            for pane in layout.panes {
                paneFrames[pane.paneId] = pane.frame
            }

            func isHiddenOrAncestorHidden(_ view: NSView) -> Bool {
                if view.isHidden { return true }
                var current = view.superview
                while let v = current {
                    if v.isHidden { return true }
                    current = v.superview
                }
                return false
            }

            func windowFrame(for view: NSView) -> CGRect? {
                guard view.window != nil else { return nil }
                // Prefer the view's frame as laid out by its superview. Some AppKit views
                // (notably scroll views) can temporarily report stale bounds during reparenting.
                if let superview = view.superview {
                    return superview.convert(view.frame, to: nil)
                }
                return view.convert(view.bounds, to: nil)
            }

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

    private func emptyPanelCount() -> String {
        var result = "OK 0"
        DispatchQueue.main.sync {
            result = "OK \(DebugUIEventCounters.emptyPanelAppearCount)"
        }
        return result
    }

    private func resetEmptyPanelCount() -> String {
        DispatchQueue.main.sync {
            DebugUIEventCounters.resetEmptyPanelAppearCount()
        }
        return "OK"
    }

    private func bonsplitUnderflowCount() -> String {
        var result = "OK 0"
        DispatchQueue.main.sync {
#if DEBUG
            result = "OK \(BonsplitDebugCounters.arrangedSubviewUnderflowCount)"
#else
            result = "OK 0"
#endif
        }
        return result
    }

    private func resetBonsplitUnderflowCount() -> String {
        DispatchQueue.main.sync {
#if DEBUG
            BonsplitDebugCounters.reset()
#endif
        }
        return "OK"
    }

    private func captureScreenshot(_ args: String) -> String {
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
        DispatchQueue.main.sync {
            guard let window = NSApp.mainWindow ?? NSApp.windows.first else {
                captureError = "No window available"
                return
            }

            // Get window's CGWindowID
            let windowNumber = CGWindowID(window.windowNumber)

            // Capture the window using CGWindowListCreateImage
            guard let cgImage = CGWindowListCreateImage(
                .null,  // Capture just the window bounds
                .optionIncludingWindow,
                windowNumber,
                [.boundsIgnoreFraming, .nominalResolution]
            ) else {
                captureError = "Failed to capture window image"
                return
            }

            // Convert to NSBitmapImageRep and save as PNG
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
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
#endif

    private func parseSplitDirection(_ value: String) -> SplitDirection? {
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

    private func orderedPanels(in tab: Workspace) -> [any Panel] {
        // Use bonsplit's tab ordering as the source of truth. This avoids relying on
        // Dictionary iteration order, and prevents indexing into panels that aren't
        // actually present in bonsplit anymore.
        let orderedTabIds = tab.bonsplitController.allTabIds
        var result: [any Panel] = []
        var seen = Set<UUID>()

        for tabId in orderedTabIds {
            guard let panelId = tab.panelIdFromSurfaceId(tabId),
                  let panel = tab.panels[panelId] else { continue }
            result.append(panel)
            seen.insert(panelId)
        }

        // Defensive: include any orphaned panels in a stable order at the end.
        let orphans = tab.panels.values
            .filter { !seen.contains($0.id) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        result.append(contentsOf: orphans)

        return result
    }

    private func resolveTerminalPanel(from arg: String, tabManager: TabManager) -> TerminalPanel? {
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

    private func resolveTerminalSurface(from arg: String, tabManager: TabManager, waitUpTo timeout: TimeInterval = 0.6) -> ghostty_surface_t? {
        guard let terminalPanel = resolveTerminalPanel(from: arg, tabManager: tabManager) else { return nil }
        return waitForTerminalSurface(terminalPanel, waitUpTo: timeout)
    }

    private func waitForTerminalSurface(_ terminalPanel: TerminalPanel, waitUpTo timeout: TimeInterval = 0.6) -> ghostty_surface_t? {
        if let surface = terminalPanel.surface.surface { return surface }

        // This can be transient during bonsplit tree restructuring when the SwiftUI
        // view is temporarily detached and then reattached (surface creation is
        // gated on view/window/bounds). Pump the runloop briefly to allow pending
        // attach retries to execute.
        let deadline = Date().addingTimeInterval(timeout)
        while terminalPanel.surface.surface == nil && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }

        return terminalPanel.surface.surface
    }

    private func resolveSurface(from arg: String, tabManager: TabManager) -> ghostty_surface_t? {
        // Backwards compatibility: resolve a terminal surface by panel UUID or a stable index.
        // Use a slightly longer wait to reduce flakiness during bonsplit/layout restructures.
        return resolveTerminalSurface(from: arg, tabManager: tabManager, waitUpTo: 2.0)
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
        let parts = trimmed.split(separator: "|", maxSplits: 2).map(String.init)
        let title = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let subtitle = parts.count > 2 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let body = parts.count > 2
            ? parts[2].trimmingCharacters(in: .whitespacesAndNewlines)
            : (parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : "")
        return (title.isEmpty ? "Notification" : title, subtitle, body)
    }

    private func closeWorkspace(_ tabId: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }
        guard let uuid = UUID(uuidString: tabId) else { return "ERROR: Invalid tab ID" }

        var success = false
        DispatchQueue.main.sync {
            if let tab = tabManager.tabs.first(where: { $0.id == uuid }) {
                tabManager.closeTab(tab)
                success = true
            }
        }
        return success ? "OK" : "ERROR: Tab not found"
    }

    private func selectWorkspace(_ arg: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        var success = false
        DispatchQueue.main.sync {
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
        DispatchQueue.main.sync {
            if let id = tabManager.selectedTabId {
                result = id.uuidString
            }
        }
        return result.isEmpty ? "ERROR: No tab selected" : result
    }

    private func sendKeyEvent(
        surface: ghostty_surface_t,
        keycode: UInt32,
        mods: ghostty_input_mods_e = GHOSTTY_MODS_NONE,
        text: String? = nil
    ) {
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = GHOSTTY_ACTION_PRESS
        keyEvent.keycode = keycode
        keyEvent.mods = mods
        keyEvent.consumed_mods = GHOSTTY_MODS_NONE
        keyEvent.unshifted_codepoint = 0
        keyEvent.composing = false
        if let text {
            text.withCString { ptr in
                keyEvent.text = ptr
                _ = ghostty_surface_key(surface, keyEvent)
            }
        } else {
            keyEvent.text = nil
            _ = ghostty_surface_key(surface, keyEvent)
        }
    }

    private func sendTextEvent(surface: ghostty_surface_t, text: String) {
        sendKeyEvent(surface: surface, keycode: 0, text: text)
    }

    enum SocketTextChunk: Equatable {
        case text(String)
        case control(UnicodeScalar)
    }

    nonisolated static func socketTextChunks(_ text: String) -> [SocketTextChunk] {
        guard !text.isEmpty else { return [] }

        var chunks: [SocketTextChunk] = []
        chunks.reserveCapacity(8)
        var bufferedText = ""
        bufferedText.reserveCapacity(text.count)

        func flushBufferedText() {
            guard !bufferedText.isEmpty else { return }
            chunks.append(.text(bufferedText))
            bufferedText.removeAll(keepingCapacity: true)
        }

        for scalar in text.unicodeScalars {
            if isSocketControlScalar(scalar) {
                flushBufferedText()
                chunks.append(.control(scalar))
            } else {
                bufferedText.unicodeScalars.append(scalar)
            }
        }
        flushBufferedText()
        return chunks
    }

    private nonisolated static func isSocketControlScalar(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x0A, 0x0D, 0x09, 0x1B, 0x7F:
            return true
        default:
            return false
        }
    }

    private func sendSocketText(_ text: String, surface: ghostty_surface_t) {
        let chunks = Self.socketTextChunks(text)
        #if DEBUG
        let startedAt = ProcessInfo.processInfo.systemUptime
        #endif
        for chunk in chunks {
            switch chunk {
            case .text(let value):
                sendTextEvent(surface: surface, text: value)
            case .control(let scalar):
                _ = handleControlScalar(scalar, surface: surface)
            }
        }
        #if DEBUG
        let elapsedMs = (ProcessInfo.processInfo.systemUptime - startedAt) * 1000.0
        if elapsedMs >= 8 || chunks.count > 1 {
            dlog(
                "socket.send_text.inject chars=\(text.count) chunks=\(chunks.count) ms=\(String(format: "%.2f", elapsedMs))"
            )
        }
        #endif
    }

    private func handleControlScalar(_ scalar: UnicodeScalar, surface: ghostty_surface_t) -> Bool {
        switch scalar.value {
        case 0x0A, 0x0D:
            sendKeyEvent(surface: surface, keycode: UInt32(kVK_Return))
            return true
        case 0x09:
            sendKeyEvent(surface: surface, keycode: UInt32(kVK_Tab))
            return true
        case 0x1B:
            sendKeyEvent(surface: surface, keycode: UInt32(kVK_Escape))
            return true
        case 0x7F:
            sendKeyEvent(surface: surface, keycode: UInt32(kVK_Delete))
            return true
        default:
            return false
        }
    }

    private func keycodeForLetter(_ letter: Character) -> UInt32? {
        switch String(letter).lowercased() {
        case "a": return UInt32(kVK_ANSI_A)
        case "b": return UInt32(kVK_ANSI_B)
        case "c": return UInt32(kVK_ANSI_C)
        case "d": return UInt32(kVK_ANSI_D)
        case "e": return UInt32(kVK_ANSI_E)
        case "f": return UInt32(kVK_ANSI_F)
        case "g": return UInt32(kVK_ANSI_G)
        case "h": return UInt32(kVK_ANSI_H)
        case "i": return UInt32(kVK_ANSI_I)
        case "j": return UInt32(kVK_ANSI_J)
        case "k": return UInt32(kVK_ANSI_K)
        case "l": return UInt32(kVK_ANSI_L)
        case "m": return UInt32(kVK_ANSI_M)
        case "n": return UInt32(kVK_ANSI_N)
        case "o": return UInt32(kVK_ANSI_O)
        case "p": return UInt32(kVK_ANSI_P)
        case "q": return UInt32(kVK_ANSI_Q)
        case "r": return UInt32(kVK_ANSI_R)
        case "s": return UInt32(kVK_ANSI_S)
        case "t": return UInt32(kVK_ANSI_T)
        case "u": return UInt32(kVK_ANSI_U)
        case "v": return UInt32(kVK_ANSI_V)
        case "w": return UInt32(kVK_ANSI_W)
        case "x": return UInt32(kVK_ANSI_X)
        case "y": return UInt32(kVK_ANSI_Y)
        case "z": return UInt32(kVK_ANSI_Z)
        default: return nil
        }
    }

    private func sendNamedKey(_ surface: ghostty_surface_t, keyName: String) -> Bool {
        switch keyName.lowercased() {
        case "ctrl-c", "ctrl+c", "sigint":
            sendKeyEvent(surface: surface, keycode: UInt32(kVK_ANSI_C), mods: GHOSTTY_MODS_CTRL)
            return true
        case "ctrl-d", "ctrl+d", "eof":
            sendKeyEvent(surface: surface, keycode: UInt32(kVK_ANSI_D), mods: GHOSTTY_MODS_CTRL)
            return true
        case "ctrl-z", "ctrl+z", "sigtstp":
            sendKeyEvent(surface: surface, keycode: UInt32(kVK_ANSI_Z), mods: GHOSTTY_MODS_CTRL)
            return true
        case "ctrl-\\", "ctrl+\\", "sigquit":
            sendKeyEvent(surface: surface, keycode: UInt32(kVK_ANSI_Backslash), mods: GHOSTTY_MODS_CTRL)
            return true
        case "enter", "return":
            sendKeyEvent(surface: surface, keycode: UInt32(kVK_Return))
            return true
        case "tab":
            sendKeyEvent(surface: surface, keycode: UInt32(kVK_Tab))
            return true
        case "escape", "esc":
            sendKeyEvent(surface: surface, keycode: UInt32(kVK_Escape))
            return true
        case "backspace":
            sendKeyEvent(surface: surface, keycode: UInt32(kVK_Delete))
            return true
        default:
            if keyName.lowercased().hasPrefix("ctrl-") || keyName.lowercased().hasPrefix("ctrl+") {
                let letter = keyName.dropFirst(5)
                if letter.count == 1, let char = letter.first, let keycode = keycodeForLetter(char) {
                    sendKeyEvent(surface: surface, keycode: keycode, mods: GHOSTTY_MODS_CTRL)
                    return true
                }
            }
            return false
        }
    }

    private func sendInput(_ text: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        var success = false
        var error: String?
        DispatchQueue.main.sync {
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

            if let surface = terminalPanel.surface.surface {
                sendSocketText(unescaped, surface: surface)
            } else {
                terminalPanel.sendText(unescaped)
                terminalPanel.surface.requestBackgroundSurfaceStartIfNeeded()
            }
            success = true
        }
        if let error { return error }
        return success ? "OK" : "ERROR: Failed to send input"
    }

    private func sendInputToSurface(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }
        let parts = args.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return "ERROR: Usage: send_surface <id|idx> <text>" }

        let target = parts[0]
        let text = parts[1]

        var success = false
        DispatchQueue.main.sync {
            guard let terminalPanel = resolveTerminalPanel(from: target, tabManager: tabManager) else { return }

            let unescaped = text
                .replacingOccurrences(of: "\\n", with: "\r")
                .replacingOccurrences(of: "\\r", with: "\r")
                .replacingOccurrences(of: "\\t", with: "\t")

            if let surface = terminalPanel.surface.surface {
                sendSocketText(unescaped, surface: surface)
            } else {
                terminalPanel.sendText(unescaped)
                terminalPanel.surface.requestBackgroundSurfaceStartIfNeeded()
            }
            success = true
        }

        return success ? "OK" : "ERROR: Failed to send input"
    }

    private func sendKey(_ keyName: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        var success = false
        var error: String?
        DispatchQueue.main.sync {
            guard let selectedId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == selectedId }),
                  let terminalPanel = tab.focusedTerminalPanel else {
                error = "ERROR: No focused terminal"
                return
            }

            guard let surface = terminalPanel.surface.surface else {
                error = "ERROR: Surface not ready"
                return
            }

            success = sendNamedKey(surface, keyName: keyName)
        }
        if let error { return error }
        return success ? "OK" : "ERROR: Unknown key '\(keyName)'"
    }

    private func sendKeyToSurface(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }
        let parts = args.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return "ERROR: Usage: send_key_surface <id|idx> <key>" }

        let target = parts[0]
        let keyName = parts[1]

        var success = false
        var error: String?
        DispatchQueue.main.sync {
            guard let terminalPanel = resolveTerminalPanel(from: target, tabManager: tabManager) else {
                error = "ERROR: Surface not found"
                return
            }
            guard let surface = terminalPanel.surface.surface else {
                error = "ERROR: Surface not ready"
                return
            }
            success = sendNamedKey(surface, keyName: keyName)
        }

        if let error { return error }
        return success ? "OK" : "ERROR: Unknown key '\(keyName)'"
    }

    // MARK: - Browser Panel Commands

    private func openBrowser(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        let url: URL? = trimmed.isEmpty ? nil : URL(string: trimmed)
        let shouldFocus = socketCommandAllowsInAppFocusMutations()

        var result = "ERROR: Failed to create browser panel"
        DispatchQueue.main.sync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }),
                  let focusedPanelId = tab.focusedPanelId else {
                return
            }

            if let browserPanelId = tab.newBrowserSplit(
                from: focusedPanelId,
                orientation: .horizontal,
                url: url,
                focus: shouldFocus
            )?.id {
                result = "OK \(browserPanelId.uuidString)"
            }
        }
        return result
    }

    private func navigateBrowser(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        let parts = args.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return "ERROR: Usage: navigate <panel_id> <url>" }

        let panelArg = parts[0]
        let urlStr = parts[1]

        var result = "ERROR: Panel not found or not a browser"
        DispatchQueue.main.sync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }),
                  let panelId = UUID(uuidString: panelArg),
                  let browserPanel = tab.browserPanel(for: panelId) else {
                return
            }

            browserPanel.navigateSmart(urlStr)
            result = "OK"
        }
        return result
    }

    private func browserBack(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        let panelArg = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !panelArg.isEmpty else { return "ERROR: Usage: browser_back <panel_id>" }

        var result = "ERROR: Panel not found or not a browser"
        DispatchQueue.main.sync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }),
                  let panelId = UUID(uuidString: panelArg),
                  let browserPanel = tab.browserPanel(for: panelId) else {
                return
            }

            browserPanel.goBack()
            result = "OK"
        }
        return result
    }

    private func browserForward(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        let panelArg = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !panelArg.isEmpty else { return "ERROR: Usage: browser_forward <panel_id>" }

        var result = "ERROR: Panel not found or not a browser"
        DispatchQueue.main.sync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }),
                  let panelId = UUID(uuidString: panelArg),
                  let browserPanel = tab.browserPanel(for: panelId) else {
                return
            }

            browserPanel.goForward()
            result = "OK"
        }
        return result
    }

    private func browserReload(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        let panelArg = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !panelArg.isEmpty else { return "ERROR: Usage: browser_reload <panel_id>" }

        var result = "ERROR: Panel not found or not a browser"
        DispatchQueue.main.sync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }),
                  let panelId = UUID(uuidString: panelArg),
                  let browserPanel = tab.browserPanel(for: panelId) else {
                return
            }

            browserPanel.reload()
            result = "OK"
        }
        return result
    }

    private func getUrl(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        let panelArg = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !panelArg.isEmpty else { return "ERROR: Usage: get_url <panel_id>" }

        var result = "ERROR: Panel not found or not a browser"
        DispatchQueue.main.sync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }),
                  let panelId = UUID(uuidString: panelArg),
                  let browserPanel = tab.browserPanel(for: panelId) else {
                return
            }

            result = browserPanel.currentURL?.absoluteString ?? ""
        }
        return result
    }

    private func focusWebView(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        let panelArg = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !panelArg.isEmpty else { return "ERROR: Usage: focus_webview <panel_id>" }

        var result = "ERROR: Panel not found or not a browser"
        DispatchQueue.main.sync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }),
                  let panelId = UUID(uuidString: panelArg),
                  let browserPanel = tab.browserPanel(for: panelId) else {
                return
            }

            // Programmatic WebView focus should win over stale omnibar focus state, especially
            // after workspace switches where the blank-page omnibar auto-focus can re-trigger.
            browserPanel.endSuppressWebViewFocusForAddressBar()
            browserPanel.clearWebViewFocusSuppression()
            NotificationCenter.default.post(name: .browserDidBlurAddressBar, object: panelId)

            // Prevent omnibar auto-focus from immediately stealing first responder back.
            browserPanel.suppressOmnibarAutofocus(for: 1.5)

            let webView = browserPanel.webView
            guard let window = webView.window else {
                result = "ERROR: WebView is not in a window"
                return
            }
            guard !webView.isHiddenOrHasHiddenAncestor else {
                result = "ERROR: WebView is hidden"
                return
            }

            window.makeFirstResponder(webView)
            if Self.responderChainContains(window.firstResponder, target: webView) {
                // Some focus churn paths (workspace handoff / omnibar blur) can race this call.
                // Reassert on the next runloop if another responder steals focus immediately.
                DispatchQueue.main.async { [weak window, weak webView] in
                    guard let window, let webView else { return }
                    guard webView.window === window else { return }
                    if !Self.responderChainContains(window.firstResponder, target: webView) {
                        window.makeFirstResponder(webView)
                    }
                }
                result = "OK"
            } else {
                result = "ERROR: Focus did not move into web view"
            }
        }
        return result
    }

    private func isWebViewFocused(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        let panelArg = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !panelArg.isEmpty else { return "ERROR: Usage: is_webview_focused <panel_id>" }

        var result = "ERROR: Panel not found or not a browser"
        DispatchQueue.main.sync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }),
                  let panelId = UUID(uuidString: panelArg),
                  let browserPanel = tab.browserPanel(for: panelId) else {
                return
            }

            let webView = browserPanel.webView
            guard let window = webView.window else {
                result = "false"
                return
            }
            result = Self.responderChainContains(window.firstResponder, target: webView) ? "true" : "false"
        }
        return result
    }

    // MARK: - Bonsplit Pane Commands

    private func listPanes() -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        var result = ""
        DispatchQueue.main.sync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
                result = "ERROR: No tab selected"
                return
            }

            let paneIds = tab.bonsplitController.allPaneIds
            let focusedPaneId = tab.bonsplitController.focusedPaneId

            let lines = paneIds.enumerated().map { index, paneId in
                let selected = paneId == focusedPaneId ? "*" : " "
                let tabCount = tab.bonsplitController.tabs(inPane: paneId).count
                return "\(selected) \(index): \(paneId) [\(tabCount) tabs]"
            }
            result = lines.isEmpty ? "No panes" : lines.joined(separator: "\n")
        }
        return result
    }

    private func listPaneSurfaces(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        var result = ""
        DispatchQueue.main.sync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
                result = "ERROR: No tab selected"
                return
            }

            // Parse --pane=<pane-id|index> argument (UUID preferred).
            var paneArg: String?
            for part in args.split(separator: " ") {
                if part.hasPrefix("--pane=") {
                    paneArg = String(part.dropFirst(7))
                    break
                }
            }

            let paneIds = tab.bonsplitController.allPaneIds
            var targetPaneId: PaneID? = tab.bonsplitController.focusedPaneId
            if let paneArg {
                if let uuid = UUID(uuidString: paneArg),
                   let paneId = paneIds.first(where: { $0.id == uuid }) {
                    targetPaneId = paneId
                } else if let index = Int(paneArg), index >= 0, index < paneIds.count {
                    targetPaneId = paneIds[index]
                } else {
                    result = "ERROR: Pane not found"
                    return
                }
            }

            guard let paneId = targetPaneId else {
                result = "ERROR: No pane to list tabs from"
                return
            }

            let tabs = tab.bonsplitController.tabs(inPane: paneId)
            let selectedTab = tab.bonsplitController.selectedTab(inPane: paneId)

            let lines = tabs.enumerated().map { index, bonsplitTab in
                let selected = bonsplitTab.id == selectedTab?.id ? "*" : " "
                let panelId = tab.panelIdFromSurfaceId(bonsplitTab.id)
                let panelIdStr = panelId?.uuidString ?? "unknown"
                return "\(selected) \(index): \(bonsplitTab.title) [panel:\(panelIdStr)]"
            }
            result = lines.isEmpty ? "No tabs in pane" : lines.joined(separator: "\n")
        }
        return result
    }

    private func focusPane(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        let paneArg = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !paneArg.isEmpty else { return "ERROR: Usage: focus_pane <pane_id>" }

        var result = "ERROR: Pane not found"
        DispatchQueue.main.sync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
                return
            }

            let paneIds = tab.bonsplitController.allPaneIds

            // Try UUID first, then fall back to index
            if let uuid = UUID(uuidString: paneArg),
               let paneId = paneIds.first(where: { $0.id == uuid }) {
                tab.bonsplitController.focusPane(paneId)
                result = "OK"
            } else if let index = Int(paneArg), index >= 0, index < paneIds.count {
                tab.bonsplitController.focusPane(paneIds[index])
                result = "OK"
            }
        }
        return result
    }

	    private func focusSurfaceByPanel(_ args: String) -> String {
	        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        let tabArg = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tabArg.isEmpty else { return "ERROR: Usage: focus_surface_by_panel <panel_id>" }

        var result = "ERROR: Panel not found"
        DispatchQueue.main.sync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
                return
            }

            // Focus by panel UUID (our stable surface handle). This must also move AppKit
            // first responder into the terminal view to ensure typing routes correctly.
            if let panelUUID = UUID(uuidString: tabArg),
               tab.panels[panelUUID] != nil,
               tab.surfaceIdFromPanelId(panelUUID) != nil {
                tabManager.focusSurface(tabId: tab.id, surfaceId: panelUUID)
                result = "OK"
            }
        }
	        return result
	    }
	
	    private func dragSurfaceToSplit(_ args: String) -> String {
	        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }
	
	        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
	        let parts = trimmed.split(separator: " ").map(String.init)
	        guard parts.count >= 2 else { return "ERROR: Usage: drag_surface_to_split <id|idx> <left|right|up|down>" }
	
	        let surfaceArg = parts[0]
	        let directionArg = parts[1]
	        guard let direction = parseSplitDirection(directionArg) else {
	            return "ERROR: Invalid direction. Use left, right, up, or down."
	        }
	
	        let orientation: SplitOrientation = direction.isHorizontal ? .horizontal : .vertical
	        let insertFirst = (direction == .left || direction == .up)
	
	        var result = "ERROR: Failed to move surface"
	        DispatchQueue.main.sync {
	            guard let tabId = tabManager.selectedTabId,
	                  let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
	                result = "ERROR: No tab selected"
	                return
	            }
	
	            guard let panelId = resolveSurfaceId(from: surfaceArg, tab: tab),
	                  let bonsplitTabId = tab.surfaceIdFromPanelId(panelId) else {
	                result = "ERROR: Surface not found"
	                return
	            }
	
	            guard let newPaneId = tab.bonsplitController.splitPane(
	                orientation: orientation,
	                movingTab: bonsplitTabId,
	                insertFirst: insertFirst
	            ) else {
	                result = "ERROR: Failed to split pane"
	                return
	            }
	
	            result = "OK \(newPaneId.id.uuidString)"
	        }
	        return result
	    }
	
    private func newPane(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        // Parse arguments: --type=terminal|browser --direction=left|right|up|down --url=...
        var panelType: PanelType = .terminal
        var direction: SplitDirection = .right
        var url: URL? = nil
        var invalidDirection = false

        let parts = args.split(separator: " ")
        for part in parts {
            let partStr = String(part)
            if partStr.hasPrefix("--type=") {
                let typeStr = String(partStr.dropFirst(7))
                panelType = typeStr == "browser" ? .browser : .terminal
            } else if partStr.hasPrefix("--direction=") {
                let dirStr = String(partStr.dropFirst(12))
                if let parsed = parseSplitDirection(dirStr) {
                    direction = parsed
                } else {
                    invalidDirection = true
                }
            } else if partStr.hasPrefix("--url=") {
                let urlStr = String(partStr.dropFirst(6))
                url = URL(string: urlStr)
            }
        }

        if invalidDirection {
            return "ERROR: Invalid direction. Use left, right, up, or down."
        }

        let orientation = direction.orientation
        let insertFirst = direction.insertFirst
        let shouldFocus = socketCommandAllowsInAppFocusMutations()

        var result = "ERROR: Failed to create pane"
        DispatchQueue.main.sync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }),
                  let focusedPanelId = tab.focusedPanelId else {
                return
            }

            let newPanelId: UUID?
            if panelType == .browser {
                newPanelId = tab.newBrowserSplit(
                    from: focusedPanelId,
                    orientation: orientation,
                    insertFirst: insertFirst,
                    url: url,
                    focus: shouldFocus
                )?.id
            } else {
                newPanelId = tab.newTerminalSplit(
                    from: focusedPanelId,
                    orientation: orientation,
                    insertFirst: insertFirst,
                    focus: shouldFocus
                )?.id
            }

            if let id = newPanelId {
                result = "OK \(id.uuidString)"
            }
        }
        return result
    }

    // MARK: - Option Parsing (sidebar metadata commands)

    private func tokenizeArgs(_ args: String) -> [String] {
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var tokens: [String] = []
        var current = ""
        var inQuote = false
        var quoteChar: Character = "\""
        var cursor = trimmed.startIndex

        while cursor < trimmed.endIndex {
            let char = trimmed[cursor]
            if inQuote {
                if char == quoteChar {
                    inQuote = false
                    cursor = trimmed.index(after: cursor)
                    continue
                }
                if char == "\\" {
                    let nextIndex = trimmed.index(after: cursor)
                    if nextIndex < trimmed.endIndex {
                        let next = trimmed[nextIndex]
                        switch next {
                        case "n":
                            current.append("\n")
                            cursor = trimmed.index(after: nextIndex)
                            continue
                        case "r":
                            current.append("\r")
                            cursor = trimmed.index(after: nextIndex)
                            continue
                        case "t":
                            current.append("\t")
                            cursor = trimmed.index(after: nextIndex)
                            continue
                        case "\"", "'", "\\":
                            current.append(next)
                            cursor = trimmed.index(after: nextIndex)
                            continue
                        default:
                            break
                        }
                    }
                }
                current.append(char)
                cursor = trimmed.index(after: cursor)
                continue
            }

            if char == "'" || char == "\"" {
                inQuote = true
                quoteChar = char
                cursor = trimmed.index(after: cursor)
                continue
            }

            if char.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                cursor = trimmed.index(after: cursor)
                continue
            }

            current.append(char)
            cursor = trimmed.index(after: cursor)
        }

        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    private func parseOptions(_ args: String) -> (positional: [String], options: [String: String]) {
        let tokens = tokenizeArgs(args)
        guard !tokens.isEmpty else { return ([], [:]) }

        var positional: [String] = []
        var options: [String: String] = [:]
        var stopParsingOptions = false
        var i = 0
        while i < tokens.count {
            let token = tokens[i]
            if stopParsingOptions {
                positional.append(token)
            } else if token == "--" {
                stopParsingOptions = true
            } else if token.hasPrefix("--") {
                if let eqIndex = token.firstIndex(of: "=") {
                    let key = String(token[token.index(token.startIndex, offsetBy: 2)..<eqIndex])
                    let value = String(token[token.index(after: eqIndex)...])
                    options[key] = value
                } else {
                    let key = String(token.dropFirst(2))
                    if i + 1 < tokens.count && !tokens[i + 1].hasPrefix("--") {
                        options[key] = tokens[i + 1]
                        i += 1
                    } else {
                        options[key] = ""
                    }
                }
            } else {
                positional.append(token)
            }
            i += 1
        }
        return (positional, options)
    }

    private func parseOptionsNoStop(_ args: String) -> (positional: [String], options: [String: String]) {
        let tokens = tokenizeArgs(args)
        guard !tokens.isEmpty else { return ([], [:]) }

        var positional: [String] = []
        var options: [String: String] = [:]
        var i = 0
        while i < tokens.count {
            let token = tokens[i]
            if token == "--" {
                i += 1
                continue
            }
            if token.hasPrefix("--") {
                if let eqIndex = token.firstIndex(of: "=") {
                    let key = String(token[token.index(token.startIndex, offsetBy: 2)..<eqIndex])
                    let value = String(token[token.index(after: eqIndex)...])
                    options[key] = value
                } else {
                    let key = String(token.dropFirst(2))
                    if i + 1 < tokens.count && !tokens[i + 1].hasPrefix("--") {
                        options[key] = tokens[i + 1]
                        i += 1
                    } else {
                        options[key] = ""
                    }
                }
            } else {
                positional.append(token)
            }
            i += 1
        }
        return (positional, options)
    }

    private func resolveTabForReport(_ args: String) -> Tab? {
        guard let tabManager else { return nil }
        let parsed = parseOptions(args)
        if let tabArg = parsed.options["tab"], !tabArg.isEmpty {
            if let tab = resolveTab(from: tabArg, tabManager: tabManager) {
                return tab
            }
            // The tab may belong to a different window — search all contexts.
            if let uuid = UUID(uuidString: tabArg.trimmingCharacters(in: .whitespacesAndNewlines)),
               let otherManager = AppDelegate.shared?.tabManagerFor(tabId: uuid) {
                return otherManager.tabs.first(where: { $0.id == uuid })
            }
            return nil
        }
        guard let selectedId = tabManager.selectedTabId else { return nil }
        return tabManager.tabs.first(where: { $0.id == selectedId })
    }

    private func setStatus(_ args: String) -> String {
        guard tabManager != nil else { return "ERROR: TabManager not available" }
        let parsed = parseOptionsNoStop(args)
        guard parsed.positional.count >= 2 else {
            return "ERROR: Missing status key or value — usage: set_status <key> <value> [--icon=X] [--color=#hex] [--tab=X]"
        }
        let key = parsed.positional[0]
        let value = parsed.positional[1...].joined(separator: " ")
        let icon = parsed.options["icon"]
        let color = parsed.options["color"]

        var result = "OK"
        DispatchQueue.main.sync {
            guard let tab = resolveTabForReport(args) else {
                result = parsed.options["tab"] != nil ? "ERROR: Tab not found" : "ERROR: No tab selected"
                return
            }
            guard Self.shouldReplaceStatusEntry(
                current: tab.statusEntries[key],
                key: key,
                value: value,
                icon: icon,
                color: color
            ) else {
                return
            }
            tab.statusEntries[key] = SidebarStatusEntry(
                key: key,
                value: value,
                icon: icon,
                color: color,
                timestamp: Date()
            )
        }
        return result
    }

    private func clearStatus(_ args: String) -> String {
        let parsed = parseOptions(args)
        guard let key = parsed.positional.first, parsed.positional.count == 1 else {
            return "ERROR: Missing status key — usage: clear_status <key> [--tab=X]"
        }

        var result = "OK"
        DispatchQueue.main.sync {
            guard let tab = resolveTabForReport(args) else {
                result = parsed.options["tab"] != nil ? "ERROR: Tab not found" : "ERROR: No tab selected"
                return
            }
            if tab.statusEntries.removeValue(forKey: key) == nil {
                result = "OK (key not found)"
            }
        }
        return result
    }

    private func listStatus(_ args: String) -> String {
        var result = ""
        DispatchQueue.main.sync {
            guard let tab = resolveTabForReport(args) else {
                result = "ERROR: Tab not found"
                return
            }
            if tab.statusEntries.isEmpty {
                result = "No status entries"
                return
            }
            let lines = tab.statusEntries.values.sorted(by: { $0.key < $1.key }).map { entry in
                var line = "\(entry.key)=\(entry.value)"
                if let icon = entry.icon { line += " icon=\(icon)" }
                if let color = entry.color { line += " color=\(color)" }
                return line
            }
            result = lines.joined(separator: "\n")
        }
        return result
    }

    private func appendLog(_ args: String) -> String {
        let parsed = parseOptions(args)
        guard !parsed.positional.isEmpty else {
            return "ERROR: Missing message — usage: log [--level=X] [--source=X] [--tab=X] -- <message>"
        }
        let message = parsed.positional.joined(separator: " ")
        let levelStr = parsed.options["level"] ?? "info"
        guard let level = SidebarLogLevel(rawValue: levelStr) else {
            return "ERROR: Unknown log level '\(levelStr)' — use: info, progress, success, warning, error"
        }
        let source = parsed.options["source"]

        var result = "OK"
        DispatchQueue.main.sync {
            guard let tab = resolveTabForReport(args) else {
                result = parsed.options["tab"] != nil ? "ERROR: Tab not found" : "ERROR: No tab selected"
                return
            }
            tab.logEntries.append(SidebarLogEntry(message: message, level: level, source: source, timestamp: Date()))
            let configuredLimit = UserDefaults.standard.object(forKey: "sidebarMaxLogEntries") as? Int ?? 50
            let limit = max(1, min(500, configuredLimit))
            if tab.logEntries.count > limit {
                tab.logEntries.removeFirst(tab.logEntries.count - limit)
            }
        }
        return result
    }

    private func clearLog(_ args: String) -> String {
        var result = "OK"
        DispatchQueue.main.sync {
            guard let tab = resolveTabForReport(args) else {
                result = "ERROR: Tab not found"
                return
            }
            tab.logEntries.removeAll()
        }
        return result
    }

    private func listLog(_ args: String) -> String {
        let parsed = parseOptions(args)
        var limit: Int?
        if let limitStr = parsed.options["limit"] {
            if limitStr.isEmpty {
                return "ERROR: Missing limit value — usage: list_log [--limit=N] [--tab=X]"
            }
            guard let parsedLimit = Int(limitStr), parsedLimit >= 0 else {
                return "ERROR: Invalid limit '\(limitStr)' — must be >= 0"
            }
            limit = parsedLimit
        }

        var result = ""
        DispatchQueue.main.sync {
            guard let tab = resolveTabForReport(args) else {
                result = parsed.options["tab"] != nil ? "ERROR: Tab not found" : "ERROR: No tab selected"
                return
            }
            if tab.logEntries.isEmpty {
                result = "No log entries"
                return
            }
            let entries: [SidebarLogEntry]
            if let limit {
                entries = Array(tab.logEntries.suffix(limit))
            } else {
                entries = tab.logEntries
            }
            result = entries.map { entry in
                var line = "[\(entry.level.rawValue)] \(entry.message)"
                if let source = entry.source, !source.isEmpty {
                    line = "[\(source)] \(line)"
                }
                return line
            }.joined(separator: "\n")
        }
        return result
    }

    private func setProgress(_ args: String) -> String {
        let parsed = parseOptions(args)
        guard let first = parsed.positional.first else {
            return "ERROR: Missing progress value — usage: set_progress <0.0-1.0> [--label=X] [--tab=X]"
        }
        guard let value = Double(first), value.isFinite else {
            return "ERROR: Invalid progress value '\(first)' — must be 0.0 to 1.0"
        }
        let clamped = min(1.0, max(0.0, value))
        let label = parsed.options["label"]

        var result = "OK"
        DispatchQueue.main.sync {
            guard let tab = resolveTabForReport(args) else {
                result = parsed.options["tab"] != nil ? "ERROR: Tab not found" : "ERROR: No tab selected"
                return
            }
            guard Self.shouldReplaceProgress(current: tab.progress, value: clamped, label: label) else {
                return
            }
            tab.progress = SidebarProgressState(value: clamped, label: label)
        }
        return result
    }

    private func clearProgress(_ args: String) -> String {
        var result = "OK"
        DispatchQueue.main.sync {
            guard let tab = resolveTabForReport(args) else {
                result = "ERROR: Tab not found"
                return
            }
            if tab.progress != nil {
                tab.progress = nil
            }
        }
        return result
    }

    private func reportGitBranch(_ args: String) -> String {
        let parsed = parseOptions(args)
        guard let branch = parsed.positional.first else {
            return "ERROR: Missing branch name — usage: report_git_branch <branch> [--status=dirty] [--tab=X] [--panel=Y]"
        }
        let isDirty = parsed.options["status"]?.lowercased() == "dirty"

        var result = "OK"
        DispatchQueue.main.sync {
            guard let tab = resolveTabForReport(args) else {
                result = parsed.options["tab"] != nil ? "ERROR: Tab not found" : "ERROR: No tab selected"
                return
            }
            let validSurfaceIds = Set(tab.panels.keys)
            tab.pruneSurfaceMetadata(validSurfaceIds: validSurfaceIds)

            let panelArg = parsed.options["panel"] ?? parsed.options["surface"]
            let surfaceId: UUID
            if let panelArg {
                if panelArg.isEmpty {
                    result = "ERROR: Missing panel id — usage: report_git_branch <branch> [--status=dirty] [--tab=X] [--panel=Y]"
                    return
                }
                guard let parsedId = UUID(uuidString: panelArg) else {
                    result = "ERROR: Invalid panel id '\(panelArg)'"
                    return
                }
                surfaceId = parsedId
            } else {
                guard let focused = tab.focusedPanelId else {
                    result = "ERROR: Missing panel id (no focused surface)"
                    return
                }
                surfaceId = focused
            }

            guard validSurfaceIds.contains(surfaceId) else {
                result = "ERROR: Panel not found '\(surfaceId.uuidString)'"
                return
            }

            tab.updatePanelGitBranch(panelId: surfaceId, branch: branch, isDirty: isDirty)
        }
        return result
    }

    private func clearGitBranch(_ args: String) -> String {
        let parsed = parseOptions(args)
        var result = "OK"
        DispatchQueue.main.sync {
            guard let tab = resolveTabForReport(args) else {
                result = parsed.options["tab"] != nil ? "ERROR: Tab not found" : "ERROR: No tab selected"
                return
            }
            let validSurfaceIds = Set(tab.panels.keys)
            tab.pruneSurfaceMetadata(validSurfaceIds: validSurfaceIds)

            let panelArg = parsed.options["panel"] ?? parsed.options["surface"]
            let surfaceId: UUID
            if let panelArg {
                if panelArg.isEmpty {
                    result = "ERROR: Missing panel id — usage: clear_git_branch [--tab=X] [--panel=Y]"
                    return
                }
                guard let parsedId = UUID(uuidString: panelArg) else {
                    result = "ERROR: Invalid panel id '\(panelArg)'"
                    return
                }
                surfaceId = parsedId
            } else {
                guard let focused = tab.focusedPanelId else {
                    result = "ERROR: Missing panel id (no focused surface)"
                    return
                }
                surfaceId = focused
            }

            guard validSurfaceIds.contains(surfaceId) else {
                result = "ERROR: Panel not found '\(surfaceId.uuidString)'"
                return
            }

            tab.clearPanelGitBranch(panelId: surfaceId)
        }
        return result
    }

    private func reportPorts(_ args: String) -> String {
        let parsed = parseOptions(args)
        guard !parsed.positional.isEmpty else {
            return "ERROR: Missing ports — usage: report_ports <port1> [port2...] [--tab=X] [--panel=Y]"
        }
        var ports: [Int] = []
        for portStr in parsed.positional {
            guard let port = Int(portStr), port > 0, port <= 65535 else {
                return "ERROR: Invalid port '\(portStr)' — must be 1-65535"
            }
            ports.append(port)
        }
        let normalizedPorts = Array(Set(ports)).sorted()

        var result = "OK"
        DispatchQueue.main.sync {
            guard let tab = resolveTabForReport(args) else {
                result = parsed.options["tab"] != nil ? "ERROR: Tab not found" : "ERROR: No tab selected"
                return
            }

            let validSurfaceIds = Set(tab.panels.keys)
            tab.pruneSurfaceMetadata(validSurfaceIds: validSurfaceIds)

            let panelArg = parsed.options["panel"] ?? parsed.options["surface"]
            let surfaceId: UUID
            if let panelArg {
                if panelArg.isEmpty {
                    result = "ERROR: Missing panel id — usage: report_ports <port1> [port2...] [--tab=X] [--panel=Y]"
                    return
                }
                guard let parsedId = UUID(uuidString: panelArg) else {
                    result = "ERROR: Invalid panel id '\(panelArg)'"
                    return
                }
                surfaceId = parsedId
            } else {
                guard let focused = tab.focusedPanelId else {
                    result = "ERROR: Missing panel id (no focused surface)"
                    return
                }
                surfaceId = focused
            }

            guard validSurfaceIds.contains(surfaceId) else {
                result = "ERROR: Panel not found '\(surfaceId.uuidString)'"
                return
            }

            guard Self.shouldReplacePorts(current: tab.surfaceListeningPorts[surfaceId], next: normalizedPorts) else {
                return
            }

            tab.surfaceListeningPorts[surfaceId] = normalizedPorts
            tab.recomputeListeningPorts()
        }
        return result
    }

    private func reportPwd(_ args: String) -> String {
        let parsed = parseOptions(args)
        guard !parsed.positional.isEmpty else {
            return "ERROR: Missing path — usage: report_pwd <path> [--tab=X] [--panel=Y]"
        }

        let directory = Self.normalizeReportedDirectory(parsed.positional.joined(separator: " "))

        // Shell integration provides explicit UUID handles for cwd updates.
        // Keep this hot path off-main and drop no-op reports before scheduling UI work.
        if let scope = Self.explicitSocketScope(options: parsed.options) {
            guard Self.socketFastPathState.shouldPublishDirectory(
                workspaceId: scope.workspaceId,
                panelId: scope.panelId,
                directory: directory
            ) else {
                return "OK"
            }
            DispatchQueue.main.async {
                guard let tabManager = AppDelegate.shared?.tabManagerFor(tabId: scope.workspaceId) else { return }
                tabManager.updateSurfaceDirectory(tabId: scope.workspaceId, surfaceId: scope.panelId, directory: directory)
            }
            return "OK"
        }

        guard let tabManager else { return "ERROR: TabManager not available" }

        var result = "OK"
        DispatchQueue.main.sync {
            guard let tab = resolveTabForReport(args) else {
                result = parsed.options["tab"] != nil ? "ERROR: Tab not found" : "ERROR: No tab selected"
                return
            }

            let validSurfaceIds = Set(tab.panels.keys)
            tab.pruneSurfaceMetadata(validSurfaceIds: validSurfaceIds)

            let panelArg = parsed.options["panel"] ?? parsed.options["surface"]
            let surfaceId: UUID
            if let panelArg {
                if panelArg.isEmpty {
                    result = "ERROR: Missing panel id — usage: report_pwd <path> [--tab=X] [--panel=Y]"
                    return
                }
                guard let parsedId = UUID(uuidString: panelArg) else {
                    result = "ERROR: Invalid panel id '\(panelArg)'"
                    return
                }
                surfaceId = parsedId
            } else {
                guard let focused = tab.focusedPanelId else {
                    result = "ERROR: Missing panel id (no focused surface)"
                    return
                }
                surfaceId = focused
            }

            guard validSurfaceIds.contains(surfaceId) else {
                result = "ERROR: Panel not found '\(surfaceId.uuidString)'"
                return
            }

            tabManager.updateSurfaceDirectory(tabId: tab.id, surfaceId: surfaceId, directory: directory)
        }
        return result
    }

    private func clearPorts(_ args: String) -> String {
        let parsed = parseOptions(args)
        var result = "OK"
        DispatchQueue.main.sync {
            guard let tab = resolveTabForReport(args) else {
                result = parsed.options["tab"] != nil ? "ERROR: Tab not found" : "ERROR: No tab selected"
                return
            }

            let validSurfaceIds = Set(tab.panels.keys)
            tab.pruneSurfaceMetadata(validSurfaceIds: validSurfaceIds)

            let panelArg = parsed.options["panel"] ?? parsed.options["surface"]
            if let panelArg {
                if panelArg.isEmpty {
                    result = "ERROR: Missing panel id — usage: clear_ports [--tab=X] [--panel=Y]"
                    return
                }
                guard let surfaceId = UUID(uuidString: panelArg) else {
                    result = "ERROR: Invalid panel id '\(panelArg)'"
                    return
                }
                guard validSurfaceIds.contains(surfaceId) else {
                    result = "ERROR: Panel not found '\(surfaceId.uuidString)'"
                    return
                }
                if tab.surfaceListeningPorts.removeValue(forKey: surfaceId) != nil {
                    tab.recomputeListeningPorts()
                }
            } else {
                if !tab.surfaceListeningPorts.isEmpty {
                    tab.surfaceListeningPorts.removeAll()
                    tab.recomputeListeningPorts()
                }
            }
        }
        return result
    }

    private func reportTTY(_ args: String) -> String {
        let parsed = parseOptions(args)
        guard let ttyName = parsed.positional.first, !ttyName.isEmpty else {
            return "ERROR: Missing tty name — usage: report_tty <tty_name> [--tab=X] [--panel=Y]"
        }

        // Shell integration always provides explicit UUID handles.
        // Handle that common path off-main to avoid sync-hopping on every report.
        if let scope = Self.explicitSocketScope(options: parsed.options) {
            PortScanner.shared.registerTTY(
                workspaceId: scope.workspaceId,
                panelId: scope.panelId,
                ttyName: ttyName
            )
            return "OK"
        }

        var result = "OK"
        DispatchQueue.main.sync {
            guard let tab = resolveTabForReport(args) else {
                result = parsed.options["tab"] != nil ? "ERROR: Tab not found" : "ERROR: No tab selected"
                return
            }

            let panelArg = parsed.options["panel"] ?? parsed.options["surface"]
            let surfaceId: UUID
            if let panelArg {
                if panelArg.isEmpty {
                    result = "ERROR: Missing panel id — usage: report_tty <tty_name> [--tab=X] [--panel=Y]"
                    return
                }
                guard let parsedId = UUID(uuidString: panelArg) else {
                    result = "ERROR: Invalid panel id '\(panelArg)'"
                    return
                }
                surfaceId = parsedId
            } else {
                guard let focused = tab.focusedPanelId else {
                    result = "ERROR: Missing panel id (no focused surface)"
                    return
                }
                surfaceId = focused
            }

            let validSurfaceIds = Set(tab.panels.keys)
            guard validSurfaceIds.contains(surfaceId) else {
                result = "ERROR: Panel not found '\(surfaceId.uuidString)'"
                return
            }

            guard tab.surfaceTTYNames[surfaceId] != ttyName else { return }
            tab.surfaceTTYNames[surfaceId] = ttyName
            PortScanner.shared.registerTTY(workspaceId: tab.id, panelId: surfaceId, ttyName: ttyName)
        }
        return result
    }

    private func portsKick(_ args: String) -> String {
        let parsed = parseOptions(args)

        // Shell integration always provides explicit UUID handles.
        // Handle that common path off-main to keep prompt hooks from blocking UI work.
        if let scope = Self.explicitSocketScope(options: parsed.options) {
            PortScanner.shared.kick(workspaceId: scope.workspaceId, panelId: scope.panelId)
            return "OK"
        }

        var result = "OK"
        DispatchQueue.main.sync {
            guard let tab = resolveTabForReport(args) else {
                result = parsed.options["tab"] != nil ? "ERROR: Tab not found" : "ERROR: No tab selected"
                return
            }

            let panelArg = parsed.options["panel"] ?? parsed.options["surface"]
            let surfaceId: UUID
            if let panelArg {
                if panelArg.isEmpty {
                    result = "ERROR: Missing panel id — usage: ports_kick [--tab=X] [--panel=Y]"
                    return
                }
                guard let parsedId = UUID(uuidString: panelArg) else {
                    result = "ERROR: Invalid panel id '\(panelArg)'"
                    return
                }
                surfaceId = parsedId
            } else {
                guard let focused = tab.focusedPanelId else {
                    result = "ERROR: Missing panel id (no focused surface)"
                    return
                }
                surfaceId = focused
            }

            PortScanner.shared.kick(workspaceId: tab.id, panelId: surfaceId)
        }
        return result
    }

    private func sidebarState(_ args: String) -> String {
        var result = ""
        DispatchQueue.main.sync {
            guard let tab = resolveTabForReport(args) else {
                result = "ERROR: Tab not found"
                return
            }

            var lines: [String] = []
            lines.append("tab=\(tab.id.uuidString)")
            lines.append("cwd=\(tab.currentDirectory)")

            if let focused = tab.focusedPanelId,
               let focusedDir = tab.panelDirectories[focused] {
                lines.append("focused_cwd=\(focusedDir)")
                lines.append("focused_panel=\(focused.uuidString)")
            } else {
                lines.append("focused_cwd=unknown")
                lines.append("focused_panel=unknown")
            }

            if let git = tab.gitBranch {
                lines.append("git_branch=\(git.branch)\(git.isDirty ? " dirty" : " clean")")
            } else {
                lines.append("git_branch=none")
            }

            if tab.listeningPorts.isEmpty {
                lines.append("ports=none")
            } else {
                lines.append("ports=\(tab.listeningPorts.map(String.init).joined(separator: ","))")
            }

            if let progress = tab.progress {
                let label = progress.label ?? ""
                lines.append("progress=\(String(format: "%.2f", progress.value)) \(label)".trimmingCharacters(in: .whitespaces))
            } else {
                lines.append("progress=none")
            }

            lines.append("status_count=\(tab.statusEntries.count)")
            for entry in tab.statusEntries.values.sorted(by: { $0.key < $1.key }) {
                var line = "  \(entry.key)=\(entry.value)"
                if let icon = entry.icon { line += " icon=\(icon)" }
                if let color = entry.color { line += " color=\(color)" }
                lines.append(line)
            }

            lines.append("log_count=\(tab.logEntries.count)")
            for entry in tab.logEntries.suffix(5) {
                lines.append("  [\(entry.level.rawValue)] \(entry.message)")
            }

            result = lines.joined(separator: "\n")
        }
        return result
    }

    private func resetSidebar(_ args: String) -> String {
        var result = "OK"
        DispatchQueue.main.sync {
            guard let tab = resolveTabForReport(args) else {
                result = "ERROR: Tab not found"
                return
            }
            tab.statusEntries.removeAll()
            tab.logEntries.removeAll()
            tab.progress = nil
            tab.gitBranch = nil
            tab.panelGitBranches.removeAll()
            tab.surfaceListeningPorts.removeAll()
            tab.listeningPorts.removeAll()
        }
        return result
    }

    private func refreshSurfaces() -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        var refreshedCount = 0
        DispatchQueue.main.sync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
                return
            }

            // Force-refresh all terminal panels in current tab
            // (resets cached metrics so the Metal layer drawable resizes correctly)
            for panel in tab.panels.values {
                if let terminalPanel = panel as? TerminalPanel {
                    terminalPanel.surface.forceRefresh()
                    refreshedCount += 1
                }
            }
        }
        return "OK Refreshed \(refreshedCount) surfaces"
    }

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

    private func surfaceHealth(_ tabArg: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }
        var result = ""
        DispatchQueue.main.sync {
            guard let tab = resolveTab(from: tabArg, tabManager: tabManager) else {
                result = "ERROR: Tab not found"
                return
            }
            let panels = orderedPanels(in: tab)
            let lines = panels.enumerated().map { index, panel -> String in
                let panelId = panel.id.uuidString
                let type = panel.panelType.rawValue
                if let tp = panel as? TerminalPanel {
                    let inWindow = tp.surface.isViewInWindow
                    let portalHosted = isPortalHosted(tp.hostedView)
                    let depth = viewDepth(of: tp.hostedView)
                    return "\(index): \(panelId) type=\(type) in_window=\(inWindow) portal=\(portalHosted) view_depth=\(depth)"
                } else if let bp = panel as? BrowserPanel {
                    let inWindow = bp.webView.window != nil
                    return "\(index): \(panelId) type=\(type) in_window=\(inWindow)"
                } else {
                    return "\(index): \(panelId) type=\(type) in_window=unknown"
                }
            }
            result = lines.isEmpty ? "No surfaces" : lines.joined(separator: "\n")
        }
        return result
    }

    private func closeSurface(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)

        var result = "ERROR: Failed to close surface"
        DispatchQueue.main.sync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
                return
            }

            // Resolve surface ID from argument or use focused
            let surfaceId: UUID?
            if trimmed.isEmpty {
                surfaceId = tab.focusedPanelId
            } else {
                surfaceId = resolveSurfaceId(from: trimmed, tab: tab)
            }

            guard let targetSurfaceId = surfaceId else {
                result = "ERROR: Surface not found"
                return
            }

            // Don't close if it's the only surface
            if tab.panels.count <= 1 {
                result = "ERROR: Cannot close the last surface"
                return
            }

            // Socket commands must be non-interactive: bypass close-confirmation gating.
            tab.closePanel(targetSurfaceId, force: true)
            result = "OK"
        }
        return result
    }

    private func newSurface(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        // Parse arguments: --type=terminal|browser --pane=<pane_id> --url=...
        var panelType: PanelType = .terminal
        var paneArg: String? = nil
        var url: URL? = nil
        let shouldFocus = socketCommandAllowsInAppFocusMutations()

        let parts = args.split(separator: " ")
        for part in parts {
            let partStr = String(part)
            if partStr.hasPrefix("--type=") {
                let typeStr = String(partStr.dropFirst(7))
                panelType = typeStr == "browser" ? .browser : .terminal
            } else if partStr.hasPrefix("--pane=") {
                paneArg = String(partStr.dropFirst(7))
            } else if partStr.hasPrefix("--url=") {
                let urlStr = String(partStr.dropFirst(6))
                url = URL(string: urlStr)
            }
        }

        var result = "ERROR: Failed to create tab"
        DispatchQueue.main.sync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
                return
            }

            // Get target pane
            let paneId: PaneID?
            let paneIds = tab.bonsplitController.allPaneIds
            if let paneArg {
                if let uuid = UUID(uuidString: paneArg) {
                    paneId = paneIds.first(where: { $0.id == uuid })
                } else if let idx = Int(paneArg), idx >= 0, idx < paneIds.count {
                    paneId = paneIds[idx]
                } else {
                    paneId = nil
                }
            } else {
                paneId = tab.bonsplitController.focusedPaneId
            }

            guard let targetPaneId = paneId else {
                result = "ERROR: Pane not found"
                return
            }

            let newPanelId: UUID?
            if panelType == .browser {
                newPanelId = tab.newBrowserSurface(inPane: targetPaneId, url: url, focus: shouldFocus)?.id
            } else {
                newPanelId = tab.newTerminalSurface(inPane: targetPaneId, focus: shouldFocus)?.id
            }

            if let id = newPanelId {
                result = "OK \(id.uuidString)"
            }
        }
        return result
    }

    deinit {
        stop()
    }
}

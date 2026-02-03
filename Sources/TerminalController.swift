import AppKit
import Carbon.HIToolbox
import Foundation

/// Unix socket-based controller for programmatic terminal control
/// Allows automated testing and external control of terminal tabs
class TerminalController {
    static let shared = TerminalController()

    private var socketPath = "/tmp/cmuxterm.sock"
    private var serverSocket: Int32 = -1
    private var isRunning = false
    private var clientHandlers: [Int32: Thread] = [:]
    private weak var tabManager: TabManager?
    private var accessMode: SocketControlMode = .full

    private init() {}

    func start(tabManager: TabManager, socketPath: String, accessMode: SocketControlMode) {
        self.tabManager = tabManager
        self.accessMode = accessMode

        if isRunning {
            if self.socketPath == socketPath {
                self.accessMode = accessMode
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

        // Listen
        guard listen(serverSocket, 5) >= 0 else {
            print("TerminalController: Failed to listen on socket")
            close(serverSocket)
            return
        }

        isRunning = true
        print("TerminalController: Listening on \(socketPath)")

        // Accept connections in background thread
        Thread.detachNewThread { [weak self] in
            self?.acceptLoop()
        }
    }

    func stop() {
        isRunning = false
        if serverSocket >= 0 {
            close(serverSocket)
            serverSocket = -1
        }
        unlink(socketPath)
    }

    private func acceptLoop() {
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
                    print("TerminalController: Accept failed")
                }
                continue
            }

            // Handle client in new thread
            Thread.detachNewThread { [weak self] in
                self?.handleClient(clientSocket)
            }
        }
    }

    private func handleClient(_ socket: Int32) {
        defer { close(socket) }

        var buffer = [UInt8](repeating: 0, count: 4096)
        var pending = ""

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

                let response = processCommand(trimmed)
                let payload = response + "\n"
                payload.withCString { ptr in
                    _ = write(socket, ptr, strlen(ptr))
                }
            }
        }
    }

    private func processCommand(_ command: String) -> String {
        let parts = command.split(separator: " ", maxSplits: 1).map(String.init)
        guard !parts.isEmpty else { return "ERROR: Empty command" }

        let cmd = parts[0].lowercased()
        let args = parts.count > 1 ? parts[1] : ""
        if !isCommandAllowed(cmd) {
            return "ERROR: Command disabled by socket access mode"
        }

        switch cmd {
        case "ping":
            return "PONG"

        case "list_tabs":
            return listTabs()

        case "new_tab":
            return newTab()

        case "new_split":
            return newSplit(args)

        case "list_surfaces":
            return listSurfaces(args)

        case "focus_surface":
            return focusSurface(args)

        case "close_tab":
            return closeTab(args)

        case "select_tab":
            return selectTab(args)

        case "current_tab":
            return currentTab()

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

#if DEBUG
        case "focus_notification":
            return focusFromNotification(args)

        case "flash_count":
            return flashCount(args)

        case "reset_flash_counts":
            return resetFlashCounts()
#endif

        case "help":
            return helpText()

        default:
            return "ERROR: Unknown command '\(cmd)'. Use 'help' for available commands."
        }
    }

    private func helpText() -> String {
        var text = """
        Available commands:
          ping                    - Check if server is running
          list_tabs               - List all tabs with IDs
          new_tab                 - Create a new tab
          new_split <direction>   - Split focused surface (left/right/up/down)
          list_surfaces [tab]     - List surfaces for tab (current tab if omitted)
          focus_surface <id|idx>  - Focus surface by ID or index (current tab)
          close_tab <id>          - Close tab by ID
          select_tab <id|index>   - Select tab by ID or index (0-based)
          current_tab             - Get current tab ID
          send <text>             - Send text to current tab
          send_key <key>          - Send special key (ctrl-c, ctrl-d, enter, tab, escape)
          send_surface <id|idx> <text> - Send text to a surface in current tab
          send_key_surface <id|idx> <key> - Send special key to a surface in current tab
          notify <title>|<subtitle>|<body>   - Create a notification for the focused surface
          notify_surface <id|idx> <title>|<subtitle>|<body> - Create a notification for a surface
          notify_target <tabId> <panelId> <title>|<subtitle>|<body> - Notify a specific panel
          list_notifications      - List all notifications
          clear_notifications     - Clear all notifications
          set_app_focus <active|inactive|clear> - Override app focus state
          simulate_app_active     - Trigger app active handler
          help                    - Show this help
        """
#if DEBUG
        text += """

          focus_notification <tab|idx> [surface|idx] - Focus via notification flow
          flash_count <id|idx>    - Read flash count for a surface
          reset_flash_counts      - Reset flash counters
        """
#endif
        return text
    }

    private func isCommandAllowed(_ command: String) -> Bool {
        switch accessMode {
        case .full:
            return true
        case .notifications:
            let allowed: Set<String> = [
                "ping",
                "help",
                "notify",
                "notify_surface",
                "notify_target",
                "list_notifications",
                "clear_notifications"
            ]
            return allowed.contains(command)
        case .off:
            return false
        }
    }

    private func listTabs() -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        var result: String = ""
        DispatchQueue.main.sync {
            let tabs = tabManager.tabs.enumerated().map { (index, tab) in
                let selected = tab.id == tabManager.selectedTabId ? "*" : " "
                return "\(selected) \(index): \(tab.id.uuidString) \(tab.title)"
            }
            result = tabs.joined(separator: "\n")
        }
        return result.isEmpty ? "No tabs" : result
    }

    private func newTab() -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        var newTabId: UUID?
        DispatchQueue.main.sync {
            _ = tabManager.addDefaultTab()
            newTabId = tabManager.selectedTabId
        }
        return "OK \(newTabId?.uuidString ?? "unknown")"
    }

    private func newSplit(_ directionArg: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        let trimmed = directionArg.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let direction = parseSplitDirection(trimmed) else {
            return "ERROR: Invalid direction. Use left, right, up, or down."
        }

        var success = false
        DispatchQueue.main.sync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }),
                  let surfaceId = tab.focusedSurfaceId else {
                return
            }
            success = tabManager.newSplit(tabId: tabId, surfaceId: surfaceId, direction: direction)
        }
        return success ? "OK" : "ERROR: Failed to create split"
    }

    private func listSurfaces(_ tabArg: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }
        var result = ""
        DispatchQueue.main.sync {
            guard let tab = resolveTab(from: tabArg, tabManager: tabManager) else {
                result = "ERROR: Tab not found"
                return
            }
            let surfaces = tab.splitTree.root?.leaves() ?? []
            let focusedId = tab.focusedSurfaceId
            let lines = surfaces.enumerated().map { index, surface in
                let selected = surface.id == focusedId ? "*" : " "
                return "\(selected) \(index): \(surface.id.uuidString)"
            }
            result = lines.isEmpty ? "No surfaces" : lines.joined(separator: "\n")
        }
        return result
    }

    private func focusSurface(_ arg: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }
        let trimmed = arg.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "ERROR: Missing surface id or index" }

        var success = false
        DispatchQueue.main.sync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
                return
            }

            if let uuid = UUID(uuidString: trimmed),
               tab.surface(for: uuid) != nil {
                tabManager.focusSurface(tabId: tab.id, surfaceId: uuid)
                success = true
                return
            }

            if let index = Int(trimmed), index >= 0 {
                let surfaces = tab.splitTree.root?.leaves() ?? []
                guard index < surfaces.count else { return }
                tabManager.focusSurface(tabId: tab.id, surfaceId: surfaces[index].id)
                success = true
            }
        }

        return success ? "OK" : "ERROR: Surface not found"
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
        guard !trimmed.isEmpty else { return "ERROR: Usage: notify_target <tabId> <panelId> <title>|<subtitle>|<body>" }

        let parts = trimmed.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return "ERROR: Usage: notify_target <tabId> <panelId> <title>|<subtitle>|<body>" }

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
                  tab.surface(for: panelId) != nil else {
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
#endif

    private func parseSplitDirection(_ value: String) -> SplitTree<TerminalSurface>.NewDirection? {
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

    private func resolveSurface(from arg: String, tabManager: TabManager) -> ghostty_surface_t? {
        guard let tabId = tabManager.selectedTabId,
              let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
            return nil
        }

        if let uuid = UUID(uuidString: arg),
           let surface = tab.surface(for: uuid)?.surface {
            return surface
        }

        if let index = Int(arg), index >= 0 {
            let surfaces = tab.splitTree.root?.leaves() ?? []
            guard index < surfaces.count else { return nil }
            return surfaces[index].surface
        }

        return nil
    }

    private func resolveSurfaceId(from arg: String, tab: Tab) -> UUID? {
        if let uuid = UUID(uuidString: arg), tab.surface(for: uuid) != nil {
            return uuid
        }

        if let index = Int(arg), index >= 0 {
            let surfaces = tab.splitTree.root?.leaves() ?? []
            guard index < surfaces.count else { return nil }
            return surfaces[index].id
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

    private func closeTab(_ tabId: String) -> String {
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

    private func selectTab(_ arg: String) -> String {
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

    private func currentTab() -> String {
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
        DispatchQueue.main.sync {
            guard let selectedId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == selectedId }),
                  let surface = tab.focusedSurface?.surface else {
                return
            }

            // Unescape common escape sequences
            // Note: \n is converted to \r for terminal (Enter key sends \r)
            let unescaped = text
                .replacingOccurrences(of: "\\n", with: "\r")
                .replacingOccurrences(of: "\\r", with: "\r")
                .replacingOccurrences(of: "\\t", with: "\t")

            for char in unescaped {
                if char.unicodeScalars.count == 1,
                   let scalar = char.unicodeScalars.first,
                   handleControlScalar(scalar, surface: surface) {
                    continue
                }
                sendTextEvent(surface: surface, text: String(char))
            }
            success = true
        }
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
            guard let surface = resolveSurface(from: target, tabManager: tabManager) else { return }

            let unescaped = text
                .replacingOccurrences(of: "\\n", with: "\r")
                .replacingOccurrences(of: "\\r", with: "\r")
                .replacingOccurrences(of: "\\t", with: "\t")

            for char in unescaped {
                if char.unicodeScalars.count == 1,
                   let scalar = char.unicodeScalars.first,
                   handleControlScalar(scalar, surface: surface) {
                    continue
                }
                sendTextEvent(surface: surface, text: String(char))
            }
            success = true
        }

        return success ? "OK" : "ERROR: Failed to send input"
    }

    private func sendKey(_ keyName: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        var success = false
        DispatchQueue.main.sync {
            guard let selectedId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == selectedId }),
                  let surface = tab.focusedSurface?.surface else {
                return
            }

            success = sendNamedKey(surface, keyName: keyName)
        }
        return success ? "OK" : "ERROR: Unknown key '\(keyName)'"
    }

    private func sendKeyToSurface(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }
        let parts = args.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return "ERROR: Usage: send_key_surface <id|idx> <key>" }

        let target = parts[0]
        let keyName = parts[1]

        var success = false
        DispatchQueue.main.sync {
            guard let surface = resolveSurface(from: target, tabManager: tabManager) else { return }
            success = sendNamedKey(surface, keyName: keyName)
        }

        return success ? "OK" : "ERROR: Unknown key '\(keyName)'"
    }

    deinit {
        stop()
    }
}

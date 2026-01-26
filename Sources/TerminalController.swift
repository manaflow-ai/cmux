import Foundation

/// Unix socket-based controller for programmatic terminal control
/// Allows automated testing and external control of terminal tabs
class TerminalController {
    static let shared = TerminalController()

    private let socketPath = "/tmp/cmux.sock"
    private var serverSocket: Int32 = -1
    private var isRunning = false
    private var clientHandlers: [Int32: Thread] = [:]
    private weak var tabManager: TabManager?

    private init() {}

    func start(tabManager: TabManager) {
        self.tabManager = tabManager

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

        while isRunning {
            let bytesRead = read(socket, &buffer, buffer.count - 1)
            guard bytesRead > 0 else { break }

            buffer[bytesRead] = 0
            let command = String(cString: buffer)
            let response = processCommand(command.trimmingCharacters(in: .whitespacesAndNewlines))

            response.withCString { ptr in
                _ = write(socket, ptr, strlen(ptr))
            }
            "\n".withCString { ptr in
                _ = write(socket, ptr, 1)
            }
        }
    }

    private func processCommand(_ command: String) -> String {
        let parts = command.split(separator: " ", maxSplits: 1).map(String.init)
        guard !parts.isEmpty else { return "ERROR: Empty command" }

        let cmd = parts[0].lowercased()
        let args = parts.count > 1 ? parts[1] : ""

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

        case "help":
            return helpText()

        default:
            return "ERROR: Unknown command '\(cmd)'. Use 'help' for available commands."
        }
    }

    private func helpText() -> String {
        return """
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
          help                    - Show this help
        """
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
            tabManager.addTab()
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

            // Send each character as a key event (like typing)
            for char in unescaped {
                String(char).withCString { ptr in
                    var keyEvent = ghostty_input_key_s()
                    keyEvent.action = GHOSTTY_ACTION_PRESS
                    keyEvent.keycode = 0
                    keyEvent.mods = GHOSTTY_MODS_NONE
                    keyEvent.consumed_mods = GHOSTTY_MODS_NONE
                    keyEvent.text = ptr
                    keyEvent.composing = false
                    _ = ghostty_surface_key(surface, keyEvent)
                }
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
                String(char).withCString { ptr in
                    var keyEvent = ghostty_input_key_s()
                    keyEvent.action = GHOSTTY_ACTION_PRESS
                    keyEvent.keycode = 0
                    keyEvent.mods = GHOSTTY_MODS_NONE
                    keyEvent.consumed_mods = GHOSTTY_MODS_NONE
                    keyEvent.text = ptr
                    keyEvent.composing = false
                    _ = ghostty_surface_key(surface, keyEvent)
                }
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

            // Helper to send a key event with text
            func sendKeyEvent(text: String, mods: ghostty_input_mods_e = GHOSTTY_MODS_NONE) {
                text.withCString { ptr in
                    var keyEvent = ghostty_input_key_s()
                    keyEvent.action = GHOSTTY_ACTION_PRESS
                    keyEvent.keycode = 0
                    keyEvent.mods = mods
                    keyEvent.consumed_mods = GHOSTTY_MODS_NONE
                    keyEvent.text = ptr
                    keyEvent.composing = false
                    _ = ghostty_surface_key(surface, keyEvent)
                }
            }

            switch keyName.lowercased() {
            case "ctrl-c", "ctrl+c", "sigint":
                // Send Ctrl+C - the control character 0x03 (ETX)
                // Note: We send the raw control character, which the terminal
                // interprets as an interrupt signal
                sendKeyEvent(text: "\u{03}")
                success = true

            case "ctrl-d", "ctrl+d", "eof":
                // Send Ctrl+D - the control character 0x04 (EOT)
                sendKeyEvent(text: "\u{04}")
                success = true

            case "ctrl-z", "ctrl+z", "sigtstp":
                // Send Ctrl+Z - the control character 0x1A (SUB)
                sendKeyEvent(text: "\u{1A}")
                success = true

            case "ctrl-\\", "ctrl+\\", "sigquit":
                // Send Ctrl+\ - the control character 0x1C (FS)
                sendKeyEvent(text: "\u{1C}")
                success = true

            case "enter", "return":
                sendKeyEvent(text: "\r")
                success = true

            case "tab":
                sendKeyEvent(text: "\t")
                success = true

            case "escape", "esc":
                sendKeyEvent(text: "\u{1B}")
                success = true

            case "backspace":
                sendKeyEvent(text: "\u{7F}")
                success = true

            default:
                // Check for ctrl-<letter> pattern
                if keyName.lowercased().hasPrefix("ctrl-") || keyName.lowercased().hasPrefix("ctrl+") {
                    let letter = keyName.dropFirst(5).lowercased()
                    if letter.count == 1, let char = letter.first, char.isLetter {
                        // Convert letter to control character (a=1, b=2, ..., z=26)
                        let ctrlCode = UInt8(char.asciiValue! - Character("a").asciiValue! + 1)
                        let ctrlChar = String(UnicodeScalar(ctrlCode))
                        sendKeyEvent(text: ctrlChar)
                        success = true
                    }
                }
            }
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

            func sendKeyEvent(text: String, mods: ghostty_input_mods_e = GHOSTTY_MODS_NONE) {
                text.withCString { ptr in
                    var keyEvent = ghostty_input_key_s()
                    keyEvent.action = GHOSTTY_ACTION_PRESS
                    keyEvent.keycode = 0
                    keyEvent.mods = mods
                    keyEvent.consumed_mods = GHOSTTY_MODS_NONE
                    keyEvent.text = ptr
                    keyEvent.composing = false
                    _ = ghostty_surface_key(surface, keyEvent)
                }
            }

            switch keyName.lowercased() {
            case "ctrl-c", "ctrl+c", "sigint":
                sendKeyEvent(text: "\u{03}")
                success = true
            case "ctrl-d", "ctrl+d", "eof":
                sendKeyEvent(text: "\u{04}")
                success = true
            case "ctrl-z", "ctrl+z", "sigtstp":
                sendKeyEvent(text: "\u{1A}")
                success = true
            case "ctrl-\\", "ctrl+\\", "sigquit":
                sendKeyEvent(text: "\u{1C}")
                success = true
            case "enter", "return":
                sendKeyEvent(text: "\r")
                success = true
            case "tab":
                sendKeyEvent(text: "\t")
                success = true
            case "escape", "esc":
                sendKeyEvent(text: "\u{1B}")
                success = true
            case "backspace":
                sendKeyEvent(text: "\u{7F}")
                success = true
            default:
                if keyName.lowercased().hasPrefix("ctrl-") || keyName.lowercased().hasPrefix("ctrl+") {
                    let letter = keyName.dropFirst(5).lowercased()
                    if letter.count == 1, let char = letter.first, char.isLetter {
                        let ctrlCode = UInt8(char.asciiValue! - Character("a").asciiValue! + 1)
                        let ctrlChar = String(UnicodeScalar(ctrlCode))
                        sendKeyEvent(text: ctrlChar)
                        success = true
                    }
                }
            }
        }

        return success ? "OK" : "ERROR: Failed to send key"
    }

    deinit {
        stop()
    }
}

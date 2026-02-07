import Foundation
import Darwin

struct CLIError: Error, CustomStringConvertible {
    let message: String

    var description: String { message }
}

struct TabInfo {
    let index: Int
    let id: String
    let title: String
    let selected: Bool
}

struct PanelInfo {
    let index: Int
    let id: String
    let focused: Bool
}

struct NotificationInfo {
    let id: String
    let tabId: String
    let panelId: String?
    let isRead: Bool
    let title: String
    let subtitle: String
    let body: String
}

final class SocketClient {
    private let path: String
    private var socketFD: Int32 = -1

    init(path: String) {
        self.path = path
    }

    func connect() throws {
        if socketFD >= 0 { return }
        socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        if socketFD < 0 {
            throw CLIError(message: "Failed to create socket")
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLength = MemoryLayout.size(ofValue: addr.sun_path)
        path.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                let buf = UnsafeMutableRawPointer(pathPtr).assumingMemoryBound(to: CChar.self)
                strncpy(buf, ptr, maxLength - 1)
            }
        }

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(socketFD, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result != 0 {
            Darwin.close(socketFD)
            socketFD = -1
            throw CLIError(message: "Failed to connect to socket at \(path)")
        }
    }

    func close() {
        if socketFD >= 0 {
            Darwin.close(socketFD)
            socketFD = -1
        }
    }

    func send(command: String) throws -> String {
        guard socketFD >= 0 else { throw CLIError(message: "Not connected") }
        let payload = command + "\n"
        try payload.withCString { ptr in
            let sent = Darwin.write(socketFD, ptr, strlen(ptr))
            if sent < 0 {
                throw CLIError(message: "Failed to write to socket")
            }
        }

        var data = Data()
        var sawNewline = false
        let start = Date()

        while true {
            var pollFD = pollfd(fd: socketFD, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pollFD, 1, 100)
            if ready < 0 {
                throw CLIError(message: "Socket read error")
            }
            if ready == 0 {
                if sawNewline {
                    break
                }
                if Date().timeIntervalSince(start) > 5.0 {
                    throw CLIError(message: "Command timed out")
                }
                continue
            }

            var buffer = [UInt8](repeating: 0, count: 8192)
            let count = Darwin.read(socketFD, &buffer, buffer.count)
            if count <= 0 {
                break
            }
            data.append(buffer, count: count)
            if data.contains(UInt8(0x0A)) {
                sawNewline = true
            }
        }

        guard var response = String(data: data, encoding: .utf8) else {
            throw CLIError(message: "Invalid UTF-8 response")
        }
        if response.hasSuffix("\n") {
            response.removeLast()
        }
        return response
    }
}

struct CMUXCLI {
    let args: [String]

    func run() throws {
        var socketPath = ProcessInfo.processInfo.environment["CMUX_SOCKET_PATH"] ?? "/tmp/cmuxterm.sock"
        var jsonOutput = false

        var index = 1
        while index < args.count {
            let arg = args[index]
            if arg == "--socket" {
                guard index + 1 < args.count else {
                    throw CLIError(message: "--socket requires a path")
                }
                socketPath = args[index + 1]
                index += 2
                continue
            }
            if arg == "--json" {
                jsonOutput = true
                index += 1
                continue
            }
            if arg == "-h" || arg == "--help" {
                print(usage())
                return
            }
            break
        }

        guard index < args.count else {
            print(usage())
            throw CLIError(message: "Missing command")
        }

        let command = args[index]
        let commandArgs = Array(args[(index + 1)...])

        let client = SocketClient(path: socketPath)
        try client.connect()
        defer { client.close() }

        switch command {
        case "ping":
            let response = try client.send(command: "ping")
            print(response)

        case "list-tabs":
            let response = try client.send(command: "list_tabs")
            if jsonOutput {
                let tabs = parseTabs(response)
                let payload = tabs.map { [
                    "index": $0.index,
                    "id": $0.id,
                    "title": $0.title,
                    "selected": $0.selected
                ] }
                print(jsonString(payload))
            } else {
                print(response)
            }

        case "new-tab":
            let response = try client.send(command: "new_tab")
            print(response)

        case "new-split":
            let (panelArg, remaining) = parseOption(commandArgs, name: "--panel")
            guard let direction = remaining.first else {
                throw CLIError(message: "new-split requires a direction")
            }
            let cmd = panelArg != nil ? "new_split \(direction) \(panelArg!)" : "new_split \(direction)"
            let response = try client.send(command: cmd)
            print(response)

        case "list-panels":
            let (tabArg, _) = parseOption(commandArgs, name: "--tab")
            let response = try client.send(command: "list_surfaces \(tabArg ?? "")".trimmingCharacters(in: .whitespaces))
            if jsonOutput {
                let panels = parsePanels(response)
                let payload = panels.map { [
                    "index": $0.index,
                    "id": $0.id,
                    "focused": $0.focused
                ] }
                print(jsonString(payload))
            } else {
                print(response)
            }

        case "focus-panel":
            guard let panel = optionValue(commandArgs, name: "--panel") else {
                throw CLIError(message: "focus-panel requires --panel")
            }
            let response = try client.send(command: "focus_surface \(panel)")
            print(response)

        case "close-tab":
            guard let tab = optionValue(commandArgs, name: "--tab") else {
                throw CLIError(message: "close-tab requires --tab")
            }
            let tabId = try resolveTabId(tab, client: client)
            let response = try client.send(command: "close_tab \(tabId)")
            print(response)

        case "select-tab":
            guard let tab = optionValue(commandArgs, name: "--tab") else {
                throw CLIError(message: "select-tab requires --tab")
            }
            let response = try client.send(command: "select_tab \(tab)")
            print(response)

        case "current-tab":
            let response = try client.send(command: "current_tab")
            if jsonOutput {
                print(jsonString(["tab_id": response]))
            } else {
                print(response)
            }

        case "send":
            let text = commandArgs.joined(separator: " ")
            guard !text.isEmpty else { throw CLIError(message: "send requires text") }
            let escaped = escapeText(text)
            let response = try client.send(command: "send \(escaped)")
            print(response)

        case "send-key":
            guard let key = commandArgs.first else { throw CLIError(message: "send-key requires a key") }
            let response = try client.send(command: "send_key \(key)")
            print(response)

        case "send-panel":
            guard let panel = optionValue(commandArgs, name: "--panel") else {
                throw CLIError(message: "send-panel requires --panel")
            }
            let text = remainingArgs(commandArgs, removing: ["--panel", panel]).joined(separator: " ")
            guard !text.isEmpty else { throw CLIError(message: "send-panel requires text") }
            let escaped = escapeText(text)
            let response = try client.send(command: "send_surface \(panel) \(escaped)")
            print(response)

        case "send-key-panel":
            guard let panel = optionValue(commandArgs, name: "--panel") else {
                throw CLIError(message: "send-key-panel requires --panel")
            }
            let key = remainingArgs(commandArgs, removing: ["--panel", panel]).first ?? ""
            guard !key.isEmpty else { throw CLIError(message: "send-key-panel requires a key") }
            let response = try client.send(command: "send_key_surface \(panel) \(key)")
            print(response)

        case "notify":
            let title = optionValue(commandArgs, name: "--title") ?? "Notification"
            let subtitle = optionValue(commandArgs, name: "--subtitle") ?? ""
            let body = optionValue(commandArgs, name: "--body") ?? ""

            let tabArg = optionValue(commandArgs, name: "--tab") ?? ProcessInfo.processInfo.environment["CMUX_TAB_ID"]
            let panelArg = optionValue(commandArgs, name: "--panel") ?? ProcessInfo.processInfo.environment["CMUX_PANEL_ID"]

            let targetTab = try resolveTabId(tabArg, client: client)
            let targetPanel = try resolvePanelId(panelArg, tabId: targetTab, client: client)

            let payload = "\(title)|\(subtitle)|\(body)"
            let response = try client.send(command: "notify_target \(targetTab) \(targetPanel) \(payload)")
            print(response)

        case "list-notifications":
            let response = try client.send(command: "list_notifications")
            if jsonOutput {
                let notifications = parseNotifications(response)
                let payload = notifications.map { item in
                    var dict: [String: Any] = [
                        "id": item.id,
                        "tab_id": item.tabId,
                        "is_read": item.isRead,
                        "title": item.title,
                        "subtitle": item.subtitle,
                        "body": item.body
                    ]
                    dict["panel_id"] = item.panelId ?? NSNull()
                    return dict
                }
                print(jsonString(payload))
            } else {
                print(response)
            }

        case "clear-notifications":
            let response = try client.send(command: "clear_notifications")
            print(response)

        case "set-app-focus":
            guard let value = commandArgs.first else { throw CLIError(message: "set-app-focus requires a value") }
            let response = try client.send(command: "set_app_focus \(value)")
            print(response)

        case "simulate-app-active":
            let response = try client.send(command: "simulate_app_active")
            print(response)

        case "set-status":
            guard commandArgs.count >= 2 else {
                throw CLIError(message: "set-status requires <key> <value>")
            }
            let key = commandArgs[0]
            let value = commandArgs[1]
            let icon = optionValue(commandArgs, name: "--icon")
            let color = optionValue(commandArgs, name: "--color")
            let tabArg = optionValue(commandArgs, name: "--tab") ?? ProcessInfo.processInfo.environment["CMUX_TAB_ID"]
            var cmd = "set_status \(key) \(value)"
            if let icon { cmd += " --icon=\(icon)" }
            if let color { cmd += " --color=\(color)" }
            if let tabArg { cmd += " --tab=\(tabArg)" }
            let response = try client.send(command: cmd)
            print(response)

        case "clear-status":
            let key = commandArgs.first
            guard let key else {
                throw CLIError(message: "clear-status requires <key>")
            }
            let tabArg = optionValue(commandArgs, name: "--tab") ?? ProcessInfo.processInfo.environment["CMUX_TAB_ID"]
            var cmd = "clear_status \(key)"
            if let tabArg { cmd += " --tab=\(tabArg)" }
            let response = try client.send(command: cmd)
            print(response)

	        case "log":
	            // Remove options by position (flag + following value), not by string value,
	            // so message tokens that happen to equal an option value aren't dropped.
	            let (level, argsWithoutLevel) = parseOption(commandArgs, name: "--level")
	            let (source, argsWithoutSource) = parseOption(argsWithoutLevel, name: "--source")
	            let (explicitTab, remaining) = parseOption(argsWithoutSource, name: "--tab")
	            let tabArg = explicitTab ?? ProcessInfo.processInfo.environment["CMUX_TAB_ID"]
	            let message = remaining.joined(separator: " ")
	            guard !message.isEmpty else { throw CLIError(message: "log requires a message") }
	            // TerminalController.parseOptions treats any --* token as an option until a
	            // `--` separator. Options must come before the message to preserve arbitrary
	            // message contents (including tokens like `--force`).
	            var cmd = "log"
	            if let level { cmd += " --level=\(level)" }
	            if let source { cmd += " --source=\(source)" }
	            if let tabArg { cmd += " --tab=\(tabArg)" }
	            cmd += " -- \(quoteOptionValue(message))"
	            let response = try client.send(command: cmd)
	            print(response)

        case "clear-log":
            let tabArg = optionValue(commandArgs, name: "--tab") ?? ProcessInfo.processInfo.environment["CMUX_TAB_ID"]
            var cmd = "clear_log"
            if let tabArg { cmd += " --tab=\(tabArg)" }
            let response = try client.send(command: cmd)
            print(response)

        case "set-progress":
            guard let value = commandArgs.first else {
                throw CLIError(message: "set-progress requires a value (0.0-1.0)")
            }
            let label = optionValue(commandArgs, name: "--label")
            let tabArg = optionValue(commandArgs, name: "--tab") ?? ProcessInfo.processInfo.environment["CMUX_TAB_ID"]
            var cmd = "set_progress \(value)"
            if let label { cmd += " --label=\(quoteOptionValue(label))" }
            if let tabArg { cmd += " --tab=\(tabArg)" }
            let response = try client.send(command: cmd)
            print(response)

        case "clear-progress":
            let tabArg = optionValue(commandArgs, name: "--tab") ?? ProcessInfo.processInfo.environment["CMUX_TAB_ID"]
            var cmd = "clear_progress"
            if let tabArg { cmd += " --tab=\(tabArg)" }
            let response = try client.send(command: cmd)
            print(response)

        case "report-git-branch":
            guard let branch = commandArgs.first else {
                throw CLIError(message: "report-git-branch requires a branch name")
            }
            let status = optionValue(commandArgs, name: "--status")
            let tabArg = optionValue(commandArgs, name: "--tab") ?? ProcessInfo.processInfo.environment["CMUX_TAB_ID"]
            var cmd = "report_git_branch \(branch)"
            if let status { cmd += " --status=\(status)" }
            if let tabArg { cmd += " --tab=\(tabArg)" }
            let response = try client.send(command: cmd)
            print(response)

        case "report-ports":
            // Remove options by position (flag + following value), not by string value,
            // so a port token that equals the tab arg isn't accidentally dropped.
            let (explicitTab, remaining) = parseOption(commandArgs, name: "--tab")
            let tabArg = explicitTab ?? ProcessInfo.processInfo.environment["CMUX_TAB_ID"]
            let ports = remaining
            guard !ports.isEmpty else {
                throw CLIError(message: "report-ports requires at least one port number")
            }
            var cmd = "report_ports \(ports.joined(separator: " "))"
            if let tabArg { cmd += " --tab=\(tabArg)" }
            let response = try client.send(command: cmd)
            print(response)

        case "clear-ports":
            let tabArg = optionValue(commandArgs, name: "--tab") ?? ProcessInfo.processInfo.environment["CMUX_TAB_ID"]
            var cmd = "clear_ports"
            if let tabArg { cmd += " --tab=\(tabArg)" }
            let response = try client.send(command: cmd)
            print(response)

        case "sidebar-state":
            let tabArg = optionValue(commandArgs, name: "--tab") ?? ProcessInfo.processInfo.environment["CMUX_TAB_ID"]
            var cmd = "sidebar_state"
            if let tabArg { cmd += " --tab=\(tabArg)" }
            let response = try client.send(command: cmd)
            print(response)

        case "reset-sidebar":
            let tabArg = optionValue(commandArgs, name: "--tab") ?? ProcessInfo.processInfo.environment["CMUX_TAB_ID"]
            var cmd = "reset_sidebar"
            if let tabArg { cmd += " --tab=\(tabArg)" }
            let response = try client.send(command: cmd)
            print(response)

        case "help":
            print(usage())

        default:
            print(usage())
            throw CLIError(message: "Unknown command: \(command)")
        }
    }

    private func parseTabs(_ response: String) -> [TabInfo] {
        guard response != "No tabs" else { return [] }
        return response
            .split(separator: "\n")
            .compactMap { line in
                let raw = String(line)
                let selected = raw.hasPrefix("*")
                let cleaned = raw.trimmingCharacters(in: CharacterSet(charactersIn: "* "))
                let parts = cleaned.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
                guard parts.count >= 2 else { return nil }
                let indexText = parts[0].replacingOccurrences(of: ":", with: "")
                guard let index = Int(indexText) else { return nil }
                let id = String(parts[1])
                let title = parts.count > 2 ? String(parts[2]) : ""
                return TabInfo(index: index, id: id, title: title, selected: selected)
            }
    }

    private func parsePanels(_ response: String) -> [PanelInfo] {
        guard response != "No surfaces" else { return [] }
        return response
            .split(separator: "\n")
            .compactMap { line in
                let raw = String(line)
                let focused = raw.hasPrefix("*")
                let cleaned = raw.trimmingCharacters(in: CharacterSet(charactersIn: "* "))
                let parts = cleaned.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                guard parts.count >= 2 else { return nil }
                let indexText = parts[0].replacingOccurrences(of: ":", with: "")
                guard let index = Int(indexText) else { return nil }
                let id = String(parts[1])
                return PanelInfo(index: index, id: id, focused: focused)
            }
    }

    private func parseNotifications(_ response: String) -> [NotificationInfo] {
        guard response != "No notifications" else { return [] }
        return response
            .split(separator: "\n")
            .compactMap { line in
                let raw = String(line)
                let parts = raw.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { return nil }
                let payload = parts[1].split(separator: "|", maxSplits: 6, omittingEmptySubsequences: false)
                guard payload.count >= 7 else { return nil }
                let notifId = String(payload[0])
                let tabId = String(payload[1])
                let panelRaw = String(payload[2])
                let panelId = panelRaw == "none" ? nil : panelRaw
                let readText = String(payload[3])
                let title = String(payload[4])
                let subtitle = String(payload[5])
                let body = String(payload[6])
                return NotificationInfo(
                    id: notifId,
                    tabId: tabId,
                    panelId: panelId,
                    isRead: readText == "read",
                    title: title,
                    subtitle: subtitle,
                    body: body
                )
            }
    }

    private func resolveTabId(_ raw: String?, client: SocketClient) throws -> String {
        if let raw, isUUID(raw) {
            return raw
        }

        if let raw, let index = Int(raw) {
            let response = try client.send(command: "list_tabs")
            let tabs = parseTabs(response)
            if let match = tabs.first(where: { $0.index == index }) {
                return match.id
            }
            throw CLIError(message: "Tab index not found")
        }

        let response = try client.send(command: "current_tab")
        if response.hasPrefix("ERROR") {
            throw CLIError(message: response)
        }
        return response
    }

    private func resolvePanelId(_ raw: String?, tabId: String, client: SocketClient) throws -> String {
        if let raw, isUUID(raw) {
            return raw
        }

        let response = try client.send(command: "list_surfaces \(tabId)")
        if response.hasPrefix("ERROR") {
            throw CLIError(message: response)
        }
        let panels = parsePanels(response)

        if let raw, let index = Int(raw) {
            if let match = panels.first(where: { $0.index == index }) {
                return match.id
            }
            throw CLIError(message: "Panel index not found")
        }

        if let focused = panels.first(where: { $0.focused }) {
            return focused.id
        }

        throw CLIError(message: "Unable to resolve panel ID")
    }

    private func parseOption(_ args: [String], name: String) -> (String?, [String]) {
        var remaining: [String] = []
        var value: String?
        var skipNext = false
        for (idx, arg) in args.enumerated() {
            if skipNext {
                skipNext = false
                continue
            }
            if arg == name, idx + 1 < args.count {
                value = args[idx + 1]
                skipNext = true
                continue
            }
            remaining.append(arg)
        }
        return (value, remaining)
    }

    private func optionValue(_ args: [String], name: String) -> String? {
        guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    private func remainingArgs(_ args: [String], removing tokens: [String]) -> [String] {
        var remaining = args
        for token in tokens {
            if let index = remaining.firstIndex(of: token) {
                remaining.remove(at: index)
            }
        }
        return remaining
    }

    private func escapeText(_ text: String) -> String {
        return text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    private func quoteOptionValue(_ value: String) -> String {
        // TerminalController.parseOptions supports quoted strings with basic
        // backslash escapes (\" and \\) inside quotes.
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private func isUUID(_ value: String) -> Bool {
        return UUID(uuidString: value) != nil
    }

    private func jsonString(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]),
              let output = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return output
    }

    private func usage() -> String {
        return """
        cmuxterm - control cmuxterm via Unix socket

        Usage:
          cmuxterm [--socket PATH] [--json] <command> [options]

        Commands:
          ping
          list-tabs
          new-tab
          new-split <left|right|up|down> [--panel <id|index>]
          list-panels [--tab <id|index>]
          focus-panel --panel <id|index>
          close-tab --tab <id|index>
          select-tab --tab <id|index>
          current-tab
          send <text>
          send-key <key>
          send-panel --panel <id|index> <text>
          send-key-panel --panel <id|index> <key>
          notify --title <text> [--subtitle <text>] [--body <text>] [--tab <id|index>] [--panel <id|index>]
          list-notifications
          clear-notifications
          set-app-focus <active|inactive|clear>
          simulate-app-active
          set-status <key> <value> [--icon <name>] [--color <hex>] [--tab <id|index>]
          clear-status <key> [--tab <id|index>]
          log <message> [--level <level>] [--source <name>] [--tab <id|index>]
          clear-log [--tab <id|index>]
          set-progress <value> [--label <text>] [--tab <id|index>]
          clear-progress [--tab <id|index>]
          report-git-branch <branch> [--status <clean|dirty>] [--tab <id>]
          report-ports <port1> [port2...] [--tab <id>]
          clear-ports [--tab <id>]
          sidebar-state [--tab <id>]
          reset-sidebar [--tab <id>]
          help

        Environment:
          CMUX_TAB_ID, CMUX_PANEL_ID, CMUX_SOCKET_PATH
        """
    }
}

@main
struct CMUXTermMain {
    static func main() {
        let cli = CMUXCLI(args: CommandLine.arguments)
        do {
            try cli.run()
        } catch {
            FileHandle.standardError.write(Data("Error: \(error)\n".utf8))
            exit(1)
        }
    }
}

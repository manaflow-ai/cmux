import Foundation
import Darwin

struct CLIError: Error, CustomStringConvertible {
    let message: String

    var description: String { message }
}

struct WorkspaceInfo {
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

struct WindowInfo {
    let index: Int
    let id: String
    let key: Bool
    let selectedWorkspaceId: String?
    let workspaceCount: Int
}

struct NotificationInfo {
    let id: String
    let workspaceId: String
    let surfaceId: String?
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
        var windowId: String? = nil

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
            if arg == "--window" {
                guard index + 1 < args.count else {
                    throw CLIError(message: "--window requires a window id")
                }
                windowId = args[index + 1]
                index += 2
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

        // If the user explicitly targets a window, focus it first so v1 commands route correctly.
        if let windowId {
            let resp = try client.send(command: "focus_window \(windowId)")
            if resp.hasPrefix("ERROR") {
                throw CLIError(message: resp)
            }
        }

        switch command {
        case "ping":
            let response = try client.send(command: "ping")
            print(response)

        case "list-windows":
            let response = try client.send(command: "list_windows")
            if jsonOutput {
                let windows = parseWindows(response)
                let payload = windows.map { item -> [String: Any] in
                    var dict: [String: Any] = [
                        "index": item.index,
                        "id": item.id,
                        "key": item.key,
                        "workspace_count": item.workspaceCount,
                    ]
                    dict["selected_workspace_id"] = item.selectedWorkspaceId ?? NSNull()
                    return dict
                }
                print(jsonString(payload))
            } else {
                print(response)
            }

        case "current-window":
            let response = try client.send(command: "current_window")
            if jsonOutput {
                print(jsonString(["window_id": response]))
            } else {
                print(response)
            }

        case "new-window":
            let response = try client.send(command: "new_window")
            print(response)

        case "focus-window":
            guard let target = optionValue(commandArgs, name: "--window") else {
                throw CLIError(message: "focus-window requires --window")
            }
            let response = try client.send(command: "focus_window \(target)")
            print(response)

        case "close-window":
            guard let target = optionValue(commandArgs, name: "--window") else {
                throw CLIError(message: "close-window requires --window")
            }
            let response = try client.send(command: "close_window \(target)")
            print(response)

        case "move-workspace-to-window":
            guard let workspace = optionValue(commandArgs, name: "--workspace") else {
                throw CLIError(message: "move-workspace-to-window requires --workspace")
            }
            guard let target = optionValue(commandArgs, name: "--window") else {
                throw CLIError(message: "move-workspace-to-window requires --window")
            }
            let wsId = try resolveWorkspaceId(workspace, client: client)
            let response = try client.send(command: "move_workspace_to_window \(wsId) \(target)")
            print(response)

        case "list-workspaces":
            let response = try client.send(command: "list_workspaces")
            if jsonOutput {
                let workspaces = parseWorkspaces(response)
                let payload = workspaces.map { [
                    "index": $0.index,
                    "id": $0.id,
                    "title": $0.title,
                    "selected": $0.selected
                ] }
                print(jsonString(payload))
            } else {
                print(response)
            }

        case "new-workspace":
            let response = try client.send(command: "new_workspace")
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
            let (workspaceArg, _) = parseOption(commandArgs, name: "--workspace")
            let response = try client.send(command: "list_surfaces \(workspaceArg ?? "")".trimmingCharacters(in: .whitespaces))
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

        case "close-workspace":
            guard let workspace = optionValue(commandArgs, name: "--workspace") else {
                throw CLIError(message: "close-workspace requires --workspace")
            }
            let workspaceId = try resolveWorkspaceId(workspace, client: client)
            let response = try client.send(command: "close_workspace \(workspaceId)")
            print(response)

        case "select-workspace":
            guard let workspace = optionValue(commandArgs, name: "--workspace") else {
                throw CLIError(message: "select-workspace requires --workspace")
            }
            let response = try client.send(command: "select_workspace \(workspace)")
            print(response)

        case "current-workspace":
            let response = try client.send(command: "current_workspace")
            if jsonOutput {
                print(jsonString(["workspace_id": response]))
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

            let workspaceArg = optionValue(commandArgs, name: "--workspace") ?? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"]
            let surfaceArg = optionValue(commandArgs, name: "--surface") ?? ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"]

            let targetWorkspace = try resolveWorkspaceId(workspaceArg, client: client)
            let targetSurface = try resolveSurfaceId(surfaceArg, workspaceId: targetWorkspace, client: client)

            let payload = "\(title)|\(subtitle)|\(body)"
            let response = try client.send(command: "notify_target \(targetWorkspace) \(targetSurface) \(payload)")
            print(response)

        case "list-notifications":
            let response = try client.send(command: "list_notifications")
            if jsonOutput {
                let notifications = parseNotifications(response)
                let payload = notifications.map { item in
                    var dict: [String: Any] = [
                        "id": item.id,
                        "workspace_id": item.workspaceId,
                        "is_read": item.isRead,
                        "title": item.title,
                        "subtitle": item.subtitle,
                        "body": item.body
                    ]
                    dict["surface_id"] = item.surfaceId ?? NSNull()
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

        case "help":
            print(usage())

        // Browser commands
        case "open-browser":
            let url = commandArgs.first ?? ""
            let response = try client.send(command: "open_browser \(url)".trimmingCharacters(in: .whitespaces))
            print(response)

        case "navigate":
            guard let panel = optionValue(commandArgs, name: "--panel") else {
                throw CLIError(message: "navigate requires --panel")
            }
            let url = remainingArgs(commandArgs, removing: ["--panel", panel]).joined(separator: " ")
            guard !url.isEmpty else { throw CLIError(message: "navigate requires a URL") }
            let response = try client.send(command: "navigate \(panel) \(url)")
            print(response)

        case "browser-back":
            guard let panel = optionValue(commandArgs, name: "--panel") else {
                throw CLIError(message: "browser-back requires --panel")
            }
            let response = try client.send(command: "browser_back \(panel)")
            print(response)

        case "browser-forward":
            guard let panel = optionValue(commandArgs, name: "--panel") else {
                throw CLIError(message: "browser-forward requires --panel")
            }
            let response = try client.send(command: "browser_forward \(panel)")
            print(response)

        case "browser-reload":
            guard let panel = optionValue(commandArgs, name: "--panel") else {
                throw CLIError(message: "browser-reload requires --panel")
            }
            let response = try client.send(command: "browser_reload \(panel)")
            print(response)

        case "get-url":
            guard let panel = optionValue(commandArgs, name: "--panel") else {
                throw CLIError(message: "get-url requires --panel")
            }
            let response = try client.send(command: "get_url \(panel)")
            print(response)

        default:
            print(usage())
            throw CLIError(message: "Unknown command: \(command)")
        }
    }

    private func parseWorkspaces(_ response: String) -> [WorkspaceInfo] {
        guard response != "No workspaces" else { return [] }
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
                return WorkspaceInfo(index: index, id: id, title: title, selected: selected)
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

    private func parseWindows(_ response: String) -> [WindowInfo] {
        guard response != "No windows" else { return [] }
        return response
            .split(separator: "\n")
            .compactMap { line in
                let raw = String(line)
                let key = raw.hasPrefix("*")
                let cleaned = raw.trimmingCharacters(in: CharacterSet(charactersIn: "* "))
                let parts = cleaned.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
                guard parts.count >= 2 else { return nil }
                let indexText = parts[0].replacingOccurrences(of: ":", with: "")
                guard let index = Int(indexText) else { return nil }
                let id = parts[1]

                var selectedWorkspaceId: String?
                var workspaceCount: Int = 0
                for token in parts.dropFirst(2) {
                    if token.hasPrefix("selected_workspace=") {
                        let v = token.replacingOccurrences(of: "selected_workspace=", with: "")
                        selectedWorkspaceId = (v == "none") ? nil : v
                    } else if token.hasPrefix("workspaces=") {
                        let v = token.replacingOccurrences(of: "workspaces=", with: "")
                        workspaceCount = Int(v) ?? 0
                    }
                }

                return WindowInfo(
                    index: index,
                    id: id,
                    key: key,
                    selectedWorkspaceId: selectedWorkspaceId,
                    workspaceCount: workspaceCount
                )
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
                let workspaceId = String(payload[1])
                let surfaceRaw = String(payload[2])
                let surfaceId = surfaceRaw == "none" ? nil : surfaceRaw
                let readText = String(payload[3])
                let title = String(payload[4])
                let subtitle = String(payload[5])
                let body = String(payload[6])
                return NotificationInfo(
                    id: notifId,
                    workspaceId: workspaceId,
                    surfaceId: surfaceId,
                    isRead: readText == "read",
                    title: title,
                    subtitle: subtitle,
                    body: body
                )
            }
    }

    private func resolveWorkspaceId(_ raw: String?, client: SocketClient) throws -> String {
        if let raw, isUUID(raw) {
            return raw
        }

        if let raw, let index = Int(raw) {
            let response = try client.send(command: "list_workspaces")
            let workspaces = parseWorkspaces(response)
            if let match = workspaces.first(where: { $0.index == index }) {
                return match.id
            }
            throw CLIError(message: "Workspace index not found")
        }

        let response = try client.send(command: "current_workspace")
        if response.hasPrefix("ERROR") {
            throw CLIError(message: response)
        }
        return response
    }

    private func resolveSurfaceId(_ raw: String?, workspaceId: String, client: SocketClient) throws -> String {
        if let raw, isUUID(raw) {
            return raw
        }

        let response = try client.send(command: "list_surfaces \(workspaceId)")
        if response.hasPrefix("ERROR") {
            throw CLIError(message: response)
        }
        let panels = parsePanels(response)

        if let raw, let index = Int(raw) {
            if let match = panels.first(where: { $0.index == index }) {
                return match.id
            }
            throw CLIError(message: "Surface index not found")
        }

        if let focused = panels.first(where: { $0.focused }) {
            return focused.id
        }

        throw CLIError(message: "Unable to resolve surface ID")
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
          cmuxterm [--socket PATH] [--window WINDOW_ID] [--json] <command> [options]

        Commands:
          ping
          list-windows
          current-window
          new-window
          focus-window --window <id>
          close-window --window <id>
          move-workspace-to-window --workspace <id|index> --window <id>
          list-workspaces
          new-workspace
          new-split <left|right|up|down> [--panel <id|index>]
          list-panels [--workspace <id|index>]
          focus-panel --panel <id|index>
          close-workspace --workspace <id|index>
          select-workspace --workspace <id|index>
          current-workspace
          send <text>
          send-key <key>
          send-panel --panel <id|index> <text>
          send-key-panel --panel <id|index> <key>
          notify --title <text> [--subtitle <text>] [--body <text>] [--workspace <id|index>] [--surface <id|index>]
          list-notifications
          clear-notifications
          set-app-focus <active|inactive|clear>
          simulate-app-active
          open-browser [url]
          navigate --panel <id> <url>
          browser-back --panel <id>
          browser-forward --panel <id>
          browser-reload --panel <id>
          get-url --panel <id>
          help

        Environment:
          CMUX_WORKSPACE_ID, CMUX_SURFACE_ID, CMUX_SOCKET_PATH
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

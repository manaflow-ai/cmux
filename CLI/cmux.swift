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

struct PaneInfo {
    let index: Int
    let id: String
    let focused: Bool
    let tabCount: Int
}

struct PaneSurfaceInfo {
    let index: Int
    let title: String
    let panelId: String
    let selected: Bool
}

struct SurfaceHealthInfo {
    let index: Int
    let id: String
    let surfaceType: String
    let inWindow: Bool?
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

private struct ClaudeHookParsedInput {
    let rawInput: String
    let object: [String: Any]?
    let sessionId: String?
    let cwd: String?
    let transcriptPath: String?
}

private struct ClaudeHookSessionRecord: Codable {
    var sessionId: String
    var workspaceId: String
    var surfaceId: String
    var cwd: String?
    var lastSubtitle: String?
    var lastBody: String?
    var startedAt: TimeInterval
    var updatedAt: TimeInterval
}

private struct ClaudeHookSessionStoreFile: Codable {
    var version: Int = 1
    var sessions: [String: ClaudeHookSessionRecord] = [:]
}

private final class ClaudeHookSessionStore {
    private static let defaultStatePath = "~/.cmuxterm/claude-hook-sessions.json"
    private static let maxStateAgeSeconds: TimeInterval = 60 * 60 * 24 * 7

    private let statePath: String
    private let fileManager: FileManager
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(
        processEnv: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) {
        if let overridePath = processEnv["CMUX_CLAUDE_HOOK_STATE_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !overridePath.isEmpty {
            self.statePath = NSString(string: overridePath).expandingTildeInPath
        } else {
            self.statePath = NSString(string: Self.defaultStatePath).expandingTildeInPath
        }
        self.fileManager = fileManager
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func lookup(sessionId: String) throws -> ClaudeHookSessionRecord? {
        let normalized = normalizeSessionId(sessionId)
        guard !normalized.isEmpty else { return nil }
        return try withLockedState { state in
            state.sessions[normalized]
        }
    }

    func upsert(
        sessionId: String,
        workspaceId: String,
        surfaceId: String,
        cwd: String?,
        lastSubtitle: String? = nil,
        lastBody: String? = nil
    ) throws {
        let normalized = normalizeSessionId(sessionId)
        guard !normalized.isEmpty else { return }
        try withLockedState { state in
            let now = Date().timeIntervalSince1970
            var record = state.sessions[normalized] ?? ClaudeHookSessionRecord(
                sessionId: normalized,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                cwd: nil,
                lastSubtitle: nil,
                lastBody: nil,
                startedAt: now,
                updatedAt: now
            )
            record.workspaceId = workspaceId
            record.surfaceId = surfaceId
            if let cwd = normalizeOptional(cwd) {
                record.cwd = cwd
            }
            if let subtitle = normalizeOptional(lastSubtitle) {
                record.lastSubtitle = subtitle
            }
            if let body = normalizeOptional(lastBody) {
                record.lastBody = body
            }
            record.updatedAt = now
            state.sessions[normalized] = record
        }
    }

    func consume(
        sessionId: String?,
        workspaceId: String?,
        surfaceId: String?
    ) throws -> ClaudeHookSessionRecord? {
        let normalizedSessionId = normalizeOptional(sessionId)
        let normalizedWorkspace = normalizeOptional(workspaceId)
        let normalizedSurface = normalizeOptional(surfaceId)
        return try withLockedState { state in
            if let normalizedSessionId,
               let removed = state.sessions.removeValue(forKey: normalizedSessionId) {
                return removed
            }

            guard let fallback = fallbackRecord(
                sessions: Array(state.sessions.values),
                workspaceId: normalizedWorkspace,
                surfaceId: normalizedSurface
            ) else {
                return nil
            }
            state.sessions.removeValue(forKey: fallback.sessionId)
            return fallback
        }
    }

    private func fallbackRecord(
        sessions: [ClaudeHookSessionRecord],
        workspaceId: String?,
        surfaceId: String?
    ) -> ClaudeHookSessionRecord? {
        if let surfaceId {
            let matches = sessions.filter { $0.surfaceId == surfaceId }
            return matches.max(by: { $0.updatedAt < $1.updatedAt })
        }
        if let workspaceId {
            let matches = sessions.filter { $0.workspaceId == workspaceId }
            if matches.count == 1 {
                return matches[0]
            }
        }
        return nil
    }

    private func withLockedState<T>(_ body: (inout ClaudeHookSessionStoreFile) throws -> T) throws -> T {
        let lockPath = statePath + ".lock"
        let fd = open(lockPath, O_CREAT | O_RDWR, mode_t(S_IRUSR | S_IWUSR))
        if fd < 0 {
            throw CLIError(message: "Failed to open Claude hook state lock: \(lockPath)")
        }
        defer { Darwin.close(fd) }

        if flock(fd, LOCK_EX) != 0 {
            throw CLIError(message: "Failed to lock Claude hook state: \(lockPath)")
        }
        defer { _ = flock(fd, LOCK_UN) }

        var state = loadUnlocked()
        pruneExpired(&state)
        let result = try body(&state)
        try saveUnlocked(state)
        return result
    }

    private func loadUnlocked() -> ClaudeHookSessionStoreFile {
        guard fileManager.fileExists(atPath: statePath) else {
            return ClaudeHookSessionStoreFile()
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: statePath)),
              let decoded = try? decoder.decode(ClaudeHookSessionStoreFile.self, from: data) else {
            return ClaudeHookSessionStoreFile()
        }
        return decoded
    }

    private func saveUnlocked(_ state: ClaudeHookSessionStoreFile) throws {
        let stateURL = URL(fileURLWithPath: statePath)
        let parentURL = stateURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true, attributes: nil)
        let data = try encoder.encode(state)
        try data.write(to: stateURL, options: .atomic)
    }

    private func pruneExpired(_ state: inout ClaudeHookSessionStoreFile) {
        let now = Date().timeIntervalSince1970
        let cutoff = now - Self.maxStateAgeSeconds
        state.sessions = state.sessions.filter { _, record in
            record.updatedAt >= cutoff
        }
    }

    private func normalizeSessionId(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizeOptional(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}

enum CLIIDFormat: String {
    case refs
    case uuids
    case both

    static func parse(_ raw: String?) throws -> CLIIDFormat? {
        guard let raw else { return nil }
        guard let parsed = CLIIDFormat(rawValue: raw.lowercased()) else {
            throw CLIError(message: "--id-format must be one of: refs, uuids, both")
        }
        return parsed
    }
}

final class SocketClient {
    private let path: String
    private var socketFD: Int32 = -1
    private static let defaultResponseTimeoutSeconds: TimeInterval = 15.0
    private static let responseTimeoutSeconds: TimeInterval = {
        let env = ProcessInfo.processInfo.environment
        if let raw = env["CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC"],
           let seconds = Double(raw),
           seconds > 0 {
            return seconds
        }
        return defaultResponseTimeoutSeconds
    }()

    init(path: String) {
        self.path = path
    }

    func connect() throws {
        if socketFD >= 0 { return }

        // Verify socket is owned by the current user to prevent fake-socket attacks
        var st = stat()
        guard stat(path, &st) == 0 else {
            throw CLIError(message: "Socket not found at \(path)")
        }
        guard st.st_uid == getuid() else {
            throw CLIError(message: "Socket at \(path) is not owned by the current user — refusing to connect")
        }

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
                if Date().timeIntervalSince(start) > Self.responseTimeoutSeconds {
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

    func sendV2(method: String, params: [String: Any] = [:]) throws -> [String: Any] {
        let request: [String: Any] = [
            "id": UUID().uuidString,
            "method": method,
            "params": params
        ]
        guard JSONSerialization.isValidJSONObject(request) else {
            throw CLIError(message: "Failed to encode v2 request")
        }

        let requestData = try JSONSerialization.data(withJSONObject: request, options: [])
        guard let requestLine = String(data: requestData, encoding: .utf8) else {
            throw CLIError(message: "Failed to encode v2 request")
        }

        let raw = try send(command: requestLine)
        guard let responseData = raw.data(using: .utf8) else {
            throw CLIError(message: "Invalid UTF-8 v2 response")
        }
        guard let response = try JSONSerialization.jsonObject(with: responseData, options: []) as? [String: Any] else {
            throw CLIError(message: "Invalid v2 response")
        }

        if let ok = response["ok"] as? Bool, ok {
            return (response["result"] as? [String: Any]) ?? [:]
        }

        if let error = response["error"] as? [String: Any] {
            let code = (error["code"] as? String) ?? "error"
            let message = (error["message"] as? String) ?? "Unknown v2 error"
            throw CLIError(message: "\(code): \(message)")
        }

        throw CLIError(message: "v2 request failed")
    }
}

struct CMUXCLI {
    let args: [String]

    func run() throws {
        var socketPath = ProcessInfo.processInfo.environment["CMUX_SOCKET_PATH"] ?? "/tmp/cmux.sock"
        var jsonOutput = false
        var idFormatArg: String? = nil
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
            if arg == "--id-format" {
                guard index + 1 < args.count else {
                    throw CLIError(message: "--id-format requires a value (refs|uuids|both)")
                }
                idFormatArg = args[index + 1]
                index += 2
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

        let idFormat = try resolvedIDFormat(jsonOutput: jsonOutput, raw: idFormatArg)

        // If the user explicitly targets a window, focus it first so commands route correctly.
        if let windowId {
            let normalizedWindow = try normalizeWindowHandle(windowId, client: client) ?? windowId
            _ = try client.sendV2(method: "window.focus", params: ["window_id": normalizedWindow])
        }

        switch command {
        case "ping":
            let response = try client.send(command: "ping")
            print(response)

        case "capabilities":
            let response = try client.sendV2(method: "system.capabilities")
            print(jsonString(formatIDs(response, mode: idFormat)))

        case "identify":
            var params: [String: Any] = [:]
            let includeCaller = !hasFlag(commandArgs, name: "--no-caller")
            if includeCaller {
                let workspaceArg = optionValue(commandArgs, name: "--workspace") ?? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"]
                let surfaceArg = optionValue(commandArgs, name: "--surface") ?? ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"]
                if workspaceArg != nil || surfaceArg != nil {
                    let workspaceId = try normalizeWorkspaceHandle(
                        workspaceArg,
                        client: client,
                        allowCurrent: surfaceArg != nil
                    )
                    var caller: [String: Any] = [:]
                    if let workspaceId {
                        caller["workspace_id"] = workspaceId
                    }
                    if surfaceArg != nil {
                        guard let surfaceId = try normalizeSurfaceHandle(
                            surfaceArg,
                            client: client,
                            workspaceHandle: workspaceId
                        ) else {
                            throw CLIError(message: "Invalid surface handle")
                        }
                        caller["surface_id"] = surfaceId
                    }
                    if !caller.isEmpty {
                        params["caller"] = caller
                    }
                }
            }
            let response = try client.sendV2(method: "system.identify", params: params)
            print(jsonString(formatIDs(response, mode: idFormat)))

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

        case "move-surface":
            try runMoveSurface(commandArgs: commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        case "reorder-surface":
            try runReorderSurface(commandArgs: commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        case "reorder-workspace":
            try runReorderWorkspace(commandArgs: commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

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

        case "list-panes":
            let response = try client.send(command: "list_panes")
            if jsonOutput {
                let panes = parsePanes(response)
                let payload = panes.map { [
                    "index": $0.index,
                    "id": $0.id,
                    "focused": $0.focused,
                    "tab_count": $0.tabCount
                ] }
                print(jsonString(payload))
            } else {
                print(response)
            }

        case "list-pane-surfaces":
            let pane = optionValue(commandArgs, name: "--pane")
            let cmd = pane != nil ? "list_pane_surfaces --pane=\(pane!)" : "list_pane_surfaces"
            let response = try client.send(command: cmd)
            if jsonOutput {
                let surfaces = parsePaneSurfaces(response)
                let payload = surfaces.map { [
                    "index": $0.index,
                    "title": $0.title,
                    "id": $0.panelId,
                    "selected": $0.selected
                ] }
                print(jsonString(payload))
            } else {
                print(response)
            }

        case "focus-pane":
            guard let pane = optionValue(commandArgs, name: "--pane") ?? commandArgs.first else {
                throw CLIError(message: "focus-pane requires --pane <id|index>")
            }
            let response = try client.send(command: "focus_pane \(pane)")
            print(response)

        case "new-pane":
            let type = optionValue(commandArgs, name: "--type")
            let direction = optionValue(commandArgs, name: "--direction")
            let url = optionValue(commandArgs, name: "--url")
            var args: [String] = []
            if let type { args.append("--type=\(type)") }
            if let direction { args.append("--direction=\(direction)") }
            if let url { args.append("--url=\(url)") }
            let cmd = args.isEmpty ? "new_pane" : "new_pane \(args.joined(separator: " "))"
            let response = try client.send(command: cmd)
            print(formatLegacySurfaceResponse(response, client: client, idFormat: idFormat))

        case "new-surface":
            let type = optionValue(commandArgs, name: "--type")
            let pane = optionValue(commandArgs, name: "--pane")
            let url = optionValue(commandArgs, name: "--url")
            var args: [String] = []
            if let type { args.append("--type=\(type)") }
            if let pane { args.append("--pane=\(pane)") }
            if let url { args.append("--url=\(url)") }
            let cmd = args.isEmpty ? "new_surface" : "new_surface \(args.joined(separator: " "))"
            let response = try client.send(command: cmd)
            print(formatLegacySurfaceResponse(response, client: client, idFormat: idFormat))

        case "close-surface":
            let surface = optionValue(commandArgs, name: "--surface") ?? optionValue(commandArgs, name: "--panel")
            let cmd = surface != nil ? "close_surface \(surface!)" : "close_surface"
            let response = try client.send(command: cmd)
            print(response)

        case "drag-surface-to-split":
            let (surfaceArg, rem0) = parseOption(commandArgs, name: "--surface")
            let (panelArg, rem1) = parseOption(rem0, name: "--panel")
            let surface = surfaceArg ?? panelArg
            guard let surface else {
                throw CLIError(message: "drag-surface-to-split requires --surface <id|index>")
            }
            guard let direction = rem1.first else {
                throw CLIError(message: "drag-surface-to-split requires a direction")
            }
            let response = try client.send(command: "drag_surface_to_split \(surface) \(direction)")
            print(response)

        case "refresh-surfaces":
            let response = try client.send(command: "refresh_surfaces")
            print(response)

        case "surface-health":
            let workspace = optionValue(commandArgs, name: "--workspace")
            let cmd = workspace != nil ? "surface_health \(workspace!)" : "surface_health"
            let response = try client.send(command: cmd)
            if jsonOutput {
                let rows = parseSurfaceHealth(response)
                let payload = rows.map { row -> [String: Any] in
                    var item: [String: Any] = [
                        "index": row.index,
                        "id": row.id,
                        "type": row.surfaceType,
                    ]
                    item["in_window"] = row.inWindow ?? NSNull()
                    return item
                }
                print(jsonString(payload))
            } else {
                print(response)
            }

        case "trigger-flash":
            let workspaceArg = optionValue(commandArgs, name: "--workspace") ?? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"]
            let surfaceArg = optionValue(commandArgs, name: "--surface") ?? optionValue(commandArgs, name: "--panel") ?? ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"]
            var params: [String: Any] = [:]
            var workspaceId: String?
            if workspaceArg != nil || surfaceArg != nil {
                workspaceId = try resolveWorkspaceId(workspaceArg, client: client)
                if let workspaceId {
                    params["workspace_id"] = workspaceId
                }
            }
            if let surfaceArg {
                let ws: String
                if let workspaceId {
                    ws = workspaceId
                } else {
                    ws = try resolveWorkspaceId(nil, client: client)
                }
                let surfaceId = try resolveSurfaceId(surfaceArg, workspaceId: ws, client: client)
                params["workspace_id"] = ws
                params["surface_id"] = surfaceId
            }
            let payload = try client.sendV2(method: "surface.trigger_flash", params: params)
            if jsonOutput {
                print(jsonString(formatIDs(payload, mode: idFormat)))
            } else {
                let sid = formatHandle(payload, kind: "surface", idFormat: idFormat)
                let ws = formatHandle(payload, kind: "workspace", idFormat: idFormat)
                if let sid, let ws {
                    print("OK \(sid) \(ws)")
                } else if let sid {
                    print("OK \(sid)")
                } else {
                    print("OK")
                }
            }

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

        case "claude-hook":
            try runClaudeHook(commandArgs: commandArgs, client: client)

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
        case "browser":
            try runBrowserCommand(commandArgs: commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        // Legacy aliases shimmed onto the v2 browser command surface.
        case "open-browser":
            try runBrowserCommand(commandArgs: ["open"] + commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        case "navigate":
            let bridged = replaceToken(commandArgs, from: "--panel", to: "--surface")
            try runBrowserCommand(commandArgs: ["navigate"] + bridged, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        case "browser-back":
            let bridged = replaceToken(commandArgs, from: "--panel", to: "--surface")
            try runBrowserCommand(commandArgs: ["back"] + bridged, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        case "browser-forward":
            let bridged = replaceToken(commandArgs, from: "--panel", to: "--surface")
            try runBrowserCommand(commandArgs: ["forward"] + bridged, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        case "browser-reload":
            let bridged = replaceToken(commandArgs, from: "--panel", to: "--surface")
            try runBrowserCommand(commandArgs: ["reload"] + bridged, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        case "get-url":
            let bridged = replaceToken(commandArgs, from: "--panel", to: "--surface")
            try runBrowserCommand(commandArgs: ["get-url"] + bridged, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        case "focus-webview":
            let bridged = replaceToken(commandArgs, from: "--panel", to: "--surface")
            try runBrowserCommand(commandArgs: ["focus-webview"] + bridged, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        case "is-webview-focused":
            let bridged = replaceToken(commandArgs, from: "--panel", to: "--surface")
            try runBrowserCommand(commandArgs: ["is-webview-focused"] + bridged, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        default:
            print(usage())
            throw CLIError(message: "Unknown command: \(command)")
        }
    }

    private func resolvedIDFormat(jsonOutput: Bool, raw: String?) throws -> CLIIDFormat {
        _ = jsonOutput
        if let parsed = try CLIIDFormat.parse(raw) {
            return parsed
        }
        return .refs
    }

    private func formatIDs(_ object: Any, mode: CLIIDFormat) -> Any {
        switch object {
        case let dict as [String: Any]:
            var out: [String: Any] = [:]
            for (k, v) in dict {
                out[k] = formatIDs(v, mode: mode)
            }

            switch mode {
            case .both:
                break
            case .refs:
                if out["ref"] != nil && out["id"] != nil {
                    out.removeValue(forKey: "id")
                }
                let keys = Array(out.keys)
                for key in keys where key.hasSuffix("_id") {
                    let prefix = String(key.dropLast(3))
                    if out["\(prefix)_ref"] != nil {
                        out.removeValue(forKey: key)
                    }
                }
            case .uuids:
                if out["id"] != nil && out["ref"] != nil {
                    out.removeValue(forKey: "ref")
                }
                let keys = Array(out.keys)
                for key in keys where key.hasSuffix("_ref") {
                    let prefix = String(key.dropLast(4))
                    if out["\(prefix)_id"] != nil {
                        out.removeValue(forKey: key)
                    }
                }
            }
            return out

        case let array as [Any]:
            return array.map { formatIDs($0, mode: mode) }

        default:
            return object
        }
    }

    private func intFromAny(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(s) }
        return nil
    }

    private func parseBoolString(_ raw: String) -> Bool? {
        switch raw.lowercased() {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return nil
        }
    }

    private func parsePositiveInt(_ raw: String?, label: String) throws -> Int? {
        guard let raw else { return nil }
        guard let value = Int(raw) else {
            throw CLIError(message: "\(label) must be an integer")
        }
        return value
    }

    private func isHandleRef(_ value: String) -> Bool {
        let pieces = value.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 2 else { return false }
        let kind = String(pieces[0]).lowercased()
        guard ["window", "workspace", "pane", "surface"].contains(kind) else { return false }
        return Int(String(pieces[1])) != nil
    }

    private func normalizeWindowHandle(_ raw: String?, client: SocketClient, allowCurrent: Bool = false) throws -> String? {
        guard let raw else {
            if !allowCurrent { return nil }
            let current = try client.sendV2(method: "window.current")
            return (current["window_ref"] as? String) ?? (current["window_id"] as? String)
        }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if isUUID(trimmed) || isHandleRef(trimmed) {
            return trimmed
        }
        guard let wantedIndex = Int(trimmed) else {
            return trimmed
        }

        let listed = try client.sendV2(method: "window.list")
        let windows = listed["windows"] as? [[String: Any]] ?? []
        for item in windows where intFromAny(item["index"]) == wantedIndex {
            return (item["ref"] as? String) ?? (item["id"] as? String)
        }
        throw CLIError(message: "Window index not found")
    }

    private func normalizeWorkspaceHandle(
        _ raw: String?,
        client: SocketClient,
        windowHandle: String? = nil,
        allowCurrent: Bool = false
    ) throws -> String? {
        guard let raw else {
            if !allowCurrent { return nil }
            let current = try client.sendV2(method: "workspace.current")
            return (current["workspace_ref"] as? String) ?? (current["workspace_id"] as? String)
        }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if isUUID(trimmed) || isHandleRef(trimmed) {
            return trimmed
        }
        guard let wantedIndex = Int(trimmed) else {
            return trimmed
        }

        var params: [String: Any] = [:]
        if let windowHandle {
            params["window_id"] = windowHandle
        }
        let listed = try client.sendV2(method: "workspace.list", params: params)
        let items = listed["workspaces"] as? [[String: Any]] ?? []
        for item in items where intFromAny(item["index"]) == wantedIndex {
            return (item["ref"] as? String) ?? (item["id"] as? String)
        }
        throw CLIError(message: "Workspace index not found")
    }

    private func normalizePaneHandle(
        _ raw: String?,
        client: SocketClient,
        workspaceHandle: String? = nil,
        allowFocused: Bool = false
    ) throws -> String? {
        guard let raw else {
            if !allowFocused { return nil }
            let ident = try client.sendV2(method: "system.identify")
            let focused = ident["focused"] as? [String: Any] ?? [:]
            return (focused["pane_ref"] as? String) ?? (focused["pane_id"] as? String)
        }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if isUUID(trimmed) || isHandleRef(trimmed) {
            return trimmed
        }
        guard let wantedIndex = Int(trimmed) else {
            return trimmed
        }

        var params: [String: Any] = [:]
        if let workspaceHandle {
            params["workspace_id"] = workspaceHandle
        }
        let listed = try client.sendV2(method: "pane.list", params: params)
        let items = listed["panes"] as? [[String: Any]] ?? []
        for item in items where intFromAny(item["index"]) == wantedIndex {
            return (item["ref"] as? String) ?? (item["id"] as? String)
        }
        throw CLIError(message: "Pane index not found")
    }

    private func normalizeSurfaceHandle(
        _ raw: String?,
        client: SocketClient,
        workspaceHandle: String? = nil,
        allowFocused: Bool = false
    ) throws -> String? {
        guard let raw else {
            if !allowFocused { return nil }
            let ident = try client.sendV2(method: "system.identify")
            let focused = ident["focused"] as? [String: Any] ?? [:]
            return (focused["surface_ref"] as? String) ?? (focused["surface_id"] as? String)
        }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if isUUID(trimmed) || isHandleRef(trimmed) {
            return trimmed
        }
        guard let wantedIndex = Int(trimmed) else {
            return trimmed
        }

        var params: [String: Any] = [:]
        if let workspaceHandle {
            params["workspace_id"] = workspaceHandle
        }
        let listed = try client.sendV2(method: "surface.list", params: params)
        let items = listed["surfaces"] as? [[String: Any]] ?? []
        for item in items where intFromAny(item["index"]) == wantedIndex {
            return (item["ref"] as? String) ?? (item["id"] as? String)
        }
        throw CLIError(message: "Surface index not found")
    }

    private func formatHandle(_ payload: [String: Any], kind: String, idFormat: CLIIDFormat) -> String? {
        let id = payload["\(kind)_id"] as? String
        let ref = payload["\(kind)_ref"] as? String
        switch idFormat {
        case .refs:
            return ref ?? id
        case .uuids:
            return id ?? ref
        case .both:
            if let ref, let id {
                return "\(ref) (\(id))"
            }
            return ref ?? id
        }
    }

    private func formatLegacySurfaceResponse(_ response: String, client: SocketClient, idFormat: CLIIDFormat) -> String {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("OK ") else { return response }

        let suffix = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard isUUID(suffix), idFormat != .uuids else { return response }

        do {
            let listed = try client.sendV2(method: "surface.list")
            let surfaces = listed["surfaces"] as? [[String: Any]] ?? []
            guard let row = surfaces.first(where: { ($0["id"] as? String) == suffix }) else {
                return response
            }

            let ref = row["ref"] as? String
            let rendered: String
            switch idFormat {
            case .refs:
                rendered = ref ?? suffix
            case .uuids:
                rendered = suffix
            case .both:
                if let ref {
                    rendered = "\(ref) (\(suffix))"
                } else {
                    rendered = suffix
                }
            }
            return "OK \(rendered)"
        } catch {
            return response
        }
    }

    private func printV2Payload(
        _ payload: [String: Any],
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        fallbackText: String
    ) {
        if jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
        } else {
            print(fallbackText)
        }
    }

    private func runMoveSurface(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let surfaceRaw = optionValue(commandArgs, name: "--surface") ?? commandArgs.first
        guard let surfaceRaw else {
            throw CLIError(message: "move-surface requires --surface <id|ref|index>")
        }

        let workspaceRaw = optionValue(commandArgs, name: "--workspace")
        let windowRaw = optionValue(commandArgs, name: "--window")
        let paneRaw = optionValue(commandArgs, name: "--pane")
        let beforeRaw = optionValue(commandArgs, name: "--before") ?? optionValue(commandArgs, name: "--before-surface")
        let afterRaw = optionValue(commandArgs, name: "--after") ?? optionValue(commandArgs, name: "--after-surface")

        let windowHandle = try normalizeWindowHandle(windowRaw, client: client)
        let workspaceHandle = try normalizeWorkspaceHandle(workspaceRaw, client: client, windowHandle: windowHandle)
        let surfaceHandle = try normalizeSurfaceHandle(surfaceRaw, client: client, workspaceHandle: workspaceHandle, allowFocused: false)
        let paneHandle = try normalizePaneHandle(paneRaw, client: client, workspaceHandle: workspaceHandle)
        let beforeHandle = try normalizeSurfaceHandle(beforeRaw, client: client, workspaceHandle: workspaceHandle)
        let afterHandle = try normalizeSurfaceHandle(afterRaw, client: client, workspaceHandle: workspaceHandle)

        var params: [String: Any] = [:]
        if let surfaceHandle { params["surface_id"] = surfaceHandle }
        if let paneHandle { params["pane_id"] = paneHandle }
        if let workspaceHandle { params["workspace_id"] = workspaceHandle }
        if let windowHandle { params["window_id"] = windowHandle }
        if let beforeHandle { params["before_surface_id"] = beforeHandle }
        if let afterHandle { params["after_surface_id"] = afterHandle }

        if let indexRaw = optionValue(commandArgs, name: "--index") {
            guard let index = Int(indexRaw) else {
                throw CLIError(message: "--index must be an integer")
            }
            params["index"] = index
        }
        if let focusRaw = optionValue(commandArgs, name: "--focus") {
            guard let focus = parseBoolString(focusRaw) else {
                throw CLIError(message: "--focus must be true|false")
            }
            params["focus"] = focus
        }

        let payload = try client.sendV2(method: "surface.move", params: params)
        let summary = "OK surface=\(formatHandle(payload, kind: "surface", idFormat: idFormat) ?? "unknown") pane=\(formatHandle(payload, kind: "pane", idFormat: idFormat) ?? "unknown") workspace=\(formatHandle(payload, kind: "workspace", idFormat: idFormat) ?? "unknown") window=\(formatHandle(payload, kind: "window", idFormat: idFormat) ?? "unknown")"
        printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: summary)
    }

    private func runReorderSurface(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let surfaceRaw = optionValue(commandArgs, name: "--surface") ?? commandArgs.first
        guard let surfaceRaw else {
            throw CLIError(message: "reorder-surface requires --surface <id|ref|index>")
        }

        let workspaceRaw = optionValue(commandArgs, name: "--workspace")
        let workspaceHandle = try normalizeWorkspaceHandle(workspaceRaw, client: client)
        let surfaceHandle = try normalizeSurfaceHandle(surfaceRaw, client: client, workspaceHandle: workspaceHandle)

        let beforeRaw = optionValue(commandArgs, name: "--before") ?? optionValue(commandArgs, name: "--before-surface")
        let afterRaw = optionValue(commandArgs, name: "--after") ?? optionValue(commandArgs, name: "--after-surface")
        let beforeHandle = try normalizeSurfaceHandle(beforeRaw, client: client, workspaceHandle: workspaceHandle)
        let afterHandle = try normalizeSurfaceHandle(afterRaw, client: client, workspaceHandle: workspaceHandle)

        var params: [String: Any] = [:]
        if let surfaceHandle { params["surface_id"] = surfaceHandle }
        if let beforeHandle { params["before_surface_id"] = beforeHandle }
        if let afterHandle { params["after_surface_id"] = afterHandle }
        if let indexRaw = optionValue(commandArgs, name: "--index") {
            guard let index = Int(indexRaw) else {
                throw CLIError(message: "--index must be an integer")
            }
            params["index"] = index
        }

        let payload = try client.sendV2(method: "surface.reorder", params: params)
        let summary = "OK surface=\(formatHandle(payload, kind: "surface", idFormat: idFormat) ?? "unknown") pane=\(formatHandle(payload, kind: "pane", idFormat: idFormat) ?? "unknown") workspace=\(formatHandle(payload, kind: "workspace", idFormat: idFormat) ?? "unknown")"
        printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: summary)
    }

    private func runReorderWorkspace(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let workspaceRaw = optionValue(commandArgs, name: "--workspace") ?? commandArgs.first
        guard let workspaceRaw else {
            throw CLIError(message: "reorder-workspace requires --workspace <id|ref|index>")
        }

        let windowRaw = optionValue(commandArgs, name: "--window")
        let windowHandle = try normalizeWindowHandle(windowRaw, client: client)
        let workspaceHandle = try normalizeWorkspaceHandle(workspaceRaw, client: client, windowHandle: windowHandle)

        let beforeRaw = optionValue(commandArgs, name: "--before") ?? optionValue(commandArgs, name: "--before-workspace")
        let afterRaw = optionValue(commandArgs, name: "--after") ?? optionValue(commandArgs, name: "--after-workspace")
        let beforeHandle = try normalizeWorkspaceHandle(beforeRaw, client: client, windowHandle: windowHandle)
        let afterHandle = try normalizeWorkspaceHandle(afterRaw, client: client, windowHandle: windowHandle)

        var params: [String: Any] = [:]
        if let workspaceHandle { params["workspace_id"] = workspaceHandle }
        if let beforeHandle { params["before_workspace_id"] = beforeHandle }
        if let afterHandle { params["after_workspace_id"] = afterHandle }
        if let indexRaw = optionValue(commandArgs, name: "--index") {
            guard let index = Int(indexRaw) else {
                throw CLIError(message: "--index must be an integer")
            }
            params["index"] = index
        }
        if let windowHandle {
            params["window_id"] = windowHandle
        }

        let payload = try client.sendV2(method: "workspace.reorder", params: params)
        let summary = "OK workspace=\(formatHandle(payload, kind: "workspace", idFormat: idFormat) ?? "unknown") window=\(formatHandle(payload, kind: "window", idFormat: idFormat) ?? "unknown") index=\(payload["index"] ?? "?")"
        printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: summary)
    }

    private func runBrowserCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        guard !commandArgs.isEmpty else {
            throw CLIError(message: "browser requires a subcommand")
        }

        let (surfaceOpt, argsWithoutSurfaceFlag) = parseOption(commandArgs, name: "--surface")
        var surfaceRaw = surfaceOpt
        var args = argsWithoutSurfaceFlag

        let verbsWithoutSurface: Set<String> = ["open", "open-split", "new", "identify"]
        if surfaceRaw == nil, let first = args.first {
            if !first.hasPrefix("-") && !verbsWithoutSurface.contains(first.lowercased()) {
                surfaceRaw = first
                args = Array(args.dropFirst())
            }
        }

        guard let subcommandRaw = args.first else {
            throw CLIError(message: "browser requires a subcommand")
        }
        let subcommand = subcommandRaw.lowercased()
        let subArgs = Array(args.dropFirst())

        func requireSurface() throws -> String {
            guard let raw = surfaceRaw else {
                throw CLIError(message: "browser \(subcommand) requires a surface handle (use: browser <surface> \(subcommand) ... or --surface)")
            }
            guard let resolved = try normalizeSurfaceHandle(raw, client: client) else {
                throw CLIError(message: "Invalid surface handle")
            }
            return resolved
        }

        func output(_ payload: [String: Any], fallback: String) {
            if jsonOutput {
                print(jsonString(formatIDs(payload, mode: idFormat)))
                return
            }
            print(fallback)
            if let snapshot = payload["post_action_snapshot"] as? String,
               !snapshot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                print(snapshot)
            }
        }

        func nonFlagArgs(_ values: [String]) -> [String] {
            values.filter { !$0.hasPrefix("-") }
        }

        if subcommand == "identify" {
            let surface = try normalizeSurfaceHandle(surfaceRaw, client: client, allowFocused: true)
            var payload = try client.sendV2(method: "system.identify")
            if let surface {
                let urlPayload = try client.sendV2(method: "browser.url.get", params: ["surface_id": surface])
                let titlePayload = try client.sendV2(method: "browser.get.title", params: ["surface_id": surface])
                var browser: [String: Any] = [:]
                browser["surface"] = surface
                browser["url"] = urlPayload["url"] ?? ""
                browser["title"] = titlePayload["title"] ?? ""
                payload["browser"] = browser
            }
            output(payload, fallback: "OK")
            return
        }

        if subcommand == "open" || subcommand == "open-split" || subcommand == "new" {
            // Parse routing flags before URL assembly so they never leak into the URL string.
            let (workspaceOpt, argsAfterWorkspace) = parseOption(subArgs, name: "--workspace")
            let (windowOpt, urlArgs) = parseOption(argsAfterWorkspace, name: "--window")
            let url = urlArgs.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)

            if surfaceRaw != nil, subcommand == "open" {
                // Treat `browser <surface> open <url>` as navigate for agent-browser ergonomics.
                let sid = try requireSurface()
                guard !url.isEmpty else {
                    throw CLIError(message: "browser <surface> open requires a URL")
                }
                let payload = try client.sendV2(method: "browser.navigate", params: ["surface_id": sid, "url": url])
                output(payload, fallback: "OK")
                return
            }

            var params: [String: Any] = [:]
            if !url.isEmpty {
                params["url"] = url
            }
            if let sourceSurface = try normalizeSurfaceHandle(surfaceRaw, client: client) {
                params["surface_id"] = sourceSurface
            }
            let workspaceRaw = workspaceOpt ?? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"]
            if let workspaceRaw {
                if let workspace = try normalizeWorkspaceHandle(workspaceRaw, client: client) {
                    params["workspace_id"] = workspace
                }
            }
            if let windowRaw = windowOpt {
                if let window = try normalizeWindowHandle(windowRaw, client: client) {
                    params["window_id"] = window
                }
            }
            let payload = try client.sendV2(method: "browser.open_split", params: params)
            let surfaceText = formatHandle(payload, kind: "surface", idFormat: idFormat) ?? "unknown"
            let paneText = formatHandle(payload, kind: "pane", idFormat: idFormat) ?? "unknown"
            let placement = ((payload["created_split"] as? Bool) == true) ? "split" : "reuse"
            output(payload, fallback: "OK surface=\(surfaceText) pane=\(paneText) placement=\(placement)")
            return
        }

        if subcommand == "goto" || subcommand == "navigate" {
            let sid = try requireSurface()
            let url = subArgs.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !url.isEmpty else {
                throw CLIError(message: "browser \(subcommand) requires a URL")
            }
            var params: [String: Any] = ["surface_id": sid, "url": url]
            if hasFlag(subArgs, name: "--snapshot-after") {
                params["snapshot_after"] = true
            }
            let payload = try client.sendV2(method: "browser.navigate", params: params)
            output(payload, fallback: "OK")
            return
        }

        if subcommand == "back" || subcommand == "forward" || subcommand == "reload" {
            let sid = try requireSurface()
            let methodMap: [String: String] = [
                "back": "browser.back",
                "forward": "browser.forward",
                "reload": "browser.reload",
            ]
            var params: [String: Any] = ["surface_id": sid]
            if hasFlag(subArgs, name: "--snapshot-after") {
                params["snapshot_after"] = true
            }
            let payload = try client.sendV2(method: methodMap[subcommand]!, params: params)
            output(payload, fallback: "OK")
            return
        }

        if subcommand == "url" || subcommand == "get-url" {
            let sid = try requireSurface()
            let payload = try client.sendV2(method: "browser.url.get", params: ["surface_id": sid])
            if jsonOutput {
                print(jsonString(formatIDs(payload, mode: idFormat)))
            } else {
                print((payload["url"] as? String) ?? "")
            }
            return
        }

        if ["focus-webview", "focus_webview"].contains(subcommand) {
            let sid = try requireSurface()
            let payload = try client.sendV2(method: "browser.focus_webview", params: ["surface_id": sid])
            output(payload, fallback: "OK")
            return
        }

        if ["is-webview-focused", "is_webview_focused"].contains(subcommand) {
            let sid = try requireSurface()
            let payload = try client.sendV2(method: "browser.is_webview_focused", params: ["surface_id": sid])
            if jsonOutput {
                print(jsonString(formatIDs(payload, mode: idFormat)))
            } else {
                print((payload["focused"] as? Bool) == true ? "true" : "false")
            }
            return
        }

        if subcommand == "snapshot" {
            let sid = try requireSurface()
            let (selectorOpt, rem1) = parseOption(subArgs, name: "--selector")
            let (depthOpt, _) = parseOption(rem1, name: "--max-depth")

            var params: [String: Any] = ["surface_id": sid]
            if let selectorOpt {
                params["selector"] = selectorOpt
            }
            if hasFlag(subArgs, name: "--interactive") || hasFlag(subArgs, name: "-i") {
                params["interactive"] = true
            }
            if hasFlag(subArgs, name: "--cursor") {
                params["cursor"] = true
            }
            if hasFlag(subArgs, name: "--compact") {
                params["compact"] = true
            }
            if let depthOpt {
                guard let depth = Int(depthOpt), depth >= 0 else {
                    throw CLIError(message: "--max-depth must be a non-negative integer")
                }
                params["max_depth"] = depth
            }

            let payload = try client.sendV2(method: "browser.snapshot", params: params)
            if jsonOutput {
                print(jsonString(formatIDs(payload, mode: idFormat)))
            } else if let text = payload["snapshot"] as? String {
                print(text)
            } else {
                print("Empty page")
            }
            return
        }

        if subcommand == "eval" {
            let sid = try requireSurface()
            let script = optionValue(subArgs, name: "--script") ?? subArgs.joined(separator: " ")
            let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw CLIError(message: "browser eval requires a script")
            }
            let payload = try client.sendV2(method: "browser.eval", params: ["surface_id": sid, "script": trimmed])
            output(payload, fallback: "OK")
            return
        }

        if subcommand == "wait" {
            let sid = try requireSurface()
            var params: [String: Any] = ["surface_id": sid]

            let (selectorOpt, rem1) = parseOption(subArgs, name: "--selector")
            let (textOpt, rem2) = parseOption(rem1, name: "--text")
            let (urlContainsOptA, rem3) = parseOption(rem2, name: "--url-contains")
            let (urlContainsOptB, rem4) = parseOption(rem3, name: "--url")
            let (loadStateOpt, rem5) = parseOption(rem4, name: "--load-state")
            let (functionOpt, rem6) = parseOption(rem5, name: "--function")
            let (timeoutOptMs, rem7) = parseOption(rem6, name: "--timeout-ms")
            let (timeoutOptSec, rem8) = parseOption(rem7, name: "--timeout")

            if let selector = selectorOpt ?? rem8.first {
                params["selector"] = selector
            }
            if let textOpt {
                params["text_contains"] = textOpt
            }
            if let urlContains = urlContainsOptA ?? urlContainsOptB {
                params["url_contains"] = urlContains
            }
            if let loadStateOpt {
                params["load_state"] = loadStateOpt
            }
            if let functionOpt {
                params["function"] = functionOpt
            }
            if let timeoutOptMs {
                guard let ms = Int(timeoutOptMs) else {
                    throw CLIError(message: "--timeout-ms must be an integer")
                }
                params["timeout_ms"] = ms
            } else if let timeoutOptSec {
                guard let seconds = Double(timeoutOptSec) else {
                    throw CLIError(message: "--timeout must be a number")
                }
                params["timeout_ms"] = max(1, Int(seconds * 1000.0))
            }

            let payload = try client.sendV2(method: "browser.wait", params: params)
            output(payload, fallback: "OK")
            return
        }

        if ["click", "dblclick", "hover", "focus", "check", "uncheck", "scrollintoview", "scrollinto", "scroll-into-view"].contains(subcommand) {
            let sid = try requireSurface()
            let (selectorOpt, rem1) = parseOption(subArgs, name: "--selector")
            let selector = selectorOpt ?? rem1.first
            guard let selector else {
                throw CLIError(message: "browser \(subcommand) requires a selector")
            }
            let methodMap: [String: String] = [
                "click": "browser.click",
                "dblclick": "browser.dblclick",
                "hover": "browser.hover",
                "focus": "browser.focus",
                "check": "browser.check",
                "uncheck": "browser.uncheck",
                "scrollintoview": "browser.scroll_into_view",
                "scrollinto": "browser.scroll_into_view",
                "scroll-into-view": "browser.scroll_into_view",
            ]
            var params: [String: Any] = ["surface_id": sid, "selector": selector]
            if hasFlag(subArgs, name: "--snapshot-after") {
                params["snapshot_after"] = true
            }
            let payload = try client.sendV2(method: methodMap[subcommand]!, params: params)
            output(payload, fallback: "OK")
            return
        }

        if ["type", "fill"].contains(subcommand) {
            let sid = try requireSurface()
            let (selectorOpt, rem1) = parseOption(subArgs, name: "--selector")
            let (textOpt, rem2) = parseOption(rem1, name: "--text")
            let selector = selectorOpt ?? rem2.first
            guard let selector else {
                throw CLIError(message: "browser \(subcommand) requires a selector")
            }

            let positional = selectorOpt != nil ? rem2 : Array(rem2.dropFirst())
            let hasExplicitText = textOpt != nil || !positional.isEmpty
            let text: String
            if let textOpt {
                text = textOpt
            } else {
                text = positional.joined(separator: " ")
            }
            if subcommand == "type" {
                guard hasExplicitText, !text.isEmpty else {
                    throw CLIError(message: "browser type requires text")
                }
            }

            let method = (subcommand == "type") ? "browser.type" : "browser.fill"
            var params: [String: Any] = ["surface_id": sid, "selector": selector, "text": text]
            if hasFlag(subArgs, name: "--snapshot-after") {
                params["snapshot_after"] = true
            }
            let payload = try client.sendV2(method: method, params: params)
            output(payload, fallback: "OK")
            return
        }

        if ["press", "key", "keydown", "keyup"].contains(subcommand) {
            let sid = try requireSurface()
            let (keyOpt, rem1) = parseOption(subArgs, name: "--key")
            let key = keyOpt ?? rem1.first
            guard let key else {
                throw CLIError(message: "browser \(subcommand) requires a key")
            }
            let methodMap: [String: String] = [
                "press": "browser.press",
                "key": "browser.press",
                "keydown": "browser.keydown",
                "keyup": "browser.keyup",
            ]
            var params: [String: Any] = ["surface_id": sid, "key": key]
            if hasFlag(subArgs, name: "--snapshot-after") {
                params["snapshot_after"] = true
            }
            let payload = try client.sendV2(method: methodMap[subcommand]!, params: params)
            output(payload, fallback: "OK")
            return
        }

        if subcommand == "select" {
            let sid = try requireSurface()
            let (selectorOpt, rem1) = parseOption(subArgs, name: "--selector")
            let (valueOpt, rem2) = parseOption(rem1, name: "--value")
            let selector = selectorOpt ?? rem2.first
            guard let selector else {
                throw CLIError(message: "browser select requires a selector")
            }
            let value = valueOpt ?? (selectorOpt != nil ? rem2.first : rem2.dropFirst().first)
            guard let value else {
                throw CLIError(message: "browser select requires a value")
            }
            var params: [String: Any] = ["surface_id": sid, "selector": selector, "value": value]
            if hasFlag(subArgs, name: "--snapshot-after") {
                params["snapshot_after"] = true
            }
            let payload = try client.sendV2(method: "browser.select", params: params)
            output(payload, fallback: "OK")
            return
        }

        if subcommand == "scroll" {
            let sid = try requireSurface()
            let (selectorOpt, rem1) = parseOption(subArgs, name: "--selector")
            let (dxOpt, rem2) = parseOption(rem1, name: "--dx")
            let (dyOpt, rem3) = parseOption(rem2, name: "--dy")

            var params: [String: Any] = ["surface_id": sid]
            if let selectorOpt {
                params["selector"] = selectorOpt
            }

            if let dxOpt {
                guard let dx = Int(dxOpt) else {
                    throw CLIError(message: "--dx must be an integer")
                }
                params["dx"] = dx
            }
            if let dyOpt {
                guard let dy = Int(dyOpt) else {
                    throw CLIError(message: "--dy must be an integer")
                }
                params["dy"] = dy
            } else if let first = rem3.first, let dy = Int(first) {
                params["dy"] = dy
            }
            if hasFlag(subArgs, name: "--snapshot-after") {
                params["snapshot_after"] = true
            }

            let payload = try client.sendV2(method: "browser.scroll", params: params)
            output(payload, fallback: "OK")
            return
        }

        if subcommand == "screenshot" {
            let sid = try requireSurface()
            let (outPathOpt, _) = parseOption(subArgs, name: "--out")
            let payload = try client.sendV2(method: "browser.screenshot", params: ["surface_id": sid])
            if let outPathOpt,
               let b64 = payload["png_base64"] as? String,
               let data = Data(base64Encoded: b64) {
                try data.write(to: URL(fileURLWithPath: outPathOpt))
            }

            if jsonOutput {
                print(jsonString(formatIDs(payload, mode: idFormat)))
            } else if let outPathOpt {
                print("OK \(outPathOpt)")
            } else {
                print("OK")
            }
            return
        }

        if subcommand == "get" {
            let sid = try requireSurface()
            guard let getVerb = subArgs.first?.lowercased() else {
                throw CLIError(message: "browser get requires a subcommand")
            }
            let getArgs = Array(subArgs.dropFirst())

            switch getVerb {
            case "url":
                let payload = try client.sendV2(method: "browser.url.get", params: ["surface_id": sid])
                output(payload, fallback: (payload["url"] as? String) ?? "")
            case "title":
                let payload = try client.sendV2(method: "browser.get.title", params: ["surface_id": sid])
                output(payload, fallback: (payload["title"] as? String) ?? "")
            case "text", "html", "value", "count", "box", "styles", "attr":
                let (selectorOpt, rem1) = parseOption(getArgs, name: "--selector")
                let selector = selectorOpt ?? rem1.first
                if getVerb != "title" && getVerb != "url" {
                    guard selector != nil else {
                        throw CLIError(message: "browser get \(getVerb) requires a selector")
                    }
                }
                var params: [String: Any] = ["surface_id": sid]
                if let selector {
                    params["selector"] = selector
                }
                if getVerb == "attr" {
                    let (attrOpt, rem2) = parseOption(rem1, name: "--attr")
                    let attr = attrOpt ?? rem2.dropFirst().first
                    guard let attr else {
                        throw CLIError(message: "browser get attr requires --attr <name>")
                    }
                    params["attr"] = attr
                }
                if getVerb == "styles" {
                    let (propOpt, _) = parseOption(rem1, name: "--property")
                    if let propOpt {
                        params["property"] = propOpt
                    }
                }

                let methodMap: [String: String] = [
                    "text": "browser.get.text",
                    "html": "browser.get.html",
                    "value": "browser.get.value",
                    "attr": "browser.get.attr",
                    "count": "browser.get.count",
                    "box": "browser.get.box",
                    "styles": "browser.get.styles",
                ]
                let payload = try client.sendV2(method: methodMap[getVerb]!, params: params)
                if jsonOutput {
                    print(jsonString(formatIDs(payload, mode: idFormat)))
                } else if let value = payload["value"] {
                    if let str = value as? String {
                        print(str)
                    } else {
                        print(jsonString(value))
                    }
                } else if let count = payload["count"] {
                    print("\(count)")
                } else {
                    print("OK")
                }
            default:
                throw CLIError(message: "Unsupported browser get subcommand: \(getVerb)")
            }
            return
        }

        if subcommand == "is" {
            let sid = try requireSurface()
            guard let isVerb = subArgs.first?.lowercased() else {
                throw CLIError(message: "browser is requires a subcommand")
            }
            let isArgs = Array(subArgs.dropFirst())
            let (selectorOpt, rem1) = parseOption(isArgs, name: "--selector")
            let selector = selectorOpt ?? rem1.first
            guard let selector else {
                throw CLIError(message: "browser is \(isVerb) requires a selector")
            }

            let methodMap: [String: String] = [
                "visible": "browser.is.visible",
                "enabled": "browser.is.enabled",
                "checked": "browser.is.checked",
            ]
            guard let method = methodMap[isVerb] else {
                throw CLIError(message: "Unsupported browser is subcommand: \(isVerb)")
            }
            let payload = try client.sendV2(method: method, params: ["surface_id": sid, "selector": selector])
            if jsonOutput {
                print(jsonString(formatIDs(payload, mode: idFormat)))
            } else if let value = payload["value"] {
                print("\(value)")
            } else {
                print("false")
            }
            return
        }


        if subcommand == "find" {
            let sid = try requireSurface()
            guard let locator = subArgs.first?.lowercased() else {
                throw CLIError(message: "browser find requires a locator (role|text|label|placeholder|alt|title|testid|first|last|nth)")
            }
            let locatorArgs = Array(subArgs.dropFirst())

            var params: [String: Any] = ["surface_id": sid]
            let method: String

            switch locator {
            case "role":
                let (nameOpt, rem1) = parseOption(locatorArgs, name: "--name")
                let candidates = nonFlagArgs(rem1)
                guard let role = candidates.first else {
                    throw CLIError(message: "browser find role requires <role>")
                }
                params["role"] = role
                if let nameOpt {
                    params["name"] = nameOpt
                }
                if hasFlag(locatorArgs, name: "--exact") {
                    params["exact"] = true
                }
                method = "browser.find.role"
            case "text", "label", "placeholder", "alt", "title", "testid":
                let keyMap: [String: String] = [
                    "text": "text",
                    "label": "label",
                    "placeholder": "placeholder",
                    "alt": "alt",
                    "title": "title",
                    "testid": "testid",
                ]
                let candidates = nonFlagArgs(locatorArgs)
                guard let value = candidates.first else {
                    throw CLIError(message: "browser find \(locator) requires a value")
                }
                params[keyMap[locator]!] = value
                if hasFlag(locatorArgs, name: "--exact") {
                    params["exact"] = true
                }
                method = "browser.find.\(locator)"
            case "first", "last":
                let (selectorOpt, rem1) = parseOption(locatorArgs, name: "--selector")
                let candidates = nonFlagArgs(rem1)
                guard let selector = selectorOpt ?? candidates.first else {
                    throw CLIError(message: "browser find \(locator) requires a selector")
                }
                params["selector"] = selector
                method = "browser.find.\(locator)"
            case "nth":
                let (indexOpt, rem1) = parseOption(locatorArgs, name: "--index")
                let (selectorOpt, rem2) = parseOption(rem1, name: "--selector")
                let candidates = nonFlagArgs(rem2)
                let indexRaw = indexOpt ?? candidates.first
                guard let indexRaw,
                      let index = Int(indexRaw) else {
                    throw CLIError(message: "browser find nth requires an integer index")
                }
                let selector = selectorOpt ?? (candidates.count >= 2 ? candidates[1] : nil)
                guard let selector else {
                    throw CLIError(message: "browser find nth requires a selector")
                }
                params["index"] = index
                params["selector"] = selector
                method = "browser.find.nth"
            default:
                throw CLIError(message: "Unsupported browser find locator: \(locator)")
            }

            let payload = try client.sendV2(method: method, params: params)
            output(payload, fallback: "OK")
            return
        }

        if subcommand == "frame" {
            let sid = try requireSurface()
            guard let frameVerb = subArgs.first?.lowercased() else {
                throw CLIError(message: "browser frame requires <selector|main>")
            }
            if frameVerb == "main" {
                let payload = try client.sendV2(method: "browser.frame.main", params: ["surface_id": sid])
                output(payload, fallback: "OK")
                return
            }
            let (selectorOpt, rem1) = parseOption(subArgs, name: "--selector")
            let selector = selectorOpt ?? nonFlagArgs(rem1).first
            guard let selector else {
                throw CLIError(message: "browser frame requires a selector or 'main'")
            }
            let payload = try client.sendV2(method: "browser.frame.select", params: ["surface_id": sid, "selector": selector])
            output(payload, fallback: "OK")
            return
        }

        if subcommand == "dialog" {
            let sid = try requireSurface()
            guard let dialogVerb = subArgs.first?.lowercased() else {
                throw CLIError(message: "browser dialog requires <accept|dismiss> [text]")
            }
            let remainder = Array(subArgs.dropFirst())
            switch dialogVerb {
            case "accept":
                let text = remainder.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                var params: [String: Any] = ["surface_id": sid]
                if !text.isEmpty {
                    params["text"] = text
                }
                let payload = try client.sendV2(method: "browser.dialog.accept", params: params)
                output(payload, fallback: "OK")
            case "dismiss":
                let payload = try client.sendV2(method: "browser.dialog.dismiss", params: ["surface_id": sid])
                output(payload, fallback: "OK")
            default:
                throw CLIError(message: "Unsupported browser dialog subcommand: \(dialogVerb)")
            }
            return
        }

        if subcommand == "download" {
            let sid = try requireSurface()
            let argsForDownload: [String]
            if subArgs.first?.lowercased() == "wait" {
                argsForDownload = Array(subArgs.dropFirst())
            } else {
                argsForDownload = subArgs
            }

            let (pathOpt, rem1) = parseOption(argsForDownload, name: "--path")
            let (timeoutMsOpt, rem2) = parseOption(rem1, name: "--timeout-ms")
            let (timeoutSecOpt, rem3) = parseOption(rem2, name: "--timeout")

            var params: [String: Any] = ["surface_id": sid]
            if let path = pathOpt ?? nonFlagArgs(rem3).first {
                params["path"] = path
            }
            if let timeoutMsOpt {
                guard let timeoutMs = Int(timeoutMsOpt) else {
                    throw CLIError(message: "--timeout-ms must be an integer")
                }
                params["timeout_ms"] = timeoutMs
            } else if let timeoutSecOpt {
                guard let seconds = Double(timeoutSecOpt) else {
                    throw CLIError(message: "--timeout must be a number")
                }
                params["timeout_ms"] = max(1, Int(seconds * 1000.0))
            }

            let payload = try client.sendV2(method: "browser.download.wait", params: params)
            output(payload, fallback: "OK")
            return
        }

        if subcommand == "cookies" {
            let sid = try requireSurface()
            let cookieVerb = subArgs.first?.lowercased() ?? "get"
            let cookieArgs = subArgs.first != nil ? Array(subArgs.dropFirst()) : []

            let (nameOpt, rem1) = parseOption(cookieArgs, name: "--name")
            let (valueOpt, rem2) = parseOption(rem1, name: "--value")
            let (urlOpt, rem3) = parseOption(rem2, name: "--url")
            let (domainOpt, rem4) = parseOption(rem3, name: "--domain")
            let (pathOpt, rem5) = parseOption(rem4, name: "--path")
            let (expiresOpt, _) = parseOption(rem5, name: "--expires")

            var params: [String: Any] = ["surface_id": sid]
            if let nameOpt { params["name"] = nameOpt }
            if let valueOpt { params["value"] = valueOpt }
            if let urlOpt { params["url"] = urlOpt }
            if let domainOpt { params["domain"] = domainOpt }
            if let pathOpt { params["path"] = pathOpt }
            if hasFlag(cookieArgs, name: "--secure") {
                params["secure"] = true
            }
            if hasFlag(cookieArgs, name: "--all") {
                params["all"] = true
            }
            if let expiresOpt {
                guard let expires = Int(expiresOpt) else {
                    throw CLIError(message: "--expires must be an integer Unix timestamp")
                }
                params["expires"] = expires
            }

            switch cookieVerb {
            case "get":
                let payload = try client.sendV2(method: "browser.cookies.get", params: params)
                output(payload, fallback: "OK")
            case "set":
                var setParams = params
                let positional = nonFlagArgs(cookieArgs)
                if setParams["name"] == nil, positional.count >= 1 {
                    setParams["name"] = positional[0]
                }
                if setParams["value"] == nil, positional.count >= 2 {
                    setParams["value"] = positional[1]
                }
                guard setParams["name"] != nil, setParams["value"] != nil else {
                    throw CLIError(message: "browser cookies set requires <name> <value> (or --name/--value)")
                }
                let payload = try client.sendV2(method: "browser.cookies.set", params: setParams)
                output(payload, fallback: "OK")
            case "clear":
                let payload = try client.sendV2(method: "browser.cookies.clear", params: params)
                output(payload, fallback: "OK")
            default:
                throw CLIError(message: "Unsupported browser cookies subcommand: \(cookieVerb)")
            }
            return
        }

        if subcommand == "storage" {
            let sid = try requireSurface()
            let storageArgs = subArgs
            let storageType = storageArgs.first?.lowercased() ?? "local"
            guard storageType == "local" || storageType == "session" else {
                throw CLIError(message: "browser storage requires type: local|session")
            }
            let op = storageArgs.count >= 2 ? storageArgs[1].lowercased() : "get"
            let rest = storageArgs.count > 2 ? Array(storageArgs.dropFirst(2)) : []
            let positional = nonFlagArgs(rest)

            var params: [String: Any] = ["surface_id": sid, "type": storageType]
            switch op {
            case "get":
                if let key = positional.first {
                    params["key"] = key
                }
                let payload = try client.sendV2(method: "browser.storage.get", params: params)
                output(payload, fallback: "OK")
            case "set":
                guard positional.count >= 2 else {
                    throw CLIError(message: "browser storage \(storageType) set requires <key> <value>")
                }
                params["key"] = positional[0]
                params["value"] = positional[1]
                let payload = try client.sendV2(method: "browser.storage.set", params: params)
                output(payload, fallback: "OK")
            case "clear":
                let payload = try client.sendV2(method: "browser.storage.clear", params: params)
                output(payload, fallback: "OK")
            default:
                throw CLIError(message: "Unsupported browser storage subcommand: \(op)")
            }
            return
        }

        if subcommand == "tab" {
            let sid = try requireSurface()
            let first = subArgs.first?.lowercased()
            let tabVerb: String
            let tabArgs: [String]
            if let first, ["new", "list", "close", "switch"].contains(first) {
                tabVerb = first
                tabArgs = Array(subArgs.dropFirst())
            } else if let first, Int(first) != nil {
                tabVerb = "switch"
                tabArgs = subArgs
            } else {
                tabVerb = "list"
                tabArgs = subArgs
            }

            switch tabVerb {
            case "list":
                let payload = try client.sendV2(method: "browser.tab.list", params: ["surface_id": sid])
                output(payload, fallback: "OK")
            case "new":
                var params: [String: Any] = ["surface_id": sid]
                let url = tabArgs.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                if !url.isEmpty {
                    params["url"] = url
                }
                let payload = try client.sendV2(method: "browser.tab.new", params: params)
                output(payload, fallback: "OK")
            case "switch", "close":
                let method = (tabVerb == "switch") ? "browser.tab.switch" : "browser.tab.close"
                var params: [String: Any] = ["surface_id": sid]
                let target = tabArgs.first
                if let target {
                    if let index = Int(target) {
                        params["index"] = index
                    } else {
                        params["target_surface_id"] = target
                    }
                }
                let payload = try client.sendV2(method: method, params: params)
                output(payload, fallback: "OK")
            default:
                throw CLIError(message: "Unsupported browser tab subcommand: \(tabVerb)")
            }
            return
        }

        if subcommand == "console" {
            let sid = try requireSurface()
            let consoleVerb = subArgs.first?.lowercased() ?? "list"
            let method = (consoleVerb == "clear") ? "browser.console.clear" : "browser.console.list"
            if consoleVerb != "list" && consoleVerb != "clear" {
                throw CLIError(message: "Unsupported browser console subcommand: \(consoleVerb)")
            }
            let payload = try client.sendV2(method: method, params: ["surface_id": sid])
            output(payload, fallback: "OK")
            return
        }

        if subcommand == "errors" {
            let sid = try requireSurface()
            let errorsVerb = subArgs.first?.lowercased() ?? "list"
            var params: [String: Any] = ["surface_id": sid]
            if errorsVerb == "clear" {
                params["clear"] = true
            } else if errorsVerb != "list" {
                throw CLIError(message: "Unsupported browser errors subcommand: \(errorsVerb)")
            }
            let payload = try client.sendV2(method: "browser.errors.list", params: params)
            output(payload, fallback: "OK")
            return
        }

        if subcommand == "highlight" {
            let sid = try requireSurface()
            let (selectorOpt, rem1) = parseOption(subArgs, name: "--selector")
            let selector = selectorOpt ?? nonFlagArgs(rem1).first
            guard let selector else {
                throw CLIError(message: "browser highlight requires a selector")
            }
            let payload = try client.sendV2(method: "browser.highlight", params: ["surface_id": sid, "selector": selector])
            output(payload, fallback: "OK")
            return
        }

        if subcommand == "state" {
            let sid = try requireSurface()
            guard let stateVerb = subArgs.first?.lowercased() else {
                throw CLIError(message: "browser state requires save|load <path>")
            }
            guard subArgs.count >= 2 else {
                throw CLIError(message: "browser state \(stateVerb) requires a file path")
            }
            let path = subArgs[1]
            let method: String
            switch stateVerb {
            case "save":
                method = "browser.state.save"
            case "load":
                method = "browser.state.load"
            default:
                throw CLIError(message: "Unsupported browser state subcommand: \(stateVerb)")
            }
            let payload = try client.sendV2(method: method, params: ["surface_id": sid, "path": path])
            output(payload, fallback: "OK")
            return
        }

        if subcommand == "addinitscript" || subcommand == "addscript" || subcommand == "addstyle" {
            let sid = try requireSurface()
            let field = (subcommand == "addstyle") ? "css" : "script"
            let flag = (subcommand == "addstyle") ? "--css" : "--script"
            let (scriptOpt, rem1) = parseOption(subArgs, name: flag)
            let content = (scriptOpt ?? rem1.joined(separator: " ")).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else {
                throw CLIError(message: "browser \(subcommand) requires content")
            }
            let payload = try client.sendV2(method: "browser.\(subcommand)", params: ["surface_id": sid, field: content])
            output(payload, fallback: "OK")
            return
        }

        if subcommand == "viewport" {
            let sid = try requireSurface()
            guard subArgs.count >= 2,
                  let width = Int(subArgs[0]),
                  let height = Int(subArgs[1]) else {
                throw CLIError(message: "browser viewport requires: <width> <height>")
            }
            let payload = try client.sendV2(method: "browser.viewport.set", params: ["surface_id": sid, "width": width, "height": height])
            output(payload, fallback: "OK")
            return
        }

        if subcommand == "geolocation" || subcommand == "geo" {
            let sid = try requireSurface()
            guard subArgs.count >= 2,
                  let latitude = Double(subArgs[0]),
                  let longitude = Double(subArgs[1]) else {
                throw CLIError(message: "browser geolocation requires: <latitude> <longitude>")
            }
            let payload = try client.sendV2(method: "browser.geolocation.set", params: ["surface_id": sid, "latitude": latitude, "longitude": longitude])
            output(payload, fallback: "OK")
            return
        }

        if subcommand == "offline" {
            let sid = try requireSurface()
            guard let raw = subArgs.first,
                  let enabled = parseBoolString(raw) else {
                throw CLIError(message: "browser offline requires true|false")
            }
            let payload = try client.sendV2(method: "browser.offline.set", params: ["surface_id": sid, "enabled": enabled])
            output(payload, fallback: "OK")
            return
        }

        if subcommand == "trace" {
            let sid = try requireSurface()
            guard let traceVerb = subArgs.first?.lowercased() else {
                throw CLIError(message: "browser trace requires start|stop")
            }
            let method: String
            switch traceVerb {
            case "start":
                method = "browser.trace.start"
            case "stop":
                method = "browser.trace.stop"
            default:
                throw CLIError(message: "Unsupported browser trace subcommand: \(traceVerb)")
            }
            var params: [String: Any] = ["surface_id": sid]
            if subArgs.count >= 2 {
                params["path"] = subArgs[1]
            }
            let payload = try client.sendV2(method: method, params: params)
            output(payload, fallback: "OK")
            return
        }

        if subcommand == "network" {
            let sid = try requireSurface()
            guard let networkVerb = subArgs.first?.lowercased() else {
                throw CLIError(message: "browser network requires route|unroute|requests")
            }
            let networkArgs = Array(subArgs.dropFirst())
            switch networkVerb {
            case "route":
                guard let pattern = networkArgs.first else {
                    throw CLIError(message: "browser network route requires a URL/pattern")
                }
                var params: [String: Any] = ["surface_id": sid, "url": pattern]
                if hasFlag(networkArgs, name: "--abort") {
                    params["abort"] = true
                }
                let (bodyOpt, _) = parseOption(networkArgs, name: "--body")
                if let bodyOpt {
                    params["body"] = bodyOpt
                }
                let payload = try client.sendV2(method: "browser.network.route", params: params)
                output(payload, fallback: "OK")
            case "unroute":
                guard let pattern = networkArgs.first else {
                    throw CLIError(message: "browser network unroute requires a URL/pattern")
                }
                let payload = try client.sendV2(method: "browser.network.unroute", params: ["surface_id": sid, "url": pattern])
                output(payload, fallback: "OK")
            case "requests":
                let payload = try client.sendV2(method: "browser.network.requests", params: ["surface_id": sid])
                output(payload, fallback: "OK")
            default:
                throw CLIError(message: "Unsupported browser network subcommand: \(networkVerb)")
            }
            return
        }

        if subcommand == "screencast" {
            let sid = try requireSurface()
            guard let castVerb = subArgs.first?.lowercased() else {
                throw CLIError(message: "browser screencast requires start|stop")
            }
            let method: String
            switch castVerb {
            case "start":
                method = "browser.screencast.start"
            case "stop":
                method = "browser.screencast.stop"
            default:
                throw CLIError(message: "Unsupported browser screencast subcommand: \(castVerb)")
            }
            let payload = try client.sendV2(method: method, params: ["surface_id": sid])
            output(payload, fallback: "OK")
            return
        }

        if subcommand == "input" {
            let sid = try requireSurface()
            guard let inputVerb = subArgs.first?.lowercased() else {
                throw CLIError(message: "browser input requires mouse|keyboard|touch")
            }
            let remainder = Array(subArgs.dropFirst())
            let method: String
            switch inputVerb {
            case "mouse":
                method = "browser.input_mouse"
            case "keyboard":
                method = "browser.input_keyboard"
            case "touch":
                method = "browser.input_touch"
            default:
                throw CLIError(message: "Unsupported browser input subcommand: \(inputVerb)")
            }
            var params: [String: Any] = ["surface_id": sid]
            if !remainder.isEmpty {
                params["args"] = remainder
            }
            let payload = try client.sendV2(method: method, params: params)
            output(payload, fallback: "OK")
            return
        }

        if ["input_mouse", "input_keyboard", "input_touch"].contains(subcommand) {
            let sid = try requireSurface()
            let payload = try client.sendV2(method: "browser.\(subcommand)", params: ["surface_id": sid])
            output(payload, fallback: "OK")
            return
        }

        throw CLIError(message: "Unsupported browser subcommand: \(subcommand)")
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

    private func parsePanes(_ response: String) -> [PaneInfo] {
        guard response != "No panes" else { return [] }
        return response
            .split(separator: "\n")
            .compactMap { line in
                let raw = String(line)
                let focused = raw.hasPrefix("*")
                let cleaned = raw.trimmingCharacters(in: CharacterSet(charactersIn: "* "))
                let parts = cleaned.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
                guard parts.count >= 2 else { return nil }

                let indexText = parts[0].replacingOccurrences(of: ":", with: "")
                guard let index = Int(indexText) else { return nil }
                let id = String(parts[1])

                var tabCount = 0
                if parts.count >= 3 {
                    let trailing = String(parts[2])
                    if let open = trailing.firstIndex(of: "["),
                       let close = trailing.firstIndex(of: "]"),
                       open < close {
                        let inside = trailing[trailing.index(after: open)..<close]
                        let number = inside.replacingOccurrences(of: "tabs", with: "")
                            .trimmingCharacters(in: .whitespaces)
                        tabCount = Int(number) ?? 0
                    }
                }

                return PaneInfo(index: index, id: id, focused: focused, tabCount: tabCount)
            }
    }

    private func parsePaneSurfaces(_ response: String) -> [PaneSurfaceInfo] {
        guard response != "No tabs in pane" else { return [] }
        return response
            .split(separator: "\n")
            .compactMap { line in
                let raw = String(line)
                let selected = raw.hasPrefix("*")
                let cleaned = raw.trimmingCharacters(in: CharacterSet(charactersIn: "* "))

                guard let firstSpace = cleaned.firstIndex(of: " ") else { return nil }
                let indexToken = cleaned[..<firstSpace]
                let indexText = indexToken.replacingOccurrences(of: ":", with: "")
                guard let index = Int(indexText) else { return nil }

                let remainder = cleaned[cleaned.index(after: firstSpace)...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard let panelRange = remainder.range(of: "[panel:"),
                      let endBracket = remainder[panelRange.upperBound...].firstIndex(of: "]") else { return nil }

                let title = remainder[..<panelRange.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
                let panelId = remainder[panelRange.upperBound..<endBracket]

                return PaneSurfaceInfo(
                    index: index,
                    title: title,
                    panelId: String(panelId),
                    selected: selected
                )
            }
    }

    private func parseSurfaceHealth(_ response: String) -> [SurfaceHealthInfo] {
        guard response != "No surfaces" else { return [] }
        return response
            .split(separator: "\n")
            .compactMap { line in
                let raw = String(line)
                let parts = raw.split(separator: " ").map(String.init)
                guard parts.count >= 4 else { return nil }

                let indexText = parts[0].replacingOccurrences(of: ":", with: "")
                guard let index = Int(indexText) else { return nil }
                let id = parts[1]

                var surfaceType = ""
                var inWindow: Bool?
                for token in parts.dropFirst(2) {
                    if token.hasPrefix("type=") {
                        surfaceType = token.replacingOccurrences(of: "type=", with: "")
                    } else if token.hasPrefix("in_window=") {
                        let value = token.replacingOccurrences(of: "in_window=", with: "")
                        if value == "true" {
                            inWindow = true
                        } else if value == "false" {
                            inWindow = false
                        } else {
                            inWindow = nil
                        }
                    }
                }

                return SurfaceHealthInfo(index: index, id: id, surfaceType: surfaceType, inWindow: inWindow)
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

    private func hasFlag(_ args: [String], name: String) -> Bool {
        args.contains(name)
    }

    private func replaceToken(_ args: [String], from: String, to: String) -> [String] {
        args.map { $0 == from ? to : $0 }
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

    private func runClaudeHook(commandArgs: [String], client: SocketClient) throws {
        let subcommand = commandArgs.first?.lowercased() ?? "help"
        let hookArgs = Array(commandArgs.dropFirst())
        let workspaceArg = optionValue(hookArgs, name: "--workspace") ?? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"]
        let surfaceArg = optionValue(hookArgs, name: "--surface") ?? ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"]
        let rawInput = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let parsedInput = parseClaudeHookInput(rawInput: rawInput)
        let sessionStore = ClaudeHookSessionStore()
        let fallbackWorkspaceId = try resolveWorkspaceIdForClaudeHook(workspaceArg, client: client)
        let fallbackSurfaceId = try? resolveSurfaceId(surfaceArg, workspaceId: fallbackWorkspaceId, client: client)

        switch subcommand {
        case "session-start", "active":
            let workspaceId = fallbackWorkspaceId
            let surfaceId = try resolveSurfaceIdForClaudeHook(
                surfaceArg,
                workspaceId: workspaceId,
                client: client
            )
            if let sessionId = parsedInput.sessionId {
                try? sessionStore.upsert(
                    sessionId: sessionId,
                    workspaceId: workspaceId,
                    surfaceId: surfaceId,
                    cwd: parsedInput.cwd
                )
            }
            try setClaudeStatus(
                client: client,
                workspaceId: workspaceId,
                value: "Running",
                icon: "bolt.fill",
                color: "#4C8DFF"
            )
            print("OK")

        case "stop", "idle":
            let consumedSession = try? sessionStore.consume(
                sessionId: parsedInput.sessionId,
                workspaceId: fallbackWorkspaceId,
                surfaceId: fallbackSurfaceId
            )
            let workspaceId = consumedSession?.workspaceId ?? fallbackWorkspaceId
            try clearClaudeStatus(client: client, workspaceId: workspaceId)

            if let completion = summarizeClaudeHookStop(
                parsedInput: parsedInput,
                sessionRecord: consumedSession
            ) {
                let surfaceId = try resolveSurfaceIdForClaudeHook(
                    consumedSession?.surfaceId ?? surfaceArg,
                    workspaceId: workspaceId,
                    client: client
                )
                let title = "Claude Code"
                let subtitle = sanitizeNotificationField(completion.subtitle)
                let body = sanitizeNotificationField(completion.body)
                let payload = "\(title)|\(subtitle)|\(body)"
                let response = try client.send(command: "notify_target \(workspaceId) \(surfaceId) \(payload)")
                print(response)
            } else {
                print("OK")
            }

        case "notification", "notify":
            let summary = summarizeClaudeHookNotification(rawInput: rawInput)

            var workspaceId = fallbackWorkspaceId
            var preferredSurface = surfaceArg
            var mappedSession: ClaudeHookSessionRecord?
            if let sessionId = parsedInput.sessionId,
               let mapped = try? sessionStore.lookup(sessionId: sessionId) {
                mappedSession = mapped
                if let mappedWorkspace = try? resolveWorkspaceIdForClaudeHook(mapped.workspaceId, client: client) {
                    workspaceId = mappedWorkspace
                    preferredSurface = mapped.surfaceId
                }
            }

            let surfaceId = try resolveSurfaceIdForClaudeHook(
                preferredSurface,
                workspaceId: workspaceId,
                client: client
            )

            let title = "Claude Code"
            let subtitle = sanitizeNotificationField(summary.subtitle)
            let body = sanitizeNotificationField(summary.body)
            let payload = "\(title)|\(subtitle)|\(body)"

            if let sessionId = parsedInput.sessionId {
                try? sessionStore.upsert(
                    sessionId: sessionId,
                    workspaceId: workspaceId,
                    surfaceId: surfaceId,
                    cwd: parsedInput.cwd,
                    lastSubtitle: summary.subtitle,
                    lastBody: summary.body
                )
            }

            let actionable = isActionableClaudeNotification(summary: summary)
            let duplicate = isDuplicateClaudeNotification(summary: summary, sessionRecord: mappedSession)
            guard actionable && !duplicate else {
                if !actionable {
                    _ = try? setClaudeStatus(
                        client: client,
                        workspaceId: workspaceId,
                        value: "Running",
                        icon: "bolt.fill",
                        color: "#4C8DFF"
                    )
                }
                print("OK")
                break
            }

            let response = try client.send(command: "notify_target \(workspaceId) \(surfaceId) \(payload)")
            _ = try? setClaudeStatus(
                client: client,
                workspaceId: workspaceId,
                value: "Needs input",
                icon: "bell.fill",
                color: "#4C8DFF"
            )
            print(response)

        case "help", "--help", "-h":
            print(
                """
                cmux claude-hook <session-start|stop|notification> [--workspace <id|index>] [--surface <id|index>]
                """
            )

        default:
            throw CLIError(message: "Unknown claude-hook subcommand: \(subcommand)")
        }
    }

    private func setClaudeStatus(
        client: SocketClient,
        workspaceId: String,
        value: String,
        icon: String,
        color: String
    ) throws {
        _ = try client.send(
            command: "set_status claude_code \(value) --icon=\(icon) --color=\(color) --tab=\(workspaceId)"
        )
    }

    private func clearClaudeStatus(client: SocketClient, workspaceId: String) throws {
        _ = try client.send(command: "clear_status claude_code --tab=\(workspaceId)")
    }

    private func resolveWorkspaceIdForClaudeHook(_ raw: String?, client: SocketClient) throws -> String {
        if let raw, !raw.isEmpty, let candidate = try? resolveWorkspaceId(raw, client: client) {
            let probe = try? client.send(command: "list_surfaces \(candidate)")
            if let probe, !probe.hasPrefix("ERROR") {
                return candidate
            }
        }
        return try resolveWorkspaceId(nil, client: client)
    }

    private func resolveSurfaceIdForClaudeHook(
        _ raw: String?,
        workspaceId: String,
        client: SocketClient
    ) throws -> String {
        if let raw, !raw.isEmpty, let candidate = try? resolveSurfaceId(raw, workspaceId: workspaceId, client: client) {
            return candidate
        }
        return try resolveSurfaceId(nil, workspaceId: workspaceId, client: client)
    }

    private func parseClaudeHookInput(rawInput: String) -> ClaudeHookParsedInput {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data, options: []),
              let object = json as? [String: Any] else {
            return ClaudeHookParsedInput(rawInput: rawInput, object: nil, sessionId: nil, cwd: nil, transcriptPath: nil)
        }

        let sessionId = extractClaudeHookSessionId(from: object)
        let cwd = extractClaudeHookCWD(from: object)
        let transcriptPath = firstString(in: object, keys: ["transcript_path", "transcriptPath"])
        return ClaudeHookParsedInput(rawInput: rawInput, object: object, sessionId: sessionId, cwd: cwd, transcriptPath: transcriptPath)
    }

    private func extractClaudeHookSessionId(from object: [String: Any]) -> String? {
        if let id = firstString(in: object, keys: ["session_id", "sessionId"]) {
            return id
        }

        if let nested = object["notification"] as? [String: Any],
           let id = firstString(in: nested, keys: ["session_id", "sessionId"]) {
            return id
        }
        if let nested = object["data"] as? [String: Any],
           let id = firstString(in: nested, keys: ["session_id", "sessionId"]) {
            return id
        }
        if let session = object["session"] as? [String: Any],
           let id = firstString(in: session, keys: ["id", "session_id", "sessionId"]) {
            return id
        }
        if let context = object["context"] as? [String: Any],
           let id = firstString(in: context, keys: ["session_id", "sessionId"]) {
            return id
        }
        return nil
    }

    private func extractClaudeHookCWD(from object: [String: Any]) -> String? {
        let cwdKeys = ["cwd", "working_directory", "workingDirectory", "project_dir", "projectDir"]
        if let cwd = firstString(in: object, keys: cwdKeys) {
            return cwd
        }
        if let nested = object["notification"] as? [String: Any],
           let cwd = firstString(in: nested, keys: cwdKeys) {
            return cwd
        }
        if let nested = object["data"] as? [String: Any],
           let cwd = firstString(in: nested, keys: cwdKeys) {
            return cwd
        }
        if let context = object["context"] as? [String: Any],
           let cwd = firstString(in: context, keys: cwdKeys) {
            return cwd
        }
        return nil
    }

    private func summarizeClaudeHookStop(
        parsedInput: ClaudeHookParsedInput,
        sessionRecord: ClaudeHookSessionRecord?
    ) -> (subtitle: String, body: String)? {
        let cwd = parsedInput.cwd ?? sessionRecord?.cwd
        let transcriptPath = parsedInput.transcriptPath

        let projectName: String? = {
            guard let cwd = cwd, !cwd.isEmpty else { return nil }
            let path = NSString(string: cwd).expandingTildeInPath
            let tail = URL(fileURLWithPath: path).lastPathComponent
            return tail.isEmpty ? path : tail
        }()

        // Try reading the transcript JSONL for a richer summary.
        let transcript = transcriptPath.flatMap { readTranscriptSummary(path: $0) }

        if let lastMsg = transcript?.lastAssistantMessage {
            var subtitle = "Completed"
            if let projectName, !projectName.isEmpty {
                subtitle = "Completed in \(projectName)"
            }
            return (subtitle, truncate(lastMsg, maxLength: 200))
        }

        // Fallback: use session record data.
        let lastMessage = sessionRecord?.lastBody ?? sessionRecord?.lastSubtitle
        let hasContext = cwd != nil || lastMessage != nil
        guard hasContext else { return nil }

        var body = "Claude session completed"
        if let projectName, !projectName.isEmpty {
            body += " in \(projectName)"
        }
        if let lastMessage, !lastMessage.isEmpty {
            body += ". Last: \(lastMessage)"
        }
        return ("Completed", body)
    }

    private struct TranscriptSummary {
        let lastAssistantMessage: String?
    }

    private func readTranscriptSummary(path: String) -> TranscriptSummary? {
        let expandedPath = NSString(string: path).expandingTildeInPath
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: expandedPath)) else {
            return nil
        }
        guard let content = String(data: data, encoding: .utf8) else { return nil }

        let lines = content.components(separatedBy: "\n")

        var lastAssistantMessage: String?

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let lineData = trimmed.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let message = obj["message"] as? [String: Any],
                  let role = message["role"] as? String,
                  role == "assistant" else {
                continue
            }

            let text = extractMessageText(from: message)
            guard let text, !text.isEmpty else { continue }
            lastAssistantMessage = truncate(normalizedSingleLine(text), maxLength: 120)
        }

        guard lastAssistantMessage != nil else { return nil }
        return TranscriptSummary(lastAssistantMessage: lastAssistantMessage)
    }

    private func extractMessageText(from message: [String: Any]) -> String? {
        if let content = message["content"] as? String {
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let contentArray = message["content"] as? [[String: Any]] {
            let texts = contentArray.compactMap { block -> String? in
                guard (block["type"] as? String) == "text",
                      let text = block["text"] as? String else { return nil }
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let joined = texts.joined(separator: " ")
            return joined.isEmpty ? nil : joined
        }
        return nil
    }

    private func summarizeClaudeHookNotification(rawInput: String) -> (subtitle: String, body: String) {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ("Waiting", "Claude is waiting for your input")
        }

        guard let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data, options: []),
              let object = json as? [String: Any] else {
            let fallback = truncate(normalizedSingleLine(trimmed), maxLength: 180)
            return classifyClaudeNotification(signal: fallback, message: fallback)
        }

        let nested = (object["notification"] as? [String: Any]) ?? (object["data"] as? [String: Any]) ?? [:]
        let signalParts = [
            firstString(in: object, keys: ["event", "event_name", "hook_event_name", "type", "kind"]),
            firstString(in: object, keys: ["notification_type", "matcher", "reason"]),
            firstString(in: nested, keys: ["type", "kind", "reason"])
        ]
        let messageCandidates = [
            firstString(in: object, keys: ["message", "body", "text", "prompt", "error", "description"]),
            firstString(in: nested, keys: ["message", "body", "text", "prompt", "error", "description"])
        ]
        let session = firstString(in: object, keys: ["session_id", "sessionId"])
        let message = messageCandidates.compactMap { $0 }.first ?? "Claude needs your input"
        let normalizedMessage = normalizedSingleLine(message)
        let signal = signalParts.compactMap { $0 }.joined(separator: " ")
        var classified = classifyClaudeNotification(signal: signal, message: normalizedMessage)

        if let session, !session.isEmpty {
            let shortSession = String(session.prefix(8))
            if !classified.body.contains(shortSession) {
                classified.body = "\(classified.body) [\(shortSession)]"
            }
        }

        classified.body = truncate(classified.body, maxLength: 180)
        return classified
    }

    private func classifyClaudeNotification(signal: String, message: String) -> (subtitle: String, body: String) {
        let lower = "\(signal) \(message)".lowercased()
        if lower.contains("permission") || lower.contains("approve") || lower.contains("approval") {
            let body = message.isEmpty ? "Approval needed" : message
            return ("Permission", body)
        }
        if lower.contains("error") || lower.contains("failed") || lower.contains("exception") {
            let body = message.isEmpty ? "Claude reported an error" : message
            return ("Error", body)
        }
        if lower.contains("idle") || lower.contains("wait") || lower.contains("input") || lower.contains("prompt") {
            let body = message.isEmpty ? "Claude is waiting for your input" : message
            return ("Waiting", body)
        }
        let body = message.isEmpty ? "Claude needs your input" : message
        return ("Attention", body)
    }

    private func isActionableClaudeNotification(summary: (subtitle: String, body: String)) -> Bool {
        switch normalizedSingleLine(summary.subtitle).lowercased() {
        case "permission", "error", "waiting":
            return true
        default:
            return false
        }
    }

    private func isDuplicateClaudeNotification(
        summary: (subtitle: String, body: String),
        sessionRecord: ClaudeHookSessionRecord?
    ) -> Bool {
        guard let sessionRecord else { return false }
        let previousSubtitle = normalizedSingleLine(sessionRecord.lastSubtitle ?? "").lowercased()
        let previousBody = normalizedSingleLine(sessionRecord.lastBody ?? "")
        let currentSubtitle = normalizedSingleLine(summary.subtitle).lowercased()
        let currentBody = normalizedSingleLine(summary.body)
        return previousSubtitle == currentSubtitle && previousBody == currentBody
    }

    private func firstString(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            guard let value = object[key] else { continue }
            if let string = value as? String {
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return nil
    }

    private func normalizedSingleLine(_ value: String) -> String {
        let collapsed = value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func truncate(_ value: String, maxLength: Int) -> String {
        guard value.count > maxLength else { return value }
        let index = value.index(value.startIndex, offsetBy: max(0, maxLength - 1))
        return String(value[..<index]) + "…"
    }

    private func sanitizeNotificationField(_ value: String) -> String {
        let normalized = normalizedSingleLine(value)
            .replacingOccurrences(of: "|", with: "¦")
        return truncate(normalized, maxLength: 180)
    }

    private func usage() -> String {
        return """
        cmux - control cmux via Unix socket

        Usage:
          cmux [--socket PATH] [--window WINDOW] [--json] [--id-format refs|uuids|both] <command> [options]

        Handle Inputs:
          For most v2-backed commands you can use UUIDs, short refs (window:1/workspace:2/pane:3/surface:4), or indexes.
          Output defaults to refs; pass --id-format uuids or --id-format both to include UUIDs.

        Commands:
          ping
          capabilities
          identify [--workspace <id|ref|index>] [--surface <id|ref|index>] [--no-caller]
          list-windows
          current-window
          new-window
          focus-window --window <id>
          close-window --window <id>
          move-workspace-to-window --workspace <id|index> --window <id>
          reorder-workspace --workspace <id|ref|index> (--index <n> | --before <id|ref|index> | --after <id|ref|index>) [--window <id|ref|index>]
          list-workspaces
          new-workspace
          new-split <left|right|up|down> [--panel <id|index>]
          list-panes
          list-pane-surfaces [--pane <id|index>]
          focus-pane --pane <id|index>
          new-pane [--type <terminal|browser>] [--direction <left|right|up|down>] [--url <url>]
          new-surface [--type <terminal|browser>] [--pane <id|index>] [--url <url>]
          close-surface [--surface <id|index>]
          move-surface --surface <id|ref|index> [--pane <id|ref|index>] [--workspace <id|ref|index>] [--window <id|ref|index>] [--before <id|ref|index>] [--after <id|ref|index>] [--index <n>] [--focus <true|false>]
          reorder-surface --surface <id|ref|index> (--index <n> | --before <id|ref|index> | --after <id|ref|index>)
          drag-surface-to-split --surface <id|index> <left|right|up|down>
          refresh-surfaces
          surface-health [--workspace <id|index>]
          trigger-flash [--workspace <id|index>] [--surface <id|index>]
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
          claude-hook <session-start|stop|notification> [--workspace <id|index>] [--surface <id|index>]
          set-app-focus <active|inactive|clear>
          simulate-app-active

          browser [--surface <id|ref|index> | <surface>] <subcommand> ...
          browser open [url]                   (create browser split in caller's workspace; if surface supplied, behaves like navigate)
          browser open-split [url]
          browser goto|navigate <url> [--snapshot-after]
          browser back|forward|reload [--snapshot-after]
          browser url|get-url
          browser snapshot [--interactive|-i] [--cursor] [--compact] [--max-depth <n>] [--selector <css>]
          browser eval <script>
          browser wait [--selector <css>] [--text <text>] [--url-contains <text>] [--load-state <interactive|complete>] [--function <js>] [--timeout-ms <ms>]
          browser click|dblclick|hover|focus|check|uncheck|scroll-into-view <selector> [--snapshot-after]
          browser type <selector> <text> [--snapshot-after]
          browser fill <selector> [text] [--snapshot-after]   (empty text clears input)
          browser press|keydown|keyup <key> [--snapshot-after]
          browser select <selector> <value> [--snapshot-after]
          browser scroll [--selector <css>] [--dx <n>] [--dy <n>] [--snapshot-after]
          browser get <url|title|text|html|value|attr|count|box|styles> [...]
          browser is <visible|enabled|checked> <selector>
          browser find <role|text|label|placeholder|alt|title|testid|first|last|nth> ...
          browser frame <selector|main>
          browser dialog <accept|dismiss> [text]
          browser download [wait] [--path <path>] [--timeout-ms <ms>]
          browser cookies <get|set|clear> [...]
          browser storage <local|session> <get|set|clear> [...]
          browser tab <new|list|switch|close|<index>> [...]
          browser console <list|clear>
          browser errors <list|clear>
          browser highlight <selector>
          browser state <save|load> <path>
          browser addinitscript <script>
          browser addscript <script>
          browser addstyle <css>
          browser viewport <width> <height>      (returns not_supported on WKWebView)
          browser geolocation|geo <lat> <lon>    (returns not_supported on WKWebView)
          browser offline <true|false>           (returns not_supported on WKWebView)
          browser trace <start|stop> [path]      (returns not_supported on WKWebView)
          browser network <route|unroute|requests> [...] (returns not_supported on WKWebView)
          browser screencast <start|stop>        (returns not_supported on WKWebView)
          browser input <mouse|keyboard|touch>   (returns not_supported on WKWebView)
          browser identify [--surface <id|ref|index>]

          (legacy browser aliases still supported: open-browser, navigate, browser-back, browser-forward, browser-reload, get-url)
          help

        Environment:
          CMUX_WORKSPACE_ID   Auto-set in cmux terminals. Used as default --workspace for
                              browser open, new-surface, notify, and other commands.
          CMUX_SURFACE_ID     Auto-set in cmux terminals. Used as default --surface.
          CMUX_SOCKET_PATH    Override the default Unix socket path (/tmp/cmux.sock).
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

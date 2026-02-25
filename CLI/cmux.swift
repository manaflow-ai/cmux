import Foundation
import Darwin
import Security
#if canImport(Sentry)
import Sentry
#endif

struct CLIError: Error, CustomStringConvertible {
    let message: String

    var description: String { message }
}

private final class CLISocketSentryTelemetry {
    private let command: String
    private let subcommand: String
    private let socketPath: String
    private let envSocketPath: String?
    private let workspaceId: String?
    private let surfaceId: String?
    private let disabledByEnv: Bool

#if canImport(Sentry)
    private static let startupLock = NSLock()
    private static var started = false
    private static let dsn = "https://ecba1ec90ecaee02a102fba931b6d2b3@o4507547940749312.ingest.us.sentry.io/4510796264636416"
#endif

    init(command: String, commandArgs: [String], socketPath: String, processEnv: [String: String]) {
        self.command = command.lowercased()
        self.subcommand = commandArgs.first?.lowercased() ?? "help"
        self.socketPath = socketPath
        self.envSocketPath = processEnv["CMUX_SOCKET_PATH"]
        self.workspaceId = processEnv["CMUX_WORKSPACE_ID"]
        self.surfaceId = processEnv["CMUX_SURFACE_ID"]
        self.disabledByEnv =
            processEnv["CMUX_CLI_SENTRY_DISABLED"] == "1" ||
            processEnv["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] == "1"
    }

    func breadcrumb(_ message: String, data: [String: Any] = [:]) {
        guard shouldEmit else { return }
#if canImport(Sentry)
        Self.ensureStarted()
        var payload = baseContext()
        for (key, value) in data {
            payload[key] = value
        }
        let crumb = Breadcrumb(level: .info, category: "cmux.cli")
        crumb.message = message
        crumb.data = payload
        SentrySDK.addBreadcrumb(crumb)
#endif
    }

    func captureError(stage: String, error: Error) {
        guard shouldEmit else { return }
#if canImport(Sentry)
        Self.ensureStarted()
        var context = baseContext()
        context["stage"] = stage
        context["error"] = String(describing: error)
        for (key, value) in socketDiagnostics() {
            context[key] = value
        }
        let subcommand = self.subcommand
        let command = self.command
        _ = SentrySDK.capture(error: error) { scope in
            scope.setLevel(.error)
            scope.setTag(value: "cmux-cli", key: "component")
            scope.setTag(value: command, key: "cli_command")
            scope.setTag(value: subcommand, key: "cli_subcommand")
            scope.setContext(value: context, key: "cli_socket")
        }
        SentrySDK.flush(timeout: 2.0)
#endif
    }

    private var shouldEmit: Bool {
        !disabledByEnv
    }

    private func baseContext() -> [String: Any] {
        var context: [String: Any] = [
            "command": command,
            "subcommand": subcommand,
            "requested_socket_path": socketPath,
            "env_socket_path": envSocketPath ?? "<unset>"
        ]
        if let workspaceId {
            context["workspace_id"] = workspaceId
        }
        if let surfaceId {
            context["surface_id"] = surfaceId
        }
        return context
    }

    private func socketDiagnostics() -> [String: Any] {
        var context: [String: Any] = [
            "cwd": FileManager.default.currentDirectoryPath,
            "uid": Int(getuid()),
            "euid": Int(geteuid())
        ]

        var st = stat()
        if lstat(socketPath, &st) == 0 {
            context["socket_exists"] = true
            context["socket_mode"] = String(format: "%o", Int(st.st_mode & 0o7777))
            context["socket_owner_uid"] = Int(st.st_uid)
            context["socket_owner_gid"] = Int(st.st_gid)
            context["socket_file_type"] = Self.fileTypeDescription(mode: st.st_mode)
        } else {
            let code = errno
            context["socket_exists"] = false
            context["socket_errno"] = Int(code)
            context["socket_errno_description"] = String(cString: strerror(code))
        }

        let tmpSockets = Self.discoverTmpCmuxSockets(limit: 10)
        if !tmpSockets.isEmpty {
            context["tmp_cmux_sockets"] = tmpSockets
        }
        let taggedSockets = tmpSockets.filter { $0 != "/tmp/cmux.sock" }
        if socketPath == "/tmp/cmux.sock",
           (envSocketPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
           !taggedSockets.isEmpty {
            context["possible_root_cause"] = "CMUX_SOCKET_PATH missing while tagged sockets exist"
        }

        return context
    }

    private static func fileTypeDescription(mode: mode_t) -> String {
        switch mode & mode_t(S_IFMT) {
        case mode_t(S_IFSOCK):
            return "socket"
        case mode_t(S_IFREG):
            return "regular"
        case mode_t(S_IFDIR):
            return "directory"
        case mode_t(S_IFLNK):
            return "symlink"
        default:
            return "other"
        }
    }

    private static func discoverTmpCmuxSockets(limit: Int) -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: "/tmp") else {
            return []
        }
        var sockets: [String] = []
        for name in entries.sorted() {
            guard name.hasPrefix("cmux"), name.hasSuffix(".sock") else { continue }
            let fullPath = "/tmp/\(name)"
            var st = stat()
            guard lstat(fullPath, &st) == 0 else { continue }
            guard (st.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK) else { continue }
            sockets.append(fullPath)
            if sockets.count >= limit {
                break
            }
        }
        return sockets
    }

#if canImport(Sentry)
    private static func ensureStarted() {
        startupLock.lock()
        defer { startupLock.unlock() }
        guard !started else { return }
        SentrySDK.start { options in
            options.dsn = dsn
#if DEBUG
            options.environment = "development-cli"
#else
            options.environment = "production-cli"
#endif
            options.debug = false
            options.sendDefaultPii = true
            options.attachStacktrace = true
            options.tracesSampleRate = 0.0
        }
        started = true
    }
#endif
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

private enum SocketPasswordResolver {
    private static let service = "com.cmuxterm.app.socket-control"
    private static let account = "local-socket-password"

    static func resolve(explicit: String?) -> String? {
        if let explicit = normalized(explicit), !explicit.isEmpty {
            return explicit
        }
        if let env = normalized(ProcessInfo.processInfo.environment["CMUX_SOCKET_PASSWORD"]), !env.isEmpty {
            return env
        }
        return loadFromKeychain()
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .newlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func loadFromKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            return nil
        }
        guard let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
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

        // The server may return plain-text errors (e.g., "ERROR: Access denied ...")
        // before the JSON protocol starts. Surface these directly instead of letting
        // JSONSerialization throw a confusing parse error.
        if raw.hasPrefix("ERROR:") {
            throw CLIError(message: raw)
        }

        guard let responseData = raw.data(using: .utf8) else {
            throw CLIError(message: "Invalid UTF-8 v2 response")
        }
        guard let response = try JSONSerialization.jsonObject(with: responseData, options: []) as? [String: Any] else {
            throw CLIError(message: "Invalid v2 response: \(raw)")
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
        var socketPasswordArg: String? = nil

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
            if arg == "--password" {
                guard index + 1 < args.count else {
                    throw CLIError(message: "--password requires a value")
                }
                socketPasswordArg = args[index + 1]
                index += 2
                continue
            }
            if arg == "-v" || arg == "--version" {
                print(versionSummary())
                return
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
        let cliTelemetry = CLISocketSentryTelemetry(
            command: command,
            commandArgs: commandArgs,
            socketPath: socketPath,
            processEnv: ProcessInfo.processInfo.environment
        )

        if command == "version" {
            print(versionSummary())
            return
        }

        // Check for --help/-h on subcommands before connecting to the socket,
        // so help text is available even when cmux is not running.
        if commandArgs.contains("--help") || commandArgs.contains("-h") {
            if dispatchSubcommandHelp(command: command, commandArgs: commandArgs) {
                return
            }
        }

        let client = SocketClient(path: socketPath)
        cliTelemetry.breadcrumb(
            "socket.connect.attempt",
            data: ["command": command]
        )
        do {
            try client.connect()
            cliTelemetry.breadcrumb("socket.connect.success")
        } catch {
            cliTelemetry.breadcrumb("socket.connect.failure")
            cliTelemetry.captureError(stage: "socket_connect", error: error)
            throw error
        }
        defer { client.close() }

        if let socketPassword = SocketPasswordResolver.resolve(explicit: socketPasswordArg) {
            let authResponse = try client.send(command: "auth \(socketPassword)")
            if authResponse.hasPrefix("ERROR:"),
               !authResponse.contains("Unknown command 'auth'") {
                throw CLIError(message: authResponse)
            }
        }

        let idFormat = try resolvedIDFormat(jsonOutput: jsonOutput, raw: idFormatArg)

        // If the user explicitly targets a window, focus it first so commands route correctly.
        if let windowId {
            let normalizedWindow = try normalizeWindowHandle(windowId, client: client) ?? windowId
            _ = try client.sendV2(method: "window.focus", params: ["window_id": normalizedWindow])
        }

        switch command {
        case "ping":
            let response = try sendV1Command("ping", client: client)
            print(response)

        case "capabilities":
            let response = try client.sendV2(method: "system.capabilities")
            print(jsonString(formatIDs(response, mode: idFormat)))

        case "identify":
            var params: [String: Any] = [:]
            let includeCaller = !hasFlag(commandArgs, name: "--no-caller")
            if includeCaller {
                let idWsFlag = optionValue(commandArgs, name: "--workspace")
                let workspaceArg = idWsFlag ?? (windowId == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
                let surfaceArg = optionValue(commandArgs, name: "--surface") ?? (idWsFlag == nil && windowId == nil ? ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"] : nil)
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
            let response = try sendV1Command("list_windows", client: client)
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
            let response = try sendV1Command("current_window", client: client)
            if jsonOutput {
                print(jsonString(["window_id": response]))
            } else {
                print(response)
            }

        case "new-window":
            let response = try sendV1Command("new_window", client: client)
            print(response)

        case "focus-window":
            guard let target = optionValue(commandArgs, name: "--window") else {
                throw CLIError(message: "focus-window requires --window")
            }
            let response = try sendV1Command("focus_window \(target)", client: client)
            print(response)

        case "close-window":
            guard let target = optionValue(commandArgs, name: "--window") else {
                throw CLIError(message: "close-window requires --window")
            }
            let response = try sendV1Command("close_window \(target)", client: client)
            print(response)

        case "move-workspace-to-window":
            guard let workspaceRaw = optionValue(commandArgs, name: "--workspace") else {
                throw CLIError(message: "move-workspace-to-window requires --workspace")
            }
            guard let windowRaw = optionValue(commandArgs, name: "--window") else {
                throw CLIError(message: "move-workspace-to-window requires --window")
            }
            var params: [String: Any] = [:]
            let wsId = try normalizeWorkspaceHandle(workspaceRaw, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let winId = try normalizeWindowHandle(windowRaw, client: client)
            if let winId { params["window_id"] = winId }
            let payload = try client.sendV2(method: "workspace.move_to_window", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat, kinds: ["workspace", "window"]))

        case "move-surface":
            try runMoveSurface(commandArgs: commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        case "reorder-surface":
            try runReorderSurface(commandArgs: commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        case "reorder-workspace":
            try runReorderWorkspace(commandArgs: commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        case "workspace-action":
            try runWorkspaceAction(commandArgs: commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat, windowOverride: windowId)

        case "tab-action":
            try runTabAction(commandArgs: commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat, windowOverride: windowId)

        case "rename-tab":
            try runRenameTab(commandArgs: commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat, windowOverride: windowId)

        case "list-workspaces":
            let payload = try client.sendV2(method: "workspace.list")
            if jsonOutput {
                print(jsonString(formatIDs(payload, mode: idFormat)))
            } else {
                let workspaces = payload["workspaces"] as? [[String: Any]] ?? []
                if workspaces.isEmpty {
                    print("No workspaces")
                } else {
                    for ws in workspaces {
                        let selected = (ws["selected"] as? Bool) == true
                        let handle = textHandle(ws, idFormat: idFormat)
                        let title = (ws["title"] as? String) ?? ""
                        let prefix = selected ? "* " : "  "
                        let selTag = selected ? "  [selected]" : ""
                        let titlePart = title.isEmpty ? "" : "  \(title)"
                        print("\(prefix)\(handle)\(titlePart)\(selTag)")
                    }
                }
            }

        case "new-workspace":
            let (commandOpt, remaining) = parseOption(commandArgs, name: "--command")
            if let unknown = remaining.first(where: { $0.hasPrefix("--") }) {
                throw CLIError(message: "new-workspace: unknown flag '\(unknown)'. Known flags: --command <text>")
            }
            let response = try sendV1Command("new_workspace", client: client)
            print(response)
            if let commandText = commandOpt {
                guard response.hasPrefix("OK ") else {
                    throw CLIError(message: "new-workspace failed, cannot run --command")
                }
                let wsId = String(response.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
                // Wait for shell to initialize
                Thread.sleep(forTimeInterval: 0.5)
                let text = unescapeSendText(commandText + "\\n")
                let params: [String: Any] = ["text": text, "workspace_id": wsId]
                _ = try client.sendV2(method: "surface.send_text", params: params)
            }

        case "new-split":
            let (wsArg, rem0) = parseOption(commandArgs, name: "--workspace")
            let (panelArg, rem1) = parseOption(rem0, name: "--panel")
            let (sfArg, rem2) = parseOption(rem1, name: "--surface")
            let workspaceArg = wsArg ?? (windowId == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
            let surfaceRaw = sfArg ?? panelArg ?? (wsArg == nil && windowId == nil ? ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"] : nil)
            guard let direction = rem2.first else {
                throw CLIError(message: "new-split requires a direction")
            }
            var params: [String: Any] = ["direction": direction]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let sfId = try normalizeSurfaceHandle(surfaceRaw, client: client, workspaceHandle: wsId)
            if let sfId { params["surface_id"] = sfId }
            let payload = try client.sendV2(method: "surface.split", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat))

        case "list-panes":
            let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowId)
            var params: [String: Any] = [:]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let payload = try client.sendV2(method: "pane.list", params: params)
            if jsonOutput {
                print(jsonString(formatIDs(payload, mode: idFormat)))
            } else {
                let panes = payload["panes"] as? [[String: Any]] ?? []
                if panes.isEmpty {
                    print("No panes")
                } else {
                    for pane in panes {
                        let focused = (pane["focused"] as? Bool) == true
                        let handle = textHandle(pane, idFormat: idFormat)
                        let count = pane["surface_count"] as? Int ?? 0
                        let prefix = focused ? "* " : "  "
                        let focusTag = focused ? "  [focused]" : ""
                        print("\(prefix)\(handle)  [\(count) surface\(count == 1 ? "" : "s")]\(focusTag)")
                    }
                }
            }

        case "list-pane-surfaces":
            let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowId)
            let paneRaw = optionValue(commandArgs, name: "--pane")
            var params: [String: Any] = [:]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let paneId = try normalizePaneHandle(paneRaw, client: client, workspaceHandle: wsId)
            if let paneId { params["pane_id"] = paneId }
            let payload = try client.sendV2(method: "pane.surfaces", params: params)
            if jsonOutput {
                print(jsonString(formatIDs(payload, mode: idFormat)))
            } else {
                let surfaces = payload["surfaces"] as? [[String: Any]] ?? []
                if surfaces.isEmpty {
                    print("No surfaces in pane")
                } else {
                    for surface in surfaces {
                        let selected = (surface["selected"] as? Bool) == true
                        let handle = textHandle(surface, idFormat: idFormat)
                        let title = (surface["title"] as? String) ?? ""
                        let prefix = selected ? "* " : "  "
                        let selTag = selected ? "  [selected]" : ""
                        print("\(prefix)\(handle)  \(title)\(selTag)")
                    }
                }
            }

        case "focus-pane":
            let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowId)
            guard let paneRaw = optionValue(commandArgs, name: "--pane") ?? commandArgs.first else {
                throw CLIError(message: "focus-pane requires --pane <id|ref>")
            }
            var params: [String: Any] = [:]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let paneId = try normalizePaneHandle(paneRaw, client: client, workspaceHandle: wsId)
            if let paneId { params["pane_id"] = paneId }
            let payload = try client.sendV2(method: "pane.focus", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat, kinds: ["pane", "workspace"]))

        case "new-pane":
            let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowId)
            let type = optionValue(commandArgs, name: "--type")
            let direction = optionValue(commandArgs, name: "--direction") ?? "right"
            let url = optionValue(commandArgs, name: "--url")
            var params: [String: Any] = ["direction": direction]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            if let type { params["type"] = type }
            if let url { params["url"] = url }
            let payload = try client.sendV2(method: "pane.create", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat, kinds: ["surface", "pane", "workspace"]))

        case "new-surface":
            let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowId)
            let type = optionValue(commandArgs, name: "--type")
            let paneRaw = optionValue(commandArgs, name: "--pane")
            let url = optionValue(commandArgs, name: "--url")
            var params: [String: Any] = [:]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let paneId = try normalizePaneHandle(paneRaw, client: client, workspaceHandle: wsId)
            if let paneId { params["pane_id"] = paneId }
            if let type { params["type"] = type }
            if let url { params["url"] = url }
            let payload = try client.sendV2(method: "surface.create", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat, kinds: ["surface", "pane", "workspace"]))

        case "close-surface":
            let csWsFlag = optionValue(commandArgs, name: "--workspace")
            let workspaceArg = csWsFlag ?? (windowId == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
            let surfaceRaw = optionValue(commandArgs, name: "--surface") ?? optionValue(commandArgs, name: "--panel") ?? (csWsFlag == nil && windowId == nil ? ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"] : nil)
            var params: [String: Any] = [:]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let sfId = try normalizeSurfaceHandle(surfaceRaw, client: client, workspaceHandle: wsId)
            if let sfId { params["surface_id"] = sfId }
            let payload = try client.sendV2(method: "surface.close", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat))

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
            let response = try sendV1Command("drag_surface_to_split \(surface) \(direction)", client: client)
            print(response)

        case "refresh-surfaces":
            let response = try sendV1Command("refresh_surfaces", client: client)
            print(response)

        case "surface-health":
            let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowId)
            var params: [String: Any] = [:]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let payload = try client.sendV2(method: "surface.health", params: params)
            if jsonOutput {
                print(jsonString(formatIDs(payload, mode: idFormat)))
            } else {
                let surfaces = payload["surfaces"] as? [[String: Any]] ?? []
                if surfaces.isEmpty {
                    print("No surfaces")
                } else {
                    for surface in surfaces {
                        let handle = textHandle(surface, idFormat: idFormat)
                        let sType = (surface["type"] as? String) ?? ""
                        let inWindow = surface["in_window"]
                        let inWindowStr: String
                        if let b = inWindow as? Bool {
                            inWindowStr = " in_window=\(b)"
                        } else {
                            inWindowStr = ""
                        }
                        print("\(handle)  type=\(sType)\(inWindowStr)")
                    }
                }
            }

        case "trigger-flash":
            let tfWsFlag = optionValue(commandArgs, name: "--workspace")
            let workspaceArg = tfWsFlag ?? (windowId == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
            let surfaceArg = optionValue(commandArgs, name: "--surface") ?? optionValue(commandArgs, name: "--panel") ?? (tfWsFlag == nil && windowId == nil ? ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"] : nil)
            var params: [String: Any] = [:]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let sfId = try normalizeSurfaceHandle(surfaceArg, client: client, workspaceHandle: wsId)
            if let sfId { params["surface_id"] = sfId }
            let payload = try client.sendV2(method: "surface.trigger_flash", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat))

        case "list-panels":
            let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowId)
            var params: [String: Any] = [:]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let payload = try client.sendV2(method: "surface.list", params: params)
            if jsonOutput {
                print(jsonString(formatIDs(payload, mode: idFormat)))
            } else {
                let surfaces = payload["surfaces"] as? [[String: Any]] ?? []
                if surfaces.isEmpty {
                    print("No surfaces")
                } else {
                    for surface in surfaces {
                        let focused = (surface["focused"] as? Bool) == true
                        let handle = textHandle(surface, idFormat: idFormat)
                        let sType = (surface["type"] as? String) ?? ""
                        let title = (surface["title"] as? String) ?? ""
                        let prefix = focused ? "* " : "  "
                        let focusTag = focused ? "  [focused]" : ""
                        let titlePart = title.isEmpty ? "" : "  \"\(title)\""
                        print("\(prefix)\(handle)  \(sType)\(focusTag)\(titlePart)")
                    }
                }
            }

        case "focus-panel":
            let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowId)
            guard let panelRaw = optionValue(commandArgs, name: "--panel") else {
                throw CLIError(message: "focus-panel requires --panel")
            }
            var params: [String: Any] = [:]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let sfId = try normalizeSurfaceHandle(panelRaw, client: client, workspaceHandle: wsId)
            if let sfId { params["surface_id"] = sfId }
            let payload = try client.sendV2(method: "surface.focus", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat))

        case "close-workspace":
            guard let workspaceRaw = optionValue(commandArgs, name: "--workspace") else {
                throw CLIError(message: "close-workspace requires --workspace")
            }
            var params: [String: Any] = [:]
            let wsId = try normalizeWorkspaceHandle(workspaceRaw, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let payload = try client.sendV2(method: "workspace.close", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat, kinds: ["workspace"]))

        case "select-workspace":
            guard let workspaceRaw = optionValue(commandArgs, name: "--workspace") else {
                throw CLIError(message: "select-workspace requires --workspace")
            }
            var params: [String: Any] = [:]
            let wsId = try normalizeWorkspaceHandle(workspaceRaw, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let payload = try client.sendV2(method: "workspace.select", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat, kinds: ["workspace"]))

        case "rename-workspace", "rename-window":
            let (wsArg, rem0) = parseOption(commandArgs, name: "--workspace")
            let workspaceArg = wsArg ?? (windowId == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
            let titleArgs = rem0.dropFirst(rem0.first == "--" ? 1 : 0)
            let title = titleArgs.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else {
                throw CLIError(message: "\(command) requires a title")
            }
            let wsId = try resolveWorkspaceId(workspaceArg, client: client)
            let params: [String: Any] = ["title": title, "workspace_id": wsId]
            let payload = try client.sendV2(method: "workspace.rename", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat, kinds: ["workspace"]))

        case "current-workspace":
            let response = try sendV1Command("current_workspace", client: client)
            if jsonOutput {
                print(jsonString(["workspace_id": response]))
            } else {
                print(response)
            }

        case "read-screen":
            let (wsArg, rem0) = parseOption(commandArgs, name: "--workspace")
            let (sfArg, rem1) = parseOption(rem0, name: "--surface")
            let (linesArg, rem2) = parseOption(rem1, name: "--lines")
            let trailing = rem2.filter { $0 != "--scrollback" }
            if !trailing.isEmpty {
                throw CLIError(message: "read-screen: unexpected arguments: \(trailing.joined(separator: " "))")
            }

            let workspaceArg = wsArg ?? (windowId == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
            let surfaceArg = sfArg ?? (wsArg == nil && windowId == nil ? ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"] : nil)

            var params: [String: Any] = [:]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let sfId = try normalizeSurfaceHandle(surfaceArg, client: client, workspaceHandle: wsId)
            if let sfId { params["surface_id"] = sfId }

            let includeScrollback = rem2.contains("--scrollback")
            if includeScrollback {
                params["scrollback"] = true
            }
            if let linesArg {
                guard let lineCount = Int(linesArg), lineCount > 0 else {
                    throw CLIError(message: "--lines must be greater than 0")
                }
                params["lines"] = lineCount
                params["scrollback"] = true
            }

            let payload = try client.sendV2(method: "surface.read_text", params: params)
            if jsonOutput {
                print(jsonString(payload))
            } else {
                print((payload["text"] as? String) ?? "")
            }

        case "send":
            let (wsArg, rem0) = parseOption(commandArgs, name: "--workspace")
            let (sfArg, rem1) = parseOption(rem0, name: "--surface")
            let workspaceArg = wsArg ?? (windowId == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
            let surfaceArg = sfArg ?? (wsArg == nil && windowId == nil ? ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"] : nil)
            let rawText = rem1.dropFirst(rem1.first == "--" ? 1 : 0).joined(separator: " ")
            guard !rawText.isEmpty else { throw CLIError(message: "send requires text") }
            let text = unescapeSendText(rawText)
            var params: [String: Any] = ["text": text]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let sfId = try normalizeSurfaceHandle(surfaceArg, client: client, workspaceHandle: wsId)
            if let sfId { params["surface_id"] = sfId }
            let payload = try client.sendV2(method: "surface.send_text", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat))

        case "send-key":
            let (wsArg, rem0) = parseOption(commandArgs, name: "--workspace")
            let (sfArg, rem1) = parseOption(rem0, name: "--surface")
            let workspaceArg = wsArg ?? (windowId == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
            let surfaceArg = sfArg ?? (wsArg == nil && windowId == nil ? ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"] : nil)
            let keyArgs = rem1.first == "--" ? Array(rem1.dropFirst()) : rem1
            guard let key = keyArgs.first else { throw CLIError(message: "send-key requires a key") }
            var params: [String: Any] = ["key": key]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let sfId = try normalizeSurfaceHandle(surfaceArg, client: client, workspaceHandle: wsId)
            if let sfId { params["surface_id"] = sfId }
            let payload = try client.sendV2(method: "surface.send_key", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat))

        case "send-panel":
            let (wsArg, rem0) = parseOption(commandArgs, name: "--workspace")
            let (panelArg, rem1) = parseOption(rem0, name: "--panel")
            let workspaceArg = wsArg ?? (windowId == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
            guard let panelArg else {
                throw CLIError(message: "send-panel requires --panel")
            }
            let rawText = rem1.dropFirst(rem1.first == "--" ? 1 : 0).joined(separator: " ")
            guard !rawText.isEmpty else { throw CLIError(message: "send-panel requires text") }
            let text = unescapeSendText(rawText)
            var params: [String: Any] = ["text": text]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let sfId = try normalizeSurfaceHandle(panelArg, client: client, workspaceHandle: wsId)
            if let sfId { params["surface_id"] = sfId }
            let payload = try client.sendV2(method: "surface.send_text", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat))

        case "send-key-panel":
            let (wsArg, rem0) = parseOption(commandArgs, name: "--workspace")
            let (panelArg, rem1) = parseOption(rem0, name: "--panel")
            let workspaceArg = wsArg ?? (windowId == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
            guard let panelArg else {
                throw CLIError(message: "send-key-panel requires --panel")
            }
            let skpArgs = rem1.first == "--" ? Array(rem1.dropFirst()) : rem1
            let key = skpArgs.first ?? ""
            guard !key.isEmpty else { throw CLIError(message: "send-key-panel requires a key") }
            var params: [String: Any] = ["key": key]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let sfId = try normalizeSurfaceHandle(panelArg, client: client, workspaceHandle: wsId)
            if let sfId { params["surface_id"] = sfId }
            let payload = try client.sendV2(method: "surface.send_key", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat))

        case "notify":
            let title = optionValue(commandArgs, name: "--title") ?? "Notification"
            let subtitle = optionValue(commandArgs, name: "--subtitle") ?? ""
            let body = optionValue(commandArgs, name: "--body") ?? ""

            let notifyWsFlag = optionValue(commandArgs, name: "--workspace")
            let workspaceArg = notifyWsFlag ?? (windowId == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
            let surfaceArg = optionValue(commandArgs, name: "--surface") ?? (notifyWsFlag == nil && windowId == nil ? ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"] : nil)

            let targetWorkspace = try resolveWorkspaceId(workspaceArg, client: client)
            let targetSurface = try resolveSurfaceId(surfaceArg, workspaceId: targetWorkspace, client: client)

            let payload = "\(title)|\(subtitle)|\(body)"
            let response = try sendV1Command("notify_target \(targetWorkspace) \(targetSurface) \(payload)", client: client)
            print(response)

        case "list-notifications":
            let response = try sendV1Command("list_notifications", client: client)
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
            let response = try sendV1Command("clear_notifications", client: client)
            print(response)

        case "claude-hook":
            cliTelemetry.breadcrumb("claude-hook.dispatch")
            do {
                try runClaudeHook(commandArgs: commandArgs, client: client, telemetry: cliTelemetry)
                cliTelemetry.breadcrumb("claude-hook.completed")
            } catch {
                cliTelemetry.breadcrumb("claude-hook.failure")
                cliTelemetry.captureError(stage: "claude_hook_dispatch", error: error)
                throw error
            }

        case "set-status":
            let (icon, r1) = parseOption(commandArgs, name: "--icon")
            let (color, r2) = parseOption(r1, name: "--color")
            let (wsFlag, r3) = parseOption(r2, name: "--workspace")
            guard r3.count >= 2 else {
                throw CLIError(message: "set-status requires <key> and <value>")
            }
            let key = r3[0]
            let value = r3.dropFirst().joined(separator: " ")
            guard !value.isEmpty else {
                throw CLIError(message: "set-status requires a non-empty value")
            }
            let workspaceArg = wsFlag ?? (windowId == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
            let wsId = try resolveWorkspaceId(workspaceArg, client: client)
            var socketCmd = "set_status \(key) \(socketQuote(value))"
            if let icon { socketCmd += " --icon=\(socketQuote(icon))" }
            if let color { socketCmd += " --color=\(socketQuote(color))" }
            socketCmd += " --tab=\(wsId)"
            let response = try sendV1Command(socketCmd, client: client)
            print(response)

        case "clear-status":
            let (wsFlag, csRemaining) = parseOption(commandArgs, name: "--workspace")
            guard let key = csRemaining.first else {
                throw CLIError(message: "clear-status requires a <key>")
            }
            let workspaceArg = wsFlag ?? (windowId == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
            let wsId = try resolveWorkspaceId(workspaceArg, client: client)
            let response = try sendV1Command("clear_status \(key) --tab=\(wsId)", client: client)
            print(response)

        case "list-status":
            let (wsFlag, _) = parseOption(commandArgs, name: "--workspace")
            let workspaceArg = wsFlag ?? (windowId == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
            let wsId = try resolveWorkspaceId(workspaceArg, client: client)
            let response = try sendV1Command("list_status --tab=\(wsId)", client: client)
            print(response)

        case "set-progress":
            let (label, spR1) = parseOption(commandArgs, name: "--label")
            let (wsFlag, spR2) = parseOption(spR1, name: "--workspace")
            guard let valueStr = spR2.first else {
                throw CLIError(message: "set-progress requires a progress value (0.0-1.0)")
            }
            let workspaceArg = wsFlag ?? (windowId == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
            let wsId = try resolveWorkspaceId(workspaceArg, client: client)
            var socketCmd = "set_progress \(valueStr)"
            if let label { socketCmd += " --label=\(socketQuote(label))" }
            socketCmd += " --tab=\(wsId)"
            let response = try sendV1Command(socketCmd, client: client)
            print(response)

        case "clear-progress":
            let (wsFlag, _) = parseOption(commandArgs, name: "--workspace")
            let workspaceArg = wsFlag ?? (windowId == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
            let wsId = try resolveWorkspaceId(workspaceArg, client: client)
            let response = try sendV1Command("clear_progress --tab=\(wsId)", client: client)
            print(response)

        case "log":
            let (level, r1) = parseOption(commandArgs, name: "--level")
            let (source, r2) = parseOption(r1, name: "--source")
            let (wsFlag, r3) = parseOption(r2, name: "--workspace")
            // Strip leading "--" separator if present
            let positional = r3.first == "--" ? Array(r3.dropFirst()) : r3
            let message = positional.joined(separator: " ")
            guard !message.isEmpty else {
                throw CLIError(message: "log requires a message")
            }
            let workspaceArg = wsFlag ?? (windowId == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
            let wsId = try resolveWorkspaceId(workspaceArg, client: client)
            var socketCmd = "log"
            if let level { socketCmd += " --level=\(level)" }
            if let source { socketCmd += " --source=\(socketQuote(source))" }
            socketCmd += " --tab=\(wsId) -- \(socketQuote(message))"
            let response = try sendV1Command(socketCmd, client: client)
            print(response)

        case "clear-log":
            let (wsFlag, _) = parseOption(commandArgs, name: "--workspace")
            let workspaceArg = wsFlag ?? (windowId == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
            let wsId = try resolveWorkspaceId(workspaceArg, client: client)
            let response = try sendV1Command("clear_log --tab=\(wsId)", client: client)
            print(response)

        case "list-log":
            let (limitStr, r1) = parseOption(commandArgs, name: "--limit")
            let (wsFlag, _) = parseOption(r1, name: "--workspace")
            let workspaceArg = wsFlag ?? (windowId == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
            let wsId = try resolveWorkspaceId(workspaceArg, client: client)
            var socketCmd = "list_log"
            if let limitStr { socketCmd += " --limit=\(limitStr)" }
            socketCmd += " --tab=\(wsId)"
            let response = try sendV1Command(socketCmd, client: client)
            print(response)

        case "sidebar-state":
            let (wsFlag, _) = parseOption(commandArgs, name: "--workspace")
            let workspaceArg = wsFlag ?? (windowId == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
            let wsId = try resolveWorkspaceId(workspaceArg, client: client)
            let response = try sendV1Command("sidebar_state --tab=\(wsId)", client: client)
            print(response)

        case "set-app-focus":
            guard let value = commandArgs.first else { throw CLIError(message: "set-app-focus requires a value") }
            let response = try sendV1Command("set_app_focus \(value)", client: client)
            print(response)

        case "simulate-app-active":
            let response = try sendV1Command("simulate_app_active", client: client)
            print(response)

        case "capture-pane",
             "resize-pane",
             "pipe-pane",
             "wait-for",
             "swap-pane",
             "break-pane",
             "join-pane",
             "last-window",
             "last-pane",
             "next-window",
             "previous-window",
             "find-window",
             "clear-history",
             "set-hook",
             "popup",
             "bind-key",
             "unbind-key",
             "copy-mode",
             "set-buffer",
             "paste-buffer",
             "list-buffers",
             "respawn-pane",
             "display-message":
            try runTmuxCompatCommand(
                command: command,
                commandArgs: commandArgs,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat,
                windowOverride: windowId
            )

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

    private func sendV1Command(_ command: String, client: SocketClient) throws -> String {
        let response = try client.send(command: command)
        if response.hasPrefix("ERROR:") {
            throw CLIError(message: response)
        }
        return response
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
                for key in keys where key.hasSuffix("_ids") {
                    let prefix = String(key.dropLast(4))
                    if out["\(prefix)_refs"] != nil {
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
                for key in keys where key.hasSuffix("_refs") {
                    let prefix = String(key.dropLast(5))
                    if out["\(prefix)_ids"] != nil {
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
            throw CLIError(message: "Invalid window handle: \(trimmed) (expected UUID, ref like window:1, or index)")
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
            throw CLIError(message: "Invalid workspace handle: \(trimmed) (expected UUID, ref like workspace:1, or index)")
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
            throw CLIError(message: "Invalid pane handle: \(trimmed) (expected UUID, ref like pane:1, or index)")
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
            throw CLIError(message: "Invalid surface handle: \(trimmed) (expected UUID, ref like surface:1, or index)")
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

    private func canonicalSurfaceHandleFromTabInput(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let pieces = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 2,
              String(pieces[0]).lowercased() == "tab",
              let ordinal = Int(String(pieces[1])) else {
            return trimmed
        }
        return "surface:\(ordinal)"
    }

    private func normalizeTabHandle(
        _ raw: String?,
        client: SocketClient,
        workspaceHandle: String? = nil,
        allowFocused: Bool = false
    ) throws -> String? {
        guard let raw else {
            return try normalizeSurfaceHandle(
                nil,
                client: client,
                workspaceHandle: workspaceHandle,
                allowFocused: allowFocused
            )
        }

        let canonical = canonicalSurfaceHandleFromTabInput(raw)
        return try normalizeSurfaceHandle(
            canonical,
            client: client,
            workspaceHandle: workspaceHandle,
            allowFocused: false
        )
    }

    private func displayTabHandle(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let pieces = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 2,
              String(pieces[0]).lowercased() == "surface",
              let ordinal = Int(String(pieces[1])) else {
            return trimmed
        }
        return "tab:\(ordinal)"
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

    private func formatTabHandle(_ payload: [String: Any], idFormat: CLIIDFormat) -> String? {
        let id = (payload["tab_id"] as? String) ?? (payload["surface_id"] as? String)
        let refRaw = (payload["tab_ref"] as? String) ?? (payload["surface_ref"] as? String)
        let ref = displayTabHandle(refRaw)
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

    private func formatCreatedTabHandle(_ payload: [String: Any], idFormat: CLIIDFormat) -> String? {
        let id = (payload["created_tab_id"] as? String) ?? (payload["created_surface_id"] as? String)
        let refRaw = (payload["created_tab_ref"] as? String) ?? (payload["created_surface_ref"] as? String)
        let ref = displayTabHandle(refRaw)
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

    private func runWorkspaceAction(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        let (workspaceOpt, rem0) = parseOption(commandArgs, name: "--workspace")
        let (actionOpt, rem1) = parseOption(rem0, name: "--action")
        let (titleOpt, rem2) = parseOption(rem1, name: "--title")

        var positional = rem2
        let actionRaw: String
        if let actionOpt {
            actionRaw = actionOpt
        } else if let first = positional.first {
            actionRaw = first
            positional.removeFirst()
        } else {
            throw CLIError(message: "workspace-action requires --action <name>")
        }

        if let unknown = positional.first(where: { $0.hasPrefix("--") }) {
            throw CLIError(message: "workspace-action: unknown flag '\(unknown)'")
        }

        let action = actionRaw.lowercased().replacingOccurrences(of: "-", with: "_")
        let workspaceArg = workspaceOpt ?? (windowOverride == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
        let workspaceId = try normalizeWorkspaceHandle(workspaceArg, client: client, allowCurrent: true)

        let inferredTitle = positional.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (titleOpt ?? (inferredTitle.isEmpty ? nil : inferredTitle))?.trimmingCharacters(in: .whitespacesAndNewlines)

        if action == "rename", (title?.isEmpty ?? true) {
            throw CLIError(message: "workspace-action rename requires --title <text> (or a trailing title)")
        }

        var params: [String: Any] = ["action": action]
        if let workspaceId {
            params["workspace_id"] = workspaceId
        }
        if let title, !title.isEmpty {
            params["title"] = title
        }

        let payload = try client.sendV2(method: "workspace.action", params: params)
        var summaryParts = ["OK", "action=\(action)"]
        if let workspaceHandle = formatHandle(payload, kind: "workspace", idFormat: idFormat) {
            summaryParts.append("workspace=\(workspaceHandle)")
        }
        if let windowHandle = formatHandle(payload, kind: "window", idFormat: idFormat) {
            summaryParts.append("window=\(windowHandle)")
        }
        if let closed = payload["closed"] {
            summaryParts.append("closed=\(closed)")
        }
        if let index = payload["index"] {
            summaryParts.append("index=\(index)")
        }
        printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: summaryParts.joined(separator: " "))
    }

    private func runTabAction(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        let (workspaceOpt, rem0) = parseOption(commandArgs, name: "--workspace")
        let (tabOpt, rem1) = parseOption(rem0, name: "--tab")
        let (surfaceOpt, rem2) = parseOption(rem1, name: "--surface")
        let (actionOpt, rem3) = parseOption(rem2, name: "--action")
        let (titleOpt, rem4) = parseOption(rem3, name: "--title")
        let (urlOpt, rem5) = parseOption(rem4, name: "--url")

        var positional = rem5
        let actionRaw: String
        if let actionOpt {
            actionRaw = actionOpt
        } else if let first = positional.first {
            actionRaw = first
            positional.removeFirst()
        } else {
            throw CLIError(message: "tab-action requires --action <name>")
        }

        if let unknown = positional.first(where: { $0.hasPrefix("--") }) {
            throw CLIError(message: "tab-action: unknown flag '\(unknown)'")
        }

        let action = actionRaw.lowercased().replacingOccurrences(of: "-", with: "_")
        let workspaceArg = workspaceOpt ?? (windowOverride == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
        let tabArg = tabOpt
            ?? surfaceOpt
            ?? (workspaceOpt == nil && windowOverride == nil
                ? (ProcessInfo.processInfo.environment["CMUX_TAB_ID"] ?? ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"])
                : nil)

        let workspaceId = try normalizeWorkspaceHandle(workspaceArg, client: client, allowCurrent: true)
        // If a workspace is explicitly targeted and no tab/surface is provided, let server-side
        // tab.action resolve that workspace's focused tab instead of using global focus.
        let allowFocusedFallback = (workspaceId == nil)
        let surfaceId = try normalizeTabHandle(
            tabArg,
            client: client,
            workspaceHandle: workspaceId,
            allowFocused: allowFocusedFallback
        )

        let inferredTitle = positional.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (titleOpt ?? (inferredTitle.isEmpty ? nil : inferredTitle))?.trimmingCharacters(in: .whitespacesAndNewlines)

        if action == "rename", (title?.isEmpty ?? true) {
            throw CLIError(message: "tab-action rename requires --title <text> (or a trailing title)")
        }

        var params: [String: Any] = ["action": action]
        if let workspaceId {
            params["workspace_id"] = workspaceId
        }
        if let surfaceId {
            params["surface_id"] = surfaceId
        }
        if let title, !title.isEmpty {
            params["title"] = title
        }
        if let urlOpt, !urlOpt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            params["url"] = urlOpt.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let payload = try client.sendV2(method: "tab.action", params: params)
        var summaryParts = ["OK", "action=\(action)"]
        if let tabHandle = formatTabHandle(payload, idFormat: idFormat) {
            summaryParts.append("tab=\(tabHandle)")
        }
        if let workspaceHandle = formatHandle(payload, kind: "workspace", idFormat: idFormat) {
            summaryParts.append("workspace=\(workspaceHandle)")
        }
        if let closed = payload["closed"] {
            summaryParts.append("closed=\(closed)")
        }
        if let created = formatCreatedTabHandle(payload, idFormat: idFormat) {
            summaryParts.append("created=\(created)")
        }
        printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: summaryParts.joined(separator: " "))
    }

    private func runRenameTab(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        let (workspaceOpt, rem0) = parseOption(commandArgs, name: "--workspace")
        let (tabOpt, rem1) = parseOption(rem0, name: "--tab")
        let (surfaceOpt, rem2) = parseOption(rem1, name: "--surface")
        let (titleOpt, rem3) = parseOption(rem2, name: "--title")

        if rem3.contains("--action") {
            throw CLIError(message: "rename-tab does not accept --action (it always performs rename)")
        }
        if let unknown = rem3.first(where: { $0.hasPrefix("--") && $0 != "--" }) {
            throw CLIError(message: "rename-tab: unknown flag '\(unknown)'")
        }

        let inferredTitle = rem3
            .dropFirst(rem3.first == "--" ? 1 : 0)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (titleOpt ?? (inferredTitle.isEmpty ? nil : inferredTitle))?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let title, !title.isEmpty else {
            throw CLIError(message: "rename-tab requires a title")
        }

        var forwarded: [String] = ["--action", "rename", "--title", title]
        if let workspaceOpt {
            forwarded += ["--workspace", workspaceOpt]
        }
        if let tabOpt {
            forwarded += ["--tab", tabOpt]
        } else if let surfaceOpt {
            forwarded += ["--surface", surfaceOpt]
        }

        try runTabAction(
            commandArgs: forwarded,
            client: client,
            jsonOutput: jsonOutput,
            idFormat: idFormat,
            windowOverride: windowOverride
        )
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

        func displayBrowserValue(_ value: Any) -> String {
            if value is NSNull {
                return "null"
            }
            if let string = value as? String {
                return string
            }
            if let bool = value as? Bool {
                return bool ? "true" : "false"
            }
            if let number = value as? NSNumber {
                return number.stringValue
            }
            if JSONSerialization.isValidJSONObject(value),
               let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted]),
               let text = String(data: data, encoding: .utf8) {
                return text
            }
            return String(describing: value)
        }

        func displayBrowserLogItems(_ value: Any?) -> String? {
            guard let items = value as? [Any], !items.isEmpty else {
                return nil
            }

            let lines = items.map { item -> String in
                guard let dict = item as? [String: Any] else {
                    return displayBrowserValue(item)
                }

                let text = (dict["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let levelRaw = (dict["level"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let level = levelRaw.isEmpty ? "log" : levelRaw

                if text.isEmpty {
                    if let message = (dict["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !message.isEmpty {
                        return "[error] \(message)"
                    }
                    return displayBrowserValue(dict)
                }
                return "[\(level)] \(text)"
            }

            return lines.joined(separator: "\n")
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
            let workspaceRaw = workspaceOpt ?? (windowOpt == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
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
            let fallback: String
            if let value = payload["value"] {
                fallback = displayBrowserValue(value)
            } else {
                fallback = "OK"
            }
            output(payload, fallback: fallback)
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
            let fallback = displayBrowserLogItems(payload["entries"]) ?? "OK"
            output(payload, fallback: fallback)
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
            let fallback = displayBrowserLogItems(payload["errors"]) ?? "OK"
            output(payload, fallback: fallback)
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
        if let raw, isHandleRef(raw) {
            // Resolve ref to UUID — search across all windows
            let windows = try client.sendV2(method: "window.list")
            let windowList = windows["windows"] as? [[String: Any]] ?? []
            for window in windowList {
                guard let windowId = window["id"] as? String else { continue }
                let listed = try client.sendV2(method: "workspace.list", params: ["window_id": windowId])
                let items = listed["workspaces"] as? [[String: Any]] ?? []
                for item in items where (item["ref"] as? String) == raw {
                    if let id = item["id"] as? String { return id }
                }
            }
            throw CLIError(message: "Workspace ref not found: \(raw)")
        }

        if let raw, let index = Int(raw) {
            let listed = try client.sendV2(method: "workspace.list")
            let items = listed["workspaces"] as? [[String: Any]] ?? []
            for item in items where intFromAny(item["index"]) == index {
                if let id = item["id"] as? String { return id }
            }
            throw CLIError(message: "Workspace index not found")
        }

        let current = try client.sendV2(method: "workspace.current")
        if let wsId = current["workspace_id"] as? String { return wsId }
        throw CLIError(message: "No workspace selected")
    }

    private func resolveSurfaceId(_ raw: String?, workspaceId: String, client: SocketClient) throws -> String {
        if let raw, isUUID(raw) {
            return raw
        }
        if let raw, isHandleRef(raw) {
            let listed = try client.sendV2(method: "surface.list", params: ["workspace_id": workspaceId])
            let items = listed["surfaces"] as? [[String: Any]] ?? []
            for item in items where (item["ref"] as? String) == raw {
                if let id = item["id"] as? String { return id }
            }
            throw CLIError(message: "Surface ref not found: \(raw)")
        }

        let listed = try client.sendV2(method: "surface.list", params: ["workspace_id": workspaceId])
        let items = listed["surfaces"] as? [[String: Any]] ?? []

        if let raw, let index = Int(raw) {
            for item in items where intFromAny(item["index"]) == index {
                if let id = item["id"] as? String { return id }
            }
            throw CLIError(message: "Surface index not found")
        }

        if let focused = items.first(where: { ($0["focused"] as? Bool) == true }) {
            if let id = focused["id"] as? String { return id }
        }

        throw CLIError(message: "Unable to resolve surface ID")
    }

    /// Return the help/usage text for a subcommand, or nil if the command has no
    /// dedicated help (e.g. simple no-arg commands like `ping`).
    private func subcommandUsage(_ command: String) -> String? {
        switch command {
        case "focus-window":
            return """
            Usage: cmux focus-window --window <id|ref|index>

            Focus (bring to front) the specified window.

            Flags:
              --window <id|ref|index>   Window to focus (required)

            Example:
              cmux focus-window --window 0
              cmux focus-window --window window:1
            """
        case "close-window":
            return """
            Usage: cmux close-window --window <id|ref|index>

            Close the specified window.

            Flags:
              --window <id|ref|index>   Window to close (required)

            Example:
              cmux close-window --window 0
              cmux close-window --window window:1
            """
        case "move-workspace-to-window":
            return """
            Usage: cmux move-workspace-to-window --workspace <id|ref> --window <id|ref>

            Move a workspace to a different window.

            Flags:
              --workspace <id|ref>   Workspace to move (required)
              --window <id|ref>      Target window (required)

            Example:
              cmux move-workspace-to-window --workspace workspace:2 --window window:1
            """
        case "move-surface":
            return """
            Usage: cmux move-surface --surface <id|ref|index> [flags]

            Move a surface to a different pane, workspace, or window.

            Flags:
              --surface <id|ref|index>   Surface to move (required)
              --pane <id|ref|index>      Target pane
              --workspace <id|ref|index> Target workspace
              --window <id|ref|index>    Target window
              --before <id|ref|index>    Place before this surface
              --after <id|ref|index>     Place after this surface
              --index <n>                Place at this index
              --focus <true|false>       Focus the surface after moving

            Example:
              cmux move-surface --surface surface:1 --workspace workspace:2
              cmux move-surface --surface 0 --pane pane:2 --index 0
            """
        case "reorder-surface":
            return """
            Usage: cmux reorder-surface --surface <id|ref|index> [flags]

            Reorder a surface within its pane.

            Flags:
              --surface <id|ref|index>   Surface to reorder (required)
              --before <id|ref|index>    Place before this surface
              --after <id|ref|index>     Place after this surface
              --index <n>                Place at this index

            Example:
              cmux reorder-surface --surface surface:1 --index 0
              cmux reorder-surface --surface surface:3 --after surface:1
            """
        case "reorder-workspace":
            return """
            Usage: cmux reorder-workspace --workspace <id|ref|index> [flags]

            Reorder a workspace within its window.

            Flags:
              --workspace <id|ref|index>   Workspace to reorder (required)
              --index <n>                  Place at this index
              --before <id|ref|index>      Place before this workspace
              --after <id|ref|index>       Place after this workspace
              --window <id|ref|index>      Window context

            Example:
              cmux reorder-workspace --workspace workspace:2 --index 0
              cmux reorder-workspace --workspace workspace:3 --after workspace:1
            """
        case "workspace-action":
            return """
            Usage: cmux workspace-action --action <name> [flags]

            Perform workspace context-menu actions from CLI/socket.

            Actions:
              pin | unpin
              rename | clear-name
              move-up | move-down | move-top
              close-others | close-above | close-below
              mark-read | mark-unread

            Flags:
              --action <name>              Action name (required if not positional)
              --workspace <id|ref|index>   Target workspace (default: current/$CMUX_WORKSPACE_ID)
              --title <text>               Title for rename

            Example:
              cmux workspace-action --workspace workspace:2 --action pin
              cmux workspace-action --action rename --title "infra"
              cmux workspace-action close-others
            """
        case "tab-action":
            return """
            Usage: cmux tab-action --action <name> [flags]

            Perform horizontal tab context-menu actions from CLI/socket.

            Actions:
              rename | clear-name
              close-left | close-right | close-others
              new-terminal-right | new-browser-right
              reload | duplicate
              pin | unpin
              mark-read | mark-unread

            Flags:
              --action <name>              Action name (required if not positional)
              --tab <id|ref|index>         Target tab (accepts tab:<n> or surface:<n>; alias: --surface)
              --surface <id|ref|index>     Alias for --tab (backward compatibility)
              --workspace <id|ref|index>   Workspace context (default: current/$CMUX_WORKSPACE_ID)
              --title <text>               Title for rename
              --url <url>                  Optional URL for new-browser-right

            Example:
              cmux tab-action --tab tab:3 --action pin
              cmux tab-action --action close-right
              cmux tab-action --tab tab:2 --action rename --title "build logs"
            """
        case "rename-tab":
            return """
            Usage: cmux rename-tab [--workspace <id|ref>] [--tab <id|ref>] [--surface <id|ref>] [--] <title>

            Rename a tab (surface). Defaults to the focused tab, using:
            1) explicit --tab/--surface
            2) $CMUX_TAB_ID / $CMUX_SURFACE_ID
            3) focused tab in the resolved workspace context

            Flags:
              --workspace <id|ref>   Workspace context (default: current/$CMUX_WORKSPACE_ID)
              --tab <id|ref>         Target tab (accepts tab:<n> or surface:<n>)
              --surface <id|ref>     Alias for --tab
              --title <text>         New title (or pass trailing title)

            Example:
              cmux rename-tab "build logs"
              cmux rename-tab --tab tab:3 "staging server"
              cmux rename-tab --workspace workspace:2 --surface surface:5 --title "agent run"
            """
        case "new-workspace":
            return """
            Usage: cmux new-workspace

            Create a new workspace in the current window.

            Example:
              cmux new-workspace
            """
        case "new-split":
            return """
            Usage: cmux new-split <left|right|up|down> [flags]

            Split the current pane in the given direction.

            Flags:
              --workspace <id|ref>   Target workspace (default: $CMUX_WORKSPACE_ID)
              --surface <id|ref>     Surface to split from (default: $CMUX_SURFACE_ID)
              --panel <id|ref>       Alias for --surface

            Example:
              cmux new-split right
              cmux new-split down --workspace workspace:1
            """
        case "focus-pane":
            return """
            Usage: cmux focus-pane --pane <id|ref> [flags]

            Focus the specified pane.

            Flags:
              --pane <id|ref>          Pane to focus (required)
              --workspace <id|ref>     Workspace context (default: $CMUX_WORKSPACE_ID)

            Example:
              cmux focus-pane --pane pane:2
              cmux focus-pane --pane pane:1 --workspace workspace:2
            """
        case "new-pane":
            return """
            Usage: cmux new-pane [flags]

            Create a new pane in the workspace.

            Flags:
              --type <terminal|browser>           Pane type (default: terminal)
              --direction <left|right|up|down>    Split direction (default: right)
              --workspace <id|ref>                Target workspace (default: $CMUX_WORKSPACE_ID)
              --url <url>                         URL for browser panes

            Example:
              cmux new-pane
              cmux new-pane --type browser --direction down --url https://example.com
            """
        case "new-surface":
            return """
            Usage: cmux new-surface [flags]

            Create a new surface (tab) in a pane.

            Flags:
              --type <terminal|browser>   Surface type (default: terminal)
              --pane <id|ref>             Target pane
              --workspace <id|ref>        Target workspace (default: $CMUX_WORKSPACE_ID)
              --url <url>                 URL for browser surfaces

            Example:
              cmux new-surface
              cmux new-surface --type browser --pane pane:1 --url https://example.com
            """
        case "close-surface":
            return """
            Usage: cmux close-surface [flags]

            Close a surface. Defaults to the focused surface if none specified.

            Flags:
              --surface <id|ref>     Surface to close (default: $CMUX_SURFACE_ID)
              --panel <id|ref>       Alias for --surface
              --workspace <id|ref>   Workspace context (default: $CMUX_WORKSPACE_ID)

            Example:
              cmux close-surface
              cmux close-surface --surface surface:3
            """
        case "drag-surface-to-split":
            return """
            Usage: cmux drag-surface-to-split --surface <id|ref> <left|right|up|down>

            Drag a surface into a new split in the given direction.

            Flags:
              --surface <id|ref>   Surface to drag (required)
              --panel <id|ref>     Alias for --surface

            Example:
              cmux drag-surface-to-split --surface surface:1 right
              cmux drag-surface-to-split --panel surface:2 down
            """
        case "close-workspace":
            return """
            Usage: cmux close-workspace --workspace <id|ref>

            Close the specified workspace.

            Flags:
              --workspace <id|ref>   Workspace to close (required)

            Example:
              cmux close-workspace --workspace workspace:2
            """
        case "select-workspace":
            return """
            Usage: cmux select-workspace --workspace <id|ref>

            Select (switch to) the specified workspace.

            Flags:
              --workspace <id|ref>   Workspace to select (required)

            Example:
              cmux select-workspace --workspace workspace:2
              cmux select-workspace --workspace 0
            """
        case "rename-workspace", "rename-window":
            return """
            Usage: cmux rename-workspace [--workspace <id|ref>] [--] <title>

            Rename a workspace. Defaults to the current workspace.
            tmux-compatible alias: rename-window

            Flags:
              --workspace <id|ref>   Workspace to rename (default: current workspace)

            Example:
              cmux rename-workspace "backend logs"
              cmux rename-window --workspace workspace:2 "agent run"
            """
        case "capture-pane":
            return """
            Usage: cmux capture-pane [--workspace <id|ref>] [--surface <id|ref>] [--scrollback] [--lines <n>]

            tmux-compatible alias for reading terminal text from a pane.

            Example:
              cmux capture-pane --workspace workspace:2 --surface surface:1 --scrollback --lines 200
            """
        case "resize-pane":
            return """
            Usage: cmux resize-pane --pane <id|ref> [--workspace <id|ref>] (-L|-R|-U|-D) [--amount <n>]

            tmux-compatible pane resize command.
            Note: currently returns not_supported until programmable divider resize is implemented.
            """
        case "pipe-pane":
            return """
            Usage: cmux pipe-pane --command <shell-command> [--workspace <id|ref>] [--surface <id|ref>]

            Capture pane text and pipe it to a shell command via stdin.
            """
        case "wait-for":
            return """
            Usage: cmux wait-for [-S|--signal] <name> [--timeout <seconds>]

            Wait for or signal a named synchronization token.
            """
        case "swap-pane", "break-pane", "join-pane", "next-window", "previous-window", "last-window", "last-pane", "find-window", "clear-history", "set-hook", "popup", "bind-key", "unbind-key", "copy-mode", "set-buffer", "paste-buffer", "list-buffers", "respawn-pane", "display-message":
            return """
            Usage: cmux \(command) --help

            tmux compatibility command. See `cmux --help` for exact syntax.
            """
        case "read-screen":
            return """
            Usage: cmux read-screen [flags]

            Read terminal text from a surface as plain text.

            Flags:
              --workspace <id|ref>   Target workspace (default: $CMUX_WORKSPACE_ID)
              --surface <id|ref>     Target surface (default: $CMUX_SURFACE_ID)
              --scrollback           Include scrollback (not just visible viewport)
              --lines <n>            Limit to the last n lines (implies --scrollback)

            Example:
              cmux read-screen
              cmux read-screen --surface surface:2 --scrollback --lines 200
            """
        case "send":
            return """
            Usage: cmux send [flags] [--] <text>

            Send text to a terminal surface. Escape sequences: \\n and \\r send Enter, \\t sends Tab.

            Flags:
              --workspace <id|ref>   Target workspace (default: $CMUX_WORKSPACE_ID)
              --surface <id|ref>     Target surface (default: $CMUX_SURFACE_ID)

            Example:
              cmux send "echo hello"
              cmux send --surface surface:2 "ls -la\\n"
            """
        case "send-key":
            return """
            Usage: cmux send-key [flags] [--] <key>

            Send a key event to a terminal surface.

            Flags:
              --workspace <id|ref>   Target workspace (default: $CMUX_WORKSPACE_ID)
              --surface <id|ref>     Target surface (default: $CMUX_SURFACE_ID)

            Example:
              cmux send-key enter
              cmux send-key --surface surface:2 ctrl+c
            """
        case "send-panel":
            return """
            Usage: cmux send-panel --panel <id|ref> [flags] [--] <text>

            Send text to a specific panel (surface). Escape sequences: \\n and \\r send Enter, \\t sends Tab.

            Flags:
              --panel <id|ref>       Target panel (required)
              --workspace <id|ref>   Target workspace (default: $CMUX_WORKSPACE_ID)

            Example:
              cmux send-panel --panel surface:2 "echo hello\\n"
            """
        case "send-key-panel":
            return """
            Usage: cmux send-key-panel --panel <id|ref> [flags] [--] <key>

            Send a key event to a specific panel (surface).

            Flags:
              --panel <id|ref>       Target panel (required)
              --workspace <id|ref>   Target workspace (default: $CMUX_WORKSPACE_ID)

            Example:
              cmux send-key-panel --panel surface:2 enter
              cmux send-key-panel --panel surface:2 ctrl+c
            """
        case "notify":
            return """
            Usage: cmux notify [flags]

            Send a notification to a workspace/surface.

            Flags:
              --title <text>         Notification title (default: "Notification")
              --subtitle <text>      Notification subtitle
              --body <text>          Notification body
              --workspace <id|ref>   Target workspace (default: $CMUX_WORKSPACE_ID)
              --surface <id|ref>     Target surface (default: $CMUX_SURFACE_ID)

            Example:
              cmux notify --title "Build done" --body "All tests passed"
              cmux notify --title "Error" --subtitle "test.swift" --body "Line 42: syntax error"
            """
        case "set-status":
            return """
            Usage: cmux set-status <key> <value> [flags]

            Set a sidebar status entry for a workspace. Status entries appear as
            pills in the sidebar tab row. Use a unique key so different tools
            (e.g. "claude_code", "build") can manage their own entries.

            Flags:
              --icon <name>          Icon name (e.g. "sparkle", "hammer")
              --color <#hex>         Pill color (e.g. "#ff9500")
              --workspace <id|ref>   Target workspace (default: $CMUX_WORKSPACE_ID)

            Example:
              cmux set-status build "compiling" --icon hammer --color "#ff9500"
              cmux set-status deploy "v1.2.3" --workspace workspace:2
            """
        case "clear-status":
            return """
            Usage: cmux clear-status <key> [flags]

            Remove a sidebar status entry by key.

            Flags:
              --workspace <id|ref>   Target workspace (default: $CMUX_WORKSPACE_ID)

            Example:
              cmux clear-status build
            """
        case "list-status":
            return """
            Usage: cmux list-status [flags]

            List all sidebar status entries for a workspace.

            Flags:
              --workspace <id|ref>   Target workspace (default: $CMUX_WORKSPACE_ID)

            Example:
              cmux list-status
              cmux list-status --workspace workspace:2
            """
        case "set-progress":
            return """
            Usage: cmux set-progress <0.0-1.0> [flags]

            Set a progress bar in the sidebar for a workspace.

            Flags:
              --label <text>         Label shown next to the progress bar
              --workspace <id|ref>   Target workspace (default: $CMUX_WORKSPACE_ID)

            Example:
              cmux set-progress 0.5 --label "Building..."
              cmux set-progress 1.0 --label "Done"
            """
        case "clear-progress":
            return """
            Usage: cmux clear-progress [flags]

            Clear the sidebar progress bar for a workspace.

            Flags:
              --workspace <id|ref>   Target workspace (default: $CMUX_WORKSPACE_ID)

            Example:
              cmux clear-progress
            """
        case "log":
            return """
            Usage: cmux log [flags] [--] <message>

            Append a log entry to the sidebar for a workspace.

            Flags:
              --level <level>        Log level: info, progress, success, warning, error (default: info)
              --source <name>        Source label (e.g. "build", "test")
              --workspace <id|ref>   Target workspace (default: $CMUX_WORKSPACE_ID)

            Example:
              cmux log "Build started"
              cmux log --level error --source build "Compilation failed"
              cmux log --level success -- "All 42 tests passed"
            """
        case "clear-log":
            return """
            Usage: cmux clear-log [flags]

            Clear all sidebar log entries for a workspace.

            Flags:
              --workspace <id|ref>   Target workspace (default: $CMUX_WORKSPACE_ID)

            Example:
              cmux clear-log
            """
        case "list-log":
            return """
            Usage: cmux list-log [flags]

            List sidebar log entries for a workspace.

            Flags:
              --limit <n>            Show only the last N entries
              --workspace <id|ref>   Target workspace (default: $CMUX_WORKSPACE_ID)

            Example:
              cmux list-log
              cmux list-log --limit 5
            """
        case "sidebar-state":
            return """
            Usage: cmux sidebar-state [flags]

            Dump all sidebar metadata for a workspace (cwd, git branch, ports,
            status entries, progress, log entries).

            Flags:
              --workspace <id|ref>   Target workspace (default: $CMUX_WORKSPACE_ID)

            Example:
              cmux sidebar-state
              cmux sidebar-state --workspace workspace:2
            """
        case "claude-hook":
            return """
            Usage: cmux claude-hook <session-start|stop|notification> [flags]

            Hook for Claude Code integration. Reads JSON from stdin.

            Subcommands:
              session-start   Signal that a Claude session has started
              stop            Signal that a Claude session has stopped
              notification    Forward a Claude notification

            Flags:
              --workspace <id|ref>   Target workspace (default: $CMUX_WORKSPACE_ID)
              --surface <id|ref>     Target surface (default: $CMUX_SURFACE_ID)

            Example:
              echo '{"session_id":"abc"}' | cmux claude-hook session-start
              echo '{}' | cmux claude-hook stop
            """
        case "browser":
            return """
            Usage: cmux browser [--surface <id|ref|index> | <surface>] <subcommand> [args]

            Browser automation commands. Most subcommands require a surface handle.

            Subcommands:
              open [url]                     Create browser split (or navigate if surface given)
              open-split [url]               Create browser in a new split
              goto|navigate <url>            Navigate to URL [--snapshot-after]
              back|forward|reload            History navigation [--snapshot-after]
              url|get-url                    Get current URL
              snapshot                       Get DOM snapshot [--interactive|-i] [--cursor] [--compact] [--max-depth <n>] [--selector <css>]
              eval <script>                  Evaluate JavaScript
              wait                           Wait for condition [--selector] [--text] [--url-contains] [--timeout-ms]
              click|dblclick|hover <sel>     Mouse actions [--snapshot-after]
              type <selector> <text>         Type text [--snapshot-after]
              fill <selector> [text]         Fill input [--snapshot-after]
              press|keydown|keyup <key>      Keyboard actions [--snapshot-after]
              get <property> [selector]      Get page properties (url|title|text|html|value|attr|count|box|styles)
              find <strategy> <query>        Find elements (role|text|label|placeholder|testid|first|last|nth)
              identify                       Identify browser surface

            Example:
              cmux browser open https://example.com
              cmux browser surface:1 navigate https://google.com
              cmux browser --surface surface:1 snapshot --interactive
            """
        default:
            return nil
        }
    }

    /// Dispatch help for a subcommand. Returns true if help was printed.
    private func dispatchSubcommandHelp(command: String, commandArgs: [String]) -> Bool {
        guard commandArgs.contains("--help") || commandArgs.contains("-h") else { return false }
        guard let text = subcommandUsage(command) else { return false }
        print("cmux \(command)")
        print("")
        print(text)
        return true
    }

    /// Escape and quote a string for safe embedding in a v1 socket command.
    /// The socket tokenizer treats `\` and `"` as special inside quoted strings,
    /// so both must be escaped before wrapping in double quotes. Newlines and
    /// carriage returns must also be escaped since the socket protocol uses
    /// newline as the message terminator.
    private func socketQuote(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "\"\(escaped)\""
    }

    private func parseOption(_ args: [String], name: String) -> (String?, [String]) {
        var remaining: [String] = []
        var value: String?
        var skipNext = false
        var pastTerminator = false
        for (idx, arg) in args.enumerated() {
            if skipNext {
                skipNext = false
                continue
            }
            if arg == "--" {
                pastTerminator = true
                remaining.append(arg)
                continue
            }
            if !pastTerminator, arg == name, idx + 1 < args.count {
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

    /// Unescape CLI escape sequences to match legacy v1 send behavior.
    /// \n and \r → carriage return (Enter), \t → tab.
    private func unescapeSendText(_ text: String) -> String {
        return text
            .replacingOccurrences(of: "\\n", with: "\r")
            .replacingOccurrences(of: "\\r", with: "\r")
            .replacingOccurrences(of: "\\t", with: "\t")
    }

    private func workspaceFromArgsOrEnv(_ args: [String], windowOverride: String? = nil) -> String? {
        if let explicit = optionValue(args, name: "--workspace") { return explicit }
        // When --window is explicitly targeted, don't fall back to env workspace from a different window
        if windowOverride != nil { return nil }
        return ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"]
    }

    /// Pick the display handle for an item dict based on --id-format.
    private func textHandle(_ item: [String: Any], idFormat: CLIIDFormat) -> String {
        let ref = item["ref"] as? String
        let id = item["id"] as? String
        switch idFormat {
        case .refs:  return ref ?? id ?? "?"
        case .uuids: return id ?? ref ?? "?"
        case .both:  return [ref, id].compactMap({ $0 }).joined(separator: " ")
        }
    }

    private func v2OKSummary(_ payload: [String: Any], idFormat: CLIIDFormat, kinds: [String] = ["surface", "workspace"]) -> String {
        var parts = ["OK"]
        for kind in kinds {
            if let handle = formatHandle(payload, kind: kind, idFormat: idFormat) {
                parts.append(handle)
            }
        }
        return parts.joined(separator: " ")
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

    private struct TmuxCompatStore: Codable {
        var buffers: [String: String] = [:]
        var hooks: [String: String] = [:]
    }

    private func tmuxCompatStoreURL() -> URL {
        let root = NSString(string: "~/.cmuxterm").expandingTildeInPath
        return URL(fileURLWithPath: root).appendingPathComponent("tmux-compat-store.json")
    }

    private func loadTmuxCompatStore() -> TmuxCompatStore {
        let url = tmuxCompatStoreURL()
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(TmuxCompatStore.self, from: data) else {
            return TmuxCompatStore()
        }
        return decoded
    }

    private func saveTmuxCompatStore(_ store: TmuxCompatStore) throws {
        let url = tmuxCompatStoreURL()
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: nil)
        let data = try JSONEncoder().encode(store)
        try data.write(to: url, options: .atomic)
    }

    private func runShellCommand(_ command: String, stdinText: String) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        if let data = stdinText.data(using: .utf8) {
            stdinPipe.fileHandleForWriting.write(data)
        }
        stdinPipe.fileHandleForWriting.closeFile()
        process.waitUntilExit()

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, stdout, stderr)
    }

    private func tmuxWaitForSignalURL(name: String) -> URL {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let sanitized = name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        return URL(fileURLWithPath: "/tmp/cmux-wait-for-\(String(sanitized)).sig")
    }

    private func runTmuxCompatCommand(
        command: String,
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        switch command {
        case "capture-pane":
            let (wsArg, rem0) = parseOption(commandArgs, name: "--workspace")
            let (sfArg, rem1) = parseOption(rem0, name: "--surface")
            let (linesArg, rem2) = parseOption(rem1, name: "--lines")
            let workspaceArg = wsArg ?? (windowOverride == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
            let surfaceArg = sfArg ?? (wsArg == nil && windowOverride == nil ? ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"] : nil)

            var params: [String: Any] = [:]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let sfId = try normalizeSurfaceHandle(surfaceArg, client: client, workspaceHandle: wsId)
            if let sfId { params["surface_id"] = sfId }

            let includeScrollback = rem2.contains("--scrollback")
            if includeScrollback {
                params["scrollback"] = true
            }
            if let linesArg {
                guard let lineCount = Int(linesArg), lineCount > 0 else {
                    throw CLIError(message: "--lines must be greater than 0")
                }
                params["lines"] = lineCount
                params["scrollback"] = true
            }

            let payload = try client.sendV2(method: "surface.read_text", params: params)
            if jsonOutput {
                print(jsonString(payload))
            } else {
                print((payload["text"] as? String) ?? "")
            }

        case "resize-pane":
            let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowOverride)
            let paneArg = optionValue(commandArgs, name: "--pane")
            let amountArg = optionValue(commandArgs, name: "--amount")
            let amount = Int(amountArg ?? "1") ?? 1
            if amount <= 0 {
                throw CLIError(message: "--amount must be greater than 0")
            }

            let direction: String = {
                if commandArgs.contains("-L") { return "left" }
                if commandArgs.contains("-R") { return "right" }
                if commandArgs.contains("-U") { return "up" }
                if commandArgs.contains("-D") { return "down" }
                return "right"
            }()

            var params: [String: Any] = ["direction": direction, "amount": amount]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let paneId = try normalizePaneHandle(paneArg, client: client, workspaceHandle: wsId, allowFocused: true)
            if let paneId { params["pane_id"] = paneId }
            let payload = try client.sendV2(method: "pane.resize", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat, kinds: ["pane"]))

        case "pipe-pane":
            let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowOverride)
            let surfaceArg = optionValue(commandArgs, name: "--surface")
            let (cmdOpt, rem0) = parseOption(commandArgs, name: "--command")
            let commandText: String = {
                if let cmdOpt { return cmdOpt }
                let trimmed = rem0.dropFirst(rem0.first == "--" ? 1 : 0).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed
            }()
            guard !commandText.isEmpty else {
                throw CLIError(message: "pipe-pane requires --command <shell-command>")
            }

            var params: [String: Any] = ["scrollback": true]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client, allowCurrent: true)
            if let wsId { params["workspace_id"] = wsId }
            let sfId = try normalizeSurfaceHandle(surfaceArg, client: client, workspaceHandle: wsId, allowFocused: true)
            if let sfId { params["surface_id"] = sfId }
            let payload = try client.sendV2(method: "surface.read_text", params: params)
            let text = (payload["text"] as? String) ?? ""
            let shell = try runShellCommand(commandText, stdinText: text)
            if shell.status != 0 {
                throw CLIError(message: "pipe-pane command failed (\(shell.status)): \(shell.stderr)")
            }
            if jsonOutput {
                print(jsonString([
                    "ok": true,
                    "status": shell.status,
                    "stdout": shell.stdout,
                    "stderr": shell.stderr
                ]))
            } else {
                if !shell.stdout.isEmpty {
                    print(shell.stdout, terminator: "")
                }
                print("OK")
            }

        case "wait-for":
            let signal = commandArgs.contains("-S") || commandArgs.contains("--signal")
            let timeoutRaw = optionValue(commandArgs, name: "--timeout")
            let timeout = timeoutRaw.flatMap { Double($0) } ?? 30.0
            let name = commandArgs.first(where: { !$0.hasPrefix("-") }) ?? ""
            guard !name.isEmpty else {
                throw CLIError(message: "wait-for requires a name")
            }
            let signalURL = tmuxWaitForSignalURL(name: name)
            if signal {
                FileManager.default.createFile(atPath: signalURL.path, contents: Data())
                print("OK")
                return
            }
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if FileManager.default.fileExists(atPath: signalURL.path) {
                    try? FileManager.default.removeItem(at: signalURL)
                    print("OK")
                    return
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
            throw CLIError(message: "wait-for timed out waiting for '\(name)'")

        case "swap-pane":
            let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowOverride)
            guard let sourcePaneRaw = optionValue(commandArgs, name: "--pane") else {
                throw CLIError(message: "swap-pane requires --pane")
            }
            guard let targetPaneRaw = optionValue(commandArgs, name: "--target-pane") else {
                throw CLIError(message: "swap-pane requires --target-pane")
            }
            var params: [String: Any] = [:]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let sourcePane = try normalizePaneHandle(sourcePaneRaw, client: client, workspaceHandle: wsId)
            let targetPane = try normalizePaneHandle(targetPaneRaw, client: client, workspaceHandle: wsId)
            if let sourcePane { params["pane_id"] = sourcePane }
            if let targetPane { params["target_pane_id"] = targetPane }
            let payload = try client.sendV2(method: "pane.swap", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: "OK")

        case "break-pane":
            let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowOverride)
            let paneArg = optionValue(commandArgs, name: "--pane")
            let surfaceArg = optionValue(commandArgs, name: "--surface")
            var params: [String: Any] = ["focus": !commandArgs.contains("--no-focus")]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let paneId = try normalizePaneHandle(paneArg, client: client, workspaceHandle: wsId)
            if let paneId { params["pane_id"] = paneId }
            let surfaceId = try normalizeSurfaceHandle(surfaceArg, client: client, workspaceHandle: wsId)
            if let surfaceId { params["surface_id"] = surfaceId }
            let payload = try client.sendV2(method: "pane.break", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: "OK")

        case "join-pane":
            let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowOverride)
            let sourcePaneArg = optionValue(commandArgs, name: "--pane")
            let surfaceArg = optionValue(commandArgs, name: "--surface")
            guard let targetPaneArg = optionValue(commandArgs, name: "--target-pane") else {
                throw CLIError(message: "join-pane requires --target-pane")
            }
            var params: [String: Any] = ["focus": !commandArgs.contains("--no-focus")]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let sourcePaneId = try normalizePaneHandle(sourcePaneArg, client: client, workspaceHandle: wsId)
            if let sourcePaneId { params["pane_id"] = sourcePaneId }
            let targetPaneId = try normalizePaneHandle(targetPaneArg, client: client, workspaceHandle: wsId)
            if let targetPaneId { params["target_pane_id"] = targetPaneId }
            let surfaceId = try normalizeSurfaceHandle(surfaceArg, client: client, workspaceHandle: wsId)
            if let surfaceId { params["surface_id"] = surfaceId }
            let payload = try client.sendV2(method: "pane.join", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: "OK")

        case "last-window":
            let payload = try client.sendV2(method: "workspace.last")
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat, kinds: ["workspace"]))

        case "next-window":
            let payload = try client.sendV2(method: "workspace.next")
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat, kinds: ["workspace"]))

        case "previous-window":
            let payload = try client.sendV2(method: "workspace.previous")
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat, kinds: ["workspace"]))

        case "last-pane":
            let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowOverride)
            var params: [String: Any] = [:]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let payload = try client.sendV2(method: "pane.last", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat, kinds: ["pane"]))

        case "find-window":
            let includeContent = commandArgs.contains("--content")
            let shouldSelect = commandArgs.contains("--select")
            let query = commandArgs
                .filter { !$0.hasPrefix("-") }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let listPayload = try client.sendV2(method: "workspace.list")
            let workspaces = listPayload["workspaces"] as? [[String: Any]] ?? []

            var matches: [[String: Any]] = []
            for ws in workspaces {
                let title = (ws["title"] as? String) ?? ""
                let titleMatch = query.isEmpty || title.localizedCaseInsensitiveContains(query)
                var contentMatch = false
                if includeContent && !query.isEmpty, let wsId = ws["id"] as? String {
                    let textPayload = try? client.sendV2(method: "surface.read_text", params: ["workspace_id": wsId])
                    let text = (textPayload?["text"] as? String) ?? ""
                    contentMatch = text.localizedCaseInsensitiveContains(query)
                }
                if titleMatch || contentMatch {
                    matches.append(ws)
                }
            }

            if shouldSelect, let first = matches.first, let wsId = first["id"] as? String {
                _ = try client.sendV2(method: "workspace.select", params: ["workspace_id": wsId])
            }

            if jsonOutput {
                let formatted = formatIDs(["matches": matches], mode: idFormat) as? [String: Any]
                print(jsonString(["matches": formatted?["matches"] ?? []]))
            } else if matches.isEmpty {
                print("No matches")
            } else {
                for item in matches {
                    let handle = textHandle(item, idFormat: idFormat)
                    let title = (item["title"] as? String) ?? ""
                    print("\(handle)  \"\(title)\"")
                }
            }

        case "clear-history":
            let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowOverride)
            let surfaceArg = optionValue(commandArgs, name: "--surface")
            var params: [String: Any] = [:]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let sfId = try normalizeSurfaceHandle(surfaceArg, client: client, workspaceHandle: wsId, allowFocused: true)
            if let sfId { params["surface_id"] = sfId }
            let payload = try client.sendV2(method: "surface.clear_history", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat))

        case "set-hook":
            var store = loadTmuxCompatStore()
            if commandArgs.contains("--list") {
                if jsonOutput {
                    print(jsonString(["hooks": store.hooks]))
                } else if store.hooks.isEmpty {
                    print("No hooks configured")
                } else {
                    for (event, hookCmd) in store.hooks.sorted(by: { $0.key < $1.key }) {
                        print("\(event) -> \(hookCmd)")
                    }
                }
                return
            }
            if commandArgs.contains("--unset") {
                guard let event = commandArgs.last else {
                    throw CLIError(message: "set-hook --unset requires an event name")
                }
                store.hooks.removeValue(forKey: event)
                try saveTmuxCompatStore(store)
                print("OK")
                return
            }
            guard let event = commandArgs.first(where: { !$0.hasPrefix("-") }) else {
                throw CLIError(message: "set-hook requires <event> <command>")
            }
            let commandText = commandArgs.drop(while: { $0 != event }).dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !commandText.isEmpty else {
                throw CLIError(message: "set-hook requires <event> <command>")
            }
            store.hooks[event] = commandText
            try saveTmuxCompatStore(store)
            print("OK")

        case "popup":
            throw CLIError(message: "popup is not supported yet in cmux CLI parity mode")

        case "bind-key", "unbind-key", "copy-mode":
            throw CLIError(message: "\(command) is not supported yet in cmux CLI parity mode")

        case "set-buffer":
            let (nameArg, rem0) = parseOption(commandArgs, name: "--name")
            let name = (nameArg?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? nameArg! : "default"
            let content = rem0.dropFirst(rem0.first == "--" ? 1 : 0).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else {
                throw CLIError(message: "set-buffer requires text")
            }
            var store = loadTmuxCompatStore()
            store.buffers[name] = content
            try saveTmuxCompatStore(store)
            print("OK")

        case "list-buffers":
            let store = loadTmuxCompatStore()
            if jsonOutput {
                let payload = store.buffers.map { key, value in ["name": key, "size": value.count] }
                print(jsonString(["buffers": payload.sorted { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }]))
            } else if store.buffers.isEmpty {
                print("No buffers")
            } else {
                for key in store.buffers.keys.sorted() {
                    let size = store.buffers[key]?.count ?? 0
                    print("\(key)\t\(size)")
                }
            }

        case "paste-buffer":
            let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowOverride)
            let surfaceArg = optionValue(commandArgs, name: "--surface")
            let name = optionValue(commandArgs, name: "--name") ?? "default"
            let store = loadTmuxCompatStore()
            guard let buffer = store.buffers[name] else {
                throw CLIError(message: "Buffer not found: \(name)")
            }
            var params: [String: Any] = ["text": buffer]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client, allowCurrent: true)
            if let wsId { params["workspace_id"] = wsId }
            let sfId = try normalizeSurfaceHandle(surfaceArg, client: client, workspaceHandle: wsId, allowFocused: true)
            if let sfId { params["surface_id"] = sfId }
            let payload = try client.sendV2(method: "surface.send_text", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: "OK")

        case "respawn-pane":
            let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowOverride)
            let surfaceArg = optionValue(commandArgs, name: "--surface")
            let (commandOpt, rem0) = parseOption(commandArgs, name: "--command")
            let commandText = (commandOpt ?? rem0.dropFirst(rem0.first == "--" ? 1 : 0).joined(separator: " ")).trimmingCharacters(in: .whitespacesAndNewlines)
            let finalCommand = commandText.isEmpty ? "exec ${SHELL:-/bin/zsh} -l" : commandText
            var params: [String: Any] = ["text": finalCommand + "\n"]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client, allowCurrent: true)
            if let wsId { params["workspace_id"] = wsId }
            let sfId = try normalizeSurfaceHandle(surfaceArg, client: client, workspaceHandle: wsId, allowFocused: true)
            if let sfId { params["surface_id"] = sfId }
            let payload = try client.sendV2(method: "surface.send_text", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: "OK")

        case "display-message":
            let printOnly = commandArgs.contains("-p") || commandArgs.contains("--print")
            let message = commandArgs
                .filter { !$0.hasPrefix("-") }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !message.isEmpty else {
                throw CLIError(message: "display-message requires text")
            }
            if printOnly {
                print(message)
                return
            }
            let payload = try client.sendV2(method: "notification.create", params: ["title": "cmux", "body": message])
            if jsonOutput {
                print(jsonString(payload))
            } else {
                print(message)
            }

        default:
            throw CLIError(message: "Unsupported tmux compatibility command: \(command)")
        }
    }

    private func runClaudeHook(
        commandArgs: [String],
        client: SocketClient,
        telemetry: CLISocketSentryTelemetry
    ) throws {
        let subcommand = commandArgs.first?.lowercased() ?? "help"
        let hookArgs = Array(commandArgs.dropFirst())
        let hookWsFlag = optionValue(hookArgs, name: "--workspace")
        let workspaceArg = hookWsFlag ?? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"]
        let surfaceArg = optionValue(hookArgs, name: "--surface") ?? (hookWsFlag == nil ? ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"] : nil)
        let rawInput = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let parsedInput = parseClaudeHookInput(rawInput: rawInput)
        let sessionStore = ClaudeHookSessionStore()
        telemetry.breadcrumb(
            "claude-hook.input",
            data: [
                "subcommand": subcommand,
                "has_session_id": parsedInput.sessionId != nil,
                "has_workspace_flag": hookWsFlag != nil,
                "has_surface_flag": optionValue(hookArgs, name: "--surface") != nil
            ]
        )
        let fallbackWorkspaceId = try resolveWorkspaceIdForClaudeHook(workspaceArg, client: client)
        let fallbackSurfaceId = try? resolveSurfaceId(surfaceArg, workspaceId: fallbackWorkspaceId, client: client)

        switch subcommand {
        case "session-start", "active":
            telemetry.breadcrumb("claude-hook.session-start")
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
            telemetry.breadcrumb("claude-hook.stop")
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
                let response = try sendV1Command("notify_target \(workspaceId) \(surfaceId) \(payload)", client: client)
                print(response)
            } else {
                print("OK")
            }

        case "notification", "notify":
            telemetry.breadcrumb("claude-hook.notification")
            let summary = summarizeClaudeHookNotification(rawInput: rawInput)

            var workspaceId = fallbackWorkspaceId
            var preferredSurface = surfaceArg
            if let sessionId = parsedInput.sessionId,
               let mapped = try? sessionStore.lookup(sessionId: sessionId),
               let mappedWorkspace = try? resolveWorkspaceIdForClaudeHook(mapped.workspaceId, client: client) {
                workspaceId = mappedWorkspace
                preferredSurface = mapped.surfaceId
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

            let response = try sendV1Command("notify_target \(workspaceId) \(surfaceId) \(payload)", client: client)
            _ = try? setClaudeStatus(
                client: client,
                workspaceId: workspaceId,
                value: "Needs input",
                icon: "bell.fill",
                color: "#4C8DFF"
            )
            print(response)

        case "help", "--help", "-h":
            telemetry.breadcrumb("claude-hook.help")
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
            let probe = try? client.sendV2(method: "surface.list", params: ["workspace_id": candidate])
            if probe != nil {
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
        let dedupedMessage = dedupeBranchContextLines(message)
        let normalizedMessage = normalizedSingleLine(dedupedMessage)
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

    private func dedupeBranchContextLines(_ value: String) -> String {
        let lines = value.components(separatedBy: .newlines)
        guard lines.count > 1 else { return value }

        var lastIndexByPath: [String: Int] = [:]
        for (index, line) in lines.enumerated() {
            guard let path = branchContextPath(from: line) else { continue }
            lastIndexByPath[path] = index
        }
        guard !lastIndexByPath.isEmpty else { return value }

        let deduped = lines.enumerated().compactMap { index, line -> String? in
            guard let path = branchContextPath(from: line) else { return line }
            return lastIndexByPath[path] == index ? line : nil
        }
        return deduped.joined(separator: "\n")
    }

    private func branchContextPath(from line: String) -> String? {
        let parts = line.split(separator: "•", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }

        let branch = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let path = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branch.isEmpty, !path.isEmpty else { return nil }

        let looksLikePath = path.hasPrefix("/") || path.hasPrefix("~") || path.hasPrefix(".") || path.contains("/")
        guard looksLikePath else { return nil }

        let trimmedQuotes = path.trimmingCharacters(in: CharacterSet(charactersIn: "`'\""))
        let expanded = NSString(string: trimmedQuotes).expandingTildeInPath
        let standardized = NSString(string: expanded).standardizingPath
        let normalized = standardized.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
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

    private func versionSummary() -> String {
        let info = resolvedVersionInfo()
        if let version = info["CFBundleShortVersionString"], let build = info["CFBundleVersion"] {
            return "cmux \(version) (\(build))"
        }
        if let version = info["CFBundleShortVersionString"] {
            return "cmux \(version)"
        }
        if let build = info["CFBundleVersion"] {
            return "cmux build \(build)"
        }
        return "cmux version unknown"
    }

    private func resolvedVersionInfo() -> [String: String] {
        if let main = versionInfo(from: Bundle.main.infoDictionary) {
            return main
        }

        for plistURL in candidateInfoPlistURLs() {
            guard let data = try? Data(contentsOf: plistURL),
                  let raw = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
                  let dictionary = raw as? [String: Any],
                  let parsed = versionInfo(from: dictionary)
            else {
                continue
            }
            return parsed
        }

        if let fromProject = versionInfoFromProjectFile() {
            return fromProject
        }

        return [:]
    }

    private func versionInfo(from dictionary: [String: Any]?) -> [String: String]? {
        guard let dictionary else { return nil }

        var info: [String: String] = [:]
        if let version = dictionary["CFBundleShortVersionString"] as? String {
            let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && !trimmed.contains("$(") {
                info["CFBundleShortVersionString"] = trimmed
            }
        }
        if let build = dictionary["CFBundleVersion"] as? String {
            let trimmed = build.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && !trimmed.contains("$(") {
                info["CFBundleVersion"] = trimmed
            }
        }
        return info.isEmpty ? nil : info
    }

    private func versionInfoFromProjectFile() -> [String: String]? {
        guard let executable = currentExecutablePath(), !executable.isEmpty else {
            return nil
        }

        let fileManager = FileManager.default
        var current = URL(fileURLWithPath: executable)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .deletingLastPathComponent()

        while true {
            let projectFile = current.appendingPathComponent("GhosttyTabs.xcodeproj/project.pbxproj")
            if fileManager.fileExists(atPath: projectFile.path),
               let contents = try? String(contentsOf: projectFile, encoding: .utf8) {
                var info: [String: String] = [:]
                if let version = firstProjectSetting("MARKETING_VERSION", in: contents) {
                    info["CFBundleShortVersionString"] = version
                }
                if let build = firstProjectSetting("CURRENT_PROJECT_VERSION", in: contents) {
                    info["CFBundleVersion"] = build
                }
                if !info.isEmpty {
                    return info
                }
            }

            let parent = current.deletingLastPathComponent()
            if parent.path == current.path {
                break
            }
            current = parent
        }

        return nil
    }

    private func firstProjectSetting(_ key: String, in source: String) -> String? {
        let pattern = NSRegularExpression.escapedPattern(for: key) + "\\s*=\\s*([^;]+);"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let searchRange = NSRange(source.startIndex..<source.endIndex, in: source)
        guard let match = regex.firstMatch(in: source, options: [], range: searchRange),
              match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: source)
        else {
            return nil
        }
        let value = source[valueRange]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        guard !value.isEmpty, !value.contains("$(") else {
            return nil
        }
        return value
    }

    private func candidateInfoPlistURLs() -> [URL] {
        guard let executable = currentExecutablePath(), !executable.isEmpty else {
            return []
        }

        let fileManager = FileManager.default
        let executableURL = URL(fileURLWithPath: executable)
            .resolvingSymlinksInPath()
            .standardizedFileURL

        var candidates: [URL] = []
        var current = executableURL.deletingLastPathComponent()
        while true {
            if current.pathExtension == "app" {
                candidates.append(current.appendingPathComponent("Contents/Info.plist"))
            }
            if current.lastPathComponent == "Contents" {
                candidates.append(current.appendingPathComponent("Info.plist"))
            }

            // Local dev fallback: resolve version from the repo's app Info.plist
            // when running a standalone cmux-cli binary from build/Debug.
            let projectMarker = current.appendingPathComponent("GhosttyTabs.xcodeproj/project.pbxproj")
            let repoInfo = current.appendingPathComponent("Resources/Info.plist")
            if fileManager.fileExists(atPath: projectMarker.path),
               fileManager.fileExists(atPath: repoInfo.path) {
                candidates.append(repoInfo)
                break
            }

            let parent = current.deletingLastPathComponent()
            if parent.path == current.path {
                break
            }
            current = parent
        }

        let searchRoots = [
            executableURL.deletingLastPathComponent(),
            executableURL.deletingLastPathComponent().deletingLastPathComponent()
        ]
        for root in searchRoots {
            guard let entries = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            for entry in entries where entry.pathExtension == "app" {
                candidates.append(entry.appendingPathComponent("Contents/Info.plist"))
            }
        }

        var seen: Set<String> = []
        return candidates.filter { url in
            let path = url.path
            guard !path.isEmpty else { return false }
            guard seen.insert(path).inserted else { return false }
            return fileManager.fileExists(atPath: path)
        }
    }

    private func currentExecutablePath() -> String? {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        if size > 0 {
            var buffer = Array<CChar>(repeating: 0, count: Int(size))
            if _NSGetExecutablePath(&buffer, &size) == 0 {
                let path = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
                if !path.isEmpty {
                    return path
                }
            }
        }
        return Bundle.main.executableURL?.path ?? args.first
    }

    private func usage() -> String {
        return """
        cmux - control cmux via Unix socket

        Usage:
          cmux [--socket PATH] [--window WINDOW] [--password PASSWORD] [--json] [--id-format refs|uuids|both] [--version] <command> [options]

        Handle Inputs:
          For most v2-backed commands you can use UUIDs, short refs (window:1/workspace:2/pane:3/surface:4), or indexes.
          `tab-action` also accepts `tab:<n>` in addition to `surface:<n>`.
          Output defaults to refs; pass --id-format uuids or --id-format both to include UUIDs.

        Socket Auth:
          --password takes precedence, then CMUX_SOCKET_PASSWORD env var, then keychain password saved in Settings.

        Commands:
          version
          ping
          capabilities
          identify [--workspace <id|ref|index>] [--surface <id|ref|index>] [--no-caller]
          list-windows
          current-window
          new-window
          focus-window --window <id>
          close-window --window <id>
          move-workspace-to-window --workspace <id|ref> --window <id|ref>
          reorder-workspace --workspace <id|ref|index> (--index <n> | --before <id|ref|index> | --after <id|ref|index>) [--window <id|ref|index>]
          workspace-action --action <name> [--workspace <id|ref|index>] [--title <text>]
          list-workspaces
          new-workspace [--command <text>]
          new-split <left|right|up|down> [--workspace <id|ref>] [--surface <id|ref>] [--panel <id|ref>]
          list-panes [--workspace <id|ref>]
          list-pane-surfaces [--workspace <id|ref>] [--pane <id|ref>]
          focus-pane --pane <id|ref> [--workspace <id|ref>]
          new-pane [--type <terminal|browser>] [--direction <left|right|up|down>] [--workspace <id|ref>] [--url <url>]
          new-surface [--type <terminal|browser>] [--pane <id|ref>] [--workspace <id|ref>] [--url <url>]
          close-surface [--surface <id|ref>] [--workspace <id|ref>]
          move-surface --surface <id|ref|index> [--pane <id|ref|index>] [--workspace <id|ref|index>] [--window <id|ref|index>] [--before <id|ref|index>] [--after <id|ref|index>] [--index <n>] [--focus <true|false>]
          reorder-surface --surface <id|ref|index> (--index <n> | --before <id|ref|index> | --after <id|ref|index>)
          tab-action --action <name> [--tab <id|ref|index>] [--surface <id|ref|index>] [--workspace <id|ref|index>] [--title <text>] [--url <url>]
          rename-tab [--workspace <id|ref>] [--tab <id|ref>] [--surface <id|ref>] <title>
          drag-surface-to-split --surface <id|ref> <left|right|up|down>
          refresh-surfaces
          surface-health [--workspace <id|ref>]
          trigger-flash [--workspace <id|ref>] [--surface <id|ref>]
          list-panels [--workspace <id|ref>]
          focus-panel --panel <id|ref> [--workspace <id|ref>]
          close-workspace --workspace <id|ref>
          select-workspace --workspace <id|ref>
          rename-workspace [--workspace <id|ref>] <title>
          rename-window [--workspace <id|ref>] <title>
          current-workspace
          read-screen [--workspace <id|ref>] [--surface <id|ref>] [--scrollback] [--lines <n>]
          send [--workspace <id|ref>] [--surface <id|ref>] <text>
          send-key [--workspace <id|ref>] [--surface <id|ref>] <key>
          send-panel --panel <id|ref> [--workspace <id|ref>] <text>
          send-key-panel --panel <id|ref> [--workspace <id|ref>] <key>
          notify --title <text> [--subtitle <text>] [--body <text>] [--workspace <id|ref>] [--surface <id|ref>]
          list-notifications
          clear-notifications
          claude-hook <session-start|stop|notification> [--workspace <id|ref>] [--surface <id|ref>]

          # sidebar metadata commands
          set-status <key> <value> [--icon <name>] [--color <#hex>] [--workspace <id|ref>]
          clear-status <key> [--workspace <id|ref>]
          list-status [--workspace <id|ref>]
          set-progress <0.0-1.0> [--label <text>] [--workspace <id|ref>]
          clear-progress [--workspace <id|ref>]
          log [--level <level>] [--source <name>] [--workspace <id|ref>] [--] <message>
          clear-log [--workspace <id|ref>]
          list-log [--limit <n>] [--workspace <id|ref>]
          sidebar-state [--workspace <id|ref>]

          set-app-focus <active|inactive|clear>
          simulate-app-active

          # tmux compatibility commands
          capture-pane [--workspace <id|ref>] [--surface <id|ref>] [--scrollback] [--lines <n>]
          resize-pane --pane <id|ref> [--workspace <id|ref>] (-L|-R|-U|-D) [--amount <n>]
          pipe-pane --command <shell-command> [--workspace <id|ref>] [--surface <id|ref>]
          wait-for [-S|--signal] <name> [--timeout <seconds>]
          swap-pane --pane <id|ref> --target-pane <id|ref> [--workspace <id|ref>]
          break-pane [--workspace <id|ref>] [--pane <id|ref>] [--surface <id|ref>] [--no-focus]
          join-pane --target-pane <id|ref> [--workspace <id|ref>] [--pane <id|ref>] [--surface <id|ref>] [--no-focus]
          next-window | previous-window | last-window
          last-pane [--workspace <id|ref>]
          find-window [--content] [--select] <query>
          clear-history [--workspace <id|ref>] [--surface <id|ref>]
          set-hook [--list] [--unset <event>] | <event> <command>
          popup
          bind-key | unbind-key | copy-mode
          set-buffer [--name <name>] <text>
          list-buffers
          paste-buffer [--name <name>] [--workspace <id|ref>] [--surface <id|ref>]
          respawn-pane [--workspace <id|ref>] [--surface <id|ref>] [--command <cmd>]
          display-message [-p|--print] <text>

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
                              ALL commands (send, list-panels, new-split, notify, etc.).
          CMUX_TAB_ID         Optional alias used by `tab-action`/`rename-tab` as default --tab.
          CMUX_SURFACE_ID     Auto-set in cmux terminals. Used as default --surface.
          CMUX_SOCKET_PATH    Override the default Unix socket path (/tmp/cmux.sock).
          CMUX_CLI_SENTRY_DISABLED
                              Set to 1 to disable CLI Sentry socket diagnostics.
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

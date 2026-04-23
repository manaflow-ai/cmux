import Foundation
import CryptoKit
import Darwin
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if canImport(Security)
import Security
#endif
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

    private static func currentSentryReleaseName() -> String? {
        guard let bundleIdentifier = currentSentryBundleIdentifier(),
              let version = currentBundleVersionValue(forKey: "CFBundleShortVersionString"),
              let build = currentBundleVersionValue(forKey: "CFBundleVersion")
        else {
            return nil
        }
        return "\(bundleIdentifier)@\(version)+\(build)"
    }

    private static func currentSentryBundleIdentifier() -> String? {
        if let bundleIdentifier = ProcessInfo.processInfo.environment["CMUX_BUNDLE_ID"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !bundleIdentifier.isEmpty {
            return bundleIdentifier
        }

        if let bundleIdentifier = currentSentryBundle()?.bundleIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !bundleIdentifier.isEmpty {
            return bundleIdentifier
        }

        return nil
    }

    private static func currentBundleVersionValue(forKey key: String) -> String? {
        guard let value = currentSentryBundle()?.infoDictionary?[key] as? String else {
            return nil
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("$(") else {
            return nil
        }
        return trimmed
    }

    private static func currentSentryBundle() -> Bundle? {
        if Bundle.main.bundleIdentifier?.isEmpty == false {
            return Bundle.main
        }

        guard let executableURL = currentExecutableURL() else {
            return Bundle.main
        }

        var current = executableURL.deletingLastPathComponent().standardizedFileURL
        while true {
            if current.pathExtension == "app", let bundle = Bundle(url: current) {
                return bundle
            }

            if current.lastPathComponent == "Contents" {
                let appURL = current.deletingLastPathComponent().standardizedFileURL
                if appURL.pathExtension == "app", let bundle = Bundle(url: appURL) {
                    return bundle
                }
            }

            guard let parent = parentSearchURL(for: current) else {
                break
            }
            current = parent
        }

        return Bundle.main
    }

    private static func currentExecutableURL() -> URL? {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        if size > 0 {
            var buffer = Array<CChar>(repeating: 0, count: Int(size))
            if _NSGetExecutablePath(&buffer, &size) == 0 {
                return URL(fileURLWithPath: String(cString: buffer)).standardizedFileURL
            }
        }

        return Bundle.main.executableURL?.standardizedFileURL
    }

    private static func parentSearchURL(for url: URL) -> URL? {
        let standardized = url.standardizedFileURL
        let path = standardized.path
        guard !path.isEmpty, path != "/" else {
            return nil
        }

        let parent = standardized.deletingLastPathComponent().standardizedFileURL
        guard parent.path != path else {
            return nil
        }
        return parent
    }
#endif

    init(command: String, commandArgs: [String], socketPath: String, processEnv: [String: String]) {
        self.command = command.lowercased()
        self.subcommand = commandArgs.first?.lowercased() ?? "help"
        self.socketPath = socketPath
        self.envSocketPath = processEnv["CMUX_SOCKET_PATH"] ?? processEnv["CMUX_SOCKET"]
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

        let tmpSockets = Self.discoverSockets(in: "/tmp", limit: 10)
        if !tmpSockets.isEmpty {
            context["tmp_cmux_sockets"] = tmpSockets
        }
        let taggedSockets = tmpSockets.filter { $0 != CLISocketPathResolver.legacyDefaultSocketPath }
        if CLISocketPathResolver.isImplicitDefaultPath(socketPath),
           (envSocketPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
           !taggedSockets.isEmpty {
            context["possible_root_cause"] = "CMUX_SOCKET_PATH/CMUX_SOCKET missing while tagged sockets exist"
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

    private static func discoverSockets(in directory: String, limit: Int) -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
            return []
        }
        var sockets: [String] = []
        for name in entries.sorted() {
            guard name.hasPrefix("cmux"), name.hasSuffix(".sock") else { continue }
            let fullPath = URL(fileURLWithPath: directory)
                .appendingPathComponent(name, isDirectory: false)
                .path
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
            options.releaseName = currentSentryReleaseName()
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
    let object: [String: Any]?
    let rawFallback: String?
    let sessionId: String?
    let cwd: String?
    let transcriptPath: String?
}

private struct ClaudeHookSessionRecord: Codable {
    var sessionId: String
    var workspaceId: String
    var surfaceId: String
    var cwd: String?
    var pid: Int?
    var launchCommand: AgentHookLaunchCommandRecord?
    var lastSubtitle: String?
    var lastBody: String?
    var startedAt: TimeInterval
    var updatedAt: TimeInterval
}

private struct AgentHookLaunchCommandRecord: Codable {
    var launcher: String?
    var executablePath: String?
    var arguments: [String]
    var workingDirectory: String?
    var environment: [String: String]?
    var capturedAt: TimeInterval?
    var source: String?
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
        } else if let overrideDirectory = processEnv["CMUX_AGENT_HOOK_STATE_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !overrideDirectory.isEmpty {
            self.statePath = URL(fileURLWithPath: NSString(string: overrideDirectory).expandingTildeInPath, isDirectory: true)
                .appendingPathComponent("claude-hook-sessions.json", isDirectory: false)
                .path
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
        pid: Int? = nil,
        launchCommand: AgentHookLaunchCommandRecord? = nil,
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
                pid: nil,
                launchCommand: nil,
                lastSubtitle: nil,
                lastBody: nil,
                startedAt: now,
                updatedAt: now
            )
            record.workspaceId = workspaceId
            if !surfaceId.isEmpty {
                record.surfaceId = surfaceId
            }
            if let cwd = normalizeOptional(cwd) {
                record.cwd = cwd
            }
            if let pid {
                record.pid = pid
            }
            if let launchCommand, !launchCommand.arguments.isEmpty {
                record.launchCommand = launchCommand
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

private let codexHookWrapperProcessNames: Set<String> = [
    "sh",
    "bash",
    "zsh",
    "env"
]

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

enum SocketPasswordResolver {
    private static let service = "com.cmuxterm.app.socket-control"
    private static let account = "local-socket-password"
    private static let directoryName = "cmux"
    private static let fileName = "socket-control-password"

    static func resolve(explicit: String?, socketPath: String) -> String? {
        if let explicit = normalized(explicit) {
            return explicit
        }
        if let env = normalized(ProcessInfo.processInfo.environment["CMUX_SOCKET_PASSWORD"]) {
            return env
        }
        if let filePassword = loadFromFile() {
            return filePassword
        }
        return loadFromKeychain(socketPath: socketPath)
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .newlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func loadFromFile() -> String? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let passwordURL = appSupport
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
        guard let data = try? Data(contentsOf: passwordURL) else {
            return nil
        }
        guard let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return normalized(value)
    }

    static func keychainServices(
        socketPath: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        guard let scope = keychainScope(socketPath: socketPath, environment: environment) else {
            return [service]
        }
        return ["\(service).\(scope)", service]
    }

    private static func keychainScope(
        socketPath: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        if let tag = normalized(environment["CMUX_TAG"]) {
            let scoped = sanitizeScope(tag)
            if !scoped.isEmpty {
                return scoped
            }
        }

        let candidate = URL(fileURLWithPath: socketPath).lastPathComponent
        let prefixes = ["cmux-debug-", "cmux-"]
        for prefix in prefixes {
            guard candidate.hasPrefix(prefix), candidate.hasSuffix(".sock") else { continue }
            let start = candidate.index(candidate.startIndex, offsetBy: prefix.count)
            let end = candidate.index(candidate.endIndex, offsetBy: -".sock".count)
            guard start < end else { continue }
            let rawScope = String(candidate[start..<end])
            let scoped = sanitizeScope(rawScope)
            if !scoped.isEmpty {
                return scoped
            }
        }
        return nil
    }

    private static func sanitizeScope(_ raw: String) -> String {
        let lowered = raw.lowercased()
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
        let mappedScalars = lowered.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "."
        }
        var normalizedScope = String(mappedScalars)
        normalizedScope = normalizedScope.replacingOccurrences(
            of: "\\.+",
            with: ".",
            options: .regularExpression
        )
        normalizedScope = normalizedScope.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return normalizedScope
    }

    private static func loadFromKeychain(socketPath: String) -> String? {
        for service in keychainServices(socketPath: socketPath) {
            let authContext = LAContext()
            authContext.interactionNotAllowed = true
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
                // Never trigger keychain UI from CLI commands; fail fast instead.
                kSecUseAuthenticationContext as String: authContext,
            ]
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound || status == errSecInteractionNotAllowed || status == errSecAuthFailed {
                continue
            }
            guard status == errSecSuccess else {
                continue
            }
            guard let data = result as? Data,
                  let password = String(data: data, encoding: .utf8) else {
                continue
            }
            return password
        }
        return nil
    }
}

private enum CLISocketPathSource {
    case explicitFlag
    case environment
    case implicitDefault
}

private enum CLISocketPathResolver {
    private static let appSupportDirectoryName = "cmux"
    private static let stableSocketFileName = "cmux.sock"
    private static let lastSocketPathFileName = "last-socket-path"
    static let legacyDefaultSocketPath = "/tmp/cmux.sock"
    private static let fallbackSocketPath = "/tmp/cmux-debug.sock"
    private static let stagingSocketPath = "/tmp/cmux-staging.sock"
    private static let legacyLastSocketPathFile = "/tmp/cmux-last-socket-path"

    static var defaultSocketPath: String {
        let stablePath: String? = stableSocketDirectoryURL()?
            .appendingPathComponent(stableSocketFileName, isDirectory: false)
            .path
        return stablePath ?? legacyDefaultSocketPath
    }

    static func isImplicitDefaultPath(_ path: String) -> Bool {
        path == defaultSocketPath || path == legacyDefaultSocketPath
    }

    static func resolve(
        requestedPath: String,
        source: CLISocketPathSource,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        guard source == .implicitDefault else {
            return requestedPath
        }

        let candidates = dedupe(candidatePaths(requestedPath: requestedPath, environment: environment))

        // Prefer sockets that are currently accepting connections.
        for path in candidates where canConnect(to: path) {
            return path
        }

        // If the listener is still starting, prefer existing socket files.
        for path in candidates where isSocketFile(path) {
            return path
        }

        return requestedPath
    }

    private static func candidatePaths(requestedPath: String, environment: [String: String]) -> [String] {
        var candidates: [String] = []

        if let tag = normalized(environment["CMUX_TAG"]) {
            let slug = sanitizeTagSlug(tag)
            candidates.append("/tmp/cmux-debug-\(slug).sock")
            candidates.append("/tmp/cmux-\(slug).sock")
        }

        candidates.append(requestedPath)
        candidates.append(defaultSocketPath)
        candidates.append(legacyDefaultSocketPath)
        candidates.append(fallbackSocketPath)
        candidates.append(stagingSocketPath)
        candidates.append(contentsOf: discoverTaggedSockets(limit: 12))
        if let last = readLastSocketPath() {
            candidates.append(last)
        }
        return candidates
    }

    private static func readLastSocketPath() -> String? {
        let primaryCandidate: String? = stableSocketDirectoryURL()?
            .appendingPathComponent(lastSocketPathFileName, isDirectory: false)
            .path
        let candidates = [primaryCandidate, legacyLastSocketPathFile].compactMap { $0 }

        for candidate in candidates {
            guard let data = try? String(contentsOfFile: candidate, encoding: .utf8) else {
                continue
            }
            if let value = normalized(data) {
                return value
            }
        }
        return nil
    }

    private static func discoverTaggedSockets(limit: Int) -> [String] {
        var discovered: [(path: String, mtime: TimeInterval)] = []
        for directory in socketDiscoveryDirectories() {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
                continue
            }
            discovered.reserveCapacity(min(limit, discovered.count + entries.count))
            for name in entries where name.hasPrefix("cmux") && name.hasSuffix(".sock") {
                let path = URL(fileURLWithPath: directory)
                    .appendingPathComponent(name, isDirectory: false)
                    .path
                var st = stat()
                guard lstat(path, &st) == 0 else { continue }
                guard (st.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK) else { continue }
                if path == defaultSocketPath || path == legacyDefaultSocketPath || path == fallbackSocketPath || path == stagingSocketPath {
                    continue
                }
                let modified = TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1_000_000_000
                discovered.append((path: path, mtime: modified))
            }
        }

        discovered.sort { $0.mtime > $1.mtime }
        return dedupe(discovered.prefix(limit).map(\.path))
    }

    private static func isSocketFile(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK)
    }

    private static func canConnect(to path: String) -> Bool {
        guard isSocketFile(path) else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }

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
                Darwin.connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return result == 0
    }

    private static func sanitizeTagSlug(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let slug = trimmed
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? "agent" : slug
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func stableSocketDirectoryURL() -> URL? {
        guard let appSupportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return appSupportDirectory.appendingPathComponent(appSupportDirectoryName, isDirectory: true)
    }

    private static func socketDiscoveryDirectories() -> [String] {
        let appSupportSocketDirectory: String = stableSocketDirectoryURL()?.path ?? ""
        return dedupe([
            "/tmp",
            appSupportSocketDirectory,
        ])
    }

    private static func dedupe(_ paths: [String]) -> [String] {
        var seen: Set<String> = []
        var ordered: [String] = []
        ordered.reserveCapacity(paths.count)
        for path in paths where !path.isEmpty {
            if seen.insert(path).inserted {
                ordered.append(path)
            }
        }
        return ordered
    }
}

final class SocketClient {
    private struct RelayEndpoint {
        let host: String
        let port: UInt16
    }

    private struct RelayCredentials {
        let relayID: String
        let relayToken: Data
    }

    private let path: String
    private var socketFD: Int32 = -1
    private static let defaultResponseTimeoutSeconds: TimeInterval = 15.0
    private static let multilineResponseIdleTimeoutSeconds: TimeInterval = 0.12
    private static let maxSocketTimeoutSeconds: TimeInterval = 9_007_199_254_740_991
    private static let responseTimeoutSeconds: TimeInterval = {
        let env = ProcessInfo.processInfo.environment
        if let raw = env["CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC"],
           let seconds = Double(raw),
           seconds.isFinite,
           seconds > 0 {
            return seconds
        }
        return defaultResponseTimeoutSeconds
    }()

    init(path: String) {
        self.path = path
    }

    var socketPath: String {
        path
    }

    private var relayEndpoint: RelayEndpoint? {
        Self.parseRelayEndpoint(path)
    }

    private static func trimmedEnvValue(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func socketTimeval(for timeout: TimeInterval) -> timeval {
        let sanitizedTimeout = timeout.isFinite ? timeout : defaultResponseTimeoutSeconds
        let clampedTimeout = min(max(sanitizedTimeout, 0.01), maxSocketTimeoutSeconds)
        let seconds = floor(clampedTimeout)
        let microseconds = min(
            max(Int((clampedTimeout - seconds) * 1_000_000), 0),
            999_999
        )
        return timeval(
            tv_sec: Int(seconds),
            tv_usec: __darwin_suseconds_t(microseconds)
        )
    }

    func connect() throws {
        if socketFD >= 0 { return }
        try connectOnce()
    }

    func close() {
        if socketFD >= 0 {
            Darwin.close(socketFD)
            socketFD = -1
        }
    }

    func send(command: String) throws -> String {
        if relayEndpoint != nil, socketFD < 0 {
            try connect()
        }
        guard socketFD >= 0 else { throw CLIError(message: "Not connected") }
        let shouldCloseAfterSend = relayEndpoint != nil
        defer {
            if shouldCloseAfterSend {
                close()
            }
        }

        let payload = command + "\n"
        try writeAll(
            Data(payload.utf8),
            timeoutMessage: "Command timed out",
            failureMessage: "Failed to write to socket"
        )

        var data = Data()
        var sawNewline = false

        while true {
            try configureReceiveTimeout(
                sawNewline ? Self.multilineResponseIdleTimeoutSeconds : Self.responseTimeoutSeconds
            )

            var buffer = [UInt8](repeating: 0, count: 8192)
            let count = Darwin.read(socketFD, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR {
                    continue
                }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    if sawNewline {
                        break
                    }
                    throw CLIError(message: "Command timed out")
                }
                throw CLIError(message: "Socket read error")
            }
            if count == 0 {
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

    private func connectOnce() throws {
        if let relayEndpoint {
            try connectToRelay(endpoint: relayEndpoint)
            return
        }

        // Verify socket is owned by the current user to prevent fake-socket attacks.
        var st = stat()
        guard stat(path, &st) == 0 else {
            throw CLIError(message: "Socket not found at \(path)")
        }
        guard (st.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK) else {
            throw CLIError(message: "Path exists at \(path) but is not a Unix socket")
        }
        guard st.st_uid == getuid() else {
            throw CLIError(message: "Socket at \(path) is not owned by the current user — refusing to connect")
        }

        socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        if socketFD < 0 {
            throw CLIError(message: "Failed to create socket")
        }
        do {
            try configureSocketWriteSafety(Self.responseTimeoutSeconds)
        } catch {
            close()
            throw error
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
        if result == 0 {
            return
        }

        let connectErrno = errno
        Darwin.close(socketFD)
        socketFD = -1
        throw CLIError(
            message: "Failed to connect to socket at \(path) (\(String(cString: strerror(connectErrno))), errno \(connectErrno))"
        )
    }

    private static func parseRelayEndpoint(_ raw: String) -> RelayEndpoint? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("/") else {
            return nil
        }
        let components = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard components.count == 2,
              let port = UInt16(components[1]),
              port > 0 else {
            return nil
        }
        let host = String(components[0]).lowercased()
        guard host == "127.0.0.1" || host == "localhost" else {
            return nil
        }
        return RelayEndpoint(host: host == "localhost" ? "127.0.0.1" : host, port: port)
    }

    private static func relayCredentials(for endpoint: RelayEndpoint) throws -> RelayCredentials {
        let environment = ProcessInfo.processInfo.environment
        if let relayID = trimmedEnvValue(environment["CMUX_RELAY_ID"]),
           let relayTokenHex = trimmedEnvValue(environment["CMUX_RELAY_TOKEN"]),
           let relayToken = hexData(from: relayTokenHex) {
            return RelayCredentials(relayID: relayID, relayToken: relayToken)
        }

        let authURL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".cmux/relay/\(endpoint.port).auth", isDirectory: false)
        guard let authData = try? Data(contentsOf: authURL),
              let authObject = try? JSONSerialization.jsonObject(with: authData) as? [String: Any],
              let relayID = trimmedEnvValue(authObject["relay_id"] as? String),
              let relayTokenHex = trimmedEnvValue(authObject["relay_token"] as? String),
              let relayToken = hexData(from: relayTokenHex) else {
            throw CLIError(message: "Missing relay auth metadata for \(endpoint.host):\(endpoint.port)")
        }

        return RelayCredentials(relayID: relayID, relayToken: relayToken)
    }

    private static func hexData(from string: String) -> Data? {
        let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized.count.isMultiple(of: 2) else {
            return nil
        }

        var data = Data(capacity: normalized.count / 2)
        var cursor = normalized.startIndex
        while cursor < normalized.endIndex {
            let next = normalized.index(cursor, offsetBy: 2)
            guard let byte = UInt8(normalized[cursor..<next], radix: 16) else {
                return nil
            }
            data.append(byte)
            cursor = next
        }
        return data
    }

    private static func hexString(from data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private func connectToRelay(endpoint: RelayEndpoint) throws {
        let credentials = try Self.relayCredentials(for: endpoint)

        socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw CLIError(message: "Failed to create relay socket")
        }
        do {
            try configureSocketWriteSafety(Self.responseTimeoutSeconds)
            try configureReceiveTimeout(Self.responseTimeoutSeconds)
        } catch {
            close()
            throw error
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.stride)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = endpoint.port.bigEndian
        let parsedAddress = withUnsafeMutablePointer(to: &address.sin_addr) { pointer in
            endpoint.host.withCString { hostPointer in
                inet_pton(AF_INET, hostPointer, pointer)
            }
        }
        guard parsedAddress == 1 else {
            close()
            throw CLIError(message: "Invalid relay endpoint \(endpoint.host):\(endpoint.port)")
        }

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(socketFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.stride))
            }
        }
        if result != 0 {
            let connectErrno = errno
            close()
            throw CLIError(
                message: "Failed to connect to relay at \(endpoint.host):\(endpoint.port) (\(String(cString: strerror(connectErrno))), errno \(connectErrno))"
            )
        }

        do {
            try authenticateRelay(credentials: credentials)
        } catch {
            close()
            throw error
        }
    }

    private func authenticateRelay(credentials: RelayCredentials) throws {
        let challengeLine = try readLine()
        guard let challengeData = challengeLine.data(using: .utf8),
              let challenge = try JSONSerialization.jsonObject(with: challengeData) as? [String: Any],
              (challenge["protocol"] as? String) == "cmux-relay-auth",
              let version = challenge["version"] as? Int,
              let relayID = challenge["relay_id"] as? String,
              relayID == credentials.relayID,
              let nonce = challenge["nonce"] as? String,
              !nonce.isEmpty else {
            throw CLIError(message: "Invalid relay authentication challenge")
        }

        let authMessage = Data("relay_id=\(relayID)\nnonce=\(nonce)\nversion=\(version)".utf8)
        let key = SymmetricKey(data: credentials.relayToken)
        let mac = Data(HMAC<SHA256>.authenticationCode(for: authMessage, using: key))
        let authPayload = try JSONSerialization.data(withJSONObject: [
            "relay_id": relayID,
            "mac": Self.hexString(from: mac),
        ])
        try writeAll(
            authPayload + Data([0x0A]),
            timeoutMessage: "Relay command timed out",
            failureMessage: "Failed to write to relay socket"
        )

        let authResponseLine = try readLine()
        guard let authResponseData = authResponseLine.data(using: .utf8),
              let authResponse = try JSONSerialization.jsonObject(with: authResponseData) as? [String: Any],
              (authResponse["ok"] as? Bool) == true else {
            throw CLIError(message: "Relay authentication failed")
        }
    }

    private func writeAll(
        _ data: Data,
        timeoutMessage: String,
        failureMessage: String
    ) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return
            }
            var offset = 0
            while offset < data.count {
                let written = Darwin.write(socketFD, baseAddress.advanced(by: offset), data.count - offset)
                if written < 0 {
                    let errorCode = errno
                    if errorCode == EINTR {
                        continue
                    }
                    close()
                    if errorCode == EAGAIN || errorCode == EWOULDBLOCK || errorCode == ETIMEDOUT {
                        throw CLIError(message: timeoutMessage)
                    }
                    let reason = String(cString: strerror(errorCode))
                    throw CLIError(
                        message: "\(failureMessage) (\(reason), errno \(errorCode))"
                    )
                }
                if written == 0 {
                    close()
                    throw CLIError(message: failureMessage)
                }
                offset += written
            }
        }
    }

    private func configureSocketWriteSafety(_ timeout: TimeInterval) throws {
        var interval = Self.socketTimeval(for: timeout)
        let sendTimeoutResult = withUnsafePointer(to: &interval) { ptr in
            setsockopt(
                socketFD,
                SOL_SOCKET,
                SO_SNDTIMEO,
                ptr,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }
        guard sendTimeoutResult == 0 else {
            throw CLIError(message: "Failed to configure socket write timeout")
        }

#if os(macOS)
        var noSigPipe: Int32 = 1
        let noSigPipeResult = withUnsafePointer(to: &noSigPipe) { ptr in
            setsockopt(
                socketFD,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                ptr,
                socklen_t(MemoryLayout<Int32>.size)
            )
        }
        guard noSigPipeResult == 0 else {
            throw CLIError(message: "Failed to disable SIGPIPE on socket")
        }
#endif
    }

    private func readLine(maxBytes: Int = 16 * 1024) throws -> String {
        var data = Data()

        while data.count < maxBytes {
            try configureReceiveTimeout(Self.responseTimeoutSeconds)

            var byte: UInt8 = 0
            let count = Darwin.read(socketFD, &byte, 1)
            if count < 0 {
                if errno == EINTR {
                    continue
                }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    throw CLIError(message: "Relay command timed out")
                }
                throw CLIError(message: "Relay socket read error")
            }
            if count == 0 {
                break
            }
            if byte == 0x0A {
                break
            }
            data.append(byte)
        }

        guard !data.isEmpty else {
            throw CLIError(message: "Unexpected EOF from relay")
        }
        guard let line = String(data: data, encoding: .utf8) else {
            throw CLIError(message: "Invalid UTF-8 relay response")
        }
        return line.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func configureReceiveTimeout(_ timeout: TimeInterval) throws {
        var interval = Self.socketTimeval(for: timeout)
        let result = withUnsafePointer(to: &interval) { ptr in
            setsockopt(
                socketFD,
                SOL_SOCKET,
                SO_RCVTIMEO,
                ptr,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }
        guard result == 0 else {
            throw CLIError(message: "Failed to configure socket receive timeout")
        }
    }

    static func waitForConnectableSocket(path: String, timeout: TimeInterval) throws -> SocketClient {
        let client = SocketClient(path: path)
        if (try? client.connect()) != nil {
            if client.relayEndpoint != nil {
                client.close()
            }
            return client
        }

        guard let watchDirectory = existingWatchDirectory(forPath: path) else {
            throw CLIError(message: "cmux app did not start in time (socket not found at \(path))")
        }
        let watchFD = open(watchDirectory, O_EVTONLY)
        guard watchFD >= 0 else {
            throw CLIError(message: "cmux app did not start in time (socket not found at \(path))")
        }

        let queue = DispatchQueue(label: "com.cmux.cli.socket-watch.\(UUID().uuidString)")
        let semaphore = DispatchSemaphore(value: 0)
        var connected = false
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: watchFD,
            eventMask: [.write, .rename, .delete, .attrib, .extend, .link],
            queue: queue
        )

        func attemptConnect() {
            guard !connected else { return }
            if (try? client.connect()) != nil {
                connected = true
                semaphore.signal()
            }
        }

        source.setEventHandler {
            attemptConnect()
        }
        source.setCancelHandler {
            Darwin.close(watchFD)
        }
        source.resume()
        queue.async {
            attemptConnect()
        }

        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            source.cancel()
            client.close()
            throw CLIError(message: "cmux app did not start in time (socket not found at \(path))")
        }

        source.cancel()
        return client
    }

    static func waitForFilesystemPath(_ path: String, timeout: TimeInterval) throws {
        if FileManager.default.fileExists(atPath: path) {
            return
        }

        guard let watchDirectory = existingWatchDirectory(forPath: path) else {
            throw CLIError(message: "Timed out waiting for \(path)")
        }
        let watchFD = open(watchDirectory, O_EVTONLY)
        guard watchFD >= 0 else {
            throw CLIError(message: "Timed out waiting for \(path)")
        }

        let queue = DispatchQueue(label: "com.cmux.cli.path-watch.\(UUID().uuidString)")
        let semaphore = DispatchSemaphore(value: 0)
        var found = false
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: watchFD,
            eventMask: [.write, .rename, .delete, .attrib, .extend, .link],
            queue: queue
        )

        func checkPath() {
            guard !found else { return }
            if FileManager.default.fileExists(atPath: path) {
                found = true
                semaphore.signal()
            }
        }

        source.setEventHandler {
            checkPath()
        }
        source.setCancelHandler {
            Darwin.close(watchFD)
        }
        source.resume()
        queue.async {
            checkPath()
        }

        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            source.cancel()
            throw CLIError(message: "Timed out waiting for \(path)")
        }

        source.cancel()
    }

    private static func existingWatchDirectory(forPath path: String) -> String? {
        let fileManager = FileManager.default
        var candidate = URL(fileURLWithPath: (path as NSString).deletingLastPathComponent, isDirectory: true)

        while !candidate.path.isEmpty {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return candidate.path
            }
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path {
                break
            }
            candidate = parent
        }
        return nil
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

struct CLIProcessResult {
    let status: Int32
    let stdout: String
    let stderr: String
    let timedOut: Bool
}

enum CLIProcessRunner {
    static func runProcess(
        executablePath: String,
        arguments: [String],
        stdinText: String? = nil,
        timeout: TimeInterval? = nil
    ) -> CLIProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdinPipe: Pipe?
        if stdinText != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            stdinPipe = pipe
        } else {
            stdinPipe = nil
        }

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            finished.signal()
        }

        do {
            try process.run()
        } catch {
            return CLIProcessResult(status: 1, stdout: "", stderr: String(describing: error), timedOut: false)
        }

        if let stdinText, let stdinPipe {
            if let data = stdinText.data(using: .utf8) {
                stdinPipe.fileHandleForWriting.write(data)
            }
            stdinPipe.fileHandleForWriting.closeFile()
        }

        let timedOut: Bool
        if let timeout {
            switch finished.wait(timeout: .now() + timeout) {
            case .success:
                timedOut = false
            case .timedOut:
                timedOut = true
                terminate(process: process, finished: finished)
            }
        } else {
            finished.wait()
            timedOut = false
        }

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        var stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if timedOut {
            let timeoutMessage = "process timed out"
            if stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                stderr = timeoutMessage
            } else if !stderr.contains(timeoutMessage) {
                stderr += "\n\(timeoutMessage)"
            }
        }

        return CLIProcessResult(
            status: timedOut ? 124 : process.terminationStatus,
            stdout: stdout,
            stderr: stderr,
            timedOut: timedOut
        )
    }

    private static func terminate(process: Process, finished: DispatchSemaphore) {
        guard process.isRunning else { return }
        process.terminate()
        if finished.wait(timeout: .now() + 0.5) == .success {
            return
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        _ = finished.wait(timeout: .now() + 0.5)
    }
}

struct CMUXCLI {
    let args: [String]

    private static let debugLastSocketHintPath = "/tmp/cmux-last-socket-path"

    private static func normalizedEnvValue(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func pathIsSocket(_ path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFSOCK
    }

    private static func debugSocketPathFromHintFile() -> String? {
#if DEBUG
        guard let raw = try? String(contentsOfFile: debugLastSocketHintPath, encoding: .utf8) else {
            return nil
        }
        guard let hinted = normalizedEnvValue(raw),
              hinted.hasPrefix("/tmp/cmux-debug"),
              hinted.hasSuffix(".sock"),
              pathIsSocket(hinted) else {
            return nil
        }
        return hinted
#else
        return nil
#endif
    }

    private static func defaultSocketPath(environment: [String: String]) -> String {
        if let explicit = normalizedEnvValue(environment["CMUX_SOCKET_PATH"]) {
            return explicit
        }
#if DEBUG
        if let hinted = debugSocketPathFromHintFile() {
            return hinted
        }
        return "/tmp/cmux-debug.sock"
#else
        return "/tmp/cmux.sock"
#endif
    }

    func run() throws {
        let processEnv = ProcessInfo.processInfo.environment
        let envSocketPath: String? = {
            for key in ["CMUX_SOCKET_PATH", "CMUX_SOCKET"] {
                guard let raw = processEnv[key] else { continue }
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
            return nil
        }()
        var socketPath = envSocketPath ?? CLISocketPathResolver.defaultSocketPath
        var socketPathSource: CLISocketPathSource
        if let envSocketPath {
            socketPathSource = CLISocketPathResolver.isImplicitDefaultPath(envSocketPath) ? .implicitDefault : .environment
        } else {
            socketPathSource = .implicitDefault
        }
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
                socketPathSource = .explicitFlag
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
            processEnv: processEnv
        )
        let resolvedSocketPath = CLISocketPathResolver.resolve(
            requestedPath: socketPath,
            source: socketPathSource,
            environment: processEnv
        )

        if command == "version" {
            print(versionSummary())
            return
        }

        if command == "remote-daemon-status" {
            try runRemoteDaemonStatus(commandArgs: commandArgs, jsonOutput: jsonOutput)
            return
        }

        // If the argument looks like a path (not a known command), open a workspace there.
        if looksLikePath(command) {
            try openPath(command, socketPath: resolvedSocketPath)
            return
        }

        // Check for --help/-h on subcommands before connecting to the socket,
        // so help text is available even when cmux is not running.
        if command != "__tmux-compat",
           command != "claude-teams",
           command != "codex",
           (commandArgs.contains("--help") || commandArgs.contains("-h")) {
            if dispatchSubcommandHelp(command: command, commandArgs: commandArgs) {
                return
            }
            print("Unknown command '\(command)'. Run 'cmux help' to see available commands.")
            return
        }

        if command == "welcome" {
            printWelcome()
            return
        }

        if command == "shortcuts" {
            try runShortcuts(
                commandArgs: commandArgs,
                socketPath: resolvedSocketPath,
                explicitPassword: socketPasswordArg,
                jsonOutput: jsonOutput
            )
            return
        }

        if command == "restore-session" {
            try runRestoreSession(
                commandArgs: commandArgs,
                socketPath: resolvedSocketPath,
                explicitPassword: socketPasswordArg,
                jsonOutput: jsonOutput
            )
            return
        }

        if command == "feedback" {
            try runFeedback(
                commandArgs: commandArgs,
                socketPath: resolvedSocketPath,
                explicitPassword: socketPasswordArg,
                jsonOutput: jsonOutput
            )
            return
        }

        if command == "themes" {
            try runThemes(
                commandArgs: commandArgs,
                jsonOutput: jsonOutput
            )
            return
        }

        if command == "claude-teams" {
            try runClaudeTeams(
                commandArgs: commandArgs,
                socketPath: resolvedSocketPath,
                explicitPassword: socketPasswordArg
            )
            return
        }

        if command == "omo" {
            try runOMO(
                commandArgs: commandArgs,
                socketPath: resolvedSocketPath,
                explicitPassword: socketPasswordArg
            )
            return
        }

        if command == "omx" {
            try runOMX(
                commandArgs: commandArgs,
                socketPath: resolvedSocketPath,
                explicitPassword: socketPasswordArg
            )
            return
        }

        if command == "omc" {
            try runOMC(
                commandArgs: commandArgs,
                socketPath: resolvedSocketPath,
                explicitPassword: socketPasswordArg
            )
            return
        }

        // Codex hooks management (no socket needed)
        if command == "codex" {
            let sub = commandArgs.first?.lowercased() ?? "help"
            if sub == "install-hooks" {
                try installAgentHooks(Self.agentDef(named: "codex")!)
                return
            } else if sub == "uninstall-hooks" {
                try uninstallAgentHooks(Self.agentDef(named: "codex")!)
                return
            }
        }

        // OpenCode plugin management (no socket needed)
        if command == "opencode" {
            let sub = commandArgs.first?.lowercased() ?? "help"
            if sub == "install-hooks" {
                try installAgentHooks(Self.agentDef(named: "opencode")!)
                return
            } else if sub == "uninstall-hooks" {
                try uninstallAgentHooks(Self.agentDef(named: "opencode")!)
                return
            }
        }

        // Codex hook handler: gracefully no-op when not inside cmux
        // (before socket connection, so it doesn't fail when no socket exists)
        if command == "codex-hook" {
            guard ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"] != nil else {
                print("{}")
                return
            }
        }

        // OpenCode hook handler: gracefully no-op when not inside cmux
        if command == "opencode-hook" {
            guard ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"] != nil else {
                print("{}")
                return
            }
        }

        // Cursor hooks management (no socket needed)
        if command == "cursor" {
            let sub = commandArgs.first?.lowercased() ?? "help"
            if sub == "install-hooks" {
                try runCursorInstallHooks()
                return
            } else if sub == "uninstall-hooks" {
                try runCursorUninstallHooks()
                return
            }
        }

        // Cursor hook handler: gracefully no-op when not inside cmux
        if command == "cursor-hook" {
            guard ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"] != nil else {
                print("{}")
                return
            }
        }

        // Gemini hooks management (no socket needed)
        if command == "gemini" {
            let sub = commandArgs.first?.lowercased() ?? "help"
            if sub == "install-hooks" {
                try runGeminiInstallHooks()
                return
            } else if sub == "uninstall-hooks" {
                try runGeminiUninstallHooks()
                return
            }
        }

        // Gemini hook handler: gracefully no-op when not inside cmux
        if command == "gemini-hook" {
            guard ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"] != nil else {
                print("{}")
                return
            }
        }

        // Generic agent hooks management (copilot, codebuddy, factory, qoder)
        for agentName in ["copilot", "codebuddy", "factory", "qoder"] {
            guard command == agentName else { continue }
            let sub = commandArgs.first?.lowercased() ?? "help"
            if sub == "install-hooks", let def = Self.agentDef(named: agentName) {
                try installAgentHooks(def)
                return
            } else if sub == "uninstall-hooks", let def = Self.agentDef(named: agentName) {
                try uninstallAgentHooks(def)
                return
            }
        }

        // Generic agent hook handlers: gracefully no-op outside cmux
        if ["copilot-hook", "codebuddy-hook", "factory-hook", "qoder-hook"].contains(command) {
            guard ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"] != nil else {
                print("{}")
                return
            }
        }

        // Unified hook setup for all agents
        if command == "setup-hooks" || command == "uninstall-hooks" {
            try runSetupHooks(uninstall: command == "uninstall-hooks")
            return
        }

        let client = SocketClient(path: resolvedSocketPath)
        if resolvedSocketPath != socketPath {
            cliTelemetry.breadcrumb(
                "socket.path.autodiscovered",
                data: [
                    "requested_path": socketPath,
                    "resolved_path": resolvedSocketPath
                ]
            )
        }
        cliTelemetry.breadcrumb(
            "socket.connect.attempt",
            data: [
                "command": command,
                "path": resolvedSocketPath
            ]
        )
        do {
            try client.connect()
            cliTelemetry.breadcrumb("socket.connect.success", data: ["path": resolvedSocketPath])
        } catch {
            cliTelemetry.breadcrumb("socket.connect.failure", data: ["path": resolvedSocketPath])
            cliTelemetry.captureError(stage: "socket_connect", error: error)
            throw error
        }
        defer { client.close() }

        try authenticateClientIfNeeded(
            client,
            explicitPassword: socketPasswordArg,
            socketPath: resolvedSocketPath
        )

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

        case "auth":
            let sub = commandArgs.first?.lowercased() ?? "status"
            switch sub {
            case "status":
                let response = try client.sendV2(method: "auth.status")
                if jsonOutput {
                    print(jsonString(response))
                    break
                }
                let signedIn = (response["signed_in"] as? Bool) ?? false
                if !signedIn {
                    print("Not signed in.")
                    print("Run: cmux auth login")
                    break
                }
                let user = response["user"] as? [String: Any]
                let email = user?["email"] as? String
                let display = user?["display_name"] as? String
                let userID = user?["id"] as? String
                print("Signed in.")
                if let email { print("  email:    \(email)") }
                if let display { print("  name:     \(display)") }
                if let userID { print("  user_id:  \(userID)") }
                if let teamID = response["selected_team_id"] as? String {
                    print("  team_id:  \(teamID)")
                }

            case "login":
                let statusBefore = try client.sendV2(method: "auth.status")
                if (statusBefore["signed_in"] as? Bool) == true {
                    let email = (statusBefore["user"] as? [String: Any])?["email"] as? String
                    print("Already signed in\(email.map { " as \($0)" } ?? ""). Use `cmux auth logout` to sign out first.")
                    break
                }
                print("Opening sign-in popup on the cmux mac app.")
                // auth.begin_sign_in blocks on the server side until the
                // popup completes (or 5min timeout). The response is the
                // callback — no polling.
                let result = try client.sendV2(method: "auth.begin_sign_in")
                if (result["signed_in"] as? Bool) == true {
                    let email = (result["user"] as? [String: Any])?["email"] as? String
                    print("Signed in\(email.map { " as \($0)" } ?? "").")
                } else if (result["timed_out"] as? Bool) == true {
                    print("Timed out waiting for sign-in. Run `cmux auth status` once you've finished in the popup.")
                } else {
                    print("Sign-in did not complete. Run `cmux auth status` to check.")
                }

            case "logout":
                let statusBefore = try client.sendV2(method: "auth.status")
                if (statusBefore["signed_in"] as? Bool) != true {
                    print("Already signed out.")
                    break
                }
                // auth.sign_out awaits the token clear before replying.
                let result = try client.sendV2(method: "auth.sign_out")
                if (result["signed_in"] as? Bool) != true {
                    print("Signed out.")
                } else {
                    print("Sign-out requested but state hasn't cleared yet. Run `cmux auth status` to confirm.")
                }

            default:
                throw CLIError(message: "Usage: cmux auth <status|login|logout>")
            }

        case "rpc":
            guard let method = commandArgs.first?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !method.isEmpty else {
                throw CLIError(message: "Usage: cmux rpc <method> [json-params]")
            }
            let params = try parseRPCParams(Array(commandArgs.dropFirst()))
            let response = try client.sendV2(method: method, params: params)
            let output: Any = idFormatArg == nil ? response : formatIDs(response, mode: idFormat)
            print(jsonString(output))

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
                        let remoteTag: String = {
                            guard let remote = ws["remote"] as? [String: Any],
                                  (remote["enabled"] as? Bool) == true else {
                                return ""
                            }
                            let state = (remote["state"] as? String) ?? "unknown"
                            return "  [ssh:\(state)]"
                        }()
                        let prefix = selected ? "* " : "  "
                        let selTag = selected ? "  [selected]" : ""
                        let titlePart = title.isEmpty ? "" : "  \(title)"
                        print("\(prefix)\(handle)\(titlePart)\(remoteTag)\(selTag)")
                    }
                }
            }

        case "ssh":
            try runSSH(commandArgs: commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat)
        case "ssh-session-end":
            try runSSHSessionEnd(commandArgs: commandArgs, client: client)

        case "new-workspace":
            let (commandOpt, rem0) = parseOption(commandArgs, name: "--command")
            let (cwdOpt, rem1) = parseOption(rem0, name: "--cwd")
            let (nameOpt, rem2) = parseOption(rem1, name: "--name")
            let (descriptionOpt, rem3) = parseOption(rem2, name: "--description")
            let (layoutOpt, remaining) = parseOption(rem3, name: "--layout")
            if let unknown = remaining.first(where: { $0.hasPrefix("--") }) {
                throw CLIError(message: "new-workspace: unknown flag '\(unknown)'. Known flags: --name <title>, --description <text>, --command <text>, --cwd <path>, --layout <json>")
            }
            var params: [String: Any] = [:]
            if let cwdOpt {
                let resolved = resolvePath(cwdOpt)
                params["cwd"] = resolved
            }
            if let nameOpt {
                params["title"] = nameOpt
            }
            if let descriptionOpt {
                params["description"] = descriptionOpt
            }
            if let layoutOpt {
                guard let layoutData = layoutOpt.data(using: .utf8),
                      let layoutObj = try? JSONSerialization.jsonObject(with: layoutData) as? [String: Any] else {
                    throw CLIError(message: "new-workspace: --layout value must be a valid JSON object")
                }
                params["layout"] = layoutObj
            }
            let response = try client.sendV2(method: "workspace.create", params: params)
            let wsId = (response["workspace_ref"] as? String) ?? (response["workspace_id"] as? String) ?? ""
            print("OK \(wsId)")
            if layoutOpt == nil, let commandText = commandOpt, !wsId.isEmpty {
                let text = unescapeSendText(commandText + "\\n")
                let sendParams: [String: Any] = ["text": text, "workspace_id": wsId]
                _ = try client.sendV2(method: "surface.send_text", params: sendParams)
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

        case "tree":
            try runTreeCommand(commandArgs: commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

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
            if let closedWorkspaceId = (payload["workspace_id"] as? String) ?? wsId,
               let closedSurfaceId = (payload["surface_id"] as? String) ?? sfId {
                try? tmuxPruneCompatSurfaceState(
                    workspaceId: closedWorkspaceId,
                    surfaceId: closedSurfaceId,
                    client: client
                )
            }
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
        case "reload-config":
            if let unexpected = commandArgs.first {
                throw CLIError(message: "reload-config does not accept arguments. Unexpected argument '\(unexpected)'")
            }
            let response = try sendV1Command("reload_config", client: client)
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

        case "debug-terminals":
            let unexpected = commandArgs.filter { $0 != "--" }
            if let extra = unexpected.first {
                throw CLIError(message: "debug-terminals: unexpected argument '\(extra)'")
            }
            let payload = try client.sendV2(method: "debug.terminals")
            if jsonOutput {
                print(jsonString(formatIDs(payload, mode: idFormat)))
            } else {
                print(formatDebugTerminalsPayload(payload, idFormat: idFormat))
            }

        case "trigger-flash":
            let tfWsFlag = optionValue(commandArgs, name: "--workspace")
            let explicitWorkspaceArg = tfWsFlag
            let preferTTYFallback = windowId == nil && ProcessInfo.processInfo.environment["TMUX"] != nil
            let callerWorkspaceArg = preferTTYFallback
                ? nil
                : (windowId == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
            let workspaceArg = explicitWorkspaceArg ?? callerWorkspaceArg
            let explicitSurfaceArg = optionValue(commandArgs, name: "--surface") ?? optionValue(commandArgs, name: "--panel")
            let callerSurfaceArg = explicitSurfaceArg == nil && preferTTYFallback == false && windowId == nil
                ? ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"]
                : nil
            let surfaceArg = explicitSurfaceArg ?? callerSurfaceArg
            var params: [String: Any] = [:]
            let wsId = try {
                if explicitWorkspaceArg != nil {
                    return try normalizeWorkspaceHandle(workspaceArg, client: client)
                }
                return try resolveWorkspaceIdAllowingFallback(workspaceArg, client: client)
            }()
            if let wsId { params["workspace_id"] = wsId }
            let sfId = try {
                if explicitSurfaceArg != nil {
                    return try normalizeSurfaceHandle(surfaceArg, client: client, workspaceHandle: wsId)
                }
                guard let wsId else { return nil }
                return try resolveSurfaceIdAllowingFallback(
                    surfaceArg,
                    workspaceId: wsId,
                    client: client
                )
            }()
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
            if let closedWorkspaceId = (payload["workspace_id"] as? String) ?? wsId {
                try? tmuxPruneCompatWorkspaceState(workspaceId: closedWorkspaceId)
            }
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
            let response = try client.sendV2(method: "workspace.current")
            if jsonOutput {
                print(jsonString(formatIDs(response, mode: idFormat)))
            } else {
                let handle = formatHandle(response, kind: "workspace", idFormat: idFormat)
                    ?? (response["workspace_id"] as? String)
                    ?? ""
                print(handle)
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

            let explicitWorkspaceArg = optionValue(commandArgs, name: "--workspace")
            let preferTTYFallback = windowId == nil && ProcessInfo.processInfo.environment["TMUX"] != nil
            let callerWorkspaceArg = preferTTYFallback
                ? nil
                : (windowId == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
            let workspaceArg = explicitWorkspaceArg ?? callerWorkspaceArg
            let explicitSurfaceArg = optionValue(commandArgs, name: "--surface")
            let callerSurfaceArg = explicitSurfaceArg == nil && preferTTYFallback == false && windowId == nil
                ? ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"]
                : nil
            let surfaceArg = explicitSurfaceArg ?? callerSurfaceArg

            let targetWorkspace = try {
                if explicitWorkspaceArg != nil {
                    return try resolveWorkspaceId(workspaceArg, client: client)
                }
                return try resolveWorkspaceIdAllowingFallback(workspaceArg, client: client)
            }()
            let targetSurface = try {
                if explicitSurfaceArg != nil {
                    return try resolveSurfaceId(surfaceArg, workspaceId: targetWorkspace, client: client)
                }
                return try resolveSurfaceIdAllowingFallback(
                    surfaceArg,
                    workspaceId: targetWorkspace,
                    client: client
                )
            }()

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
            var socketCmd = "clear_notifications"
            if let wsFlag = optionValue(commandArgs, name: "--workspace") {
                let wsId = try resolveWorkspaceId(wsFlag, client: client)
                socketCmd += " --tab=\(wsId)"
            } else if windowId == nil,
                      let envWs = ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"],
                      let wsId = try? resolveWorkspaceId(envWs, client: client) {
                socketCmd += " --tab=\(wsId)"
            }
            let response = try sendV1Command(socketCmd, client: client)
            print(response)

        case "set-status":
            let response = try forwardSidebarMetadataCommand(
                "set_status",
                commandArgs: commandArgs,
                client: client,
                windowOverride: windowId
            )
            print(response)

        case "clear-status":
            let response = try forwardSidebarMetadataCommand(
                "clear_status",
                commandArgs: commandArgs,
                client: client,
                windowOverride: windowId
            )
            print(response)

        case "list-status":
            let response = try forwardSidebarMetadataCommand(
                "list_status",
                commandArgs: commandArgs,
                client: client,
                windowOverride: windowId
            )
            print(response)

        case "set-progress":
            let response = try forwardSidebarMetadataCommand(
                "set_progress",
                commandArgs: commandArgs,
                client: client,
                windowOverride: windowId
            )
            print(response)

        case "clear-progress":
            let response = try forwardSidebarMetadataCommand(
                "clear_progress",
                commandArgs: commandArgs,
                client: client,
                windowOverride: windowId
            )
            print(response)

        case "log":
            let response = try forwardSidebarMetadataCommand(
                "log",
                commandArgs: commandArgs,
                client: client,
                windowOverride: windowId
            )
            print(response)

        case "clear-log":
            let response = try forwardSidebarMetadataCommand(
                "clear_log",
                commandArgs: commandArgs,
                client: client,
                windowOverride: windowId
            )
            print(response)

        case "list-log":
            let response = try forwardSidebarMetadataCommand(
                "list_log",
                commandArgs: commandArgs,
                client: client,
                windowOverride: windowId
            )
            print(response)

        case "sidebar-state":
            let response = try forwardSidebarMetadataCommand(
                "sidebar_state",
                commandArgs: commandArgs,
                client: client,
                windowOverride: windowId
            )
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

        case "codex-hook":
            cliTelemetry.breadcrumb("codex-hook.dispatch")
            do {
                try runGenericAgentHook(def: Self.agentDef(named: "codex")!, commandArgs: commandArgs, client: client, telemetry: cliTelemetry)
                cliTelemetry.breadcrumb("codex-hook.completed")
            } catch {
                cliTelemetry.breadcrumb("codex-hook.failure")
                cliTelemetry.captureError(stage: "codex_hook_dispatch", error: error)
                throw error
            }

        case "opencode-hook":
            cliTelemetry.breadcrumb("opencode-hook.dispatch")
            do {
                try runGenericAgentHook(def: Self.agentDef(named: "opencode")!, commandArgs: commandArgs, client: client, telemetry: cliTelemetry)
                cliTelemetry.breadcrumb("opencode-hook.completed")
            } catch {
                cliTelemetry.breadcrumb("opencode-hook.failure")
                cliTelemetry.captureError(stage: "opencode_hook_dispatch", error: error)
                throw error
            }

        case "cursor-hook":
            cliTelemetry.breadcrumb("cursor-hook.dispatch")
            do {
                try runCursorHook(commandArgs: commandArgs, client: client, telemetry: cliTelemetry)
                cliTelemetry.breadcrumb("cursor-hook.completed")
            } catch {
                cliTelemetry.breadcrumb("cursor-hook.failure")
                cliTelemetry.captureError(stage: "cursor_hook_dispatch", error: error)
                throw error
            }

        case "gemini-hook":
            cliTelemetry.breadcrumb("gemini-hook.dispatch")
            do {
                try runGeminiHook(commandArgs: commandArgs, client: client, telemetry: cliTelemetry)
                cliTelemetry.breadcrumb("gemini-hook.completed")
            } catch {
                cliTelemetry.breadcrumb("gemini-hook.failure")
                cliTelemetry.captureError(stage: "gemini_hook_dispatch", error: error)
                throw error
            }

        case "copilot-hook", "codebuddy-hook", "factory-hook", "qoder-hook":
            let agentName = String(command.dropLast("-hook".count))
            guard let def = Self.agentDef(named: agentName) else {
                throw CLIError(message: "Unknown agent: \(agentName)")
            }
            cliTelemetry.breadcrumb("\(command).dispatch")
            do {
                try runGenericAgentHook(def: def, commandArgs: commandArgs, client: client, telemetry: cliTelemetry)
                cliTelemetry.breadcrumb("\(command).completed")
            } catch {
                cliTelemetry.breadcrumb("\(command).failure")
                cliTelemetry.captureError(stage: "\(agentName)_hook_dispatch", error: error)
                throw error
            }

        case "set-app-focus":
            guard let value = commandArgs.first else { throw CLIError(message: "set-app-focus requires a value") }
            let response = try sendV1Command("set_app_focus \(value)", client: client)
            print(response)

        case "simulate-app-active":
            let response = try sendV1Command("simulate_app_active", client: client)
            print(response)

        case "__tmux-compat":
            try runClaudeTeamsTmuxCompat(
                commandArgs: commandArgs,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat,
                windowOverride: windowId
            )

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

        // Markdown commands
        case "markdown":
            try runMarkdownCommand(commandArgs: commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        default:
            print(usage())
            throw CLIError(message: "Unknown command: \(command)")
        }
    }

    private func resolvePath(_ path: String) -> String {
        let expanded = NSString(string: path).expandingTildeInPath
        if expanded.hasPrefix("/") { return expanded }
        let cwd = FileManager.default.currentDirectoryPath
        return (cwd as NSString).appendingPathComponent(expanded)
    }

    private func sanitizedFilenameComponent(_ raw: String) -> String {
        let sanitized = raw.replacingOccurrences(
            of: #"[^\p{L}\p{N}._-]+"#,
            with: "-",
            options: .regularExpression
        )
        let trimmed = sanitized.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return trimmed.isEmpty ? "item" : trimmed
    }

    private func bestEffortPruneTemporaryFiles(
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

    // MARK: - Markdown Commands

    private func runMarkdownCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        var args = commandArgs

        // Parse routing flags
        let (workspaceOpt, argsAfterWorkspace) = parseOption(args, name: "--workspace")
        let (windowOpt, argsAfterWindow) = parseOption(argsAfterWorkspace, name: "--window")
        let (surfaceOpt, argsAfterSurface) = parseOption(argsAfterWindow, name: "--surface")
        let (directionOpt, argsAfterDirection) = parseOption(argsAfterSurface, name: "--direction")
        args = argsAfterDirection

        // Determine subcommand. Explicit "open" is supported, otherwise treat
        // a single positional argument as shorthand path.
        let subArgs: [String]
        if let first = args.first, first.lowercased() == "open" {
            subArgs = Array(args.dropFirst())
        } else if args.count == 1, let first = args.first, !first.hasPrefix("-") {
            subArgs = [first]
        } else {
            // Allow path-like first tokens (e.g. plan.md) with trailing args
            // so we can surface specific trailing-arg/flag errors below.
            if let first = args.first, first.hasPrefix("-") {
                throw CLIError(
                    message:
                        "markdown open: unknown flag '\(first)'. Usage: cmux markdown open <path> [--workspace <id|ref|index>] [--surface <id|ref|index>] [--window <id|ref|index>] [--direction right|down|left|up]"
                )
            } else if let first = args.first, looksLikePath(first) || first.contains(".") {
                subArgs = args
            } else if let first = args.first {
                throw CLIError(message: "Unknown markdown subcommand: \(first). Usage: cmux markdown open <path>")
            } else {
                subArgs = []
            }
        }

        guard let rawPath = subArgs.first, !rawPath.isEmpty else {
            throw CLIError(message: "markdown open requires a file path. Usage: cmux markdown open <path>")
        }
        let trailingArgs = Array(subArgs.dropFirst())
        if let unknownFlag = trailingArgs.first(where: { $0.hasPrefix("-") }) {
            throw CLIError(
                message:
                    "markdown open: unknown flag '\(unknownFlag)'. Usage: cmux markdown open <path> [--workspace <id|ref|index>] [--surface <id|ref|index>] [--window <id|ref|index>] [--direction right|down|left|up]"
            )
        }
        if let extraArg = trailingArgs.first {
            throw CLIError(
                message:
                    "markdown open: unexpected argument '\(extraArg)'. Usage: cmux markdown open <path> [--workspace <id|ref|index>] [--surface <id|ref|index>] [--window <id|ref|index>] [--direction right|down|left|up]"
            )
        }

        let absolutePath = resolvePath(rawPath)

        // Build params
        let direction = directionOpt ?? "right"
        var params: [String: Any] = ["path": absolutePath, "direction": direction]
        if let surfaceRaw = surfaceOpt {
            if let surface = try normalizeSurfaceHandle(surfaceRaw, client: client) {
                params["surface_id"] = surface
            }
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

        let payload = try client.sendV2(method: "markdown.open", params: params)

        if jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
        } else {
            let surfaceText = formatHandle(payload, kind: "surface", idFormat: idFormat) ?? "unknown"
            let paneText = formatHandle(payload, kind: "pane", idFormat: idFormat) ?? "unknown"
            let filePath = (payload["path"] as? String) ?? absolutePath
            print("OK surface=\(surfaceText) pane=\(paneText) path=\(filePath)")
        }
    }

    /// Returns true if the argument looks like a filesystem path rather than a CLI command.
    private func looksLikePath(_ arg: String) -> Bool {
        if arg == "." || arg == ".." { return true }
        if arg.hasPrefix("/") || arg.hasPrefix("./") || arg.hasPrefix("../") || arg.hasPrefix("~") { return true }
        if arg.contains("/") { return true }
        return false
    }

    /// Open a path in cmux by creating a new workspace with the given directory.
    /// Launches the app if it isn't already running.
    private func openPath(_ path: String, socketPath: String) throws {
        let resolved = resolvePath(path)
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir)

        let directory: String
        if exists && isDir.boolValue {
            directory = resolved
        } else if exists {
            // It's a file; use its parent directory
            directory = (resolved as NSString).deletingLastPathComponent
        } else {
            throw CLIError(message: "Path does not exist: \(resolved)")
        }

        // Try connecting to the socket. If it fails, launch the app and retry.
        let client = SocketClient(path: socketPath)
        if (try? client.connect()) == nil {
            client.close()
            try launchApp()
            let launchedClient = try SocketClient.waitForConnectableSocket(path: socketPath, timeout: 10)
            defer { launchedClient.close() }
            let params: [String: Any] = ["cwd": directory]
            let response = try launchedClient.sendV2(method: "workspace.create", params: params)
            let wsRef = (response["workspace_ref"] as? String) ?? (response["workspace_id"] as? String) ?? ""
            if !wsRef.isEmpty {
                print("OK \(wsRef)")
            }
            try activateApp()
            return
        }
        defer { client.close() }

        let params: [String: Any] = ["cwd": directory]
        let response = try client.sendV2(method: "workspace.create", params: params)
        let wsRef = (response["workspace_ref"] as? String) ?? (response["workspace_id"] as? String) ?? ""
        if !wsRef.isEmpty {
            print("OK \(wsRef)")
        }

        // Bring the app to front
        try activateApp()
    }

    private func runFeedback(
        commandArgs: [String],
        socketPath: String,
        explicitPassword: String?,
        jsonOutput: Bool
    ) throws {
        let (emailOpt, rem0) = parseOption(commandArgs, name: "--email")
        let (bodyOpt, rem1) = parseOption(rem0, name: "--body")
        let (imagePaths, rem2) = parseRepeatedOption(rem1, name: "--image")
        let remaining = rem2.filter { $0 != "--" }

        if let unknown = remaining.first {
            throw CLIError(message: "feedback: unknown flag '\(unknown)'. Known flags: --email <email>, --body <text>, --image <path>")
        }

        let client = try connectClient(
            socketPath: socketPath,
            explicitPassword: explicitPassword,
            launchIfNeeded: true
        )
        defer { client.close() }

        if emailOpt == nil && bodyOpt == nil && imagePaths.isEmpty {
            var params: [String: Any] = [:]
            let env = ProcessInfo.processInfo.environment
            if let workspaceId = env["CMUX_WORKSPACE_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !workspaceId.isEmpty {
                params["workspace_id"] = workspaceId
                params["activate"] = false
            } else {
                params["activate"] = true
            }
            let response = try client.sendV2(method: "feedback.open", params: params)
            if jsonOutput {
                print(jsonString(response))
            } else {
                print("OK")
            }
            return
        }

        guard let email = emailOpt?.trimmingCharacters(in: .whitespacesAndNewlines),
              email.isEmpty == false else {
            throw CLIError(message: "feedback requires --email <email> when sending feedback")
        }
        guard let body = bodyOpt, body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw CLIError(message: "feedback requires --body <text> when sending feedback")
        }

        let resolvedImages = imagePaths.map(resolvePath)
        let response = try client.sendV2(method: "feedback.submit", params: [
            "email": email,
            "body": body,
            "image_paths": resolvedImages,
        ])
        if jsonOutput {
            print(jsonString(response))
        } else {
            print("OK")
        }
    }

    private func runShortcuts(
        commandArgs: [String],
        socketPath: String,
        explicitPassword: String?,
        jsonOutput: Bool
    ) throws {
        let remaining = commandArgs.filter { $0 != "--" }
        if let unknown = remaining.first {
            throw CLIError(message: "shortcuts: unknown flag '\(unknown)'")
        }

        let client = try connectClient(
            socketPath: socketPath,
            explicitPassword: explicitPassword,
            launchIfNeeded: true
        )
        defer { client.close() }

        let response = try client.sendV2(method: "settings.open", params: [
            "target": "keyboardShortcuts",
            "activate": true,
        ])
        if jsonOutput {
            print(jsonString(response))
        } else {
            print("OK")
        }
    }

    private func runRestoreSession(
        commandArgs: [String],
        socketPath: String,
        explicitPassword: String?,
        jsonOutput: Bool
    ) throws {
        let remaining = commandArgs.filter { $0 != "--" }
        if let unknown = remaining.first {
            throw CLIError(message: "restore-session: unknown flag '\(unknown)'")
        }

        let initialClient = SocketClient(path: socketPath)
        let client: SocketClient
        let launched: Bool
        if (try? initialClient.connect()) == nil {
            initialClient.close()
            try launchApp()
            client = try SocketClient.waitForConnectableSocket(path: socketPath, timeout: 10)
            launched = true
        } else {
            client = initialClient
            launched = false
        }

        defer { client.close() }
        try authenticateClientIfNeeded(
            client,
            explicitPassword: explicitPassword,
            socketPath: socketPath
        )

        let response = try client.sendV2(method: "session.restore_previous")
        if jsonOutput {
            var payload = response
            payload["launched"] = launched
            print(jsonString(payload))
        } else {
            print("OK")
        }
    }

    private func connectClient(
        socketPath: String,
        explicitPassword: String?,
        launchIfNeeded: Bool
    ) throws -> SocketClient {
        let client = SocketClient(path: socketPath)
        if launchIfNeeded && (try? client.connect()) == nil {
            client.close()
            try launchApp()
            let launchedClient = try SocketClient.waitForConnectableSocket(path: socketPath, timeout: 10)
            try authenticateClientIfNeeded(
                launchedClient,
                explicitPassword: explicitPassword,
                socketPath: socketPath
            )
            return launchedClient
        }

        try client.connect()
        try authenticateClientIfNeeded(
            client,
            explicitPassword: explicitPassword,
            socketPath: socketPath
        )
        return client
    }

    private func authenticateClientIfNeeded(
        _ client: SocketClient,
        explicitPassword: String?,
        socketPath: String
    ) throws {
        if let socketPassword = SocketPasswordResolver.resolve(
            explicit: explicitPassword,
            socketPath: socketPath
        ) {
            let authResponse = try client.send(command: "auth \(socketPassword)")
            if authResponse.hasPrefix("ERROR:"),
               !authResponse.contains("Unknown command 'auth'") {
                throw CLIError(message: authResponse)
            }
        }
    }

    private func launchApp() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "cmux"]
        try process.run()
        process.waitUntilExit()
    }

    private func activateApp() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "cmux"]
        try process.run()
        process.waitUntilExit()
    }

    private func resolvedIDFormat(jsonOutput: Bool, raw: String?) throws -> CLIIDFormat {
        _ = jsonOutput
        if let parsed = try CLIIDFormat.parse(raw) {
            return parsed
        }
        return .refs
    }

    private func sendV1Command(_ command: String, client: SocketClient) throws -> String {
        let response = try client.send(command: command)
        if response.hasPrefix("ERROR:") {
            throw CLIError(message: response)
        }
        return response
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

    private func doubleFromAny(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let f = value as? Float { return Double(f) }
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
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

    private func debugString(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        if let string = value as? String {
            return string
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return String(describing: value)
    }

    private func debugBool(_ value: Any?) -> Bool? {
        if let bool = value as? Bool {
            return bool
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        if let string = value as? String {
            return parseBoolString(string)
        }
        return nil
    }

    private func debugFlag(_ value: Any?) -> String {
        guard let bool = debugBool(value) else { return "nil" }
        return bool ? "1" : "0"
    }

    private func formatDebugRect(_ value: Any?) -> String? {
        guard let rect = value as? [String: Any],
              let x = doubleFromAny(rect["x"]),
              let y = doubleFromAny(rect["y"]),
              let width = doubleFromAny(rect["width"]),
              let height = doubleFromAny(rect["height"]) else {
            return nil
        }
        return String(format: "{%.1f,%.1f %.1fx%.1f}", x, y, width, height)
    }

    private func formatDebugPorts(_ value: Any?) -> String {
        guard let array = value as? [Any], !array.isEmpty else { return "[]" }
        let ports = array
            .compactMap { intFromAny($0) }
            .map(String.init)
        return ports.isEmpty ? "[]" : ports.joined(separator: ",")
    }

    private func formatDebugList(_ value: Any?) -> String? {
        guard let array = value as? [Any], !array.isEmpty else { return nil }
        let items = array.compactMap { item -> String? in
            if let string = item as? String {
                return string
            }
            return debugString(item)
        }
        guard !items.isEmpty else { return nil }
        return items.joined(separator: ">")
    }

    private func formatDebugAge(_ value: Any?) -> String? {
        guard let seconds = doubleFromAny(value) else { return nil }
        return String(format: "%.3fs", seconds)
    }

    private func formatDebugTerminalsPayload(_ payload: [String: Any], idFormat: CLIIDFormat) -> String {
        let terminals = payload["terminals"] as? [[String: Any]] ?? []
        guard !terminals.isEmpty else { return "No terminal surfaces" }

        return terminals.map { item in
            let index = intFromAny(item["index"]) ?? 0
            let surface = formatHandle(item, kind: "surface", idFormat: idFormat) ?? "?"
            let window = formatHandle(item, kind: "window", idFormat: idFormat) ?? "nil"
            let workspace = formatHandle(item, kind: "workspace", idFormat: idFormat) ?? "nil"
            let pane = formatHandle(item, kind: "pane", idFormat: idFormat) ?? "nil"
            let bonsplitTab = debugString(item["bonsplit_tab_id"]) ?? "nil"
            let lastKnownWorkspace = debugString(item["last_known_workspace_ref"]) ?? debugString(item["last_known_workspace_id"]) ?? "nil"
            let titleSuffix: String = {
                guard let title = debugString(item["surface_title"]), !title.isEmpty else { return "" }
                let escaped = title.replacingOccurrences(of: "\"", with: "\\\"")
                return " \"\(escaped)\""
            }()
            let branchLabel: String = {
                guard let branch = debugString(item["git_branch"]), !branch.isEmpty else { return "nil" }
                return debugBool(item["git_dirty"]) == true ? "\(branch)*" : branch
            }()
            let teardownLabel: String = {
                guard debugBool(item["teardown_requested"]) == true else { return "nil" }
                let reason = debugString(item["teardown_requested_reason"]) ?? "requested"
                let age = formatDebugAge(item["teardown_requested_age_seconds"]) ?? "unknown"
                return "\(reason)@\(age)"
            }()
            let portalHostLabel: String = {
                let hostId = debugString(item["portal_host_id"]) ?? "nil"
                let area = doubleFromAny(item["portal_host_area"]).map { String(format: "%.1f", $0) } ?? "nil"
                let inWindow = debugFlag(item["portal_host_in_window"])
                return "\(hostId)/win=\(inWindow)/area=\(area)"
            }()
            let windowMetaLabel: String = {
                let title = debugString(item["window_title"]) ?? "nil"
                let windowClass = debugString(item["window_class"]) ?? "nil"
                let controllerClass = debugString(item["window_controller_class"]) ?? "nil"
                let delegateClass = debugString(item["window_delegate_class"]) ?? "nil"
                return "title=\(title) class=\(windowClass) controller=\(controllerClass) delegate=\(delegateClass)"
            }()

            let line1 =
                "[\(index)] \(surface)\(titleSuffix) " +
                "mapped=\(debugFlag(item["mapped"])) tree=\(debugFlag(item["tree_visible"])) " +
                "window=\(window) workspace=\(workspace) pane=\(pane) bonsplitTab=\(bonsplitTab) " +
                "ctx=\(debugString(item["surface_context"]) ?? "nil")"

            let line2 =
                "    runtime=\(debugFlag(item["runtime_surface_ready"])) " +
                "focused=\(debugFlag(item["surface_focused"])) " +
                "selected=\(debugFlag(item["surface_selected_in_pane"])) " +
                "pinned=\(debugFlag(item["surface_pinned"])) " +
                "terminal=\(debugString(item["terminal_object_ptr"]) ?? "nil") " +
                "hosted=\(debugString(item["hosted_view_ptr"]) ?? "nil") " +
                "ghostty=\(debugString(item["ghostty_surface_ptr"]) ?? "nil") " +
                "portal=\(debugString(item["portal_binding_state"]) ?? "nil")#\(debugString(item["portal_binding_generation"]) ?? "nil") " +
                "teardown=\(teardownLabel)"

            let line3 =
                "    tty=\(debugString(item["tty"]) ?? "nil") " +
                "cwd=\(debugString(item["current_directory"]) ?? debugString(item["requested_working_directory"]) ?? "nil") " +
                "branch=\(branchLabel) " +
                "ports=\(formatDebugPorts(item["listening_ports"])) " +
                "visible=\(debugFlag(item["hosted_view_visible_in_ui"])) " +
                "inWindow=\(debugFlag(item["hosted_view_in_window"])) " +
                "superview=\(debugFlag(item["hosted_view_has_superview"])) " +
                "hidden=\(debugFlag(item["hosted_view_hidden"])) " +
                "ancestorHidden=\(debugFlag(item["hosted_view_hidden_or_ancestor_hidden"])) " +
                "firstResponder=\(debugFlag(item["surface_view_first_responder"])) " +
                "windowNum=\(debugString(item["window_number"]) ?? "nil") " +
                "windowKey=\(debugFlag(item["window_key"])) " +
                "frame=\(formatDebugRect(item["hosted_view_frame_in_window"]) ?? "nil")"

            let line4 =
                "    created=\(formatDebugAge(item["surface_age_seconds"]) ?? "nil") " +
                "runtimeCreated=\(formatDebugAge(item["runtime_surface_age_seconds"]) ?? "nil") " +
                "lastWorkspace=\(lastKnownWorkspace) " +
                "initialCommand=\(debugString(item["initial_command"]) ?? "nil") " +
                "portalHost=\(portalHostLabel)"

            let line5 =
                "    window=\(windowMetaLabel) " +
                "chain=\(formatDebugList(item["hosted_view_superview_chain"]) ?? "nil")"

            return [line1, line2, line3, line4, line5].joined(separator: "\n")
        }
        .joined(separator: "\n")
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
        let (colorOpt, rem3) = parseOption(rem2, name: "--color")
        let (descriptionOpt, rem4) = parseOption(rem3, name: "--description")

        var positional = rem4
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

        let inferredPositionalRaw = positional.joined(separator: " ")
        let inferredPositional = inferredPositionalRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (titleOpt ?? (action == "rename" && !inferredPositional.isEmpty ? inferredPositional : nil))?.trimmingCharacters(in: .whitespacesAndNewlines)

        if action == "rename", (title?.isEmpty ?? true) {
            throw CLIError(message: "workspace-action rename requires --title <text> (or a trailing title)")
        }

        let color = (
            colorOpt ?? (action == "set_color" ? (inferredPositional.isEmpty ? nil : inferredPositional) : nil)
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        if action == "set_color", (color?.isEmpty ?? true) {
            throw CLIError(message: "workspace-action set-color requires --color <name|#hex> (or a trailing color)")
        }

        let description = (
            descriptionOpt ?? (action == "set_description" && !inferredPositional.isEmpty ? inferredPositionalRaw : nil)
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        if action == "set_description", (description?.isEmpty ?? true) {
            throw CLIError(message: "workspace-action set-description requires --description <text> (or trailing text)")
        }

        var params: [String: Any] = ["action": action]
        if let workspaceId {
            params["workspace_id"] = workspaceId
        }
        if let title, !title.isEmpty {
            params["title"] = title
        }
        if let color, !color.isEmpty {
            params["color"] = color
        }
        if let description, !description.isEmpty {
            params["description"] = description
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
        if let color = payload["color"] as? String {
            summaryParts.append("color=\(color)")
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
    struct SSHCommandOptions {
        let destination: String
        let port: Int?
        let identityFile: String?
        let workspaceName: String?
        let noFocus: Bool
        let sshOptions: [String]
        let extraArguments: [String]
        let localSocketPath: String
        let remoteRelayPort: Int
    }

    private struct RemoteDaemonManifest: Decodable {
        struct Entry: Decodable {
            let goOS: String
            let goArch: String
            let assetName: String
            let downloadURL: String
            let sha256: String
        }

        let schemaVersion: Int
        let appVersion: String
        let releaseTag: String
        let releaseURL: String
        let checksumsAssetName: String
        let checksumsURL: String
        let entries: [Entry]

        func entry(goOS: String, goArch: String) -> Entry? {
            entries.first { $0.goOS == goOS && $0.goArch == goArch }
        }
    }

    private func generateRemoteRelayPort() -> Int {
        // Random port in the ephemeral range (49152-65535)
        Int.random(in: 49152...65535)
    }

    private func randomHex(byteCount: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw CLIError(message: "failed to generate SSH relay credential")
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func runSSH(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let sshStartedAt = Date()
        // Use the socket path from this invocation (supports --socket overrides).
        let localSocketPath = client.socketPath
        let remoteRelayPort = generateRemoteRelayPort()
        let relayID = UUID().uuidString.lowercased()
        let relayToken = try randomHex(byteCount: 32)
        let sshOptions = try parseSSHCommandOptions(commandArgs, localSocketPath: localSocketPath, remoteRelayPort: remoteRelayPort)
        func logSSHTiming(_ stage: String, extra: String = "") {
            let elapsedMs = Int(Date().timeIntervalSince(sshStartedAt) * 1000)
            let suffix = extra.isEmpty ? "" : " \(extra)"
            cliDebugLog(
                "cli.ssh.timing target=\(sshOptions.destination) relayPort=\(sshOptions.remoteRelayPort) " +
                "stage=\(stage) elapsedMs=\(elapsedMs)\(suffix)"
            )
        }

        logSSHTiming("parsed")
        let terminfoSource = localXtermGhosttyTerminfoSource()
        cliDebugLog(
            "cli.ssh.timing target=\(sshOptions.destination) relayPort=\(sshOptions.remoteRelayPort) " +
            "stage=terminfo elapsedMs=0 mode=deferred term=xterm-256color " +
            "source=\(terminfoSource == nil ? 0 : 1)"
        )
        let shellFeaturesValue = scopedGhosttyShellFeaturesValue()
        let remoteSSHOptions = effectiveSSHOptions(
            sshOptions.sshOptions,
            remoteRelayPort: sshOptions.remoteRelayPort
        )
        let initialSSHCommand = buildSSHCommandText(sshOptions)
        let remoteTerminalBootstrapScript = sshOptions.extraArguments.isEmpty
            ? buildInteractiveRemoteShellScript(
                remoteRelayPort: sshOptions.remoteRelayPort,
                shellFeatures: shellFeaturesValue,
                terminfoSource: terminfoSource
            )
            : nil
        let remoteTerminalSSHCommand = buildSSHCommandText(
            sshOptions,
            remoteBootstrapScript: remoteTerminalBootstrapScript
        )
        let deferredRemoteReconnectToken = UUID().uuidString.lowercased()
        let deferredRemoteReconnectCommand = deferredRemoteReconnectLocalCommand(
            in: remoteSSHOptions,
            localCLIPath: resolvedExecutableURL()?.path,
            foregroundAuthToken: deferredRemoteReconnectToken
        )
        let configuredForegroundAuthToken = deferredRemoteReconnectCommand == nil ? nil : deferredRemoteReconnectToken
        let startupInitialSSHCommand = buildSSHCommandText(
            sshOptions,
            localCommand: deferredRemoteReconnectCommand
        )
        let startupRemoteTerminalSSHCommand = buildSSHCommandText(
            sshOptions,
            remoteBootstrapScript: remoteTerminalBootstrapScript,
            localCommand: deferredRemoteReconnectCommand
        )
        let initialSSHStartupCommand: String
        let remoteTerminalSSHStartupCommand: String
        if let remoteTerminalBootstrapScript, !remoteTerminalBootstrapScript.isEmpty {
            let bootstrapSSHStartupCommand = try buildBootstrapSSHStartupCommand(
                options: sshOptions,
                remoteBootstrapScript: remoteTerminalBootstrapScript,
                shellFeatures: shellFeaturesValue,
                remoteRelayPort: sshOptions.remoteRelayPort,
                localCommand: deferredRemoteReconnectCommand
            )
            initialSSHStartupCommand = bootstrapSSHStartupCommand
            remoteTerminalSSHStartupCommand = bootstrapSSHStartupCommand
        } else {
            initialSSHStartupCommand = try buildSSHStartupCommand(
                sshCommand: startupInitialSSHCommand,
                shellFeatures: "",
                remoteRelayPort: sshOptions.remoteRelayPort
            )
            remoteTerminalSSHStartupCommand = try buildSSHStartupCommand(
                sshCommand: startupRemoteTerminalSSHCommand,
                shellFeatures: shellFeaturesValue,
                remoteRelayPort: sshOptions.remoteRelayPort
            )
        }
        cliDebugLog(
            "cli.ssh.start target=\(sshOptions.destination) port=\(sshOptions.port.map(String.init) ?? "nil") " +
            "relayPort=\(sshOptions.remoteRelayPort) localSocket=\(sshOptions.localSocketPath) " +
            "controlPath=\(sshOptionValue(named: "ControlPath", in: remoteSSHOptions) ?? "nil") " +
            "workspaceName=\(sshOptions.workspaceName?.replacingOccurrences(of: " ", with: "_") ?? "nil") " +
            "extraArgs=\(sshOptions.extraArguments.count)"
        )

        let workspaceCreateParams: [String: Any] = [
            "initial_command": initialSSHStartupCommand,
        ]

        let workspaceCreateStartedAt = Date()
        let workspaceCreate = try client.sendV2(method: "workspace.create", params: workspaceCreateParams)
        guard let workspaceId = workspaceCreate["workspace_id"] as? String, !workspaceId.isEmpty else {
            throw CLIError(message: "workspace.create did not return workspace_id")
        }
        let workspaceWindowId = (workspaceCreate["window_id"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        cliDebugLog(
            "cli.ssh.workspace.created workspace=\(String(workspaceId.prefix(8))) " +
            "window=\(workspaceWindowId.map { String($0.prefix(8)) } ?? "nil")"
        )
        cliDebugLog(
            "cli.ssh.timing target=\(sshOptions.destination) relayPort=\(sshOptions.remoteRelayPort) " +
            "workspace=\(String(workspaceId.prefix(8))) stage=workspace.create elapsedMs=\(Int(Date().timeIntervalSince(workspaceCreateStartedAt) * 1000))"
        )
        let configuredPayload: [String: Any]
        do {
            if let workspaceName = sshOptions.workspaceName?.trimmingCharacters(in: .whitespacesAndNewlines),
               !workspaceName.isEmpty {
                _ = try client.sendV2(method: "workspace.rename", params: [
                    "workspace_id": workspaceId,
                    "title": workspaceName,
                ])
            }

            var configureParams: [String: Any] = [
                "workspace_id": workspaceId,
                "destination": sshOptions.destination,
                "auto_connect": deferredRemoteReconnectCommand == nil,
            ]
            if let configuredForegroundAuthToken {
                configureParams["foreground_auth_token"] = configuredForegroundAuthToken
            }
            if let port = sshOptions.port {
                configureParams["port"] = port
            }
            if let identityFile = normalizedSSHIdentityPath(sshOptions.identityFile) {
                configureParams["identity_file"] = identityFile
            }
            if !remoteSSHOptions.isEmpty {
                configureParams["ssh_options"] = remoteSSHOptions
            }
            if sshOptions.remoteRelayPort > 0 {
                configureParams["relay_port"] = sshOptions.remoteRelayPort
                configureParams["relay_id"] = relayID
                configureParams["relay_token"] = relayToken
                configureParams["local_socket_path"] = sshOptions.localSocketPath
            }
            configureParams["terminal_startup_command"] = remoteTerminalSSHStartupCommand

            cliDebugLog(
                "cli.ssh.remote.configure workspace=\(String(workspaceId.prefix(8))) " +
                "target=\(sshOptions.destination) relayPort=\(sshOptions.remoteRelayPort) " +
                "controlPath=\(sshOptionValue(named: "ControlPath", in: remoteSSHOptions) ?? "nil") " +
                "deferredReconnect=\(deferredRemoteReconnectCommand == nil ? 0 : 1) " +
                "sshOptions=\(remoteSSHOptions.joined(separator: "|"))"
            )
            let configureStartedAt = Date()
            configuredPayload = try client.sendV2(method: "workspace.remote.configure", params: configureParams)
            var selectParams: [String: Any] = ["workspace_id": workspaceId]
            if let workspaceWindowId, !workspaceWindowId.isEmpty {
                selectParams["window_id"] = workspaceWindowId
            }
            // `cmux ssh` is an explicit "open this remote workspace now" action,
            // so we intentionally select the newly created workspace after wiring
            // up the remote connection — unless --no-focus is passed.
            if !sshOptions.noFocus {
                _ = try client.sendV2(method: "workspace.select", params: selectParams)
            }
            let remoteState = ((configuredPayload["remote"] as? [String: Any])?["state"] as? String) ?? "unknown"
            cliDebugLog(
                "cli.ssh.remote.configure.ok workspace=\(String(workspaceId.prefix(8))) state=\(remoteState)"
            )
            cliDebugLog(
                "cli.ssh.timing target=\(sshOptions.destination) relayPort=\(sshOptions.remoteRelayPort) " +
                "workspace=\(String(workspaceId.prefix(8))) stage=workspace.remote.configure elapsedMs=\(Int(Date().timeIntervalSince(configureStartedAt) * 1000))"
            )
        } catch {
            cliDebugLog(
                "cli.ssh.remote.configure.error workspace=\(String(workspaceId.prefix(8))) error=\(String(describing: error))"
            )
            do {
                _ = try client.sendV2(method: "workspace.close", params: ["workspace_id": workspaceId])
            } catch {
                let warning = "Warning: failed to rollback workspace \(workspaceId): \(error)\n"
                FileHandle.standardError.write(Data(warning.utf8))
            }
            throw error
        }

        var payload = configuredPayload

        payload["ssh_command"] = initialSSHCommand
        payload["ssh_startup_command"] = initialSSHStartupCommand
        payload["ssh_terminal_command"] = remoteTerminalSSHCommand
        payload["ssh_terminal_startup_command"] = remoteTerminalSSHStartupCommand
        payload["ssh_env_overrides"] = [
            "GHOSTTY_SHELL_FEATURES": shellFeaturesValue,
        ]
        payload["remote_relay_port"] = remoteRelayPort
        logSSHTiming("complete", extra: "workspace=\(String(workspaceId.prefix(8)))")
        if jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
        } else {
            let workspaceHandle = formatHandle(payload, kind: "workspace", idFormat: idFormat) ?? workspaceId
            let remote = payload["remote"] as? [String: Any]
            let state = (remote?["state"] as? String) ?? "unknown"
            print("OK workspace=\(workspaceHandle) target=\(sshOptions.destination) state=\(state)")
        }
    }

    private func parseSSHCommandOptions(_ commandArgs: [String], localSocketPath: String = "", remoteRelayPort: Int = 0) throws -> SSHCommandOptions {
        var destination: String?
        var port: Int?
        var identityFile: String?
        var workspaceName: String?
        var noFocus = false
        var sshOptions: [String] = []
        var extraArguments: [String] = []

        var passthrough = false
        var index = 0
        while index < commandArgs.count {
            let arg = commandArgs[index]
            if passthrough {
                extraArguments.append(arg)
                index += 1
                continue
            }

            switch arg {
            case "--":
                passthrough = true
                index += 1
            case "--port":
                guard index + 1 < commandArgs.count else {
                    throw CLIError(message: "ssh: --port requires a value")
                }
                guard let parsed = Int(commandArgs[index + 1]), parsed > 0, parsed <= 65535 else {
                    throw CLIError(message: "ssh: --port must be 1-65535")
                }
                port = parsed
                index += 2
            case "--identity":
                guard index + 1 < commandArgs.count else {
                    throw CLIError(message: "ssh: --identity requires a path")
                }
                identityFile = commandArgs[index + 1]
                index += 2
            case "--name":
                guard index + 1 < commandArgs.count else {
                    throw CLIError(message: "ssh: --name requires a workspace title")
                }
                workspaceName = commandArgs[index + 1]
                index += 2
            case "--no-focus":
                noFocus = true
                index += 1
            case "--ssh-option":
                guard index + 1 < commandArgs.count else {
                    throw CLIError(message: "ssh: --ssh-option requires a value")
                }
                let value = commandArgs[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty {
                    sshOptions.append(value)
                }
                index += 2
            default:
                if arg.hasPrefix("--") {
                    throw CLIError(message: "ssh: unknown flag '\(arg)'")
                }
                if destination == nil {
                    if arg.hasPrefix("-") {
                        throw CLIError(
                            message: "ssh: destination must be <user@host>. Use --port/--identity/--ssh-option for SSH flags and `--` for remote command args."
                        )
                    }
                    destination = arg
                } else {
                    extraArguments.append(arg)
                }
                index += 1
            }
        }

        guard let destination else {
            throw CLIError(message: "ssh requires a destination (example: cmux ssh user@host)")
        }
        return SSHCommandOptions(
            destination: destination,
            port: port,
            identityFile: identityFile,
            workspaceName: workspaceName,
            noFocus: noFocus,
            sshOptions: sshOptions,
            extraArguments: extraArguments,
            localSocketPath: localSocketPath,
            remoteRelayPort: remoteRelayPort
        )
    }

    func buildSSHCommandText(
        _ options: SSHCommandOptions,
        remoteBootstrapScript: String? = nil,
        localCommand: String? = nil
    ) -> String {
        var parts = baseSSHArguments(options, localCommand: localCommand)
        let trimmedRemoteBootstrap = remoteBootstrapScript?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if options.extraArguments.isEmpty {
            if let trimmedRemoteBootstrap, !trimmedRemoteBootstrap.isEmpty {
                let remoteCommand = sshPercentEscapedRemoteCommand(
                    encodedRemoteBootstrapCommand(
                        trimmedRemoteBootstrap,
                        remoteRelayPort: options.remoteRelayPort
                    )
                )
                parts += ["-o", "RemoteCommand=\(remoteCommand)"]
            }
            if !hasSSHOptionKey(options.sshOptions, key: "RequestTTY") {
                parts.append("-tt")
            }
            parts.append(options.destination)
        } else {
            parts.append(options.destination)
            parts.append(contentsOf: options.extraArguments)
        }
        return parts.map(shellQuote).joined(separator: " ")
    }

    func buildBootstrapSSHStartupCommand(
        options: SSHCommandOptions,
        remoteBootstrapScript: String,
        shellFeatures: String,
        remoteRelayPort: Int,
        localCommand: String? = nil
    ) throws -> String {
        let commandSnippet = buildSSHBootstrapCommandSnippet(
            options: options,
            remoteBootstrapScript: remoteBootstrapScript,
            localCommand: localCommand
        )
        return try buildSSHStartupCommand(
            sshCommand: commandSnippet,
            shellFeatures: shellFeatures,
            remoteRelayPort: remoteRelayPort,
            isShellSnippet: true
        )
    }

    private func buildSSHBootstrapCommandSnippet(
        options: SSHCommandOptions,
        remoteBootstrapScript: String,
        localCommand: String? = nil
    ) -> String {
        let encodedBootstrapScript = Data(remoteBootstrapScript.utf8).base64EncodedString()
        let installSSHPrefix = baseSSHArguments(options, localCommand: localCommand).map(shellQuote).joined(separator: " ")
        let sessionSSHPrefix = baseSSHArguments(options).map(shellQuote).joined(separator: " ")
        let remoteCommandTemplate = sshPercentEscapedRemoteCommand(
            stagedRemoteBootstrapCommandShell(
                remoteRelayPort: options.remoteRelayPort
            )
        )
        let remoteBootstrapInstallCommand = "/bin/sh -c " + shellQuote(
            remoteBootstrapInstallShell(remoteRelayPort: options.remoteRelayPort)
        )
        var lines: [String] = [
            "cmux_workspace_id=\"${CMUX_WORKSPACE_ID:-}\"",
            "cmux_surface_id=\"${CMUX_SURFACE_ID:-}\"",
            "cmux_remote_bootstrap_b64=\(shellQuote(encodedBootstrapScript))",
            "cmux_remote_bootstrap=\"$(printf %s \"$cmux_remote_bootstrap_b64\" | base64 -d 2>/dev/null || printf %s \"$cmux_remote_bootstrap_b64\" | base64 -D 2>/dev/null)\"",
            "cmux_remote_bootstrap=\"$(printf '%s' \"$cmux_remote_bootstrap\" | sed \"s/__CMUX_WORKSPACE_ID__/$cmux_workspace_id/g; s/__CMUX_SURFACE_ID__/$cmux_surface_id/g\")\"",
            "if ! printf '%s' \"$cmux_remote_bootstrap\" | command \(installSSHPrefix) -T \(shellQuote(options.destination)) \(shellQuote(remoteBootstrapInstallCommand)); then",
            "  exit 1",
            "fi",
            "cmux_remote_command_template=\(shellQuote(remoteCommandTemplate))",
            "cmux_remote_command=\"$(printf '%s' \"$cmux_remote_command_template\" | sed \"s/__CMUX_WORKSPACE_ID__/$cmux_workspace_id/g; s/__CMUX_SURFACE_ID__/$cmux_surface_id/g\")\"",
        ]

        var sshInvocation = "command \(sessionSSHPrefix) -o \"RemoteCommand=$cmux_remote_command\""
        if !hasSSHOptionKey(options.sshOptions, key: "RequestTTY") {
            sshInvocation += " -tt"
        }
        sshInvocation += " " + shellQuote(options.destination)
        lines.append(sshInvocation)
        return lines.joined(separator: "\n")
    }

    private func stagedRemoteBootstrapCommandShell(
        remoteRelayPort: Int
    ) -> String {
        var lines = remoteBootstrapTTYCaptureLines(remoteRelayPort: remoteRelayPort, includeRelayRPC: true)
        lines.append("/bin/sh \"$HOME/.cmux/relay/\(remoteRelayPort).bootstrap.sh\"")
        return lines.joined(separator: "\n")
    }

    private func remoteBootstrapInstallShell(remoteRelayPort: Int) -> String {
        [
            "set -eu",
            "umask 077",
            "cmux_bootstrap_path=\"$HOME/.cmux/relay/\(remoteRelayPort).bootstrap.sh\"",
            "mkdir -p \"$HOME/.cmux/relay\"",
            "cat > \"$cmux_bootstrap_path\"",
            "chmod 700 \"$cmux_bootstrap_path\" >/dev/null 2>&1 || true",
        ].joined(separator: "\n")
    }

    private func runtimeEncodedRemoteBootstrapCommandShell(
        base64Placeholder: String,
        remoteRelayPort: Int
    ) -> String {
        var lines = remoteBootstrapTTYCaptureLines(remoteRelayPort: remoteRelayPort, includeRelayRPC: false)
        lines += [
            "cmux_tmp=$(mktemp \"${TMPDIR:-/tmp}/cmux-ssh-bootstrap.XXXXXX\") || exit 1",
            "(printf %s '\(base64Placeholder)' | base64 -d 2>/dev/null || printf %s '\(base64Placeholder)' | base64 -D 2>/dev/null) > \"$cmux_tmp\" || { rm -f \"$cmux_tmp\"; exit 1; }",
            "chmod 700 \"$cmux_tmp\" >/dev/null 2>&1 || true",
            "/bin/sh \"$cmux_tmp\"",
            "cmux_status=$?",
            "rm -f \"$cmux_tmp\"",
            "exit $cmux_status",
        ]
        return lines.joined(separator: "\n")
    }

    private func remoteBootstrapTTYCaptureLines(
        remoteRelayPort: Int,
        includeRelayRPC: Bool
    ) -> [String] {
        guard remoteRelayPort > 0 else { return [] }

        var lines: [String] = [
            "cmux_bootstrap_tty=\"$(tty 2>/dev/null || true)\"",
            "cmux_bootstrap_tty=\"${cmux_bootstrap_tty##*/}\"",
            "if [ -n \"$cmux_bootstrap_tty\" ] && [ \"$cmux_bootstrap_tty\" != \"not a tty\" ]; then",
            "  mkdir -p \"$HOME/.cmux/relay\" >/dev/null 2>&1 || true",
            "  printf '%s' \"$cmux_bootstrap_tty\" > \"$HOME/.cmux/relay/\(remoteRelayPort).tty\" 2>/dev/null || true",
            "  export CMUX_BOOTSTRAP_TTY=\"$cmux_bootstrap_tty\"",
        ]

        if includeRelayRPC {
            lines += [
                "  cmux_relay_cli=\"$HOME/.cmux/bin/cmux\"",
                "  if [ ! -x \"$cmux_relay_cli\" ]; then cmux_relay_cli=\"$(command -v cmux 2>/dev/null || true)\"; fi",
                "  if [ -n \"$cmux_relay_cli\" ]; then",
                "    cmux_relay_report_tty='{\"workspace_id\":\"__CMUX_WORKSPACE_ID__\",\"tty_name\":\"'$cmux_bootstrap_tty'\"}'",
                "    cmux_relay_ports_kick='{\"workspace_id\":\"__CMUX_WORKSPACE_ID__\",\"reason\":\"command\"}'",
                "    if [ -n \"__CMUX_SURFACE_ID__\" ]; then",
                "      cmux_relay_report_tty='{\"workspace_id\":\"__CMUX_WORKSPACE_ID__\",\"surface_id\":\"__CMUX_SURFACE_ID__\",\"tty_name\":\"'$cmux_bootstrap_tty'\"}'",
                "      cmux_relay_ports_kick='{\"workspace_id\":\"__CMUX_WORKSPACE_ID__\",\"surface_id\":\"__CMUX_SURFACE_ID__\",\"reason\":\"command\"}'",
                "    fi",
                "    CMUX_SOCKET_PATH=\"127.0.0.1:\(remoteRelayPort)\" CMUX_SOCKET=\"127.0.0.1:\(remoteRelayPort)\" \"$cmux_relay_cli\" rpc surface.report_tty \"$cmux_relay_report_tty\" >/dev/null 2>&1 || true",
                "    CMUX_SOCKET_PATH=\"127.0.0.1:\(remoteRelayPort)\" CMUX_SOCKET=\"127.0.0.1:\(remoteRelayPort)\" \"$cmux_relay_cli\" rpc surface.ports_kick \"$cmux_relay_ports_kick\" >/dev/null 2>&1 || true",
                "    unset cmux_relay_cli cmux_relay_report_tty cmux_relay_ports_kick",
                "  fi",
            ]
        }

        lines.append("fi")
        return lines
    }

    private func effectiveSSHOptions(_ options: [String], remoteRelayPort: Int? = nil) -> [String] {
        var merged = sshOptionsWithControlSocketDefaults(options, remoteRelayPort: remoteRelayPort)
        if !hasSSHOptionKey(merged, key: "StrictHostKeyChecking") {
            merged.append("StrictHostKeyChecking=accept-new")
        }
        return merged
    }

    func buildInteractiveRemoteShellScript(
        remoteRelayPort: Int,
        shellFeatures: String,
        terminfoSource: String? = nil
    ) -> String {
        let remoteTerminalLines = interactiveRemoteTerminalSetupLines(terminfoSource: terminfoSource)
        let remoteEnvExportLines = interactiveRemoteShellExportLines(shellFeatures: shellFeatures)
        let shellStateDir = shellStateDirForRemoteRelayPort(remoteRelayPort)
        let remoteCallerExportLines = [
            "if [ -n '__CMUX_WORKSPACE_ID__' ]; then export CMUX_WORKSPACE_ID='__CMUX_WORKSPACE_ID__'; fi",
            "if [ -n '__CMUX_WORKSPACE_ID__' ]; then export CMUX_TAB_ID='__CMUX_WORKSPACE_ID__'; fi",
            "if [ -n '__CMUX_SURFACE_ID__' ]; then export CMUX_SURFACE_ID='__CMUX_SURFACE_ID__'; export CMUX_PANEL_ID='__CMUX_SURFACE_ID__'; fi",
        ]
        let relaySocket = remoteRelayPort > 0 ? "127.0.0.1:\(remoteRelayPort)" : nil
        var commonShellExportLines = remoteTerminalLines
        commonShellExportLines.append(contentsOf: remoteEnvExportLines)
        commonShellExportLines.append("export PATH=\"$HOME/.cmux/bin:$PATH\"")
        commonShellExportLines.append("export CMUX_BUNDLED_CLI_PATH=\"$HOME/.cmux/bin/cmux\"")
        commonShellExportLines.append("export CMUX_SHELL_INTEGRATION_DIR=\"\(shellStateDir)\"")
        if let relaySocket {
            commonShellExportLines.append("export CMUX_SOCKET_PATH=\(relaySocket)")
            commonShellExportLines.append("export CMUX_SOCKET=\(relaySocket)")
        }
        commonShellExportLines.append(contentsOf: remoteCallerExportLines)
        commonShellExportLines.append(contentsOf: [
            "hash -r >/dev/null 2>&1 || true",
            "rehash >/dev/null 2>&1 || true",
        ])
        var zshShellLines = commonShellExportLines
        zshShellLines.append(
            #"if [ "${CMUX_SHELL_INTEGRATION:-1}" != "0" ] && [ -r "${CMUX_SHELL_INTEGRATION_DIR}/cmux-zsh-integration.zsh" ]; then . "${CMUX_SHELL_INTEGRATION_DIR}/cmux-zsh-integration.zsh"; fi"#
        )
        var bashShellLines = commonShellExportLines
        bashShellLines.append(
            #"if [ "${CMUX_SHELL_INTEGRATION:-1}" != "0" ] && [ -r "${CMUX_SHELL_INTEGRATION_DIR}/cmux-bash-integration.bash" ]; then . "${CMUX_SHELL_INTEGRATION_DIR}/cmux-bash-integration.bash"; fi"#
        )
        let zshBootstrap = RemoteRelayZshBootstrap(shellStateDir: shellStateDir)
        let zshEnvLines = zshBootstrap.zshEnvLines
        let zshProfileLines = zshBootstrap.zshProfileLines
        let zshRCLines = zshBootstrap.zshRCLines(commonShellLines: zshShellLines)
        let zshLoginLines = zshBootstrap.zshLoginLines
        let bundledZshIntegration = bundledShellIntegrationScript(named: "cmux-zsh-integration.zsh")
        let bundledBashIntegration = bundledShellIntegrationScript(named: "cmux-bash-integration.bash")
        let bashRCLines = [
            "if [ -f \"$HOME/.bash_profile\" ]; then . \"$HOME/.bash_profile\"; elif [ -f \"$HOME/.bash_login\" ]; then . \"$HOME/.bash_login\"; elif [ -f \"$HOME/.profile\" ]; then . \"$HOME/.profile\"; fi",
            "[ -f \"$HOME/.bashrc\" ] && . \"$HOME/.bashrc\"",
        ] + bashShellLines
        let relayWarmupLines = interactiveRemoteRelayWarmupLines(remoteRelayPort: remoteRelayPort)

        var outerLines: [String] = [
            "mkdir -p \"$HOME/.cmux/relay\"",
            "cmux_shell_dir=\"\(shellStateDir)\"",
            "mkdir -p \"$cmux_shell_dir\"",
        ]
        if let bundledZshIntegration {
            outerLines += [
                "cat > \"$cmux_shell_dir/cmux-zsh-integration.zsh\" <<'CMUXCMUXZSH'",
                bundledZshIntegration,
                "CMUXCMUXZSH",
            ]
        }
        if let bundledBashIntegration {
            outerLines += [
                "cat > \"$cmux_shell_dir/cmux-bash-integration.bash\" <<'CMUXCMUXBASH'",
                bundledBashIntegration,
                "CMUXCMUXBASH",
            ]
        }
        outerLines.append(contentsOf: commonShellExportLines)
        outerLines += [
            "CMUX_LOGIN_SHELL=\"${SHELL:-/bin/zsh}\"",
            "case \"${CMUX_LOGIN_SHELL##*/}\" in",
            "  zsh)",
            "    cat > \"$cmux_shell_dir/.zshenv\" <<'CMUXZSHENV'",
        ]
        outerLines.append(contentsOf: zshEnvLines)
        outerLines += [
            "CMUXZSHENV",
            "    cat > \"$cmux_shell_dir/.zprofile\" <<'CMUXZSHPROFILE'",
        ]
        outerLines.append(contentsOf: zshProfileLines)
        outerLines += [
            "CMUXZSHPROFILE",
            "    cat > \"$cmux_shell_dir/.zshrc\" <<'CMUXZSHRC'",
        ]
        outerLines.append(contentsOf: zshRCLines)
        outerLines += [
            "CMUXZSHRC",
            "    cat > \"$cmux_shell_dir/.zlogin\" <<'CMUXZSHLOGIN'",
        ]
        outerLines.append(contentsOf: zshLoginLines)
        outerLines += [
            "CMUXZSHLOGIN",
            "    chmod 600 \"$cmux_shell_dir/.zshenv\" \"$cmux_shell_dir/.zprofile\" \"$cmux_shell_dir/.zshrc\" \"$cmux_shell_dir/.zlogin\" >/dev/null 2>&1 || true",
        ]
        outerLines.append(contentsOf: relayWarmupLines.map { "    " + $0 })
        outerLines += [
            "    export CMUX_REAL_ZDOTDIR=\"${ZDOTDIR:-$HOME}\"",
            "    export ZDOTDIR=\"$cmux_shell_dir\"",
            "    exec \"$CMUX_LOGIN_SHELL\" -il",
            "    ;;",
            "  bash)",
            "    cat > \"$cmux_shell_dir/.bashrc\" <<'CMUXBASHRC'",
        ]
        outerLines.append(contentsOf: bashRCLines)
        outerLines += [
            "CMUXBASHRC",
            "    chmod 600 \"$cmux_shell_dir/.bashrc\" >/dev/null 2>&1 || true",
        ]
        outerLines.append(contentsOf: relayWarmupLines.map { "    " + $0 })
        outerLines += [
            "    exec \"$CMUX_LOGIN_SHELL\" --rcfile \"$cmux_shell_dir/.bashrc\" -i",
            "    ;;",
            "  *)",
        ]
        outerLines.append(contentsOf: commonShellExportLines)
        outerLines.append(contentsOf: relayWarmupLines)
        outerLines += [
            "exec \"$CMUX_LOGIN_SHELL\" -i",
            ";;",
            "esac",
        ]

        return outerLines.joined(separator: "\n")
    }

    private func shellStateDirForRemoteRelayPort(_ remoteRelayPort: Int) -> String {
        "$HOME/.cmux/relay/\(max(remoteRelayPort, 0)).shell"
    }

    private func bundledShellIntegrationScript(named fileName: String) -> String? {
        let fileManager = FileManager.default
        var candidates: [URL] = []

        if let executableURL = resolvedExecutableURL() {
            var current = executableURL.deletingLastPathComponent().standardizedFileURL
            while true {
                if current.lastPathComponent == "Contents" {
                    candidates.append(
                        current
                            .appendingPathComponent("Resources", isDirectory: true)
                            .appendingPathComponent("shell-integration", isDirectory: true)
                            .appendingPathComponent(fileName, isDirectory: false)
                    )
                }

                let projectMarker = current.appendingPathComponent("GhosttyTabs.xcodeproj/project.pbxproj", isDirectory: false)
                if fileManager.fileExists(atPath: projectMarker.path) {
                    candidates.append(
                        current
                            .appendingPathComponent("Resources", isDirectory: true)
                            .appendingPathComponent("shell-integration", isDirectory: true)
                            .appendingPathComponent(fileName, isDirectory: false)
                    )
                    break
                }

                guard let parent = parentSearchURL(for: current) else {
                    break
                }
                current = parent
            }
        }

        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(
                resourceURL
                    .appendingPathComponent("shell-integration", isDirectory: true)
                    .appendingPathComponent(fileName, isDirectory: false)
            )
        }

        for url in candidates {
            guard fileManager.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url),
                  let contents = String(data: data, encoding: .utf8) else {
                continue
            }
            return contents
        }

        return nil
    }

    func buildInteractiveRemoteShellCommand(
        remoteRelayPort: Int,
        shellFeatures: String,
        terminfoSource: String? = nil
    ) -> String {
        let script = buildInteractiveRemoteShellScript(
            remoteRelayPort: remoteRelayPort,
            shellFeatures: shellFeatures,
            terminfoSource: terminfoSource
        )
        return "/bin/sh -c \(shellQuote(script))"
    }

    private func interactiveRemoteTerminalSetupLines(terminfoSource: String?) -> [String] {
        var lines: [String] = [
            "cmux_term='xterm-256color'",
            "if command -v infocmp >/dev/null 2>&1 && infocmp xterm-ghostty >/dev/null 2>&1; then",
            "  cmux_term='xterm-ghostty'",
            "fi",
            "export TERM=\"$cmux_term\"",
        ]
        guard let terminfoSource else { return lines }
        let trimmedTerminfoSource = terminfoSource.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTerminfoSource.isEmpty else { return lines }
        lines += [
            "if [ \"$cmux_term\" != 'xterm-ghostty' ]; then",
            "  (",
            "    command -v tic >/dev/null 2>&1 || exit 0",
            "    mkdir -p \"$HOME/.terminfo\" 2>/dev/null || exit 0",
            "    cat <<'CMUXTERMINFO' | tic -x - >/dev/null 2>&1",
            trimmedTerminfoSource,
            "CMUXTERMINFO",
            "  ) >/dev/null 2>&1 &",
            "fi",
        ]
        return lines
    }

    private func interactiveRemoteShellExportLines(shellFeatures: String) -> [String] {
        let environment = ProcessInfo.processInfo.environment
        let colorTerm = Self.normalizedEnvValue(environment["COLORTERM"]) ?? "truecolor"
        let termProgram = Self.normalizedEnvValue(environment["TERM_PROGRAM"]) ?? "ghostty"
        let termProgramVersion = Self.normalizedEnvValue(environment["TERM_PROGRAM_VERSION"])
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? ""
        let trimmedShellFeatures = shellFeatures.trimmingCharacters(in: .whitespacesAndNewlines)

        var exports: [String] = [
            "export COLORTERM=\(shellQuote(colorTerm))",
            "export TERM_PROGRAM=\(shellQuote(termProgram))",
        ]
        if !termProgramVersion.isEmpty {
            exports.append("export TERM_PROGRAM_VERSION=\(shellQuote(termProgramVersion))")
        }
        if !trimmedShellFeatures.isEmpty {
            exports.append("export GHOSTTY_SHELL_FEATURES=\(shellQuote(trimmedShellFeatures))")
        }
        return exports
    }

    private func interactiveRemoteRelayWarmupLines(remoteRelayPort: Int) -> [String] {
        guard remoteRelayPort > 0 else {
            return []
        }
        return [
            "cmux_relay_cli=\"${CMUX_BUNDLED_CLI_PATH:-$HOME/.cmux/bin/cmux}\"",
            "if [ ! -x \"$cmux_relay_cli\" ]; then cmux_relay_cli=\"$(command -v cmux 2>/dev/null || true)\"; fi",
            "cmux_relay_tty=\"${CMUX_BOOTSTRAP_TTY:-}\"",
            "if [ -z \"$cmux_relay_tty\" ]; then cmux_relay_tty=\"$(tty 2>/dev/null || true)\"; fi",
            "cmux_relay_tty=\"${cmux_relay_tty##*/}\"",
            "if [ -n \"$cmux_relay_tty\" ] && [ \"$cmux_relay_tty\" != \"not a tty\" ]; then",
            "  mkdir -p \"$HOME/.cmux/relay\" >/dev/null 2>&1 || true",
            "  printf '%s' \"$cmux_relay_tty\" > \"$HOME/.cmux/relay/\(remoteRelayPort).tty\" 2>/dev/null || true",
            "fi",
            "if [ -n \"$cmux_relay_cli\" ] && [ -n \"$CMUX_WORKSPACE_ID\" ] && [ -n \"$cmux_relay_tty\" ] && [ \"$cmux_relay_tty\" != \"not a tty\" ]; then",
            "  cmux_relay_report_tty=\"{\\\"workspace_id\\\":\\\"$CMUX_WORKSPACE_ID\\\",\\\"tty_name\\\":\\\"$cmux_relay_tty\\\"}\"",
            "  cmux_relay_ports_kick=\"{\\\"workspace_id\\\":\\\"$CMUX_WORKSPACE_ID\\\",\\\"reason\\\":\\\"command\\\"}\"",
            "  if [ -n \"$CMUX_SURFACE_ID\" ]; then",
            "    cmux_relay_report_tty=\"{\\\"workspace_id\\\":\\\"$CMUX_WORKSPACE_ID\\\",\\\"surface_id\\\":\\\"$CMUX_SURFACE_ID\\\",\\\"tty_name\\\":\\\"$cmux_relay_tty\\\"}\"",
            "    cmux_relay_ports_kick=\"{\\\"workspace_id\\\":\\\"$CMUX_WORKSPACE_ID\\\",\\\"surface_id\\\":\\\"$CMUX_SURFACE_ID\\\",\\\"reason\\\":\\\"command\\\"}\"",
            "  fi",
            "  \"$cmux_relay_cli\" rpc surface.report_tty \"$cmux_relay_report_tty\" >/dev/null 2>&1 || true",
            "  \"$cmux_relay_cli\" rpc surface.ports_kick \"$cmux_relay_ports_kick\" >/dev/null 2>&1 || true",
            "fi",
            "unset CMUX_BOOTSTRAP_TTY cmux_relay_cli cmux_relay_tty cmux_relay_report_tty cmux_relay_ports_kick",
        ]
    }

    private func baseSSHArguments(_ options: SSHCommandOptions, localCommand: String? = nil) -> [String] {
        let effectiveSSHOptions = effectiveSSHOptions(
            options.sshOptions,
            remoteRelayPort: options.remoteRelayPort
        )
        var parts: [String] = ["ssh"]
        if !hasSSHOptionKey(effectiveSSHOptions, key: "ConnectTimeout") {
            parts += ["-o", "ConnectTimeout=6"]
        }
        if !hasSSHOptionKey(effectiveSSHOptions, key: "ServerAliveInterval") {
            parts += ["-o", "ServerAliveInterval=20"]
        }
        if !hasSSHOptionKey(effectiveSSHOptions, key: "ServerAliveCountMax") {
            parts += ["-o", "ServerAliveCountMax=2"]
        }
        if !hasSSHOptionKey(effectiveSSHOptions, key: "SetEnv") {
            parts += ["-o", "SetEnv COLORTERM=truecolor"]
        }
        if !hasSSHOptionKey(effectiveSSHOptions, key: "SendEnv") {
            parts += ["-o", "SendEnv TERM_PROGRAM TERM_PROGRAM_VERSION"]
        }
        if let port = options.port {
            parts += ["-p", String(port)]
        }
        if let identityFile = normalizedSSHIdentityPath(options.identityFile) {
            parts += ["-i", identityFile]
        }
        for option in effectiveSSHOptions {
            parts += ["-o", option]
        }
        if let localCommand, !localCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let escapedLocalCommand = localCommand.replacingOccurrences(of: "%", with: "%%")
            parts += ["-o", "PermitLocalCommand=yes"]
            parts += ["-o", "LocalCommand=\(escapedLocalCommand)"]
        }
        return parts
    }

    private func localXtermGhosttyTerminfoSource() -> String? {
        let result = runProcess(
            executablePath: "/usr/bin/infocmp",
            arguments: ["-0", "-x", "xterm-ghostty"]
        )
        guard result.status == 0 else { return nil }
        let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? nil : output
    }

    private func sshOptionsWithControlSocketDefaults(
        _ options: [String],
        remoteRelayPort: Int? = nil
    ) -> [String] {
        var merged: [String] = []
        for option in options {
            let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            merged.append(trimmed)
        }
        if !hasSSHOptionKey(merged, key: "ControlMaster") {
            merged.append("ControlMaster=auto")
        }
        if !hasSSHOptionKey(merged, key: "ControlPersist") {
            merged.append("ControlPersist=600")
        }
        if !hasSSHOptionKey(merged, key: "ControlPath") {
            merged.append("ControlPath=\(defaultSSHControlPathTemplate(remoteRelayPort: remoteRelayPort))")
        }
        return merged
    }

    private func scopedGhosttyShellFeaturesValue() -> String {
        let rawExisting = ProcessInfo.processInfo.environment["GHOSTTY_SHELL_FEATURES"] ?? ""
        var seen: Set<String> = []
        var merged: [String] = []

        for token in rawExisting.split(separator: ",") {
            let feature = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !feature.isEmpty else { continue }
            if seen.insert(feature).inserted {
                merged.append(feature)
            }
        }

        for required in ["ssh-env", "ssh-terminfo"] {
            if seen.insert(required).inserted {
                merged.append(required)
            }
        }

        return merged.joined(separator: ",")
    }

    func encodedRemoteBootstrapCommand(
        _ remoteBootstrapScript: String,
        remoteRelayPort: Int
    ) -> String {
        let encodedScript = Data(remoteBootstrapScript.utf8).base64EncodedString()
        let encodedLiteral = shellQuote(encodedScript)
        var lines = remoteBootstrapTTYCaptureLines(remoteRelayPort: remoteRelayPort, includeRelayRPC: false)
        lines += [
            "cmux_tmp=$(mktemp \"${TMPDIR:-/tmp}/cmux-ssh-bootstrap.XXXXXX\") || exit 1",
            "(printf %s \(encodedLiteral) | base64 -d 2>/dev/null || printf %s \(encodedLiteral) | base64 -D 2>/dev/null) > \"$cmux_tmp\" || { rm -f \"$cmux_tmp\"; exit 1; }",
            "chmod 700 \"$cmux_tmp\" >/dev/null 2>&1 || true",
            "/bin/sh \"$cmux_tmp\"",
            "cmux_status=$?",
            "rm -f \"$cmux_tmp\"",
            "exit $cmux_status",
        ]
        return lines.joined(separator: "\n")
    }

    func sshPercentEscapedRemoteCommand(_ remoteCommand: String) -> String {
        remoteCommand.replacingOccurrences(of: "%", with: "%%")
    }

    func buildSSHStartupCommand(
        sshCommand: String,
        shellFeatures: String,
        remoteRelayPort: Int,
        isShellSnippet: Bool = false
    ) throws -> String {
        let trimmedFeatures = shellFeatures.trimmingCharacters(in: .whitespacesAndNewlines)
        let shellFeaturesBootstrap: String = trimmedFeatures.isEmpty
            ? ""
            : "export GHOSTTY_SHELL_FEATURES=\(shellQuote(trimmedFeatures))"
        let lifecycleCleanup = buildSSHSessionEndShellCommand(remoteRelayPort: remoteRelayPort)
        var scriptLines: [String] = []
        if !shellFeaturesBootstrap.isEmpty {
            scriptLines.append(shellFeaturesBootstrap)
        }
        scriptLines += [
            "CMUX_SSH_SESSION_ENDED=0",
            "cmux_ssh_session_end() { if [ \"${CMUX_SSH_SESSION_ENDED:-0}\" = 1 ]; then return; fi; CMUX_SSH_SESSION_ENDED=1; \(lifecycleCleanup); }",
            "trap 'cmux_ssh_session_end' EXIT HUP INT TERM",
        ]
        if isShellSnippet {
            scriptLines.append(sshCommand)
        } else {
            scriptLines.append("command \(sshCommand)")
        }
        scriptLines += [
            "cmux_ssh_status=$?",
            "trap - EXIT HUP INT TERM",
            "cmux_ssh_session_end",
            "exit $cmux_ssh_status",
        ]
        let script = scriptLines.joined(separator: "\n")
        return try writeSSHStartupScript(script, remoteRelayPort: remoteRelayPort)
    }

    private func writeSSHStartupScript(_ scriptBody: String, remoteRelayPort: Int) throws -> String {
        let tempDir = FileManager.default.temporaryDirectory
        let scriptURL = tempDir.appendingPathComponent(
            "cmux-ssh-startup-\(remoteRelayPort)-\(UUID().uuidString.lowercased()).sh"
        )
        let script = "#!/bin/sh\n\(scriptBody)\n"
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        return shellQuote(scriptURL.path)
    }

    private func buildSSHSessionEndShellCommand(remoteRelayPort: Int) -> String {
        [
            "if [ -n \"${CMUX_BUNDLED_CLI_PATH:-}\" ]",
            "&& [ -x \"${CMUX_BUNDLED_CLI_PATH}\" ]",
            "&& [ -n \"${CMUX_SOCKET_PATH:-}\" ]",
            "&& [ -n \"${CMUX_WORKSPACE_ID:-}\" ]",
            "&& [ -n \"${CMUX_SURFACE_ID:-}\" ]; then",
            "\"${CMUX_BUNDLED_CLI_PATH}\" --socket \"${CMUX_SOCKET_PATH}\" ssh-session-end --relay-port \(remoteRelayPort) --workspace \"${CMUX_WORKSPACE_ID}\" --surface \"${CMUX_SURFACE_ID}\" >/dev/null 2>&1 || true;",
            "elif command -v cmux >/dev/null 2>&1",
            "&& [ -n \"${CMUX_WORKSPACE_ID:-}\" ]",
            "&& [ -n \"${CMUX_SURFACE_ID:-}\" ]; then",
            "cmux ssh-session-end --relay-port \(remoteRelayPort) --workspace \"${CMUX_WORKSPACE_ID}\" --surface \"${CMUX_SURFACE_ID}\" >/dev/null 2>&1 || true;",
            "fi",
        ].joined(separator: " ")
    }

    private func runSSHSessionEnd(commandArgs: [String], client: SocketClient) throws {
        guard let relayPortRaw = optionValue(commandArgs, name: "--relay-port"),
              let relayPort = Int(relayPortRaw),
              relayPort > 0 else {
            throw CLIError(message: "ssh-session-end requires --relay-port <port>")
        }
        let workspaceRaw = optionValue(commandArgs, name: "--workspace") ?? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"]
        let surfaceRaw = optionValue(commandArgs, name: "--surface") ?? ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"]
        guard let workspaceRaw,
              let workspaceId = try normalizeWorkspaceHandle(workspaceRaw, client: client),
              !workspaceId.isEmpty else {
            throw CLIError(message: "ssh-session-end requires --workspace or CMUX_WORKSPACE_ID")
        }
        guard let surfaceRaw,
              let surfaceId = try normalizeSurfaceHandle(surfaceRaw, client: client, workspaceHandle: workspaceId),
              !surfaceId.isEmpty else {
            throw CLIError(message: "ssh-session-end requires --surface or CMUX_SURFACE_ID")
        }
        _ = try client.sendV2(method: "workspace.remote.terminal_session_end", params: [
            "workspace_id": workspaceId,
            "surface_id": surfaceId,
            "relay_port": relayPort,
        ])
    }

    private func runRemoteDaemonStatus(commandArgs: [String], jsonOutput: Bool) throws {
        let requestedOS = optionValue(commandArgs, name: "--os")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedArch = optionValue(commandArgs, name: "--arch")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let info = resolvedVersionInfo()
        let manifest = remoteDaemonManifest()
        let platform = defaultRemoteDaemonPlatform(requestedOS: requestedOS, requestedArch: requestedArch)
        let cacheURL = remoteDaemonCacheURL(version: manifest?.appVersion ?? remoteDaemonVersionString(from: info), goOS: platform.goOS, goArch: platform.goArch)
        let cacheExists = FileManager.default.fileExists(atPath: cacheURL.path)
        let cacheSHA = cacheExists ? try? sha256Hex(forFile: cacheURL) : nil
        let entry = manifest?.entry(goOS: platform.goOS, goArch: platform.goArch)
        let cacheVerified = (entry != nil && cacheSHA?.lowercased() == entry?.sha256.lowercased())
        let releaseTag = manifest?.releaseTag ?? "unknown"
        let assetName = entry?.assetName ?? "unknown"
        let downloadURL = entry?.downloadURL ?? "unknown"
        let checksumsAssetName = manifest?.checksumsAssetName ?? "unknown"
        let checksumsURL = manifest?.checksumsURL ?? "unknown"
        let downloadCommand = "gh release download \(releaseTag) --repo manaflow-ai/cmux --pattern \(assetName)"
        let downloadChecksumsCommand = "gh release download \(releaseTag) --repo manaflow-ai/cmux --pattern \(checksumsAssetName)"
        let checksumVerifyCommand = "shasum -a 256 -c \(checksumsAssetName) --ignore-missing"
        let signerWorkflow = releaseTag == "nightly"
            ? "manaflow-ai/cmux/.github/workflows/nightly.yml"
            : "manaflow-ai/cmux/.github/workflows/release.yml"
        let verifyCommand = "gh attestation verify ./\(assetName) --repo manaflow-ai/cmux --signer-workflow \(signerWorkflow)"

        let payload: [String: Any] = [
            "app_version": remoteDaemonVersionString(from: info),
            "build": info["CFBundleVersion"] ?? NSNull(),
            "commit": info["CMUXCommit"] ?? NSNull(),
            "manifest_present": manifest != nil,
            "release_tag": releaseTag,
            "release_url": manifest?.releaseURL ?? NSNull(),
            "target_goos": platform.goOS,
            "target_goarch": platform.goArch,
            "asset_name": assetName,
            "download_url": downloadURL,
            "checksums_asset_name": checksumsAssetName,
            "checksums_url": checksumsURL,
            "expected_sha256": entry?.sha256 ?? NSNull(),
            "cache_path": cacheURL.path,
            "cache_exists": cacheExists,
            "cache_sha256": cacheSHA ?? NSNull(),
            "cache_verified": cacheVerified,
            "dev_local_build_fallback": ProcessInfo.processInfo.environment["CMUX_REMOTE_DAEMON_ALLOW_LOCAL_BUILD"] == "1",
            "download_command": downloadCommand,
            "download_checksums_command": downloadChecksumsCommand,
            "checksum_verify_command": checksumVerifyCommand,
            "attestation_verify_command": verifyCommand,
        ]

        if jsonOutput {
            print(jsonString(payload))
            return
        }

        print("app version: \(payload["app_version"] as? String ?? "unknown")")
        if let build = payload["build"] as? String {
            print("build: \(build)")
        }
        if let commit = payload["commit"] as? String {
            print("commit: \(commit)")
        }
        print("manifest: \(manifest != nil ? "present" : "missing")")
        print("platform: \(platform.goOS)/\(platform.goArch)")
        print("release: \(releaseTag)")
        print("asset: \(assetName)")
        print("download url: \(downloadURL)")
        print("checksums asset: \(checksumsAssetName)")
        print("checksums: \(checksumsURL)")
        if let expectedSHA = entry?.sha256 {
            print("expected sha256: \(expectedSHA)")
        }
        print("cache: \(cacheURL.path)")
        print("cache exists: \(cacheExists ? "yes" : "no")")
        if let cacheSHA {
            print("cache sha256: \(cacheSHA)")
        }
        print("cache verified: \(cacheVerified ? "yes" : "no")")
        print("download command: \(downloadCommand)")
        print("download checksums: \(downloadChecksumsCommand)")
        print("verify checksum: \(checksumVerifyCommand)")
        print("attestation verify: \(verifyCommand)")
        if manifest == nil {
            print("note: this build has no embedded remote daemon manifest. Set CMUX_REMOTE_DAEMON_ALLOW_LOCAL_BUILD=1 only for dev builds.")
        }
    }

    private func defaultRemoteDaemonPlatform(requestedOS: String?, requestedArch: String?) -> (goOS: String, goArch: String) {
        let normalizedOS = requestedOS?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let normalizedArch = requestedArch?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let goOS = (normalizedOS?.isEmpty == false ? normalizedOS! : hostGoOS())
        let goArch = (normalizedArch?.isEmpty == false ? normalizedArch! : hostGoArch())
        return (goOS, goArch)
    }

    private func hostGoOS() -> String {
#if os(macOS)
        return "darwin"
#elseif os(Linux)
        return "linux"
#else
        return "unknown"
#endif
    }

    private func hostGoArch() -> String {
#if arch(arm64)
        return "arm64"
#elseif arch(x86_64)
        return "amd64"
#else
        return "unknown"
#endif
    }

    private func remoteDaemonManifest() -> RemoteDaemonManifest? {
        for plistURL in candidateInfoPlistURLs() {
            guard let raw = NSDictionary(contentsOf: plistURL) as? [String: Any],
                  let rawManifest = raw["CMUXRemoteDaemonManifestJSON"] as? String,
                  let data = rawManifest.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
                  let manifest = try? JSONDecoder().decode(RemoteDaemonManifest.self, from: data) else {
                continue
            }
            return manifest
        }
        return nil
    }

    private func remoteDaemonVersionString(from info: [String: String]) -> String {
        info["CFBundleShortVersionString"] ?? "dev"
    }

    private func remoteDaemonCacheURL(version: String, goOS: String, goArch: String) -> URL {
        let root: URL
        do {
            root = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        } catch {
            return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("cmux-remote-daemons", isDirectory: true)
                .appendingPathComponent(version, isDirectory: true)
                .appendingPathComponent("\(goOS)-\(goArch)", isDirectory: true)
                .appendingPathComponent("cmuxd-remote", isDirectory: false)
        }
        return root
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("remote-daemons", isDirectory: true)
            .appendingPathComponent(version, isDirectory: true)
            .appendingPathComponent("\(goOS)-\(goArch)", isDirectory: true)
            .appendingPathComponent("cmuxd-remote", isDirectory: false)
    }

    private func sha256Hex(forFile url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func hasSSHOptionKey(_ options: [String], key: String) -> Bool {
        let loweredKey = key.lowercased()
        for option in options {
            let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let token = trimmed.split(whereSeparator: { $0 == "=" || $0.isWhitespace }).first.map(String.init)?.lowercased()
            if token == loweredKey {
                return true
            }
        }
        return false
    }

    private func deferredRemoteReconnectLocalCommand(
        in options: [String],
        localCLIPath: String?,
        foregroundAuthToken: String
    ) -> String? {
        guard shouldDeferRemoteReconnect(in: options) else { return nil }
        let preferredCLIPath = localCLIPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        let escapedForegroundAuthToken = foregroundAuthToken
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return [
            preferredCLIPath.map { "cmux_reconnect_cli=\(shellQuote($0));" } ?? "cmux_reconnect_cli=\"\";",
            "cmux_reconnect_socket=\"${CMUX_SOCKET_PATH:-${CMUX_SOCKET:-}}\";",
            "if [ -z \"$cmux_reconnect_cli\" ] && [ -n \"${CMUX_BUNDLED_CLI_PATH:-}\" ]; then cmux_reconnect_cli=\"$CMUX_BUNDLED_CLI_PATH\"; fi;",
            "if [ ! -x \"$cmux_reconnect_cli\" ]; then cmux_reconnect_cli=\"$(command -v cmux 2>/dev/null || true)\"; fi;",
            "if [ -n \"${CMUX_WORKSPACE_ID:-}\" ]; then",
            "if [ -z \"$cmux_reconnect_socket\" ]; then printf '%s\\n' 'cmux: deferred SSH reconnect skipped, local cmux socket not found' >&2;",
            "elif [ -z \"$cmux_reconnect_cli\" ] || [ ! -x \"$cmux_reconnect_cli\" ]; then printf '%s\\n' 'cmux: deferred SSH reconnect skipped, local cmux CLI not found' >&2;",
            "else",
            "cmux_reconnect_payload=\"{\\\"workspace_id\\\":\\\"$CMUX_WORKSPACE_ID\\\",\\\"foreground_auth_token\\\":\\\"\(escapedForegroundAuthToken)\\\"}\";",
            "\"$cmux_reconnect_cli\" --socket \"$cmux_reconnect_socket\" rpc workspace.remote.foreground_auth_ready \"$cmux_reconnect_payload\" >/dev/null 2>&1 || true;",
            "unset cmux_reconnect_payload;",
            "fi;",
            "fi;",
            "unset cmux_reconnect_socket cmux_reconnect_cli;",
        ].joined(separator: " ")
    }

    private func shouldDeferRemoteReconnect(in options: [String]) -> Bool {
        guard !hasSSHOptionKey(options, key: "LocalCommand"),
              !hasSSHOptionKey(options, key: "PermitLocalCommand") else {
            return false
        }

        guard let controlPath = sshOptionValue(named: "ControlPath", in: options)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !controlPath.isEmpty,
              controlPath.lowercased() != "none" else {
            return false
        }

        let controlMaster = sshOptionValue(named: "ControlMaster", in: options)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? "auto"
        switch controlMaster {
        case "no", "false", "off":
            return false
        default:
            return true
        }
    }

    private func defaultSSHControlPathTemplate(remoteRelayPort: Int? = nil) -> String {
        if let remoteRelayPort, remoteRelayPort > 0 {
            return "/tmp/cmux-ssh-\(getuid())-\(remoteRelayPort)-%C"
        }
        return "/tmp/cmux-ssh-\(getuid())-%C"
    }

    private func normalizedSSHIdentityPath(_ rawPath: String?) -> String? {
        guard let rawPath else { return nil }
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("~") {
            let expanded = (trimmed as NSString).expandingTildeInPath
            if !expanded.isEmpty {
                return expanded
            }
        }
        return trimmed
    }

    private func shellQuote(_ value: String) -> String {
        let safePattern = "^[A-Za-z0-9_@%+=:,./-]+$"
        if value.range(of: safePattern, options: .regularExpression) != nil {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private func sshOptionValue(named key: String, in options: [String]) -> String? {
        let loweredKey = key.lowercased()
        for option in options {
            let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(
                maxSplits: 1,
                omittingEmptySubsequences: true,
                whereSeparator: { $0 == "=" || $0.isWhitespace }
            )
            if parts.count == 2, parts[0].lowercased() == loweredKey {
                let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty {
                    return value
                }
            }
        }
        return nil
    }

    private func cliDebugLog(_ message: @autoclosure () -> String) {
#if DEBUG
        let trimmedExplicit = ProcessInfo.processInfo.environment["CMUX_DEBUG_LOG"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let path: String? = {
            if let trimmedExplicit, !trimmedExplicit.isEmpty {
                return trimmedExplicit
            }
            guard let marker = try? String(contentsOfFile: "/tmp/cmux-last-debug-log-path", encoding: .utf8) else {
                return nil
            }
            let trimmedMarker = marker.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedMarker.isEmpty ? nil : trimmedMarker
        }()
        guard let path else { return }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(timestamp) [cmux-cli] \(message())\n"
        guard let data = line.data(using: .utf8) else { return }
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            return
        }
#endif
    }

    private func runProcess(
        executablePath: String,
        arguments: [String],
        stdinText: String? = nil,
        timeout: TimeInterval? = nil
    ) -> (status: Int32, stdout: String, stderr: String) {
        let result = CLIProcessRunner.runProcess(
            executablePath: executablePath,
            arguments: arguments,
            stdinText: stdinText,
            timeout: timeout
        )
        return (result.status, result.stdout, result.stderr)
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

        var effectiveJSONOutput = jsonOutput
        var effectiveIDFormat = idFormat
        var browserArgs = commandArgs

        // Browser-skill examples often place output flags at the end of the command.
        // Strip trailing display flags so they don't become part of a URL or selector.
        while !browserArgs.isEmpty {
            if browserArgs.last == "--json" {
                effectiveJSONOutput = true
                browserArgs.removeLast()
                continue
            }

            if browserArgs.count >= 2,
               browserArgs[browserArgs.count - 2] == "--id-format" {
                let raw = browserArgs.last!
                guard let parsed = try CLIIDFormat.parse(raw) else {
                    throw CLIError(message: "--id-format must be one of: refs, uuids, both")
                }
                effectiveIDFormat = parsed
                browserArgs.removeLast(2)
                continue
            }

            break
        }

        let (surfaceOpt, argsWithoutSurfaceFlag) = parseOption(browserArgs, name: "--surface")
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
            if effectiveJSONOutput {
                print(jsonString(formatIDs(payload, mode: effectiveIDFormat)))
                return
            }
            print(fallback)
            if let snapshot = payload["post_action_snapshot"] as? String,
               !snapshot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                print(snapshot)
            }
        }

        func displaySnapshotText(_ payload: [String: Any]) -> String {
            let snapshotText = (payload["snapshot"] as? String) ?? "Empty page"
            guard snapshotText.contains("\n- (empty)") else {
                return snapshotText
            }

            let url = ((payload["url"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let readyState = ((payload["ready_state"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            var lines = [snapshotText]

            if !url.isEmpty {
                lines.append("url: \(url)")
            }
            if !readyState.isEmpty {
                lines.append("ready_state: \(readyState)")
            }
            if url.isEmpty || url == "about:blank" {
                lines.append("hint: run 'cmux browser <surface> get url' to verify navigation")
            }

            return lines.joined(separator: "\n")
        }

        func displayBrowserValue(_ value: Any) -> String {
            if let dict = value as? [String: Any],
               let type = dict["__cmux_t"] as? String,
               type == "undefined" {
                return "undefined"
            }
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
            let respectExternalOpenRules: Bool = {
                guard let raw = ProcessInfo.processInfo.environment["CMUX_RESPECT_EXTERNAL_OPEN_RULES"] else {
                    return false
                }
                switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                case "1", "true", "yes", "on":
                    return true
                default:
                    return false
                }
            }()

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
            if respectExternalOpenRules {
                params["respect_external_open_rules"] = true
            }
            if let windowRaw = windowOpt {
                if let window = try normalizeWindowHandle(windowRaw, client: client) {
                    params["window_id"] = window
                }
            }
            let payload = try client.sendV2(method: "browser.open_split", params: params)
            let surfaceText = formatHandle(payload, kind: "surface", idFormat: effectiveIDFormat) ?? "unknown"
            let paneText = formatHandle(payload, kind: "pane", idFormat: effectiveIDFormat) ?? "unknown"
            let placement = ((payload["created_split"] as? Bool) == true) ? "split" : "reuse"
            output(payload, fallback: "OK surface=\(surfaceText) pane=\(paneText) placement=\(placement)")
            return
        }

        if subcommand == "goto" || subcommand == "navigate" {
            let sid = try requireSurface()
            var urlArgs = subArgs
            let snapshotAfter = urlArgs.last == "--snapshot-after"
            if snapshotAfter {
                urlArgs.removeLast()
            }
            let url = urlArgs.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !url.isEmpty else {
                throw CLIError(message: "browser \(subcommand) requires a URL")
            }
            var params: [String: Any] = ["surface_id": sid, "url": url]
            if snapshotAfter {
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
            if effectiveJSONOutput {
                print(jsonString(formatIDs(payload, mode: effectiveIDFormat)))
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
            if effectiveJSONOutput {
                print(jsonString(formatIDs(payload, mode: effectiveIDFormat)))
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
            if effectiveJSONOutput {
                print(jsonString(formatIDs(payload, mode: effectiveIDFormat)))
            } else {
                print(displaySnapshotText(payload))
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
            let localJSONOutput = hasFlag(subArgs, name: "--json")
            let outputAsJSON = effectiveJSONOutput || localJSONOutput
            var payload = try client.sendV2(method: "browser.screenshot", params: ["surface_id": sid])

            func fileURL(fromPath rawPath: String) -> URL {
                let resolvedPath = resolvePath(rawPath)
                return URL(fileURLWithPath: resolvedPath).standardizedFileURL
            }

            func writeScreenshot(_ data: Data, to destinationURL: URL) throws {
                try FileManager.default.createDirectory(
                    at: destinationURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: destinationURL, options: .atomic)
            }

            func hasText(_ value: String?) -> Bool {
                guard let value else { return false }
                return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }

            var screenshotPath = payload["path"] as? String
            var screenshotURL = payload["url"] as? String

            func syncScreenshotLocationFields() {
                if !hasText(screenshotPath),
                   let rawURL = screenshotURL,
                   let fileURL = URL(string: rawURL),
                   fileURL.isFileURL,
                   !fileURL.path.isEmpty {
                    screenshotPath = fileURL.path
                }
                if !hasText(screenshotURL),
                   let screenshotPath,
                   hasText(screenshotPath) {
                    screenshotURL = URL(fileURLWithPath: screenshotPath).standardizedFileURL.absoluteString
                }
                if let screenshotPath, hasText(screenshotPath) {
                    payload["path"] = screenshotPath
                }
                if let screenshotURL, hasText(screenshotURL) {
                    payload["url"] = screenshotURL
                }
            }

            func persistPayloadScreenshot(to destinationURL: URL, allowFailure: Bool) throws -> Bool {
                if let sourcePath = screenshotPath, hasText(sourcePath) {
                    let sourceURL = URL(fileURLWithPath: sourcePath).standardizedFileURL
                    do {
                        if sourceURL.path != destinationURL.path {
                            try FileManager.default.createDirectory(
                                at: destinationURL.deletingLastPathComponent(),
                                withIntermediateDirectories: true
                            )
                            try? FileManager.default.removeItem(at: destinationURL)
                            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
                        }
                        return true
                    } catch {
                        if payload["png_base64"] == nil {
                            if allowFailure {
                                return false
                            }
                            throw error
                        }
                    }
                }

                if let b64 = payload["png_base64"] as? String,
                   let data = Data(base64Encoded: b64) {
                    do {
                        try writeScreenshot(data, to: destinationURL)
                        return true
                    } catch {
                        if allowFailure {
                            return false
                        }
                        throw error
                    }
                }

                return false
            }

            if let outPathOpt {
                let outputURL = fileURL(fromPath: outPathOpt)
                guard try persistPayloadScreenshot(to: outputURL, allowFailure: false) else {
                    throw CLIError(message: "browser screenshot missing image data")
                }
                screenshotPath = outputURL.path
                screenshotURL = outputURL.absoluteString
                payload["path"] = screenshotPath
                payload["url"] = screenshotURL
            } else {
                syncScreenshotLocationFields()
                if !hasText(screenshotPath) && !hasText(screenshotURL) {
                    let outputDir = FileManager.default.temporaryDirectory
                        .appendingPathComponent("cmux-browser-screenshots-cli", isDirectory: true)
                    if (try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)) != nil {
                        bestEffortPruneTemporaryFiles(in: outputDir)
                        let timestampMs = Int(Date().timeIntervalSince1970 * 1000)
                        let safeSid = sanitizedFilenameComponent(sid)
                        let filename = "surface-\(safeSid)-\(timestampMs)-\(String(UUID().uuidString.prefix(8))).png"
                        let outputURL = outputDir.appendingPathComponent(filename, isDirectory: false)
                        if (try? persistPayloadScreenshot(to: outputURL, allowFailure: true)) == true {
                            screenshotPath = outputURL.path
                            screenshotURL = outputURL.absoluteString
                            payload["path"] = screenshotPath
                            payload["url"] = screenshotURL
                        }
                    }
                }
            }

            if outputAsJSON {
                let formattedPayload = formatIDs(payload, mode: effectiveIDFormat)
                if var outputPayload = formattedPayload as? [String: Any] {
                    if hasText(screenshotPath) || hasText(screenshotURL) {
                        outputPayload.removeValue(forKey: "png_base64")
                    }
                    print(jsonString(outputPayload))
                } else {
                    print(jsonString(formattedPayload))
                }
            } else if let outPathOpt {
                print("OK \(outPathOpt)")
            } else if let screenshotURL,
                      hasText(screenshotURL) {
                print("OK \(screenshotURL)")
            } else if let screenshotPath,
                      hasText(screenshotPath) {
                print("OK \(screenshotPath)")
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
                if effectiveJSONOutput {
                    print(jsonString(formatIDs(payload, mode: effectiveIDFormat)))
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
            if effectiveJSONOutput {
                print(jsonString(formatIDs(payload, mode: effectiveIDFormat)))
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
            if effectiveJSONOutput || consoleVerb == "clear" {
                output(payload, fallback: "OK")
            } else {
                print(displayBrowserLogItems(payload["entries"]) ?? "No console entries")
            }
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
            if effectiveJSONOutput || errorsVerb == "clear" {
                output(payload, fallback: "OK")
            } else {
                print(displayBrowserLogItems(payload["errors"]) ?? "No browser errors")
            }
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

    /// Return the help/usage text for a subcommand, or nil if the command is unknown.
    private func subcommandUsage(_ command: String) -> String? {
        switch command {
        case "ping":
            return """
            Usage: cmux ping

            Check connectivity to the cmux socket server.
            """
        case "capabilities":
            return """
            Usage: cmux capabilities

            Print server capabilities as JSON.
            """
        case "auth":
            return """
            Usage: cmux auth <status|login|logout>

            status   Print whether the user is signed in (add `cmux --json` for JSON).
            login    Open the sign-in popup on the cmux mac app and wait for it to finish.
            logout   Clear the current session.
            """
        case "rpc":
            return """
            Usage: cmux rpc <method> [json-params]

            Call a raw v2 method with an optional JSON object for params.
            Example: cmux rpc surface.report_tty '{"workspace_id":"...","surface_id":"...","tty_name":"ttys001"}'
            """
        case "help":
            return """
            Usage: cmux help

            Show top-level CLI usage and command list.
            """
        case "welcome":
            return """
            Usage: cmux welcome

            Show a welcome screen with the cmux logo and useful shortcuts.
            Auto-runs once on first launch.
            """
        case "shortcuts":
            return """
            Usage: cmux shortcuts

            Open the Settings window to Keyboard Shortcuts.
            """
        case "restore-session":
            return """
            Usage: cmux restore-session

            Reopen the previous saved cmux session.

            If the app is already running, this restores the last saved session into the current app.
            If the app is not running, this launches cmux and lets startup restore reopen the saved session.
            """
        case "feedback":
            return """
            Usage: cmux feedback
                   cmux feedback --email <email> --body <text> [--image <path> ...]

            Without args, open the Send Feedback modal in the running app.

            With args, submit feedback through the app using the same feedback pipeline as the modal.

            Flags:
              --email <email>   Contact email for follow-up
              --body <text>     Feedback body
              --image <path>    Attach an image file, repeat for multiple images

            Coding agents:
              Double check with the end user before sending anything. Review the message and attachments for secrets,
              private code, credentials, tokens, and other sensitive information first.
            """
        case "themes":
            return """
            Usage: cmux themes
                   cmux themes list
                   cmux themes set <theme>
                   cmux themes set --light <theme> [--dark <theme>]
                   cmux themes set --dark <theme> [--light <theme>]
                   cmux themes clear

            When run in a TTY, `cmux themes` opens an interactive theme picker with
            live app preview. Use `cmux themes list` for a plain listing.

            The picker previews the selected theme across the running cmux app and
            lets you apply it to the light theme, dark theme, or both defaults.

            Commands:
              list                      List available themes and mark the current light/dark defaults
              set <theme>               Set the same theme for both light and dark appearance
              set --light <theme>       Set the light appearance theme
              set --dark <theme>        Set the dark appearance theme
              clear                     Remove the cmux theme override and fall back to other config

            Examples:
              cmux themes
              cmux themes list
              cmux themes set "Catppuccin Mocha"
              cmux themes set --light "Catppuccin Latte" --dark "Catppuccin Mocha"
              cmux themes clear
            """
        case "claude-teams":
            return String(localized: "cli.claude-teams.usage", defaultValue: """
            Usage: cmux claude-teams [claude-args...]

            Launch Claude Code with agent teams enabled.

            This command:
              - defaults Claude teammate mode to auto
              - sets a tmux-like environment so Claude auto mode uses cmux splits
              - sets CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1
              - prepends a private tmux shim to PATH
              - forwards all remaining arguments to claude

            The tmux shim translates supported tmux window/pane commands into cmux
            workspace and split operations in the current cmux session.

            Examples:
              cmux claude-teams
              cmux claude-teams --continue
              cmux claude-teams --model sonnet
            """)
        case "omo":
            return String(localized: "cli.omo.usage", defaultValue: """
            Usage: cmux omo [opencode-args...]

            Launch OpenCode with oh-my-openagent in a cmux-aware environment.

            oh-my-openagent orchestrates multiple AI models as specialized agents in
            parallel. This command sets up a tmux shim so agent panes become native
            cmux splits with sidebar metadata and notifications.

            This command:
              - sets a tmux-like environment so oh-my-openagent uses cmux splits
              - prepends a private tmux shim to PATH
              - forwards all remaining arguments to opencode

            The tmux shim translates tmux window/pane commands into cmux workspace
            and split operations in the current cmux session.

            Examples:
              cmux omo
              cmux omo --continue
              cmux omo --model claude-sonnet-4-6
            """)
        case "opencode":
            return """
            Usage: cmux opencode <install-hooks|uninstall-hooks> [--yes]

            Install or remove the OpenCode plugin that lets cmux remember
            restorable OpenCode session IDs for reopened terminals.

            Files:
              ~/.config/opencode/plugins/cmux-session.js

            Examples:
              cmux opencode install-hooks --yes
              cmux opencode uninstall-hooks
            """
        case "omx":
            return String(localized: "cli.omx.usage", defaultValue: """
            Usage: cmux omx [omx-args...]

            Launch Oh My Codex (OMX) with native cmux pane integration.

            OMX is a multi-agent orchestration layer for OpenAI Codex CLI. This
            command sets up a tmux shim so OMX team mode, HUD, and agent panes
            become native cmux splits.

            This command:
              - sets a tmux-like environment so OMX uses cmux splits
              - prepends a private tmux shim to PATH
              - forwards all remaining arguments to omx

            Install: npm install -g oh-my-codex

            Examples:
              cmux omx
              cmux omx --madmax --high
              cmux omx team
            """)
        case "omc":
            return String(localized: "cli.omc.usage", defaultValue: """
            Usage: cmux omc [omc-args...]

            Launch Oh My Claude Code (OMC) with native cmux pane integration.

            OMC is a multi-agent orchestration system for Claude Code with
            specialized agents, smart model routing, and team pipelines. This
            command sets up a tmux shim so OMC team mode and agent panes become
            native cmux splits.

            This command:
              - sets a tmux-like environment so OMC uses cmux splits
              - prepends a private tmux shim to PATH
              - injects NODE_OPTIONS restore module for Claude compatibility
              - forwards all remaining arguments to omc

            Install: npm install -g oh-my-claude-sisyphus

            Examples:
              cmux omc
              cmux omc team 3:claude "implement feature"
              cmux omc --watch
            """)
        case "identify":
            return """
            Usage: cmux identify [--workspace <id|ref|index>] [--surface <id|ref|index>] [--no-caller]

            Print server identity and caller context details.

            Flags:
              --workspace <id|ref|index>   Caller workspace context (default: $CMUX_WORKSPACE_ID)
              --surface <id|ref|index>     Caller surface context (default: $CMUX_SURFACE_ID)
              --no-caller                  Omit caller context from the request
            """
        case "list-windows":
            return """
            Usage: cmux list-windows

            List open windows.
            """
        case "current-window":
            return """
            Usage: cmux current-window

            Print the currently selected window ID.
            """
        case "new-window":
            return """
            Usage: cmux new-window

            Create a new window.

            Example:
              cmux new-window
            """
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
            Usage: cmux move-workspace-to-window --workspace <id|ref|index> --window <id|ref|index>

            Move a workspace to a different window.

            Flags:
              --workspace <id|ref|index>   Workspace to move (required)
              --window <id|ref|index>      Target window (required)

            Example:
              cmux move-workspace-to-window --workspace workspace:2 --window window:1
            """
        case "move-surface":
            return """
            Usage: cmux move-surface [--surface <id|ref|index> | <id|ref|index>] [flags]

            Move a surface to a different pane, workspace, or window.

            Flags:
              --surface <id|ref|index>   Surface to move (required unless passed positionally)
              --pane <id|ref|index>      Target pane
              --workspace <id|ref|index> Target workspace
              --window <id|ref|index>    Target window
              --before <id|ref|index>    Place before this surface
              --before-surface <id|ref|index>
                                       Alias for --before
              --after <id|ref|index>     Place after this surface
              --after-surface <id|ref|index>
                                       Alias for --after
              --index <n>                Place at this index
              --focus <true|false>       Focus the surface after moving

            Example:
              cmux move-surface --surface surface:1 --workspace workspace:2
              cmux move-surface surface:1 --pane pane:2 --index 0
            """
        case "reorder-surface":
            return """
            Usage: cmux reorder-surface [--surface <id|ref|index> | <id|ref|index>] [flags]

            Reorder a surface within its pane.

            Flags:
              --surface <id|ref|index>   Surface to reorder (required unless passed positionally)
              --workspace <id|ref|index> Workspace context
              --before <id|ref|index>    Place before this surface
              --before-surface <id|ref|index>
                                       Alias for --before
              --after <id|ref|index>     Place after this surface
              --after-surface <id|ref|index>
                                       Alias for --after
              --index <n>                Place at this index

            Example:
              cmux reorder-surface --surface surface:1 --index 0
              cmux reorder-surface --surface surface:3 --after surface:1
            """
        case "reorder-workspace":
            return """
            Usage: cmux reorder-workspace [--workspace <id|ref|index> | <id|ref|index>] [flags]

            Reorder a workspace within its window.

            Flags:
              --workspace <id|ref|index>   Workspace to reorder (required unless passed positionally)
              --index <n>                  Place at this index
              --before <id|ref|index>      Place before this workspace
              --before-workspace <id|ref|index>
                                         Alias for --before
              --after <id|ref|index>       Place after this workspace
              --after-workspace <id|ref|index>
                                         Alias for --after
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
              set-description | clear-description
              move-up | move-down | move-top
              close-others | close-above | close-below
              mark-read | mark-unread
              set-color | clear-color

            Flags:
              --action <name>              Action name (required if not positional)
              --workspace <id|ref|index>   Target workspace (default: current/$CMUX_WORKSPACE_ID)
              --title <text>               Title for rename
              --color <name|#hex>          Color for set-color (name or #RRGGBB hex)
              --description <text>         Description for set-description

            Named colors:
              Red, Crimson, Orange, Amber, Olive, Green, Teal, Aqua,
              Blue, Navy, Indigo, Purple, Magenta, Rose, Brown, Charcoal

            Example:
              cmux workspace-action --workspace workspace:2 --action pin
              cmux workspace-action --action rename --title "infra"
              cmux workspace-action close-others
              cmux workspace-action --action set-color --color blue
              cmux workspace-action --action set-color --color "#C0392B"
              cmux workspace-action set-color Amber
              cmux workspace-action --action set-description --description "Ship checklist"
              cmux workspace-action --action set-description $'Ship checklist\n- verify build\n- post notes'
              cmux workspace-action clear-color
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
              mark-unread

            Flags:
              --action <name>              Action name (required if not positional)
              --tab <id|ref|index>         Target tab (accepts tab:<n> or surface:<n>; default: $CMUX_TAB_ID, then $CMUX_SURFACE_ID, then focused tab)
              --surface <id|ref|index>     Alias for --tab (backward compatibility)
              --workspace <id|ref|index>   Workspace context (default: current/$CMUX_WORKSPACE_ID)
              --title <text>               Title for rename (or pass trailing title text)
              --url <url>                  Optional URL for new-browser-right

            Example:
              cmux tab-action --tab tab:3 --action pin
              cmux tab-action --action close-right
              cmux tab-action --tab tab:2 --action rename --title "build logs"
            """
        case "rename-tab":
            return """
            Usage: cmux rename-tab [--workspace <id|ref>] [--tab <id|ref>] [--surface <id|ref>] [--] <title>

            Compatibility alias for tab-action rename.

            Resolution order for target tab:
            1) --tab
            2) --surface
            3) $CMUX_TAB_ID / $CMUX_SURFACE_ID
            4) currently focused tab (optionally within --workspace)

            Flags:
              --workspace <id|ref>   Workspace context (default: current/$CMUX_WORKSPACE_ID)
              --tab <id|ref>         Tab target (supports tab:<n> or surface:<n>)
              --surface <id|ref>     Alias for --tab
              --title <text>         Explicit title (or use trailing positional title)

            Examples:
              cmux rename-tab "build logs"
              cmux rename-tab --tab tab:3 "staging server"
              cmux rename-tab --workspace workspace:2 --surface surface:5 --title "agent run"
            """
        case "new-workspace":
            return """
            Usage: cmux new-workspace [--name <title>] [--description <text>] [--cwd <path>] [--command <text>] [--layout <json>]

            Create a new workspace in the current window.

            Flags:
              --name <title>       Set a custom name for the new workspace
              --description <text> Set a custom description for the new workspace
              --cwd <path>         Set the working directory for the new workspace
              --command <text>     Send text+Enter to the new workspace after creation
              --layout <json>      Create workspace with a predefined split layout (inline JSON).
                                   Uses the same schema as cmux.json layout definitions.
                                   When provided, --command is ignored (layout surfaces define their own commands).

            Example:
              cmux new-workspace
              cmux new-workspace --name "Build Server"
              cmux new-workspace --name "Launch" --description "Ship checklist"
              cmux new-workspace --cwd ~/projects/myapp
              cmux new-workspace --cwd . --command "npm test"
              cmux new-workspace --name "Dev" --layout '{"direction":"horizontal","split":0.5,"children":[{"pane":{"surfaces":[{"type":"terminal","command":"vim"}]}},{"pane":{"surfaces":[{"type":"terminal","command":"npm run start"}]}}]}'
            """
        case "list-workspaces":
            return """
            Usage: cmux list-workspaces

            List workspaces in the current window.

            Example:
              cmux list-workspaces
            """
        case "ssh":
            return """
            Usage: cmux ssh <destination> [flags] [-- <remote-command-args>]

            Create a new workspace, mark it as remote-SSH, and start an SSH session in that workspace.
            cmux will also establish a local SSH proxy endpoint so browser traffic can egress from the remote host.

            Flags:
              --name <title>          Optional workspace title
              --port <n>              SSH port
              --identity <path>       SSH identity file path
              --ssh-option <opt>      Extra SSH -o option (repeatable)
              --no-focus              Create workspace without switching to it

            Example:
              cmux ssh dev@my-host
              cmux ssh dev@my-host --name "gpu-box" --port 2222 --identity ~/.ssh/id_ed25519
              cmux ssh dev@my-host --ssh-option UserKnownHostsFile=/dev/null --ssh-option StrictHostKeyChecking=no
            """
        case "remote-daemon-status":
            return """
            Usage: cmux remote-daemon-status [--os <darwin|linux>] [--arch <arm64|amd64>]

            Show the embedded cmuxd-remote release manifest, local cache status, checksum verification state,
            and the GitHub attestation verification command for a target platform.

            Example:
              cmux remote-daemon-status
              cmux remote-daemon-status --os linux --arch arm64
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
        case "list-panes":
            return """
            Usage: cmux list-panes [--workspace <id|ref>]

            List panes in a workspace.

            Flags:
              --workspace <id|ref>   Workspace context (default: $CMUX_WORKSPACE_ID)

            Example:
              cmux list-panes
              cmux list-panes --workspace workspace:2
            """
        case "list-pane-surfaces":
            return """
            Usage: cmux list-pane-surfaces [--workspace <id|ref>] [--pane <id|ref>]

            List surfaces in a pane.

            Flags:
              --workspace <id|ref>   Workspace context (default: $CMUX_WORKSPACE_ID)
              --pane <id|ref>        Restrict to a specific pane (default: focused pane)

            Example:
              cmux list-pane-surfaces
              cmux list-pane-surfaces --workspace workspace:2 --pane pane:1
            """
        case "tree":
            return """
            Usage: cmux tree [flags]

            Print the hierarchy of windows, workspaces, panes, and surfaces.

            Flags:
              --all                         Include all windows (default: current window only)
              --workspace <id|ref|index>   Show only one workspace
              --json                        Structured JSON output

            Output:
              Text mode prints a box-drawing tree with markers:
              - ◀ active (true focused window/workspace/pane/surface path)
              - ◀ here (caller surface where `cmux tree` was invoked)
              - workspace [selected]
              - pane [focused]
              - surface [selected]
              Browser surfaces also include their current URL.

            Example:
              cmux tree
              cmux tree --all
              cmux tree --workspace workspace:2
              cmux --json tree --all
            """
        case "focus-pane":
            return """
            Usage: cmux focus-pane [--pane <id|ref> | <id|ref>] [flags]

            Focus the specified pane.

            Flags:
              --pane <id|ref>          Pane to focus (required unless passed positionally)
              --workspace <id|ref>     Workspace context (default: $CMUX_WORKSPACE_ID)

            Example:
              cmux focus-pane --pane pane:2
              cmux focus-pane pane:1
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
        case "refresh-surfaces":
            return """
            Usage: cmux refresh-surfaces

            Refresh surface snapshots for the focused workspace.
            """
        case "reload-config":
            return """
            Usage: cmux reload-config

            Run the same configuration reload as the Reload Configuration shortcut.
            This reloads Ghostty config, re-reads ~/.config/cmux/settings.json, and refreshes terminals.

            Example:
              cmux reload-config
            """
        case "surface-health":
            return """
            Usage: cmux surface-health [--workspace <id|ref>]

            List health details for surfaces in a workspace.

            Flags:
              --workspace <id|ref>   Workspace context (default: $CMUX_WORKSPACE_ID)

            Example:
              cmux surface-health
              cmux surface-health --workspace workspace:2
            """
        case "debug-terminals":
            return """
            Usage: cmux debug-terminals

            Print live Ghostty terminal runtime metadata across all windows and workspaces.
            Intended for debugging stray or detached terminal views.
            """
        case "trigger-flash":
            return """
            Usage: cmux trigger-flash [--workspace <id|ref>] [--surface <id|ref>] [--panel <id|ref>]

            Trigger the unread flash indicator for a surface.

            Flags:
              --workspace <id|ref>   Workspace context (default: $CMUX_WORKSPACE_ID)
              --surface <id|ref>     Target surface (default: $CMUX_SURFACE_ID)
              --panel <id|ref>       Alias for --surface

            Example:
              cmux trigger-flash
              cmux trigger-flash --workspace workspace:2 --surface surface:3
            """
        case "list-panels":
            return """
            Usage: cmux list-panels [--workspace <id|ref>]

            List surfaces (panels) in a workspace.

            Flags:
              --workspace <id|ref>   Workspace context (default: $CMUX_WORKSPACE_ID)

            Example:
              cmux list-panels
              cmux list-panels --workspace workspace:2
            """
        case "focus-panel":
            return """
            Usage: cmux focus-panel --panel <id|ref> [--workspace <id|ref>]

            Focus a specific panel (surface).

            Flags:
              --panel <id|ref>       Panel/surface to focus (required)
              --workspace <id|ref>   Workspace context (default: $CMUX_WORKSPACE_ID)

            Example:
              cmux focus-panel --panel surface:2
              cmux focus-panel --panel surface:5 --workspace workspace:2
            """
        case "close-workspace":
            return """
            Usage: cmux close-workspace --workspace <id|ref|index>

            Close the specified workspace.

            Flags:
              --workspace <id|ref|index>   Workspace to close (required)

            Example:
              cmux close-workspace --workspace workspace:2
            """
        case "select-workspace":
            return """
            Usage: cmux select-workspace --workspace <id|ref|index>

            Select (switch to) the specified workspace.

            Flags:
              --workspace <id|ref|index>   Workspace to select (required)

            Example:
              cmux select-workspace --workspace workspace:2
              cmux select-workspace --workspace 0
            """
        case "rename-workspace", "rename-window":
            return """
            Usage: cmux rename-workspace [--workspace <id|ref|index>] [--] <title>

            Rename a workspace. Defaults to the current workspace.
            tmux-compatible alias: rename-window

            Flags:
              --workspace <id|ref|index>   Workspace to rename (default: current/$CMUX_WORKSPACE_ID)

            Example:
              cmux rename-workspace "backend logs"
              cmux rename-window --workspace workspace:2 "agent run"
            """
        case "current-workspace":
            return """
            Usage: cmux current-workspace

            Print the currently selected workspace ID.
            """
        case "capture-pane":
            return """
            Usage: cmux capture-pane [--workspace <id|ref>] [--surface <id|ref>] [--scrollback] [--lines <n>]

            tmux-compatible alias for reading terminal text from a pane.

            Flags:
              --workspace <id|ref>   Workspace context (default: $CMUX_WORKSPACE_ID)
              --surface <id|ref>     Surface context (default: $CMUX_SURFACE_ID)
              --scrollback           Include scrollback
              --lines <n>            Return only the last N lines (implies --scrollback)

            Example:
              cmux capture-pane --workspace workspace:2 --surface surface:1 --scrollback --lines 200
            """
        case "resize-pane":
            return """
            Usage: cmux resize-pane [--pane <id|ref>] [--workspace <id|ref>] [-L|-R|-U|-D] [--amount <n>]

            tmux-compatible pane resize command.

            Flags:
              --pane <id|ref>        Pane to resize (default: focused pane)
              --workspace <id|ref>   Workspace context (default: $CMUX_WORKSPACE_ID)
              -L|-R|-U|-D            Direction (default: -R)
              --amount <n>           Resize amount (default: 1)
            """
        case "pipe-pane":
            return """
            Usage: cmux pipe-pane [--workspace <id|ref>] [--surface <id|ref>] [--command <shell-command> | <shell-command>]

            Capture pane text and pipe it to a shell command via stdin.

            Flags:
              --workspace <id|ref>   Workspace context (default: $CMUX_WORKSPACE_ID)
              --surface <id|ref>     Surface context (default: focused surface)
              --command <command>    Shell command to run (or pass as trailing text)
            """
        case "wait-for":
            return """
            Usage: cmux wait-for [-S|--signal] <name> [--timeout <seconds>]

            Wait for or signal a named synchronization token.

            Flags:
              -S, --signal           Signal the token instead of waiting
              --timeout <seconds>    Wait timeout (default: 30)
            """
        case "swap-pane":
            return """
            Usage: cmux swap-pane --pane <id|ref> --target-pane <id|ref> [--workspace <id|ref>]

            Swap two panes.

            Flags:
              --pane <id|ref>         Source pane (required)
              --target-pane <id|ref>  Target pane (required)
              --workspace <id|ref>    Workspace context (default: $CMUX_WORKSPACE_ID)
            """
        case "break-pane":
            return """
            Usage: cmux break-pane [--workspace <id|ref>] [--pane <id|ref>] [--surface <id|ref>] [--no-focus]

            Move a pane/surface out into its own pane context.

            Flags:
              --workspace <id|ref>   Workspace context (default: $CMUX_WORKSPACE_ID)
              --pane <id|ref>        Source pane
              --surface <id|ref>     Source surface
              --no-focus             Do not focus the result
            """
        case "join-pane":
            return """
            Usage: cmux join-pane --target-pane <id|ref> [--workspace <id|ref>] [--pane <id|ref>] [--surface <id|ref>] [--no-focus]

            Join a pane/surface into another pane.

            Flags:
              --target-pane <id|ref>  Target pane (required)
              --workspace <id|ref>    Workspace context (default: $CMUX_WORKSPACE_ID)
              --pane <id|ref>         Source pane
              --surface <id|ref>      Source surface
              --no-focus              Do not focus the result
            """
        case "next-window", "previous-window", "last-window":
            return """
            Usage: cmux \(command)

            Switch workspace selection (next/previous/last) in the current window.
            """
        case "last-pane":
            return """
            Usage: cmux last-pane [--workspace <id|ref>]

            Focus the previously focused pane in a workspace.

            Flags:
              --workspace <id|ref>   Workspace context (default: $CMUX_WORKSPACE_ID)
            """
        case "find-window":
            return """
            Usage: cmux find-window [--content] [--select] [query]

            Find workspaces by title (and optionally terminal content).

            Flags:
              --content   Search terminal content in addition to workspace titles
              --select    Select the first match
            """
        case "clear-history":
            return """
            Usage: cmux clear-history [--workspace <id|ref>] [--surface <id|ref>]

            Clear terminal scrollback history.

            Flags:
              --workspace <id|ref>   Workspace context (default: $CMUX_WORKSPACE_ID)
              --surface <id|ref>     Surface context (default: focused surface)
            """
        case "set-hook":
            return """
            Usage: cmux set-hook [--list] [--unset <event>] | <event> <command>

            Manage tmux-compat hook definitions.

            Flags:
              --list            List configured hooks
              --unset <event>   Remove a hook by event name
            """
        case "popup":
            return """
            Usage: cmux popup

            tmux compatibility placeholder. This command is currently not supported.
            """
        case "bind-key", "unbind-key", "copy-mode":
            return """
            Usage: cmux \(command)

            tmux compatibility placeholder. This command is currently not supported.
            """
        case "set-buffer":
            return """
            Usage: cmux set-buffer [--name <name>] [--] <text>

            Save text into a named tmux-compat buffer.

            Flags:
              --name <name>   Buffer name (default: default)
            """
        case "paste-buffer":
            return """
            Usage: cmux paste-buffer [--name <name>] [--workspace <id|ref>] [--surface <id|ref>]

            Paste a named tmux-compat buffer into a surface.

            Flags:
              --name <name>         Buffer name (default: default)
              --workspace <id|ref>  Workspace context (default: $CMUX_WORKSPACE_ID)
              --surface <id|ref>    Surface context (default: focused surface)
            """
        case "list-buffers":
            return """
            Usage: cmux list-buffers

            List tmux-compat buffers.
            """
        case "respawn-pane":
            return """
            Usage: cmux respawn-pane [--workspace <id|ref>] [--surface <id|ref>] [--command <cmd> | <cmd>]

            Send a command (or default shell restart command) to a surface.

            Flags:
              --workspace <id|ref>   Workspace context (default: $CMUX_WORKSPACE_ID)
              --surface <id|ref>     Surface context (default: focused surface)
              --command <cmd>        Command text (or pass trailing command text)
            """
        case "display-message":
            return """
            Usage: cmux display-message [-p|--print] <text>

            Print text (or show it via notification bridge in parity mode).

            Flags:
              -p, --print   Print to stdout only
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
        case "list-notifications":
            return """
            Usage: cmux list-notifications

            List queued notifications.
            """
        case "clear-notifications":
            return """
            Usage: cmux clear-notifications

            Clear all queued notifications.
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
        case "set-app-focus":
            return """
            Usage: cmux set-app-focus <active|inactive|clear>

            Override app focus state for notification routing tests.

            Example:
              cmux set-app-focus inactive
              cmux set-app-focus clear
            """
        case "simulate-app-active":
            return """
            Usage: cmux simulate-app-active

            Trigger the app-active handler used by notification focus tests.
            """
        case "claude-hook":
            return """
            Usage: cmux claude-hook <session-start|active|stop|idle|notification|notify|prompt-submit> [flags]

            Hook for Claude Code integration. Reads JSON from stdin.

            Subcommands:
              session-start   Signal that a Claude session has started
              active          Alias for session-start
              stop            Signal that a Claude session has stopped
              idle            Alias for stop
              notification    Forward a Claude notification
              notify          Alias for notification
              prompt-submit   Clear notification and set Running on user prompt

            Flags:
              --workspace <id|ref>   Target workspace (default: $CMUX_WORKSPACE_ID)
              --surface <id|ref>     Target surface (default: $CMUX_SURFACE_ID)

            Example:
              echo '{"session_id":"abc"}' | cmux claude-hook session-start
              echo '{}' | cmux claude-hook stop
            """
        case "codex":
            return """
            Usage: cmux codex <install-hooks|uninstall-hooks>

            Manage Codex CLI hooks integration.

            Subcommands:
              install-hooks     Install cmux hooks into ~/.codex/hooks.json
              uninstall-hooks   Remove cmux hooks from ~/.codex/hooks.json
            """
        case "codex-hook":
            return """
            Usage: cmux codex-hook <session-start|prompt-submit|stop> [flags]

            Hook for Codex CLI integration. Reads JSON from stdin.
            Gracefully no-ops when not running inside cmux.

            Subcommands:
              session-start   Register a Codex session
              prompt-submit   Set Running status on user prompt
              stop            Send completion notification, set Idle

            Flags:
              --workspace <id|ref>   Target workspace (default: $CMUX_WORKSPACE_ID)
              --surface <id|ref>     Target surface (default: $CMUX_SURFACE_ID)
            """
        case "browser":
            return """
            Usage: cmux browser [--surface <id|ref|index> | <surface>] <subcommand> [args]

            Browser automation commands. Most subcommands require a surface handle.
            A surface can be passed as `--surface <handle>` or as the first positional token.
            `open`/`open-split`/`new`/`identify` can run without an explicit surface.

            Subcommands:
              open|open-split|new [url] [--workspace <id|ref|index>] [--window <id|ref|index>]
                open/open-split/new default to $CMUX_WORKSPACE_ID when --workspace is omitted and --window is not set
              goto|navigate <url> [--snapshot-after]
              back|forward|reload [--snapshot-after]
              url|get-url
              focus-webview | is-webview-focused
              snapshot [--interactive|-i] [--cursor] [--compact] [--max-depth <n>] [--selector <css>]
              eval [--script <js> | <js>]
              wait [--selector <css>] [--text <text>] [--url-contains <text>|--url <text>] [--load-state <interactive|complete>] [--function <js>] [--timeout-ms <ms>|--timeout <seconds>]
              click|dblclick|hover|focus|check|uncheck|scroll-into-view [--selector <css> | <css>] [--snapshot-after]
              type|fill [--selector <css> | <css>] [--text <text> | <text>] [--snapshot-after]
              press|key|keydown|keyup [--key <key> | <key>] [--snapshot-after]
              select [--selector <css> | <css>] [--value <value> | <value>] [--snapshot-after]
              scroll [--selector <css>] [--dx <n>] [--dy <n>] [--snapshot-after]
              screenshot [--out <path>]
              get <url|title|text|html|value|attr|count|box|styles> [...]
                text|html|value|count|box|styles|attr: [--selector <css> | <css>]
                attr: [--attr <name> | <name>]
                styles: [--property <name>]
              is <visible|enabled|checked> [--selector <css> | <css>]
              find <role|text|label|placeholder|alt|title|testid|first|last|nth> [...]
                role: [--name <text>] [--exact] <role>
                text|label|placeholder|alt|title|testid: [--exact] <text>
                first|last: [--selector <css> | <css>]
                nth: [--index <n> | <n>] [--selector <css> | <css>]
              frame <main|selector> [--selector <css>]
              dialog <accept|dismiss> [text]
              download [wait] [--path <path>] [--timeout-ms <ms>|--timeout <seconds>]
              cookies <get|set|clear> [--name <name>] [--value <value>] [--url <url>] [--domain <domain>] [--path <path>] [--expires <unix>] [--secure] [--all]
              storage <local|session> <get|set|clear> [...]
              tab <new|list|switch|close|<index>> [...]
              console <list|clear>
              errors <list|clear>
              highlight [--selector <css> | <css>]
              state <save|load> <path>
              addinitscript|addscript [--script <js> | <js>]
              addstyle [--css <css> | <css>]
              viewport <width> <height>
              geolocation|geo <latitude> <longitude>
              offline <true|false>
              trace <start|stop> [path]
              network <route|unroute|requests> ...
                route <pattern> [--abort] [--body <text>]
                unroute <pattern>
              screencast <start|stop>
              input <mouse|keyboard|touch> [args...]
              input_mouse | input_keyboard | input_touch
              identify [--surface <id|ref|index>]

            Example:
              cmux browser open https://example.com
              cmux browser surface:1 navigate https://google.com
              cmux browser --surface surface:1 snapshot --interactive
            """
        // Legacy browser aliases — point users to `cmux browser --help`
        case "open-browser":
            return "Legacy alias for 'cmux browser open'. Run 'cmux browser --help' for details."
        case "navigate":
            return "Legacy alias for 'cmux browser navigate'. Run 'cmux browser --help' for details."
        case "browser-back":
            return "Legacy alias for 'cmux browser back'. Run 'cmux browser --help' for details."
        case "browser-forward":
            return "Legacy alias for 'cmux browser forward'. Run 'cmux browser --help' for details."
        case "browser-reload":
            return "Legacy alias for 'cmux browser reload'. Run 'cmux browser --help' for details."
        case "get-url":
            return "Legacy alias for 'cmux browser get-url'. Run 'cmux browser --help' for details."
        case "focus-webview":
            return "Legacy alias for 'cmux browser focus-webview'. Run 'cmux browser --help' for details."
        case "is-webview-focused":
            return "Legacy alias for 'cmux browser is-webview-focused'. Run 'cmux browser --help' for details."
        case "markdown":
            return """
            Usage: cmux markdown open <path> [options]
                   cmux markdown <path>       (shorthand for 'open')

            Open a markdown file in a formatted viewer panel with live file watching.
            The file is rendered with rich formatting (headings, code blocks, tables,
            lists, blockquotes) and automatically updates when the file changes on disk.

            Options:
              --workspace <id|ref|index>   Target workspace (default: $CMUX_WORKSPACE_ID)
              --surface <id|ref|index>     Source surface to split from (default: focused surface)
              --window <id|ref|index>      Target window
              --direction <left|right|up|down>  Split direction (default: right)

            Examples:
              cmux markdown open plan.md
              cmux markdown ~/project/CHANGELOG.md
              cmux markdown open ./docs/design.md --workspace 0
              cmux markdown open plan.md --direction down
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

    private static let cmuxThemeOverrideBundleIdentifier = "com.cmuxterm.app"
    private static let cmuxThemesBlockStart = "# cmux themes start"
    private static let cmuxThemesBlockEnd = "# cmux themes end"
    private static let cmuxThemesReloadNotificationName = "com.cmuxterm.themes.reload-config"

    private struct ThemeSelection {
        let rawValue: String?
        let light: String?
        let dark: String?
        let sourcePath: String?
    }

    private struct ThemeReloadStatus {
        let requested: Bool
        let targetBundleIdentifier: String
    }

    private enum ThemePickerTargetMode: String {
        case both
        case light
        case dark
    }

    private func shouldUseInteractiveThemePicker(jsonOutput: Bool) -> Bool {
        guard !jsonOutput else { return false }
        return isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1
    }

    private func runInteractiveThemes() throws {
        guard let helperURL = bundledHelperURL(named: "ghostty") else {
            throw CLIError(message: "Bundled Ghostty theme picker helper not found")
        }

        let selection = currentThemeSelection()
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_THEME_PICKER_CONFIG"] = try cmuxThemeOverrideConfigURL().path
        environment["CMUX_THEME_PICKER_BUNDLE_ID"] = currentCmuxAppBundleIdentifier() ?? Self.cmuxThemeOverrideBundleIdentifier
        environment["CMUX_THEME_PICKER_TARGET"] = defaultThemePickerTargetMode(current: selection).rawValue
        environment["CMUX_THEME_PICKER_COLOR_SCHEME"] = defaultAppearancePrefersDarkThemes() ? "dark" : "light"
        if let light = selection.light {
            environment["CMUX_THEME_PICKER_INITIAL_LIGHT"] = light
        }
        if let dark = selection.dark {
            environment["CMUX_THEME_PICKER_INITIAL_DARK"] = dark
        }
        if let resourcesURL = bundledGhosttyResourcesURL() {
            environment["GHOSTTY_RESOURCES_DIR"] = resourcesURL.path
        }

        try execInteractiveHelper(
            executablePath: helperURL.path,
            arguments: ["+list-themes"],
            environment: environment
        )
    }

    private func defaultThemePickerTargetMode(current: ThemeSelection) -> ThemePickerTargetMode {
        if let light = current.light,
           let dark = current.dark,
           light.caseInsensitiveCompare(dark) == .orderedSame {
            return .both
        }
        return defaultAppearancePrefersDarkThemes() ? .dark : .light
    }

    private func defaultAppearancePrefersDarkThemes() -> Bool {
        let globalDefaults = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)
        let interfaceStyle = (globalDefaults?["AppleInterfaceStyle"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return interfaceStyle?.caseInsensitiveCompare("Dark") == .orderedSame
    }

    private func bundledHelperURL(named helperName: String) -> URL? {
        let fileManager = FileManager.default
        guard let executableURL = resolvedExecutableURL() else { return nil }

        var candidates: [URL] = [
            executableURL.deletingLastPathComponent().appendingPathComponent(helperName, isDirectory: false)
        ]

        var current = executableURL.deletingLastPathComponent().standardizedFileURL
        while true {
            if current.lastPathComponent == "Contents" {
                candidates.append(
                    current
                        .appendingPathComponent("Resources", isDirectory: true)
                        .appendingPathComponent("bin", isDirectory: true)
                        .appendingPathComponent(helperName, isDirectory: false)
                )
            }

            let projectMarker = current.appendingPathComponent("GhosttyTabs.xcodeproj/project.pbxproj", isDirectory: false)
            let repoHelper = current
                .appendingPathComponent("ghostty", isDirectory: true)
                .appendingPathComponent("zig-out", isDirectory: true)
                .appendingPathComponent("bin", isDirectory: true)
                .appendingPathComponent(helperName, isDirectory: false)
            if fileManager.fileExists(atPath: projectMarker.path),
               fileManager.isExecutableFile(atPath: repoHelper.path) {
                candidates.append(repoHelper)
                break
            }

            guard let parent = parentSearchURL(for: current) else { break }
            current = parent
        }

        return candidates.first(where: { fileManager.isExecutableFile(atPath: $0.path) })
    }

    private func execInteractiveHelper(
        executablePath: String,
        arguments: [String],
        environment: [String: String]
    ) throws -> Never {
        var argv = ([executablePath] + arguments).map { strdup($0) }
        defer {
            for item in argv {
                free(item)
            }
        }
        argv.append(nil)

        var envp = environment
            .map { key, value in strdup("\(key)=\(value)") }
        defer {
            for item in envp {
                free(item)
            }
        }
        envp.append(nil)

        execve(executablePath, &argv, &envp)
        let code = errno
        throw CLIError(message: "Failed to launch interactive theme picker: \(String(cString: strerror(code)))")
    }

    private func bundledGhosttyResourcesURL() -> URL? {
        let fileManager = FileManager.default
        guard let executableURL = resolvedExecutableURL() else { return nil }

        var current = executableURL.deletingLastPathComponent().standardizedFileURL
        while true {
            if current.lastPathComponent == "Contents" {
                let candidate = current
                    .appendingPathComponent("Resources", isDirectory: true)
                    .appendingPathComponent("ghostty", isDirectory: true)
                if fileManager.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }

            let projectMarker = current.appendingPathComponent("GhosttyTabs.xcodeproj/project.pbxproj", isDirectory: false)
            let repoResources = current
                .appendingPathComponent("Resources", isDirectory: true)
                .appendingPathComponent("ghostty", isDirectory: true)
            if fileManager.fileExists(atPath: projectMarker.path),
               fileManager.fileExists(atPath: repoResources.path) {
                return repoResources
            }

            guard let parent = parentSearchURL(for: current) else { break }
            current = parent
        }

        return Bundle.main.resourceURL?.appendingPathComponent("ghostty", isDirectory: true)
    }

    private func runThemes(commandArgs: [String], jsonOutput: Bool) throws {
        if commandArgs.isEmpty {
            if shouldUseInteractiveThemePicker(jsonOutput: jsonOutput) {
                try runInteractiveThemes()
                return
            }
            try printThemesList(jsonOutput: jsonOutput)
            return
        }

        guard let subcommand = commandArgs.first else {
            try printThemesList(jsonOutput: jsonOutput)
            return
        }

        switch subcommand {
        case "list":
            if commandArgs.count > 1 {
                throw CLIError(message: "themes list does not take any positional arguments")
            }
            try printThemesList(jsonOutput: jsonOutput)
        case "set":
            try runThemesSet(
                args: Array(commandArgs.dropFirst()),
                jsonOutput: jsonOutput
            )
        case "clear":
            if commandArgs.count > 1 {
                throw CLIError(message: "themes clear does not take any positional arguments")
            }
            try runThemesClear(jsonOutput: jsonOutput)
        default:
            if subcommand.hasPrefix("-") {
                throw CLIError(message: "Unknown themes subcommand '\(subcommand)'. Run 'cmux themes --help'.")
            }

            try runThemesSet(
                args: commandArgs,
                jsonOutput: jsonOutput
            )
        }
    }

    private func printThemesList(jsonOutput: Bool) throws {
        let themes = availableThemeNames()
        let current = currentThemeSelection()
        let configPath = try cmuxThemeOverrideConfigURL().path

        if jsonOutput {
            let currentPayload: [String: Any] = [
                "raw_value": current.rawValue ?? NSNull(),
                "light": current.light ?? NSNull(),
                "dark": current.dark ?? NSNull(),
                "source_path": current.sourcePath ?? NSNull()
            ]
            let payload: [String: Any] = [
                "themes": themes.map { theme in
                    [
                        "name": theme,
                        "current_light": current.light?.caseInsensitiveCompare(theme) == .orderedSame,
                        "current_dark": current.dark?.caseInsensitiveCompare(theme) == .orderedSame
                    ]
                },
                "current": currentPayload,
                "config_path": configPath
            ]
            print(jsonString(payload))
            return
        }

        print("Current light: \(current.light ?? "inherit")")
        print("Current dark: \(current.dark ?? "inherit")")
        print("Config: \(configPath)")
        if let sourcePath = current.sourcePath {
            print("Source: \(sourcePath)")
        }
        print("")

        guard !themes.isEmpty else {
            print("No themes found.")
            return
        }

        for theme in themes {
            var badges: [String] = []
            if current.light?.caseInsensitiveCompare(theme) == .orderedSame {
                badges.append("light")
            }
            if current.dark?.caseInsensitiveCompare(theme) == .orderedSame {
                badges.append("dark")
            }
            let badgeText = badges.isEmpty ? "" : "  [\(badges.joined(separator: ", "))]"
            print("\(theme)\(badgeText)")
        }
    }

    private func runThemesSet(args: [String], jsonOutput: Bool) throws {
        let (lightOpt, rem0) = parseOption(args, name: "--light")
        let (darkOpt, rem1) = parseOption(rem0, name: "--dark")

        if let unknown = rem1.first(where: { $0.hasPrefix("--") }) {
            throw CLIError(message: "themes set: unknown flag '\(unknown)'. Known flags: --light <theme>, --dark <theme>")
        }

        let availableThemes = availableThemeNames()
        let current = currentThemeSelection()

        let lightTheme: String?
        let darkTheme: String?

        if lightOpt == nil && darkOpt == nil {
            let joinedTheme = rem1.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !joinedTheme.isEmpty else {
                throw CLIError(message: "themes set requires a theme name or --light/--dark flags")
            }
            let resolved = try validatedThemeName(joinedTheme, availableThemes: availableThemes)
            lightTheme = resolved
            darkTheme = resolved
        } else {
            if !rem1.isEmpty {
                throw CLIError(message: "themes set: unexpected argument '\(rem1.joined(separator: " "))'")
            }
            lightTheme = try lightOpt.map { try validatedThemeName($0, availableThemes: availableThemes) } ?? current.light
            darkTheme = try darkOpt.map { try validatedThemeName($0, availableThemes: availableThemes) } ?? current.dark
        }

        guard let rawThemeValue = encodedThemeValue(light: lightTheme, dark: darkTheme) else {
            throw CLIError(message: "themes set requires at least one theme")
        }

        let configURL = try writeManagedThemeOverride(rawThemeValue: rawThemeValue)
        let reloadStatus = reloadThemesIfPossible()

        if jsonOutput {
            let payload: [String: Any] = [
                "ok": true,
                "light": lightTheme ?? NSNull(),
                "dark": darkTheme ?? NSNull(),
                "raw_value": rawThemeValue,
                "config_path": configURL.path,
                "reload_requested": reloadStatus.requested,
                "reload_target_bundle_id": reloadStatus.targetBundleIdentifier
            ]
            print(jsonString(payload))
            return
        }

        print(
            "OK light=\(lightTheme ?? "-") dark=\(darkTheme ?? "-") config=\(configURL.path) reload=requested"
        )
    }

    private func runThemesClear(jsonOutput: Bool) throws {
        let configURL = try clearManagedThemeOverride()
        let reloadStatus = reloadThemesIfPossible()

        if jsonOutput {
            let payload: [String: Any] = [
                "ok": true,
                "cleared": true,
                "config_path": configURL.path,
                "reload_requested": reloadStatus.requested,
                "reload_target_bundle_id": reloadStatus.targetBundleIdentifier
            ]
            print(jsonString(payload))
            return
        }

        print("OK cleared config=\(configURL.path) reload=requested")
    }

    private func currentThemeSelection() -> ThemeSelection {
        var rawValue: String?
        var sourcePath: String?

        for url in themeConfigSearchURLs() {
            guard let contents = try? String(contentsOf: url, encoding: .utf8),
                  let nextValue = lastThemeDirective(in: contents) else {
                continue
            }
            rawValue = nextValue
            sourcePath = url.path
        }

        return parseThemeSelection(rawValue: rawValue, sourcePath: sourcePath)
    }

    private func parseThemeSelection(rawValue: String?, sourcePath: String?) -> ThemeSelection {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines), !rawValue.isEmpty else {
            return ThemeSelection(rawValue: nil, light: nil, dark: nil, sourcePath: sourcePath)
        }

        var fallbackTheme: String?
        var lightTheme: String?
        var darkTheme: String?

        for token in rawValue.split(separator: ",").map(String.init) {
            let entry = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !entry.isEmpty else { continue }

            let parts = entry.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count != 2 {
                if fallbackTheme == nil {
                    fallbackTheme = entry
                }
                continue
            }

            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }

            switch key {
            case "light":
                if lightTheme == nil {
                    lightTheme = value
                }
            case "dark":
                if darkTheme == nil {
                    darkTheme = value
                }
            default:
                if fallbackTheme == nil {
                    fallbackTheme = value
                }
            }
        }

        let resolvedLight = lightTheme ?? fallbackTheme ?? darkTheme
        let resolvedDark = darkTheme ?? fallbackTheme ?? lightTheme
        return ThemeSelection(rawValue: rawValue, light: resolvedLight, dark: resolvedDark, sourcePath: sourcePath)
    }

    private func encodedThemeValue(light: String?, dark: String?) -> String? {
        let normalizedLight = light?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedDark = dark?.trimmingCharacters(in: .whitespacesAndNewlines)

        switch (normalizedLight?.isEmpty == false ? normalizedLight : nil, normalizedDark?.isEmpty == false ? normalizedDark : nil) {
        case let (lightTheme?, darkTheme?):
            return "light:\(lightTheme),dark:\(darkTheme)"
        case let (lightTheme?, nil):
            return "light:\(lightTheme)"
        case let (nil, darkTheme?):
            return "dark:\(darkTheme)"
        case (nil, nil):
            return nil
        }
    }

    private func availableThemeNames() -> [String] {
        let fileManager = FileManager.default
        var seen: Set<String> = []
        var themes: [String] = []

        for directoryURL in themeDirectoryURLs() {
            guard let entries = try? fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for entry in entries {
                let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
                guard values?.isDirectory != true else { continue }
                guard values?.isRegularFile == true || values?.isRegularFile == nil else { continue }
                let name = entry.lastPathComponent
                let folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                if seen.insert(folded).inserted {
                    themes.append(name)
                }
            }
        }

        return themes.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private func themeDirectoryURLs() -> [URL] {
        let fileManager = FileManager.default
        let processEnv = ProcessInfo.processInfo.environment
        var urls: [URL] = []
        var seen: Set<String> = []

        func appendIfExisting(_ url: URL?) {
            guard let url else { return }
            let standardized = url.standardizedFileURL
            guard fileManager.fileExists(atPath: standardized.path) else { return }
            if seen.insert(standardized.path).inserted {
                urls.append(standardized)
            }
        }

        if let resourcesDir = processEnv["GHOSTTY_RESOURCES_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !resourcesDir.isEmpty {
            appendIfExisting(URL(fileURLWithPath: resourcesDir, isDirectory: true).appendingPathComponent("themes", isDirectory: true))
        }

        appendIfExisting(
            Bundle.main.resourceURL?
                .appendingPathComponent("ghostty", isDirectory: true)
                .appendingPathComponent("themes", isDirectory: true)
        )

        if let executableURL = resolvedExecutableURL() {
            var current = executableURL.deletingLastPathComponent().standardizedFileURL
            while true {
                if current.lastPathComponent == "Resources" {
                    appendIfExisting(
                        current
                            .appendingPathComponent("ghostty", isDirectory: true)
                            .appendingPathComponent("themes", isDirectory: true)
                    )
                }
                if current.lastPathComponent == "Contents" {
                    appendIfExisting(
                        current
                            .appendingPathComponent("Resources", isDirectory: true)
                            .appendingPathComponent("ghostty", isDirectory: true)
                            .appendingPathComponent("themes", isDirectory: true)
                    )
                }

                let projectMarker = current.appendingPathComponent("GhosttyTabs.xcodeproj/project.pbxproj", isDirectory: false)
                let repoThemes = current.appendingPathComponent("Resources/ghostty/themes", isDirectory: true)
                if fileManager.fileExists(atPath: projectMarker.path),
                   fileManager.fileExists(atPath: repoThemes.path) {
                    appendIfExisting(repoThemes)
                    break
                }

                guard let parent = parentSearchURL(for: current) else { break }
                current = parent
            }
        }

        if let xdgDataDirs = processEnv["XDG_DATA_DIRS"] {
            for dataDir in xdgDataDirs.split(separator: ":").map(String.init).filter({ !$0.isEmpty }) {
                appendIfExisting(
                    URL(fileURLWithPath: NSString(string: dataDir).expandingTildeInPath, isDirectory: true)
                        .appendingPathComponent("ghostty/themes", isDirectory: true)
                )
            }
        }

        appendIfExisting(URL(fileURLWithPath: "/Applications/Ghostty.app/Contents/Resources/ghostty/themes", isDirectory: true))
        appendIfExisting(URL(fileURLWithPath: NSString(string: "~/.config/ghostty/themes").expandingTildeInPath, isDirectory: true))
        appendIfExisting(
            URL(
                fileURLWithPath: NSString(
                    string: "~/Library/Application Support/com.mitchellh.ghostty/themes"
                ).expandingTildeInPath,
                isDirectory: true
            )
        )

        return urls
    }

    private func validatedThemeName(_ rawValue: String, availableThemes: [String]) throws -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CLIError(message: "Theme name cannot be empty")
        }
        if let matched = availableThemes.first(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return matched
        }
        if availableThemes.isEmpty {
            return trimmed
        }
        throw CLIError(message: "Unknown theme '\(trimmed)'. Run 'cmux themes' to list available themes.")
    }

    private func themeConfigSearchURLs() -> [URL] {
        let rawPaths = [
            "~/.config/ghostty/config",
            "~/.config/ghostty/config.ghostty",
            "~/Library/Application Support/com.mitchellh.ghostty/config",
            "~/Library/Application Support/com.mitchellh.ghostty/config.ghostty",
            "~/Library/Application Support/\(Self.cmuxThemeOverrideBundleIdentifier)/config",
            "~/Library/Application Support/\(Self.cmuxThemeOverrideBundleIdentifier)/config.ghostty",
        ]

        return rawPaths.map {
            URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath, isDirectory: false)
        }
    }

    private func lastThemeDirective(in contents: String) -> String? {
        var lastValue: String?

        for line in contents.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            let parts = trimmed.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            guard parts[0].trimmingCharacters(in: .whitespacesAndNewlines) == "theme" else { continue }

            let value = parts[1]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if !value.isEmpty {
                lastValue = value
            }
        }

        return lastValue
    }

    private func cmuxThemeOverrideConfigURL() throws -> URL {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw CLIError(message: "Unable to resolve Application Support directory")
        }
        return appSupport
            .appendingPathComponent(Self.cmuxThemeOverrideBundleIdentifier, isDirectory: true)
            .appendingPathComponent("config.ghostty", isDirectory: false)
    }

    private func writeManagedThemeOverride(rawThemeValue: String) throws -> URL {
        let fileManager = FileManager.default
        let configURL = try cmuxThemeOverrideConfigURL()
        let directoryURL = configURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)

        let existingContents = try readOptionalThemeOverrideContents(at: configURL) ?? ""
        let strippedContents = removingManagedThemeOverride(from: existingContents)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let block = """
        \(Self.cmuxThemesBlockStart)
        theme = \(rawThemeValue)
        \(Self.cmuxThemesBlockEnd)
        """

        let nextContents = strippedContents.isEmpty ? "\(block)\n" : "\(strippedContents)\n\n\(block)\n"
        try nextContents.write(to: configURL, atomically: true, encoding: .utf8)
        return configURL
    }

    private func clearManagedThemeOverride() throws -> URL {
        let fileManager = FileManager.default
        let configURL = try cmuxThemeOverrideConfigURL()
        guard let existingContents = try readOptionalThemeOverrideContents(at: configURL) else {
            return configURL
        }

        let strippedContents = removingManagedThemeOverride(from: existingContents)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if strippedContents.isEmpty {
            do {
                try fileManager.removeItem(at: configURL)
            } catch {
                guard !isThemeOverrideFileNotFoundError(error) else {
                    return configURL
                }
                throw error
            }
        } else {
            try strippedContents.appending("\n").write(to: configURL, atomically: true, encoding: .utf8)
        }

        return configURL
    }

    private func readOptionalThemeOverrideContents(at url: URL) throws -> String? {
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            guard isThemeOverrideFileNotFoundError(error) else {
                throw error
            }
            return nil
        }
    }

    private func isThemeOverrideFileNotFoundError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            return nsError.code == NSFileNoSuchFileError || nsError.code == NSFileReadNoSuchFileError
        }
        if nsError.domain == NSPOSIXErrorDomain {
            return nsError.code == ENOENT
        }
        return false
    }

    private func removingManagedThemeOverride(from contents: String) -> String {
        let pattern = #"(?ms)\n?# cmux themes start\n.*?\n# cmux themes end\n?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return contents
        }
        let fullRange = NSRange(contents.startIndex..<contents.endIndex, in: contents)
        return regex.stringByReplacingMatches(in: contents, options: [], range: fullRange, withTemplate: "")
    }

    private func reloadThemesIfPossible() -> ThemeReloadStatus {
        let bundleIdentifier = currentCmuxAppBundleIdentifier() ?? Self.cmuxThemeOverrideBundleIdentifier
        DistributedNotificationCenter.default().post(
            name: Notification.Name(Self.cmuxThemesReloadNotificationName),
            object: nil,
            userInfo: ["bundleIdentifier": bundleIdentifier]
        )
        return ThemeReloadStatus(requested: true, targetBundleIdentifier: bundleIdentifier)
    }

    private func currentCmuxAppBundleIdentifier() -> String? {
        if let bundleIdentifier = ProcessInfo.processInfo.environment["CMUX_BUNDLE_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !bundleIdentifier.isEmpty {
            return bundleIdentifier
        }

        if let bundleIdentifier = Bundle.main.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
           !bundleIdentifier.isEmpty {
            return bundleIdentifier
        }

        guard let executableURL = resolvedExecutableURL() else {
            return nil
        }

        var current = executableURL.deletingLastPathComponent().standardizedFileURL
        while true {
            if current.pathExtension == "app",
               let bundleIdentifier = Bundle(url: current)?.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
               !bundleIdentifier.isEmpty {
                return bundleIdentifier
            }

            if current.lastPathComponent == "Contents" {
                let appURL = current.deletingLastPathComponent().standardizedFileURL
                if appURL.pathExtension == "app",
                   let bundleIdentifier = Bundle(url: appURL)?.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !bundleIdentifier.isEmpty {
                    return bundleIdentifier
                }
            }

            guard let parent = parentSearchURL(for: current) else {
                break
            }
            current = parent
        }

        return nil
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

    private func parseRepeatedOption(_ args: [String], name: String) -> ([String], [String]) {
        var remaining: [String] = []
        var values: [String] = []
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
                values.append(args[idx + 1])
                skipNext = true
                continue
            }
            remaining.append(arg)
        }
        return (values, remaining)
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

    private func forwardSidebarMetadataCommand(
        _ socketCommand: String,
        commandArgs: [String],
        client: SocketClient,
        windowOverride: String?
    ) throws -> String {
        func insertArgumentBeforeSeparator(_ value: String, into args: inout [String]) {
            if let separatorIndex = args.firstIndex(of: "--") {
                args.insert(value, at: separatorIndex)
            } else {
                args.append(value)
            }
        }

        var forwardedArgs: [String] = []
        var resolvedExplicitWorkspace = false
        var index = 0

        while index < commandArgs.count {
            let arg = commandArgs[index]
            if arg == "--workspace", index + 1 < commandArgs.count {
                let workspaceId = try resolveWorkspaceId(commandArgs[index + 1], client: client)
                forwardedArgs.append("--tab=\(workspaceId)")
                resolvedExplicitWorkspace = true
                index += 2
                continue
            }
            if arg.hasPrefix("--workspace=") {
                let rawWorkspace = String(arg.dropFirst("--workspace=".count))
                let workspaceId = try resolveWorkspaceId(rawWorkspace, client: client)
                forwardedArgs.append("--tab=\(workspaceId)")
                resolvedExplicitWorkspace = true
                index += 1
                continue
            }
            forwardedArgs.append(arg)
            index += 1
        }

        if !resolvedExplicitWorkspace,
           let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowOverride) {
            let workspaceId = try resolveWorkspaceId(workspaceArg, client: client)
            insertArgumentBeforeSeparator("--tab=\(workspaceId)", into: &forwardedArgs)
        }

        let command = ([socketCommand] + forwardedArgs)
            .map(shellQuote)
            .joined(separator: " ")
        return try sendV1Command(command, client: client)
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

    private struct TreeCommandOptions {
        let includeAllWindows: Bool
        let workspaceHandle: String?
        let jsonOutput: Bool
    }

    private struct TreePath {
        let windowHandle: String?
        let workspaceHandle: String?
        let paneHandle: String?
        let surfaceHandle: String?
    }

    private func runTreeCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let options = try parseTreeCommandOptions(commandArgs)
        let payload = try buildTreePayload(options: options, client: client)
        if jsonOutput || options.jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
        } else {
            let windows = payload["windows"] as? [[String: Any]] ?? []
            print(renderTreeText(windows: windows, idFormat: idFormat))
        }
    }

    private func parseTreeCommandOptions(_ args: [String]) throws -> TreeCommandOptions {
        let (workspaceOpt, rem0) = parseOption(args, name: "--workspace")
        if rem0.contains("--workspace") {
            throw CLIError(message: "tree requires --workspace <id|ref|index>")
        }

        var includeAll = false
        var jsonOutput = false
        var remaining: [String] = []
        for arg in rem0 {
            if arg == "--all" {
                includeAll = true
                continue
            }
            if arg == "--json" {
                jsonOutput = true
                continue
            }
            remaining.append(arg)
        }

        if let unknown = remaining.first(where: { $0.hasPrefix("--") }) {
            throw CLIError(message: "tree: unknown flag '\(unknown)'. Known flags: --all --workspace <id|ref|index> --json")
        }
        if let extra = remaining.first {
            throw CLIError(message: "tree: unexpected argument '\(extra)'")
        }

        return TreeCommandOptions(includeAllWindows: includeAll, workspaceHandle: workspaceOpt, jsonOutput: jsonOutput)
    }

    private func buildTreePayload(
        options: TreeCommandOptions,
        client: SocketClient
    ) throws -> [String: Any] {
        var params: [String: Any] = ["all_windows": options.includeAllWindows]
        if let workspaceRaw = options.workspaceHandle {
            guard let workspaceHandle = try normalizeWorkspaceHandle(workspaceRaw, client: client) else {
                throw CLIError(message: "Invalid workspace handle")
            }
            params["workspace_id"] = workspaceHandle
        }
        if let caller = treeCallerContextFromEnvironment() {
            params["caller"] = caller
        }

        do {
            let payload = try client.sendV2(method: "system.tree", params: params)
            return treePayloadWithMarkers(payload)
        } catch let error as CLIError where error.message.hasPrefix("method_not_found:") {
            // Back-compat fallback for older servers that don't support system.tree.
            return try buildLegacyTreePayload(options: options, params: params, client: client)
        }
    }

    private func buildLegacyTreePayload(
        options: TreeCommandOptions,
        params: [String: Any],
        client: SocketClient
    ) throws -> [String: Any] {
        var identifyParams: [String: Any] = [:]
        if let caller = params["caller"] as? [String: Any], !caller.isEmpty {
            identifyParams["caller"] = caller
        }

        let identifyPayload = try client.sendV2(method: "system.identify", params: identifyParams)
        let focused = identifyPayload["focused"] as? [String: Any] ?? [:]
        let caller = identifyPayload["caller"] as? [String: Any] ?? [:]
        let activePath = parseTreePath(payload: focused)
        let windows = try buildTreeWindowNodes(options: options, activePath: activePath, client: client)

        return treePayloadWithMarkers([
            "active": focused.isEmpty ? NSNull() : focused,
            "caller": caller.isEmpty ? NSNull() : caller,
            "windows": windows
        ])
    }

    private func buildTreeWindowNodes(
        options: TreeCommandOptions,
        activePath: TreePath,
        client: SocketClient
    ) throws -> [[String: Any]] {
        let windowsPayload = try client.sendV2(method: "window.list")
        let allWindows = windowsPayload["windows"] as? [[String: Any]] ?? []

        if let workspaceRaw = options.workspaceHandle {
            guard let workspaceHandle = try normalizeWorkspaceHandle(workspaceRaw, client: client) else {
                throw CLIError(message: "Invalid workspace handle")
            }

            let workspaceListPayload = try client.sendV2(method: "workspace.list", params: ["workspace_id": workspaceHandle])
            let workspaceWindowHandle = (workspaceListPayload["window_ref"] as? String) ?? (workspaceListPayload["window_id"] as? String)
            let window = allWindows.first(where: { treeItemMatchesHandle($0, handle: workspaceWindowHandle) })
                ?? treeFallbackWindow(from: workspaceListPayload)

            let workspaces = workspaceListPayload["workspaces"] as? [[String: Any]] ?? []
            if workspaces.isEmpty {
                throw CLIError(message: "Workspace not found")
            }
            let workspaceNodes = try workspaces.map { try buildTreeWorkspaceNode(workspace: $0, activePath: activePath, client: client) }
            var node = window
            let isActiveWindow = treeItemMatchesHandle(node, handle: activePath.windowHandle)
            node["current"] = isActiveWindow
            node["active"] = isActiveWindow
            node["workspaces"] = workspaceNodes
            node["workspace_count"] = workspaceNodes.count
            return [node]
        }

        let targetWindows: [[String: Any]]
        if options.includeAllWindows {
            targetWindows = allWindows
        } else if let currentWindowHandle = activePath.windowHandle {
            let currentOnly = allWindows.filter { treeItemMatchesHandle($0, handle: currentWindowHandle) }
            targetWindows = currentOnly.isEmpty ? Array(allWindows.prefix(1)) : currentOnly
        } else {
            targetWindows = Array(allWindows.prefix(1))
        }

        return try targetWindows.map {
            try buildTreeWindowNode(
                window: $0,
                activePath: activePath,
                client: client
            )
        }
    }

    private func treeFallbackWindow(from payload: [String: Any]) -> [String: Any] {
        let workspaces = payload["workspaces"] as? [[String: Any]] ?? []
        let selectedWorkspace = workspaces.first(where: { ($0["selected"] as? Bool) == true })
        return [
            "id": payload["window_id"] ?? NSNull(),
            "ref": payload["window_ref"] ?? NSNull(),
            "index": 0,
            "key": false,
            "visible": true,
            "workspace_count": workspaces.count,
            "selected_workspace_id": selectedWorkspace?["id"] ?? NSNull(),
            "selected_workspace_ref": selectedWorkspace?["ref"] ?? NSNull(),
        ]
    }

    private func buildTreeWindowNode(
        window: [String: Any],
        activePath: TreePath,
        client: SocketClient
    ) throws -> [String: Any] {
        var workspaceParams: [String: Any] = [:]
        if let windowHandle = treeItemHandle(window) {
            workspaceParams["window_id"] = windowHandle
        }
        let workspacePayload = try client.sendV2(method: "workspace.list", params: workspaceParams)
        let workspaces = workspacePayload["workspaces"] as? [[String: Any]] ?? []
        let workspaceNodes = try workspaces.map { try buildTreeWorkspaceNode(workspace: $0, activePath: activePath, client: client) }
        var windowNode = window
        let isActiveWindow = treeItemMatchesHandle(windowNode, handle: activePath.windowHandle)
        windowNode["current"] = isActiveWindow
        windowNode["active"] = isActiveWindow
        windowNode["workspaces"] = workspaceNodes
        windowNode["workspace_count"] = workspaceNodes.count
        return windowNode
    }

    private func buildTreeWorkspaceNode(
        workspace: [String: Any],
        activePath: TreePath,
        client: SocketClient
    ) throws -> [String: Any] {
        var workspaceNode = workspace
        guard let workspaceHandle = treeItemHandle(workspace) else {
            workspaceNode["panes"] = []
            return workspaceNode
        }

        let panePayload = try client.sendV2(method: "pane.list", params: ["workspace_id": workspaceHandle])
        let surfacePayload = try client.sendV2(method: "surface.list", params: ["workspace_id": workspaceHandle])
        let panes = panePayload["panes"] as? [[String: Any]] ?? []
        let surfaces = surfacePayload["surfaces"] as? [[String: Any]] ?? []
        let browserURLsByHandle = fetchTreeBrowserURLs(
            workspaceHandle: workspaceHandle,
            surfaces: surfaces,
            client: client
        )

        var surfacesByPane: [String: [[String: Any]]] = [:]
        for surface in surfaces {
            var surfaceNode = surface
            if surfaceNode["selected"] == nil {
                surfaceNode["selected"] = (surfaceNode["selected_in_pane"] as? Bool) == true
            }
            surfaceNode["active"] = treeItemMatchesHandle(surfaceNode, handle: activePath.surfaceHandle)

            let surfaceType = ((surfaceNode["type"] as? String) ?? "").lowercased()
            if surfaceType == "browser",
               let url = treeBrowserURL(surface: surfaceNode, urlsByHandle: browserURLsByHandle),
               !url.isEmpty {
                surfaceNode["url"] = url
            } else {
                surfaceNode["url"] = NSNull()
            }

            guard let paneHandle = treeRelatedHandle(surfaceNode, refKey: "pane_ref", idKey: "pane_id") else {
                continue
            }
            surfacesByPane[paneHandle, default: []].append(surfaceNode)
        }

        for paneHandle in surfacesByPane.keys {
            surfacesByPane[paneHandle]?.sort {
                let lhs = intFromAny($0["index_in_pane"]) ?? intFromAny($0["index"]) ?? Int.max
                let rhs = intFromAny($1["index_in_pane"]) ?? intFromAny($1["index"]) ?? Int.max
                return lhs < rhs
            }
        }

        let paneNodes: [[String: Any]] = panes.map { pane in
            var paneNode = pane
            paneNode["active"] = treeItemMatchesHandle(paneNode, handle: activePath.paneHandle)
            if let paneHandle = treeItemHandle(paneNode) {
                paneNode["surfaces"] = surfacesByPane[paneHandle] ?? []
            } else {
                paneNode["surfaces"] = []
            }
            return paneNode
        }

        workspaceNode["active"] = treeItemMatchesHandle(workspaceNode, handle: activePath.workspaceHandle)
        workspaceNode["panes"] = paneNodes
        return workspaceNode
    }

    private func treeItemHandle(_ item: [String: Any]) -> String? {
        if let ref = item["ref"] as? String, !ref.isEmpty {
            return ref
        }
        if let id = item["id"] as? String, !id.isEmpty {
            return id
        }
        return nil
    }

    private func treeRelatedHandle(_ item: [String: Any], refKey: String, idKey: String) -> String? {
        if let ref = item[refKey] as? String, !ref.isEmpty {
            return ref
        }
        if let id = item[idKey] as? String, !id.isEmpty {
            return id
        }
        return nil
    }

    private func parseTreePath(payload: [String: Any]) -> TreePath {
        return TreePath(
            windowHandle: treeRelatedHandle(payload, refKey: "window_ref", idKey: "window_id"),
            workspaceHandle: treeRelatedHandle(payload, refKey: "workspace_ref", idKey: "workspace_id"),
            paneHandle: treeRelatedHandle(payload, refKey: "pane_ref", idKey: "pane_id"),
            surfaceHandle: treeRelatedHandle(payload, refKey: "surface_ref", idKey: "surface_id")
        )
    }

    private func treeCallerContextFromEnvironment() -> [String: Any]? {
        let env = ProcessInfo.processInfo.environment
        let workspaceRaw = env["CMUX_WORKSPACE_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let surfaceRaw = env["CMUX_SURFACE_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        var caller: [String: Any] = [:]
        if let workspaceRaw, !workspaceRaw.isEmpty {
            caller["workspace_id"] = workspaceRaw
        }
        if let surfaceRaw, !surfaceRaw.isEmpty {
            caller["surface_id"] = surfaceRaw
        }
        return caller.isEmpty ? nil : caller
    }

    private func treePayloadWithMarkers(_ payload: [String: Any]) -> [String: Any] {
        let active = payload["active"] as? [String: Any] ?? [:]
        let caller = payload["caller"] as? [String: Any] ?? [:]
        let activePath = parseTreePath(payload: active)
        let callerPath = parseTreePath(payload: caller)
        var result = payload
        let windows = payload["windows"] as? [[String: Any]] ?? []
        result["windows"] = treeApplyMarkers(windows: windows, activePath: activePath, callerPath: callerPath)
        if result["active"] == nil {
            result["active"] = active.isEmpty ? NSNull() : active
        }
        if result["caller"] == nil {
            result["caller"] = caller.isEmpty ? NSNull() : caller
        }
        return result
    }

    private func treeApplyMarkers(
        windows: [[String: Any]],
        activePath: TreePath,
        callerPath: TreePath
    ) -> [[String: Any]] {
        return windows.map { window in
            var windowNode = window
            let isActiveWindow = treeItemMatchesHandle(windowNode, handle: activePath.windowHandle)
            windowNode["current"] = isActiveWindow
            windowNode["active"] = isActiveWindow

            let workspaces = window["workspaces"] as? [[String: Any]] ?? []
            let workspaceNodes = workspaces.map { workspace in
                var workspaceNode = workspace
                workspaceNode["active"] = treeItemMatchesHandle(workspaceNode, handle: activePath.workspaceHandle)

                let panes = workspace["panes"] as? [[String: Any]] ?? []
                let paneNodes = panes.map { pane in
                    var paneNode = pane
                    paneNode["active"] = treeItemMatchesHandle(paneNode, handle: activePath.paneHandle)

                    let surfaces = pane["surfaces"] as? [[String: Any]] ?? []
                    paneNode["surfaces"] = surfaces.map { surface in
                        var surfaceNode = surface
                        surfaceNode["active"] = treeItemMatchesHandle(surfaceNode, handle: activePath.surfaceHandle)
                        surfaceNode["here"] = treeItemMatchesHandle(surfaceNode, handle: callerPath.surfaceHandle)
                        return surfaceNode
                    }
                    return paneNode
                }

                workspaceNode["panes"] = paneNodes
                return workspaceNode
            }

            windowNode["workspaces"] = workspaceNodes
            return windowNode
        }
    }

    private func fetchTreeBrowserURLs(
        workspaceHandle: String,
        surfaces: [[String: Any]],
        client: SocketClient
    ) -> [String: String] {
        let hasBrowserSurfaces = surfaces.contains {
            (($0["type"] as? String) ?? "").lowercased() == "browser"
        }
        guard hasBrowserSurfaces else { return [:] }

        if let payload = try? client.sendV2(
            method: "browser.tab.list",
            params: ["workspace_id": workspaceHandle]
        ) {
            let tabs = payload["tabs"] as? [[String: Any]] ?? []
            var urlByHandle: [String: String] = [:]
            for tab in tabs {
                guard let url = tab["url"] as? String, !url.isEmpty else { continue }
                if let id = tab["id"] as? String, !id.isEmpty {
                    urlByHandle[id] = url
                }
                if let ref = tab["ref"] as? String, !ref.isEmpty {
                    urlByHandle[ref] = url
                }
            }
            return urlByHandle
        }

        // Fallback for older servers that may not support browser.tab.list.
        var fallbackURLs: [String: String] = [:]
        for surface in surfaces {
            guard ((surface["type"] as? String) ?? "").lowercased() == "browser" else { continue }
            guard let surfaceHandle = treeItemHandle(surface) else { continue }
            guard let payload = try? client.sendV2(
                method: "browser.url.get",
                params: ["workspace_id": workspaceHandle, "surface_id": surfaceHandle]
            ),
            let url = payload["url"] as? String,
            !url.isEmpty else {
                continue
            }
            fallbackURLs[surfaceHandle] = url
            if let id = surface["id"] as? String, !id.isEmpty {
                fallbackURLs[id] = url
            }
            if let ref = surface["ref"] as? String, !ref.isEmpty {
                fallbackURLs[ref] = url
            }
        }
        return fallbackURLs
    }

    private func treeBrowserURL(surface: [String: Any], urlsByHandle: [String: String]) -> String? {
        if let id = surface["id"] as? String, let url = urlsByHandle[id] {
            return url
        }
        if let ref = surface["ref"] as? String, let url = urlsByHandle[ref] {
            return url
        }
        if let handle = treeItemHandle(surface), let url = urlsByHandle[handle] {
            return url
        }
        return nil
    }

    private func treeItemMatchesHandle(_ item: [String: Any], handle: String?) -> Bool {
        guard let handle = handle?.trimmingCharacters(in: .whitespacesAndNewlines), !handle.isEmpty else {
            return false
        }
        return (item["id"] as? String) == handle || (item["ref"] as? String) == handle
    }

    private func renderTreeText(windows: [[String: Any]], idFormat: CLIIDFormat) -> String {
        guard !windows.isEmpty else { return "No windows" }

        var lines: [String] = []
        for window in windows {
            lines.append(treeWindowLabel(window, idFormat: idFormat))

            let workspaces = window["workspaces"] as? [[String: Any]] ?? []
            for (workspaceIndex, workspace) in workspaces.enumerated() {
                let workspaceIsLast = workspaceIndex == workspaces.count - 1
                let workspaceBranch = workspaceIsLast ? "└── " : "├── "
                let workspaceIndent = workspaceIsLast ? "    " : "│   "
                lines.append("\(workspaceBranch)\(treeWorkspaceLabel(workspace, idFormat: idFormat))")

                let panes = workspace["panes"] as? [[String: Any]] ?? []
                for (paneIndex, pane) in panes.enumerated() {
                    let paneIsLast = paneIndex == panes.count - 1
                    let paneBranch = paneIsLast ? "└── " : "├── "
                    let paneIndent = paneIsLast ? "    " : "│   "
                    lines.append("\(workspaceIndent)\(paneBranch)\(treePaneLabel(pane, idFormat: idFormat))")

                    let surfaces = pane["surfaces"] as? [[String: Any]] ?? []
                    for (surfaceIndex, surface) in surfaces.enumerated() {
                        let surfaceIsLast = surfaceIndex == surfaces.count - 1
                        let surfaceBranch = surfaceIsLast ? "└── " : "├── "
                        lines.append("\(workspaceIndent)\(paneIndent)\(surfaceBranch)\(treeSurfaceLabel(surface, idFormat: idFormat))")
                    }
                }
            }
        }

        return lines.joined(separator: "\n")
    }

    private func treeWindowLabel(_ window: [String: Any], idFormat: CLIIDFormat) -> String {
        var parts = ["window \(textHandle(window, idFormat: idFormat))"]
        if (window["current"] as? Bool) == true {
            parts.append("[current]")
        }
        if (window["active"] as? Bool) == true {
            parts.append("◀ active")
        }
        return parts.joined(separator: " ")
    }

    private func treeWorkspaceLabel(_ workspace: [String: Any], idFormat: CLIIDFormat) -> String {
        var parts = ["workspace \(textHandle(workspace, idFormat: idFormat))"]
        let title = (workspace["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !title.isEmpty {
            parts.append("\"\(title)\"")
        }
        if (workspace["selected"] as? Bool) == true {
            parts.append("[selected]")
        }
        if (workspace["active"] as? Bool) == true {
            parts.append("◀ active")
        }
        return parts.joined(separator: " ")
    }

    private func treePaneLabel(_ pane: [String: Any], idFormat: CLIIDFormat) -> String {
        var parts = ["pane \(textHandle(pane, idFormat: idFormat))"]
        if (pane["focused"] as? Bool) == true {
            parts.append("[focused]")
        }
        if (pane["active"] as? Bool) == true {
            parts.append("◀ active")
        }
        return parts.joined(separator: " ")
    }

    private func treeSurfaceLabel(_ surface: [String: Any], idFormat: CLIIDFormat) -> String {
        let rawType = ((surface["type"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let surfaceType = rawType.isEmpty ? "unknown" : rawType
        var parts = ["surface \(textHandle(surface, idFormat: idFormat))", "[\(surfaceType)]"]
        let title = (surface["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !title.isEmpty {
            parts.append("\"\(title)\"")
        }
        if (surface["selected"] as? Bool) == true {
            parts.append("[selected]")
        }
        if (surface["active"] as? Bool) == true {
            parts.append("◀ active")
        }
        if (surface["here"] as? Bool) == true {
            parts.append("◀ here")
        }
        if let tty = surface["tty"] as? String, !tty.isEmpty {
            parts.append("tty=\(tty)")
        }
        if surfaceType.lowercased() == "browser",
           let url = surface["url"] as? String,
           !url.isEmpty {
            parts.append(url)
        }
        return parts.joined(separator: " ")
    }

    private func isUUID(_ value: String) -> Bool {
        return UUID(uuidString: value) != nil
    }

    private func jsonString(_ object: Any) -> String {
        var options: JSONSerialization.WritingOptions = [.prettyPrinted]
        options.insert(.withoutEscapingSlashes)
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: options),
              let output = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return output
    }

    private func parseRPCParams(_ args: [String]) throws -> [String: Any] {
        guard !args.isEmpty else { return [:] }
        let raw = args.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return [:] }
        guard let data = raw.data(using: .utf8) else {
            throw CLIError(message: "rpc params must be valid UTF-8 JSON")
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw CLIError(message: "rpc params must be valid JSON: \(error.localizedDescription)")
        }
        guard let params = object as? [String: Any] else {
            throw CLIError(message: "rpc params must be a JSON object")
        }
        return params
    }

    private struct TmuxParsedArguments {
        var flags: Set<String> = []
        var options: [String: [String]] = [:]
        var positional: [String] = []

        func hasFlag(_ flag: String) -> Bool {
            flags.contains(flag)
        }

        func value(_ flag: String) -> String? {
            options[flag]?.last
        }
    }

    private func parseTmuxArguments(
        _ args: [String],
        valueFlags: Set<String>,
        boolFlags: Set<String>
    ) throws -> TmuxParsedArguments {
        var parsed = TmuxParsedArguments()
        var index = 0
        var pastTerminator = false

        while index < args.count {
            let arg = args[index]
            if pastTerminator {
                parsed.positional.append(arg)
                index += 1
                continue
            }
            if arg == "--" {
                pastTerminator = true
                index += 1
                continue
            }
            if !arg.hasPrefix("-") || arg == "-" {
                parsed.positional.append(arg)
                index += 1
                continue
            }
            if arg.hasPrefix("--") {
                parsed.positional.append(arg)
                index += 1
                continue
            }

            let cluster = Array(arg.dropFirst())
            var cursor = 0
            var recognizedArgument = false
            while cursor < cluster.count {
                let flag = "-" + String(cluster[cursor])
                if boolFlags.contains(flag) {
                    parsed.flags.insert(flag)
                    cursor += 1
                    recognizedArgument = true
                    continue
                }
                if valueFlags.contains(flag) {
                    let remainder = String(cluster.dropFirst(cursor + 1))
                    let value: String
                    if !remainder.isEmpty {
                        value = remainder
                    } else {
                        guard index + 1 < args.count else {
                            throw CLIError(message: "\(flag) requires a value")
                        }
                        index += 1
                        value = args[index]
                    }
                    parsed.options[flag, default: []].append(value)
                    recognizedArgument = true
                    cursor = cluster.count
                    continue
                }

                recognizedArgument = false
                break
            }

            if !recognizedArgument {
                parsed.positional.append(arg)
            }
            index += 1
        }

        return parsed
    }

    private func splitTmuxCommand(_ args: [String]) throws -> (command: String, args: [String]) {
        var index = 0
        let globalValueFlags: Set<String> = ["-L", "-S", "-f"]
        let globalBoolFlags: Set<String> = ["-V", "-v"]

        while index < args.count {
            let arg = args[index]
            if !arg.hasPrefix("-") || arg == "-" {
                return (arg.lowercased(), Array(args.dropFirst(index + 1)))
            }
            if arg == "--" {
                break
            }
            // Handle -V (version) as a pseudo-command
            if globalBoolFlags.contains(arg) {
                return (arg, [])
            }
            if let flag = globalValueFlags.first(where: { arg == $0 || arg.hasPrefix($0) }) {
                if arg == flag {
                    index += 1
                }
            }
            index += 1
        }

        throw CLIError(message: "tmux shim requires a command")
    }

    private func normalizedTmuxTarget(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func tmuxWindowSelector(from raw: String?) -> String? {
        guard let trimmed = normalizedTmuxTarget(raw) else { return nil }
        if trimmed.hasPrefix("%") || trimmed.hasPrefix("pane:") {
            return nil
        }
        if let dot = trimmed.lastIndex(of: ".") {
            return String(trimmed[..<dot])
        }
        return trimmed
    }

    private func tmuxPaneSelector(from raw: String?) -> String? {
        guard let trimmed = normalizedTmuxTarget(raw) else { return nil }
        if trimmed.hasPrefix("%") {
            return String(trimmed.dropFirst())
        }
        if trimmed.hasPrefix("pane:") {
            return trimmed
        }
        if let dot = trimmed.lastIndex(of: ".") {
            return String(trimmed[trimmed.index(after: dot)...])
        }
        return nil
    }

    private func tmuxWorkspaceItems(client: SocketClient) throws -> [[String: Any]] {
        let payload = try client.sendV2(method: "workspace.list")
        return payload["workspaces"] as? [[String: Any]] ?? []
    }

    private func tmuxCallerWorkspaceHandle() -> String? {
        normalizedTmuxTarget(ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"])
    }

    private func tmuxCallerPaneHandle() -> String? {
        guard let pane = normalizedTmuxTarget(ProcessInfo.processInfo.environment["TMUX_PANE"])
            ?? normalizedTmuxTarget(ProcessInfo.processInfo.environment["CMUX_PANE_ID"]) else {
            return nil
        }
        return pane.hasPrefix("%") ? String(pane.dropFirst()) : pane
    }

    private func tmuxCallerSurfaceHandle() -> String? {
        normalizedTmuxTarget(ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"])
    }

    private func tmuxResolvedCallerWorkspaceId(client: SocketClient) -> String? {
        guard let callerWorkspace = tmuxCallerWorkspaceHandle() else {
            return nil
        }
        return try? resolveWorkspaceId(callerWorkspace, client: client)
    }

    private func tmuxCanonicalPaneId(
        _ handle: String,
        workspaceId: String,
        client: SocketClient
    ) throws -> String {
        if isUUID(handle) {
            return handle
        }

        let payload = try client.sendV2(method: "pane.list", params: ["workspace_id": workspaceId])
        let panes = payload["panes"] as? [[String: Any]] ?? []
        for pane in panes {
            if (pane["ref"] as? String) == handle || (pane["id"] as? String) == handle {
                if let id = pane["id"] as? String {
                    return id
                }
            }
        }

        if let index = Int(handle) {
            for pane in panes where intFromAny(pane["index"]) == index {
                if let id = pane["id"] as? String {
                    return id
                }
            }
        }

        throw CLIError(message: "Pane target not found")
    }

    private func tmuxCanonicalSurfaceId(
        _ handle: String,
        workspaceId: String,
        client: SocketClient
    ) throws -> String {
        let payload = try client.sendV2(method: "surface.list", params: ["workspace_id": workspaceId])
        let surfaces = payload["surfaces"] as? [[String: Any]] ?? []
        for surface in surfaces {
            if (surface["ref"] as? String) == handle || (surface["id"] as? String) == handle {
                if let id = surface["id"] as? String {
                    return id
                }
            }
        }

        if let index = Int(handle) {
            for surface in surfaces where intFromAny(surface["index"]) == index {
                if let id = surface["id"] as? String {
                    return id
                }
            }
        }

        throw CLIError(message: "Surface target not found")
    }

    private func tmuxWorkspaceIdForPaneHandle(_ handle: String, client: SocketClient) throws -> String? {
        guard isUUID(handle) || isHandleRef(handle) else {
            return nil
        }

        let workspaces = try tmuxWorkspaceItems(client: client)
        for workspace in workspaces {
            guard let workspaceId = workspace["id"] as? String else { continue }
            let payload = try client.sendV2(method: "pane.list", params: ["workspace_id": workspaceId])
            let panes = payload["panes"] as? [[String: Any]] ?? []
            if panes.contains(where: { ($0["id"] as? String) == handle || ($0["ref"] as? String) == handle }) {
                return workspaceId
            }
        }

        return nil
    }

    private func tmuxFocusedPaneId(workspaceId: String, client: SocketClient) throws -> String {
        let payload = try client.sendV2(method: "surface.current", params: ["workspace_id": workspaceId])
        if let paneId = payload["pane_id"] as? String {
            return paneId
        }
        if let paneRef = payload["pane_ref"] as? String {
            return try tmuxCanonicalPaneId(paneRef, workspaceId: workspaceId, client: client)
        }
        throw CLIError(message: "Pane target not found")
    }

    private func tmuxResolveWorkspaceTarget(_ raw: String?, client: SocketClient) throws -> String {
        guard var token = normalizedTmuxTarget(raw) else {
            if let callerWorkspace = tmuxCallerWorkspaceHandle() {
                return try resolveWorkspaceId(callerWorkspace, client: client)
            }
            return try resolveWorkspaceId(nil, client: client)
        }

        if token == "!" || token == "^" || token == "-" {
            let payload = try client.sendV2(method: "workspace.last")
            if let workspaceId = payload["workspace_id"] as? String {
                return workspaceId
            }
            throw CLIError(message: "Previous workspace not found")
        }

        if let dot = token.lastIndex(of: ".") {
            token = String(token[..<dot])
        }
        if let colon = token.lastIndex(of: ":") {
            let suffix = token[token.index(after: colon)...]
            token = suffix.isEmpty ? String(token[..<colon]) : String(suffix)
        }
        if token.hasPrefix("@") {
            token = String(token.dropFirst())
        }

        if let resolvedHandle = try? normalizeWorkspaceHandle(token, client: client, allowCurrent: true) {
            return try resolveWorkspaceId(resolvedHandle, client: client)
        }

        let needle = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let items = try tmuxWorkspaceItems(client: client)
        if let match = items.first(where: {
            (($0["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == needle
        }), let id = match["id"] as? String {
            return id
        }

        throw CLIError(message: "Workspace target not found: \(token)")
    }

    private func tmuxResolvePaneTarget(_ raw: String?, client: SocketClient) throws -> (workspaceId: String, paneId: String) {
        let paneSelector = tmuxPaneSelector(from: raw)
        let workspaceSelector = tmuxWindowSelector(from: raw)
        let workspaceId: String = {
            if let workspaceSelector {
                return (try? tmuxResolveWorkspaceTarget(workspaceSelector, client: client)) ?? ""
            }
            if let paneSelector,
               let workspaceId = try? tmuxWorkspaceIdForPaneHandle(paneSelector, client: client) {
                return workspaceId
            }
            return (try? tmuxResolveWorkspaceTarget(nil, client: client)) ?? ""
        }()
        guard !workspaceId.isEmpty else {
            throw CLIError(message: "Workspace target not found")
        }
        let paneId: String
        if let paneSelector {
            paneId = try tmuxCanonicalPaneId(paneSelector, workspaceId: workspaceId, client: client)
        } else if tmuxResolvedCallerWorkspaceId(client: client) == workspaceId,
                  let callerPane = tmuxCallerPaneHandle(),
                  let callerPaneId = try? tmuxCanonicalPaneId(callerPane, workspaceId: workspaceId, client: client) {
            paneId = callerPaneId
        } else {
            paneId = try tmuxFocusedPaneId(workspaceId: workspaceId, client: client)
        }
        return (workspaceId, paneId)
    }

    private func tmuxSelectedSurfaceId(
        workspaceId: String,
        paneId: String,
        client: SocketClient
    ) throws -> String {
        let payload = try client.sendV2(
            method: "pane.surfaces",
            params: ["workspace_id": workspaceId, "pane_id": paneId]
        )
        let surfaces = payload["surfaces"] as? [[String: Any]] ?? []
        if let selected = surfaces.first(where: { ($0["selected"] as? Bool) == true }),
           let id = selected["id"] as? String {
            return id
        }
        if let first = surfaces.first?["id"] as? String {
            return first
        }
        throw CLIError(message: "Pane has no surface to target")
    }

    private func tmuxResolveSurfaceTarget(
        _ raw: String?,
        client: SocketClient
    ) throws -> (workspaceId: String, paneId: String?, surfaceId: String) {
        if tmuxPaneSelector(from: raw) != nil {
            let resolved = try tmuxResolvePaneTarget(raw, client: client)
            // When the target pane matches the caller's pane, prefer the caller's
            // exact surface (CMUX_SURFACE_ID) over the pane's currently selected
            // surface. The selected surface can change (e.g. tab switches) after
            // claude-teams started, but the caller surface stays fixed.
            let callerPane = tmuxCallerPaneHandle()
            let callerSurface = tmuxCallerSurfaceHandle()
            let canonicalCallerPane = callerPane.flatMap { try? tmuxCanonicalPaneId($0, workspaceId: resolved.workspaceId, client: client) }
            let paneMatch = callerPane != nil && (resolved.paneId == callerPane! || resolved.paneId == canonicalCallerPane)
            if paneMatch,
               let callerSurface,
               let surfaceId = try? tmuxCanonicalSurfaceId(
                    callerSurface,
                    workspaceId: resolved.workspaceId,
                    client: client
               ) {
                return (resolved.workspaceId, resolved.paneId, surfaceId)
            }
            let surfaceId = try tmuxSelectedSurfaceId(
                workspaceId: resolved.workspaceId,
                paneId: resolved.paneId,
                client: client
            )
            return (resolved.workspaceId, resolved.paneId, surfaceId)
        }

        let workspaceId = try tmuxResolveWorkspaceTarget(tmuxWindowSelector(from: raw), client: client)
        if tmuxWindowSelector(from: raw) == nil,
           tmuxResolvedCallerWorkspaceId(client: client) == workspaceId,
           let callerSurface = tmuxCallerSurfaceHandle(),
           let surfaceId = try? tmuxCanonicalSurfaceId(
                callerSurface,
                workspaceId: workspaceId,
                client: client
           ) {
            return (workspaceId, nil, surfaceId)
        }
        let surfaceId = try resolveSurfaceId(nil, workspaceId: workspaceId, client: client)
        return (workspaceId, nil, surfaceId)
    }

    private func tmuxAnchoredSplitTarget(
        workspaceId: String,
        client: SocketClient
    ) -> (targetSurfaceId: String, callerSurfaceId: String?, direction: String)? {
        var store = loadTmuxCompatStore()
        if let lastColumn = store.mainVerticalLayouts[workspaceId]?.lastColumnSurfaceId {
            if let lastColumnId = try? tmuxCanonicalSurfaceId(
                lastColumn,
                workspaceId: workspaceId,
                client: client
            ) {
                // Once the agent column exists, keep stacking into it even if the
                // caller surface handle has churned from a stale surface:<n> ref.
                return (lastColumnId, nil, "down")
            }

            // Right-column anchors can outlive the pane they pointed at.
            // Drop stale state and rebuild from the caller surface instead.
            store.mainVerticalLayouts[workspaceId]?.lastColumnSurfaceId = nil
            store.lastSplitSurface.removeValue(forKey: workspaceId)
            try? saveTmuxCompatStore(store)
        }

        let candidateAnchors = [
            tmuxCallerSurfaceHandle(),
            store.mainVerticalLayouts[workspaceId]?.mainSurfaceId
        ].compactMap { $0 }
        for candidate in candidateAnchors {
            if let anchorSurfaceId = try? tmuxCanonicalSurfaceId(
                candidate,
                workspaceId: workspaceId,
                client: client
            ) {
                return (anchorSurfaceId, anchorSurfaceId, "right")
            }
        }

        let removedLayout = store.mainVerticalLayouts.removeValue(forKey: workspaceId) != nil
        let removedSplit = store.lastSplitSurface.removeValue(forKey: workspaceId) != nil
        if removedLayout || removedSplit {
            try? saveTmuxCompatStore(store)
        }
        return nil
    }

    private func tmuxRenderFormat(
        _ format: String?,
        context: [String: String],
        fallback: String
    ) -> String {
        guard let format, !format.isEmpty else { return fallback }
        var rendered = format
        for (key, value) in context {
            rendered = rendered.replacingOccurrences(of: "#{\(key)}", with: value)
        }
        rendered = rendered.replacingOccurrences(
            of: "#\\{[^}]+\\}",
            with: "",
            options: .regularExpression
        )
        let trimmed = rendered.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private func tmuxFormatContext(
        workspaceId: String,
        paneId: String? = nil,
        surfaceId: String? = nil,
        client: SocketClient
    ) throws -> [String: String] {
        let canonicalWorkspaceId = try resolveWorkspaceId(workspaceId, client: client)
        var context: [String: String] = [
            "session_name": "cmux",
            "window_id": "@\(canonicalWorkspaceId)",
            "window_uuid": canonicalWorkspaceId
        ]

        let workspaceItems = try tmuxWorkspaceItems(client: client)
        if let workspace = workspaceItems.first(where: {
            ($0["id"] as? String) == canonicalWorkspaceId || ($0["ref"] as? String) == workspaceId
        }) {
            if let index = intFromAny(workspace["index"]) {
                context["window_index"] = String(index)
            }
            let title = ((workspace["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty {
                context["window_name"] = title
            }
        }

        let currentPayload = try client.sendV2(method: "surface.current", params: ["workspace_id": canonicalWorkspaceId])
        let resolvedPaneId: String? = try {
            if let paneId {
                return try tmuxCanonicalPaneId(paneId, workspaceId: canonicalWorkspaceId, client: client)
            }
            if let currentPaneId = currentPayload["pane_id"] as? String {
                return currentPaneId
            }
            if let currentPaneRef = currentPayload["pane_ref"] as? String {
                return try tmuxCanonicalPaneId(currentPaneRef, workspaceId: canonicalWorkspaceId, client: client)
            }
            return nil
        }()
        let resolvedSurfaceId: String? = try {
            if let surfaceId {
                return try tmuxCanonicalSurfaceId(surfaceId, workspaceId: canonicalWorkspaceId, client: client)
            }
            if let resolvedPaneId {
                return try tmuxSelectedSurfaceId(
                    workspaceId: canonicalWorkspaceId,
                    paneId: resolvedPaneId,
                    client: client
                )
            }
            return currentPayload["surface_id"] as? String
        }()

        if let resolvedPaneId {
            context["pane_id"] = "%\(resolvedPaneId)"
            context["pane_uuid"] = resolvedPaneId
            let panePayload = try client.sendV2(method: "pane.list", params: ["workspace_id": canonicalWorkspaceId])
            let panes = panePayload["panes"] as? [[String: Any]] ?? []
            if let pane = panes.first(where: { ($0["id"] as? String) == resolvedPaneId }),
               let index = intFromAny(pane["index"]) {
                context["pane_index"] = String(index)
            }
        }

        if let resolvedSurfaceId {
            context["surface_id"] = resolvedSurfaceId
            let surfacePayload = try client.sendV2(method: "surface.list", params: ["workspace_id": canonicalWorkspaceId])
            let surfaces = surfacePayload["surfaces"] as? [[String: Any]] ?? []
            if let surface = surfaces.first(where: { ($0["id"] as? String) == resolvedSurfaceId }) {
                let title = ((surface["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty {
                    context["pane_title"] = title
                    context["window_name"] = context["window_name"] ?? title
                }
            }
        }

        return context
    }

    /// Enrich a tmux format context dictionary with pane geometry data from the
    /// enriched pane.list response. Computes character-cell positions from pixel
    /// frames and cell dimensions so tmux format variables like #{pane_width},
    /// #{pane_height}, #{pane_left}, #{pane_top}, #{window_width}, #{window_height}
    /// render correctly.
    private func tmuxEnrichContextWithGeometry(
        _ context: inout [String: String],
        pane: [String: Any],
        containerFrame: [String: Any]?
    ) {
        let isFocused = (pane["focused"] as? Bool) == true
        context["pane_active"] = isFocused ? "1" : "0"

        guard let columns = pane["columns"] as? Int,
              let rows = pane["rows"] as? Int else { return }

        context["pane_width"] = String(columns)
        context["pane_height"] = String(rows)

        let cellW = pane["cell_width_px"] as? Int ?? 0
        let cellH = pane["cell_height_px"] as? Int ?? 0
        guard cellW > 0, cellH > 0 else { return }

        if let frame = pane["pixel_frame"] as? [String: Any] {
            let px = frame["x"] as? Double ?? 0
            let py = frame["y"] as? Double ?? 0
            context["pane_left"] = String(Int(px) / cellW)
            context["pane_top"] = String(Int(py) / cellH)
        }

        if let cf = containerFrame {
            let cw = cf["width"] as? Double ?? 0
            let ch = cf["height"] as? Double ?? 0
            context["window_width"] = String(max(Int(cw) / cellW, 1))
            context["window_height"] = String(max(Int(ch) / cellH, 1))
        }
    }

    private func tmuxShellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private func tmuxShellCommandText(commandTokens: [String], cwd: String?) -> String? {
        let trimmedCwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines)
        let commandText = commandTokens.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard (trimmedCwd?.isEmpty == false) || !commandText.isEmpty else {
            return nil
        }

        var pieces: [String] = []
        if let trimmedCwd, !trimmedCwd.isEmpty {
            pieces.append("cd -- \(tmuxShellQuote(resolvePath(trimmedCwd)))")
        }
        if !commandText.isEmpty {
            pieces.append(commandText)
        }
        return pieces.joined(separator: " && ") + "\r"
    }

    private func tmuxSpecialKeyText(_ token: String) -> String? {
        switch token.lowercased() {
        case "enter", "c-m", "kpenter":
            return "\r"
        case "tab", "c-i":
            return "\t"
        case "space":
            return " "
        case "bspace", "backspace":
            return "\u{7f}"
        case "escape", "esc", "c-[":
            return "\u{1b}"
        case "c-c":
            return "\u{03}"
        case "c-d":
            return "\u{04}"
        case "c-z":
            return "\u{1a}"
        case "c-l":
            return "\u{0c}"
        default:
            return nil
        }
    }

    private func tmuxSendKeysText(from tokens: [String], literal: Bool) -> String {
        if literal {
            return tokens.joined(separator: " ")
        }

        var result = ""
        var pendingSpace = false
        for token in tokens {
            if let special = tmuxSpecialKeyText(token) {
                result += special
                pendingSpace = false
                continue
            }
            if pendingSpace {
                result += " "
            }
            result += token
            pendingSpace = true
        }
        return result
    }

    private func prependPathEntries(_ newEntries: [String], to currentPath: String?) -> String {
        var ordered: [String] = []
        var seen: Set<String> = []
        for entry in newEntries + (currentPath?.split(separator: ":").map(String.init) ?? []) where !entry.isEmpty {
            if seen.insert(entry).inserted {
                ordered.append(entry)
            }
        }
        return ordered.joined(separator: ":")
    }

    private struct TmuxCompatFocusedContext {
        let socketPath: String
        let workspaceId: String
        let windowId: String?
        let paneHandle: String
        let paneId: String?
        let surfaceId: String?
    }

    private func tmuxCompatResolvedSocketPath(processEnvironment: [String: String]) -> String {
        let envSocketPath: String? = {
            for key in ["CMUX_SOCKET_PATH", "CMUX_SOCKET"] {
                guard let raw = processEnvironment[key] else { continue }
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
            return nil
        }()

        let requestedSocketPath = envSocketPath ?? CLISocketPathResolver.defaultSocketPath
        let source: CLISocketPathSource
        if let envSocketPath {
            source = CLISocketPathResolver.isImplicitDefaultPath(envSocketPath) ? .implicitDefault : .environment
        } else {
            source = .implicitDefault
        }

        return CLISocketPathResolver.resolve(
            requestedPath: requestedSocketPath,
            source: source,
            environment: processEnvironment
        )
    }

    private func tmuxCompatFocusedContext(
        processEnvironment: [String: String],
        explicitPassword: String?
    ) -> TmuxCompatFocusedContext? {
        let socketPath = tmuxCompatResolvedSocketPath(processEnvironment: processEnvironment)
        let client = SocketClient(path: socketPath)

        do {
            try client.connect()
            try authenticateClientIfNeeded(
                client,
                explicitPassword: explicitPassword,
                socketPath: socketPath
            )
            defer { client.close() }

            let payload = try client.sendV2(method: "system.identify")
            let focused = payload["focused"] as? [String: Any] ?? [:]

            let workspaceId = (focused["workspace_id"] as? String)
                ?? (focused["workspace_ref"] as? String)
            let paneId = (focused["pane_id"] as? String)
                ?? (focused["pane_ref"] as? String)

            guard let workspaceId, let paneId else {
                return nil
            }

            let paneHandle = paneId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !paneHandle.isEmpty else {
                return nil
            }

            let windowId = (focused["window_id"] as? String)
                ?? (focused["window_ref"] as? String)
            let surfaceId = (focused["surface_id"] as? String)
                ?? (focused["surface_ref"] as? String)

            return TmuxCompatFocusedContext(
                socketPath: socketPath,
                workspaceId: workspaceId,
                windowId: windowId,
                paneHandle: paneHandle,
                paneId: focused["pane_id"] as? String,
                surfaceId: surfaceId
            )
        } catch {
            client.close()
            return nil
        }
    }

    private func isCmuxClaudeWrapper(at path: String) -> Bool {
        guard let data = FileManager.default.contents(atPath: path) else { return false }
        let prefixData = data.prefix(512)
        guard let prefix = String(data: prefixData, encoding: .utf8) else { return false }
        return prefix.contains("cmux claude wrapper - injects hooks and session tracking")
    }

    private func resolveExecutableInSearchPath(
        _ name: String,
        searchPath: String?,
        skip: ((String) -> Bool)? = nil
    ) -> String? {
        let entries = searchPath?.split(separator: ":").map(String.init) ?? []
        for entry in entries where !entry.isEmpty {
            let candidate = URL(fileURLWithPath: entry, isDirectory: true)
                .appendingPathComponent(name, isDirectory: false)
                .path
            guard FileManager.default.isExecutableFile(atPath: candidate) else { continue }
            if let skip, skip(candidate) { continue }
            return candidate
        }
        return nil
    }

    private func resolveClaudeExecutable(searchPath: String?) -> String? {
        resolveExecutableInSearchPath(
            "claude",
            searchPath: searchPath,
            skip: { self.isCmuxClaudeWrapper(at: $0) }
        )
    }

    private func claudeTeamsHasExplicitTeammateMode(commandArgs: [String]) -> Bool {
        commandArgs.contains { arg in
            arg == "--teammate-mode" || arg.hasPrefix("--teammate-mode=")
        }
    }

    private func claudeTeamsLaunchArguments(commandArgs: [String]) -> [String] {
        guard !claudeTeamsHasExplicitTeammateMode(commandArgs: commandArgs) else {
            return commandArgs
        }
        return ["--teammate-mode", "auto"] + commandArgs
    }

    private func exportAgentLaunchCommandEnvironment(
        launcher: String,
        executablePath: String,
        arguments: [String],
        workingDirectory: String? = nil
    ) {
        guard !arguments.isEmpty else { return }
        setenv("CMUX_AGENT_LAUNCH_KIND", launcher, 1)
        setenv("CMUX_AGENT_LAUNCH_EXECUTABLE", executablePath, 1)
        setenv("CMUX_AGENT_LAUNCH_ARGV_B64", Self.nulSeparatedBase64(arguments), 1)
        if let workingDirectory,
           !workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            setenv("CMUX_AGENT_LAUNCH_CWD", workingDirectory, 1)
        } else {
            unsetenv("CMUX_AGENT_LAUNCH_CWD")
        }
    }

    private static func nulSeparatedBase64(_ values: [String]) -> String {
        var data = Data()
        for value in values {
            data.append(contentsOf: value.utf8)
            data.append(0)
        }
        return data.base64EncodedString()
    }

    private func configureTmuxCompatEnvironment(
        processEnvironment: [String: String],
        shimDirectory: URL,
        executablePath: String,
        socketPath: String,
        explicitPassword: String?,
        focusedContext: TmuxCompatFocusedContext?,
        tmuxPathPrefix: String,
        cmuxBinEnvVar: String,
        termOverrideEnvVar: String,
        extraEnvVars: [(key: String, value: String)] = []
    ) {
        let updatedPath = prependPathEntries(
            [shimDirectory.path],
            to: processEnvironment["PATH"]
        )
        let fakeTmuxValue: String = {
            if let focusedContext {
                let windowToken = focusedContext.windowId ?? focusedContext.workspaceId
                return "/tmp/\(tmuxPathPrefix)/\(focusedContext.workspaceId),\(windowToken),\(focusedContext.paneHandle)"
            }
            return processEnvironment["TMUX"] ?? "/tmp/\(tmuxPathPrefix)/default,0,0"
        }()
        let fakeTmuxPane = focusedContext.map { "%\($0.paneHandle)" }
            ?? processEnvironment["TMUX_PANE"]
            ?? "%1"
        let fakeTerm = processEnvironment[termOverrideEnvVar] ?? "screen-256color"

        setenv(cmuxBinEnvVar, executablePath, 1)
        setenv("PATH", updatedPath, 1)
        setenv("TMUX", fakeTmuxValue, 1)
        setenv("TMUX_PANE", fakeTmuxPane, 1)
        setenv("TERM", fakeTerm, 1)
        setenv("CMUX_SOCKET_PATH", socketPath, 1)
        setenv("CMUX_SOCKET", socketPath, 1)
        if let explicitPassword,
           !explicitPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            setenv("CMUX_SOCKET_PASSWORD", explicitPassword, 1)
        }
        unsetenv("TERM_PROGRAM")
        for envVar in extraEnvVars {
            setenv(envVar.key, envVar.value, 1)
        }
        if let focusedContext {
            setenv("CMUX_WORKSPACE_ID", focusedContext.workspaceId, 1)
            if let surfaceId = focusedContext.surfaceId, !surfaceId.isEmpty {
                setenv("CMUX_SURFACE_ID", surfaceId, 1)
            }
        }
    }

    private static let claudeNodeOptionsRestoreModule = """
    const hadOriginalNodeOptions = process.env.CMUX_ORIGINAL_NODE_OPTIONS_PRESENT === "1";
    if (hadOriginalNodeOptions) {
        process.env.NODE_OPTIONS = process.env.CMUX_ORIGINAL_NODE_OPTIONS ?? "";
    } else {
        delete process.env.NODE_OPTIONS;
    }
    delete process.env.CMUX_ORIGINAL_NODE_OPTIONS;
    delete process.env.CMUX_ORIGINAL_NODE_OPTIONS_PRESENT;
    """

    private func configureClaudeTeamsEnvironment(
        processEnvironment: [String: String],
        shimDirectory: URL,
        executablePath: String,
        socketPath: String,
        explicitPassword: String?,
        focusedContext: TmuxCompatFocusedContext?
    ) {
        configureTmuxCompatEnvironment(
            processEnvironment: processEnvironment,
            shimDirectory: shimDirectory,
            executablePath: executablePath,
            socketPath: socketPath,
            explicitPassword: explicitPassword,
            focusedContext: focusedContext,
            tmuxPathPrefix: "cmux-claude-teams",
            cmuxBinEnvVar: "CMUX_CLAUDE_TEAMS_CMUX_BIN",
            termOverrideEnvVar: "CMUX_CLAUDE_TEAMS_TERM",
            extraEnvVars: [
                (key: "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS", value: "1"),
            ]
        )
        guard let restoreModuleURL = try? createClaudeNodeOptionsRestoreModule() else {
            unsetenv("CMUX_ORIGINAL_NODE_OPTIONS_PRESENT")
            unsetenv("CMUX_ORIGINAL_NODE_OPTIONS")
            return
        }
        if let existing = processEnvironment["NODE_OPTIONS"] {
            setenv("CMUX_ORIGINAL_NODE_OPTIONS_PRESENT", "1", 1)
            setenv("CMUX_ORIGINAL_NODE_OPTIONS", normalizedNodeOptionsForRestore(existing), 1)
        } else {
            setenv("CMUX_ORIGINAL_NODE_OPTIONS_PRESENT", "0", 1)
            unsetenv("CMUX_ORIGINAL_NODE_OPTIONS")
        }
        setenv(
            "NODE_OPTIONS",
            mergedNodeOptions(
                existing: processEnvironment["NODE_OPTIONS"],
                restoreModulePath: restoreModuleURL.path
            ),
            1
        )
    }

    private func createTmuxCompatShimDirectory(
        directoryName: String,
        tmuxShimScript: String
    ) throws -> URL {
        let homePath = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let root = URL(fileURLWithPath: homePath, isDirectory: true)
            .appendingPathComponent(".cmuxterm", isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: nil)
        let tmuxURL = root.appendingPathComponent("tmux", isDirectory: false)
        try writeShimIfChanged(tmuxShimScript, to: tmuxURL)
        return root
    }

    private func createClaudeTeamsShimDirectory() throws -> URL {
        let script = """
        #!/usr/bin/env bash
        set -euo pipefail
        exec "${CMUX_CLAUDE_TEAMS_CMUX_BIN:-cmux}" __tmux-compat "$@"
        """
        return try createTmuxCompatShimDirectory(
            directoryName: "claude-teams-bin",
            tmuxShimScript: script
        )
    }

    private func createClaudeNodeOptionsRestoreModule() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("cmux-claude-node-options", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: nil)
        let restoreModuleURL = root.appendingPathComponent("restore-node-options.cjs", isDirectory: false)
        try writeShimIfChanged(Self.claudeNodeOptionsRestoreModule, to: restoreModuleURL)
        return restoreModuleURL
    }

    private func runClaudeTeams(
        commandArgs: [String],
        socketPath: String,
        explicitPassword: String?
    ) throws {
        let processEnvironment = ProcessInfo.processInfo.environment
        var launcherEnvironment = processEnvironment
        launcherEnvironment["CMUX_SOCKET_PATH"] = socketPath
        launcherEnvironment["CMUX_SOCKET"] = socketPath
        if let explicitPassword,
           !explicitPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            launcherEnvironment["CMUX_SOCKET_PASSWORD"] = explicitPassword
        }
        let shimDirectory = try createClaudeTeamsShimDirectory()
        let executablePath = resolvedExecutableURL()?.path ?? (args.first ?? "cmux")
        let focusedContext = tmuxCompatFocusedContext(
            processEnvironment: launcherEnvironment,
            explicitPassword: explicitPassword
        )
        let bundledClaudePath = resolvedExecutableURL()?
            .deletingLastPathComponent()
            .appendingPathComponent("claude", isDirectory: false)
            .path
        let claudeExecutablePath: String? = {
            // Check custom path from Settings > Automation > Claude Code.
            // Try env var first (set by the app per-session), then UserDefaults.
            let candidates = [
                launcherEnvironment["CMUX_CUSTOM_CLAUDE_PATH"],
                UserDefaults.standard.string(forKey: "claudeCodeCustomClaudePath"),
            ]
            for raw in candidates {
                guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !trimmed.isEmpty else { continue }
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: trimmed, isDirectory: &isDir),
                      !isDir.boolValue,
                      FileManager.default.isExecutableFile(atPath: trimmed),
                      !isCmuxClaudeWrapper(at: trimmed) else { continue }
                return trimmed
            }
            return resolveClaudeExecutable(searchPath: launcherEnvironment["PATH"])
                ?? {
                    guard let bundledClaudePath,
                          FileManager.default.isExecutableFile(atPath: bundledClaudePath) else { return nil }
                    return bundledClaudePath
                }()
        }()
        configureClaudeTeamsEnvironment(
            processEnvironment: launcherEnvironment,
            shimDirectory: shimDirectory,
            executablePath: executablePath,
            socketPath: socketPath,
            explicitPassword: explicitPassword,
            focusedContext: focusedContext
        )

        let launchPath = claudeExecutablePath ?? "claude"
        let launchArguments = claudeTeamsLaunchArguments(commandArgs: commandArgs)
        exportAgentLaunchCommandEnvironment(
            launcher: "claudeTeams",
            executablePath: executablePath,
            arguments: [executablePath, "claude-teams"] + launchArguments,
            workingDirectory: launcherEnvironment["PWD"]
        )
        var argv = ([launchPath] + launchArguments).map { strdup($0) }
        defer {
            for item in argv {
                free(item)
            }
        }
        argv.append(nil)

        if claudeExecutablePath != nil {
            execv(launchPath, &argv)
        } else {
            execvp("claude", &argv)
        }
        let code = errno
        throw CLIError(message: "Failed to launch claude: \(String(cString: strerror(code)))")
    }

    // MARK: - cmux omo (OpenCode + oh-my-openagent)

    private func resolveOpenCodeExecutable(searchPath: String?) -> String? {
        resolveExecutableInSearchPath("opencode", searchPath: searchPath)
    }

    private func createOMOShimDirectory() throws -> URL {
        // tmux shim: redirects tmux commands to cmux __tmux-compat
        // Handle -V locally (no socket needed) since __tmux-compat requires a connection.
        let tmuxScript = """
        #!/usr/bin/env bash
        set -euo pipefail
        # Only match -V/-v as the first arg (top-level tmux flag).
        # -v inside subcommands (e.g. split-window -v) is a vertical split flag.
        case "${1:-}" in
          -V|-v) echo "tmux 3.4"; exit 0 ;;
        esac
        exec "${CMUX_OMO_CMUX_BIN:-cmux}" __tmux-compat "$@"
        """
        let root = try createTmuxCompatShimDirectory(
            directoryName: "omo-bin",
            tmuxShimScript: tmuxScript
        )

        // terminal-notifier shim: intercepts macOS notifications and routes to cmux notify
        let notifierURL = root.appendingPathComponent("terminal-notifier", isDirectory: false)
        let notifierScript = """
        #!/usr/bin/env bash
        # Intercept terminal-notifier calls and route through cmux notify.
        # oh-my-openagent calls: terminal-notifier -title <t> -message <m> [-activate <id>]
        TITLE="" BODY=""
        while [[ $# -gt 0 ]]; do
          case "$1" in
            -title)   TITLE="$2"; shift 2 ;;
            -message) BODY="$2"; shift 2 ;;
            *)        shift ;;
          esac
        done
        exec "${CMUX_OMO_CMUX_BIN:-cmux}" notify --title "${TITLE:-OpenCode}" --body "${BODY:-}"
        """
        try writeShimIfChanged(notifierScript, to: notifierURL)

        return root
    }

    private func writeShimIfChanged(_ script: String, to url: URL) throws {
        let normalized = script.trimmingCharacters(in: .whitespacesAndNewlines)
        let fileManager = FileManager.default
        let existing = try? String(contentsOf: url, encoding: .utf8)
        guard existing?.trimmingCharacters(in: .whitespacesAndNewlines) != normalized else {
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return
        }
        let directoryURL = url.deletingLastPathComponent()
        let tempURL = directoryURL.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try script.write(to: tempURL, atomically: false, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempURL.path)
        do {
            if fileManager.fileExists(atPath: url.path) {
                _ = try fileManager.replaceItemAt(url, withItemAt: tempURL)
            } else {
                try fileManager.moveItem(at: tempURL, to: url)
            }
        } catch {
            let current = try? String(contentsOf: url, encoding: .utf8)
            if current?.trimmingCharacters(in: .whitespacesAndNewlines) == normalized {
                try? fileManager.removeItem(at: tempURL)
                return
            }
            if fileManager.fileExists(atPath: url.path) {
                do {
                    _ = try fileManager.replaceItemAt(url, withItemAt: tempURL)
                    return
                } catch {}
            }
            try? fileManager.removeItem(at: tempURL)
            throw error
        }
    }

    private static let omoPluginName = "oh-my-opencode"
    private static let openCodeSessionPluginConfigSpec = "cmux-session"

    private func resolveExecutableInPath(_ name: String) -> String? {
        let entries = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        for entry in entries where !entry.isEmpty {
            let candidate = URL(fileURLWithPath: entry, isDirectory: true)
                .appendingPathComponent(name, isDirectory: false)
                .path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private func omoUserConfigDir() -> URL {
        let homePath = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        return URL(fileURLWithPath: homePath, isDirectory: true)
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("opencode", isDirectory: true)
    }

    private func omoShadowConfigDir() -> URL {
        let homePath = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        return URL(fileURLWithPath: homePath, isDirectory: true)
            .appendingPathComponent(".cmuxterm", isDirectory: true)
            .appendingPathComponent("omo-config", isDirectory: true)
    }

    private func omoFileType(at url: URL) -> FileAttributeType? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attrs?[.type] as? FileAttributeType
    }

    private func omoEnsureShadowPackageManifest(at shadowPackageURL: URL) throws {
        let fm = FileManager.default
        if omoFileType(at: shadowPackageURL) == .typeSymbolicLink {
            try? fm.removeItem(at: shadowPackageURL)
        }

        // Keep the shadow package isolated from stale/yanked pins in the user's
        // opencode package.json. bun will update this manifest with the resolved
        // oh-my-opencode version when installation succeeds.
        let packageManifest: [String: Any] = [
            "dependencies": [
                Self.omoPluginName: "latest"
            ],
            "name": "cmux-omo-shadow",
            "private": true
        ]
        let output = try JSONSerialization.data(withJSONObject: packageManifest, options: [.prettyPrinted, .sortedKeys])
        let existing = try? Data(contentsOf: shadowPackageURL)
        if existing != output {
            try output.write(to: shadowPackageURL, options: .atomic)
        }
    }

    private func omoEnsureShadowNodeModulesSymlink(
        shadowNodeModules: URL,
        userNodeModules: URL
    ) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: userNodeModules.path) else { return }

        if let type = omoFileType(at: shadowNodeModules) {
            if type == .typeSymbolicLink {
                let target = try? fm.destinationOfSymbolicLink(atPath: shadowNodeModules.path)
                if target != userNodeModules.path {
                    try? fm.removeItem(at: shadowNodeModules)
                } else {
                    return
                }
            } else {
                return
            }
        }

        if !fm.fileExists(atPath: shadowNodeModules.path) {
            try fm.createSymbolicLink(at: shadowNodeModules, withDestinationURL: userNodeModules)
        }
    }

    private func omoRunPackageInstall(
        executablePath: String,
        arguments: [String],
        currentDirectoryURL: URL
    ) throws -> Int32 {
        let process = Process()
        process.currentDirectoryURL = currentDirectoryURL
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardOutput = FileHandle.standardError
        process.standardError = FileHandle.standardError
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func omoRequestedPort(from commandArgs: [String]) -> String? {
        for (index, arg) in commandArgs.enumerated() {
            if arg == "--port" {
                let nextIndex = commandArgs.index(after: index)
                guard nextIndex < commandArgs.endIndex else { return nil }
                let value = commandArgs[nextIndex].trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }

            if arg.hasPrefix("--port=") {
                let value = String(arg.dropFirst("--port=".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }
        }

        return nil
    }

    private func omoBindableLoopbackPort(_ port: UInt16) -> UInt16? {
        let socketDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else { return nil }
        defer { close(socketDescriptor) }

        var reuseAddress: Int32 = 1
        _ = setsockopt(
            socketDescriptor,
            SOL_SOCKET,
            SO_REUSEADDR,
            &reuseAddress,
            socklen_t(MemoryLayout<Int32>.size)
        )

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.stride)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.stride))
            }
        }
        guard bindResult == 0 else { return nil }

        if port != 0 {
            return port
        }

        var boundAddress = address
        var boundAddressLength = socklen_t(MemoryLayout<sockaddr_in>.stride)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socketDescriptor, $0, &boundAddressLength)
            }
        }
        guard nameResult == 0 else { return nil }

        return UInt16(bigEndian: boundAddress.sin_port)
    }

    private func omoResolvedPort(
        commandArgs: [String],
        processEnvironment: [String: String]
    ) -> String {
        if let requestedPort = omoRequestedPort(from: commandArgs) {
            return requestedPort
        }

        if let environmentPort = processEnvironment["OPENCODE_PORT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           let parsedEnvironmentPort = UInt16(environmentPort),
           parsedEnvironmentPort != 0,
           omoBindableLoopbackPort(parsedEnvironmentPort) != nil {
            return environmentPort
        }

        if let preferredPort = omoBindableLoopbackPort(4096) {
            return String(preferredPort)
        }

        if let fallbackPort = omoBindableLoopbackPort(0) {
            return String(fallbackPort)
        }

        return "4096"
    }

    /// Creates a shadow config directory that layers oh-my-opencode on top of the user's
    /// existing opencode config without modifying the original. Sets OPENCODE_CONFIG_DIR
    /// to point at the shadow directory.
    private func omoEnsurePlugin() throws {
        let userDir = omoUserConfigDir()
        let shadowDir = omoShadowConfigDir()
        let fm = FileManager.default

        try fm.createDirectory(at: shadowDir, withIntermediateDirectories: true, attributes: nil)

        // Read the user's opencode.json (if any), add the plugin, write to shadow dir
        let userJsonURL = userDir.appendingPathComponent("opencode.json")
        let shadowJsonURL = shadowDir.appendingPathComponent("opencode.json")

        var config: [String: Any]
        if let data = try? Data(contentsOf: userJsonURL) {
            guard let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CLIError(message: "Failed to parse \(userJsonURL.path). Fix the JSON syntax and retry.")
            }
            config = existing
        } else {
            config = [:]
        }

        var plugins = Self.openCodePluginListRemovingSessionPlugin((config["plugin"] as? [Any]) ?? [])
        if !Self.openCodePluginListContains(plugins, spec: Self.omoPluginName, allowVersionSuffix: true) {
            plugins.append(Self.omoPluginName)
        }
        config["plugin"] = plugins

        let output = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        try output.write(to: shadowJsonURL, options: .atomic)

        // Symlink node_modules from the user's config dir so installed packages resolve
        let shadowNodeModules = shadowDir.appendingPathComponent("node_modules")
        let userNodeModules = userDir.appendingPathComponent("node_modules")
        try omoEnsureShadowNodeModulesSymlink(shadowNodeModules: shadowNodeModules, userNodeModules: userNodeModules)

        // The shadow config owns its own package metadata so yanked/stale pins in the
        // user's opencode package.json/bun.lock cannot poison plugin installation.
        let shadowPackageURL = shadowDir.appendingPathComponent("package.json")
        let shadowBunLockURL = shadowDir.appendingPathComponent("bun.lock")
        try omoEnsureShadowPackageManifest(at: shadowPackageURL)
        if omoFileType(at: shadowBunLockURL) == .typeSymbolicLink {
            try? fm.removeItem(at: shadowBunLockURL)
        }

        try writeOpenCodeSessionPlugin(in: shadowDir)

        // Copy oh-my-opencode plugin config (jsonc) if the user has one
        for filename in ["oh-my-opencode.json", "oh-my-opencode.jsonc"] {
            let userFile = userDir.appendingPathComponent(filename)
            let shadowFile = shadowDir.appendingPathComponent(filename)
            if fm.fileExists(atPath: userFile.path) && !fm.fileExists(atPath: shadowFile.path) {
                try fm.createSymbolicLink(at: shadowFile, withDestinationURL: userFile)
            }
        }

        // Install the package if not available via the symlinked node_modules
        let pluginPackageDir = shadowNodeModules.appendingPathComponent(Self.omoPluginName)
        if !fm.fileExists(atPath: pluginPackageDir.path) {
            let installDir = shadowDir
            if let bunPath = resolveExecutableInPath("bun") {
                FileHandle.standardError.write("Installing oh-my-opencode plugin (this may take a minute on first run)...\n".data(using: .utf8)!)
                let installArguments = ["add", Self.omoPluginName]
                let firstAttemptStatus = try omoRunPackageInstall(
                    executablePath: bunPath,
                    arguments: installArguments,
                    currentDirectoryURL: installDir
                )
                if firstAttemptStatus != 0 {
                    FileHandle.standardError.write("Retrying oh-my-opencode install with a clean shadow package state...\n".data(using: .utf8)!)
                    try? fm.removeItem(at: shadowBunLockURL)
                    try? fm.removeItem(at: shadowNodeModules)
                    try omoEnsureShadowNodeModulesSymlink(shadowNodeModules: shadowNodeModules, userNodeModules: userNodeModules)
                    let retryStatus = try omoRunPackageInstall(
                        executablePath: bunPath,
                        arguments: installArguments,
                        currentDirectoryURL: installDir
                    )
                    if retryStatus != 0 {
                        throw CLIError(message: "Failed to install oh-my-opencode. Try manually: npm install -g oh-my-opencode")
                    }
                }
            } else if let npmPath = resolveExecutableInPath("npm") {
                FileHandle.standardError.write("Installing oh-my-opencode plugin (this may take a minute on first run)...\n".data(using: .utf8)!)
                let status = try omoRunPackageInstall(
                    executablePath: npmPath,
                    arguments: ["install", Self.omoPluginName],
                    currentDirectoryURL: installDir
                )
                if status != 0 {
                    throw CLIError(message: "Failed to install oh-my-opencode. Try manually: npm install -g oh-my-opencode")
                }
            } else {
                throw CLIError(message: "Neither bun nor npm found in PATH. Install oh-my-opencode manually: bunx oh-my-opencode install")
            }
            FileHandle.standardError.write("oh-my-opencode plugin installed\n".data(using: .utf8)!)
        }

        // Ensure tmux mode is enabled in oh-my-opencode config.
        // Without this, the TmuxSessionManager won't spawn visual panes even though
        // $TMUX is set (tmux.enabled defaults to false).
        let omoConfigURL = shadowDir.appendingPathComponent("oh-my-opencode.json")
        var omoConfig: [String: Any]
        if let data = try? Data(contentsOf: omoConfigURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            omoConfig = existing
        } else {
            // Check if user has a config we symlinked, read from source
            let userOmoConfig = userDir.appendingPathComponent("oh-my-opencode.json")
            if let data = try? Data(contentsOf: userOmoConfig),
               let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                omoConfig = existing
                // Remove the symlink so we can write our own copy
                try? fm.removeItem(at: omoConfigURL)
            } else {
                omoConfig = [:]
            }
        }
        var tmuxConfig = (omoConfig["tmux"] as? [String: Any]) ?? [:]
        var needsWrite = false
        if tmuxConfig["enabled"] as? Bool != true {
            tmuxConfig["enabled"] = true
            needsWrite = true
        }
        // Lower the default min widths so agent panes spawn in normal-sized windows.
        // oh-my-openagent defaults: main_pane_min_width=120, agent_pane_min_width=40,
        // requiring 161+ columns. Most terminal windows are narrower.
        if tmuxConfig["main_pane_min_width"] == nil {
            tmuxConfig["main_pane_min_width"] = 60
            needsWrite = true
        }
        if tmuxConfig["agent_pane_min_width"] == nil {
            tmuxConfig["agent_pane_min_width"] = 30
            needsWrite = true
        }
        if tmuxConfig["main_pane_size"] == nil {
            tmuxConfig["main_pane_size"] = 50
            needsWrite = true
        }
        if needsWrite {
            omoConfig["tmux"] = tmuxConfig
            // Remove symlink if it exists (we need a real file)
            if let attrs = try? fm.attributesOfItem(atPath: omoConfigURL.path),
               attrs[.type] as? FileAttributeType == .typeSymbolicLink {
                try? fm.removeItem(at: omoConfigURL)
            }
            let output = try JSONSerialization.data(withJSONObject: omoConfig, options: [.prettyPrinted, .sortedKeys])
            try output.write(to: omoConfigURL, options: .atomic)
        }

        // Point OpenCode at the shadow config
        setenv("OPENCODE_CONFIG_DIR", shadowDir.path, 1)
    }

    private func configureOMOEnvironment(
        processEnvironment: [String: String],
        shimDirectory: URL,
        executablePath: String,
        socketPath: String,
        explicitPassword: String?,
        focusedContext: TmuxCompatFocusedContext?,
        openCodePort: String
    ) {
        configureTmuxCompatEnvironment(
            processEnvironment: processEnvironment,
            shimDirectory: shimDirectory,
            executablePath: executablePath,
            socketPath: socketPath,
            explicitPassword: explicitPassword,
            focusedContext: focusedContext,
            tmuxPathPrefix: "cmux-omo",
            cmuxBinEnvVar: "CMUX_OMO_CMUX_BIN",
            termOverrideEnvVar: "CMUX_OMO_TERM",
            extraEnvVars: [
                (key: "OPENCODE_PORT", value: openCodePort),
                (key: "CMUX_OPENCODE_CMUX_BIN", value: executablePath),
            ]
        )
    }

    private func runOMO(
        commandArgs: [String],
        socketPath: String,
        explicitPassword: String?
    ) throws {
        let processEnvironment = ProcessInfo.processInfo.environment
        var launcherEnvironment = processEnvironment
        launcherEnvironment["CMUX_SOCKET_PATH"] = socketPath
        launcherEnvironment["CMUX_SOCKET"] = socketPath
        if let explicitPassword,
           !explicitPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            launcherEnvironment["CMUX_SOCKET_PASSWORD"] = explicitPassword
        }

        // Check for opencode before doing expensive plugin setup
        let openCodeExecutablePath = resolveOpenCodeExecutable(searchPath: launcherEnvironment["PATH"])
        if openCodeExecutablePath == nil {
            let checkProcess = Process()
            checkProcess.executableURL = URL(fileURLWithPath: "/usr/bin/which")
            checkProcess.arguments = ["opencode"]
            checkProcess.standardOutput = Pipe()
            checkProcess.standardError = Pipe()
            try? checkProcess.run()
            checkProcess.waitUntilExit()
            if checkProcess.terminationStatus != 0 {
                throw CLIError(message: "opencode is not installed. Install it first:\n  npm install -g opencode-ai\n  # or\n  bun install -g opencode-ai\n\nThen run: cmux omo")
            }
        }

        // Ensure oh-my-opencode plugin is registered and installed
        try omoEnsurePlugin()

        let shimDirectory = try createOMOShimDirectory()
        let executablePath = resolvedExecutableURL()?.path ?? (args.first ?? "cmux")
        let focusedContext = tmuxCompatFocusedContext(
            processEnvironment: launcherEnvironment,
            explicitPassword: explicitPassword
        )
        let openCodePort = omoResolvedPort(
            commandArgs: commandArgs,
            processEnvironment: launcherEnvironment
        )
        launcherEnvironment["OPENCODE_PORT"] = openCodePort
        configureOMOEnvironment(
            processEnvironment: launcherEnvironment,
            shimDirectory: shimDirectory,
            executablePath: executablePath,
            socketPath: socketPath,
            explicitPassword: explicitPassword,
            focusedContext: focusedContext,
            openCodePort: openCodePort
        )

        let launchPath = openCodeExecutablePath ?? "opencode"
        // oh-my-openagent needs the OpenCode API server running to attach
        // subagent sessions to tmux panes. Prefer the historic default port
        // when it is available, otherwise fall back to a free loopback port.
        var effectiveArgs = commandArgs
        if omoRequestedPort(from: commandArgs) == nil {
            effectiveArgs.append("--port")
            effectiveArgs.append(openCodePort)
        }
        exportAgentLaunchCommandEnvironment(
            launcher: "omo",
            executablePath: executablePath,
            arguments: [executablePath, "omo"] + effectiveArgs,
            workingDirectory: launcherEnvironment["PWD"]
        )
        var argv = ([launchPath] + effectiveArgs).map { strdup($0) }
        defer {
            for item in argv {
                free(item)
            }
        }
        argv.append(nil)

        if openCodeExecutablePath != nil {
            execv(launchPath, &argv)
        } else {
            execvp("opencode", &argv)
        }
        let code = errno
        throw CLIError(message: "Failed to launch opencode: \(String(cString: strerror(code)))\n\nIs opencode installed? Install with:\n  npm install -g opencode-ai")
    }

    // MARK: - cmux omx (Oh My Codex)

    private func resolveOMXExecutable(searchPath: String?) -> String? {
        resolveExecutableInSearchPath("omx", searchPath: searchPath)
    }

    private func createOMXShimDirectory() throws -> URL {
        let tmuxScript = """
        #!/usr/bin/env bash
        set -euo pipefail
        case "${1:-}" in
          -V|-v) echo "tmux 3.4"; exit 0 ;;
        esac
        exec "${CMUX_OMX_CMUX_BIN:-cmux}" __tmux-compat "$@"
        """
        return try createTmuxCompatShimDirectory(
            directoryName: "omx-bin",
            tmuxShimScript: tmuxScript
        )
    }

    private func configureOMXEnvironment(
        processEnvironment: [String: String],
        shimDirectory: URL,
        executablePath: String,
        socketPath: String,
        explicitPassword: String?,
        focusedContext: TmuxCompatFocusedContext?
    ) {
        configureTmuxCompatEnvironment(
            processEnvironment: processEnvironment,
            shimDirectory: shimDirectory,
            executablePath: executablePath,
            socketPath: socketPath,
            explicitPassword: explicitPassword,
            focusedContext: focusedContext,
            tmuxPathPrefix: "cmux-omx",
            cmuxBinEnvVar: "CMUX_OMX_CMUX_BIN",
            termOverrideEnvVar: "CMUX_OMX_TERM"
        )
    }

    private func runOMX(
        commandArgs: [String],
        socketPath: String,
        explicitPassword: String?
    ) throws {
        let processEnvironment = ProcessInfo.processInfo.environment
        var launcherEnvironment = processEnvironment
        launcherEnvironment["CMUX_SOCKET_PATH"] = socketPath
        launcherEnvironment["CMUX_SOCKET"] = socketPath
        if let explicitPassword,
           !explicitPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            launcherEnvironment["CMUX_SOCKET_PASSWORD"] = explicitPassword
        }

        let omxExecutablePath = resolveOMXExecutable(searchPath: launcherEnvironment["PATH"])
        if omxExecutablePath == nil {
            let checkProcess = Process()
            checkProcess.executableURL = URL(fileURLWithPath: "/usr/bin/which")
            checkProcess.arguments = ["omx"]
            checkProcess.standardOutput = Pipe()
            checkProcess.standardError = Pipe()
            try? checkProcess.run()
            checkProcess.waitUntilExit()
            if checkProcess.terminationStatus != 0 {
                throw CLIError(message: "omx is not installed. Install it first:\n  npm install -g oh-my-codex\n\nThen run: cmux omx")
            }
        }

        let shimDirectory = try createOMXShimDirectory()
        let executablePath = resolvedExecutableURL()?.path ?? (args.first ?? "cmux")
        let focusedContext = tmuxCompatFocusedContext(
            processEnvironment: launcherEnvironment,
            explicitPassword: explicitPassword
        )
        configureOMXEnvironment(
            processEnvironment: launcherEnvironment,
            shimDirectory: shimDirectory,
            executablePath: executablePath,
            socketPath: socketPath,
            explicitPassword: explicitPassword,
            focusedContext: focusedContext
        )

        let launchPath = omxExecutablePath ?? "omx"
        exportAgentLaunchCommandEnvironment(
            launcher: "omx",
            executablePath: executablePath,
            arguments: [executablePath, "omx"] + commandArgs,
            workingDirectory: launcherEnvironment["PWD"]
        )
        var argv = ([launchPath] + commandArgs).map { strdup($0) }
        defer {
            for item in argv {
                free(item)
            }
        }
        argv.append(nil)

        if omxExecutablePath != nil {
            execv(launchPath, &argv)
        } else {
            execvp("omx", &argv)
        }
        let code = errno
        throw CLIError(message: "Failed to launch omx: \(String(cString: strerror(code)))\n\nIs oh-my-codex installed? Install with:\n  npm install -g oh-my-codex")
    }

    // MARK: - cmux omc (Oh My Claude Code)

    private func resolveOMCExecutable(searchPath: String?) -> String? {
        resolveExecutableInSearchPath("omc", searchPath: searchPath)
    }

    private func createOMCShimDirectory() throws -> URL {
        let tmuxScript = """
        #!/usr/bin/env bash
        set -euo pipefail
        case "${1:-}" in
          -V|-v) echo "tmux 3.4"; exit 0 ;;
        esac
        exec "${CMUX_OMC_CMUX_BIN:-cmux}" __tmux-compat "$@"
        """
        return try createTmuxCompatShimDirectory(
            directoryName: "omc-bin",
            tmuxShimScript: tmuxScript
        )
    }

    private func configureOMCEnvironment(
        processEnvironment: [String: String],
        shimDirectory: URL,
        executablePath: String,
        socketPath: String,
        explicitPassword: String?,
        focusedContext: TmuxCompatFocusedContext?
    ) {
        configureTmuxCompatEnvironment(
            processEnvironment: processEnvironment,
            shimDirectory: shimDirectory,
            executablePath: executablePath,
            socketPath: socketPath,
            explicitPassword: explicitPassword,
            focusedContext: focusedContext,
            tmuxPathPrefix: "cmux-omc",
            cmuxBinEnvVar: "CMUX_OMC_CMUX_BIN",
            termOverrideEnvVar: "CMUX_OMC_TERM"
        )
        // omc wraps Claude Code, so it needs the same NODE_OPTIONS restore module
        guard let restoreModuleURL = try? createClaudeNodeOptionsRestoreModule() else {
            unsetenv("CMUX_ORIGINAL_NODE_OPTIONS_PRESENT")
            unsetenv("CMUX_ORIGINAL_NODE_OPTIONS")
            return
        }
        if let existing = processEnvironment["NODE_OPTIONS"] {
            setenv("CMUX_ORIGINAL_NODE_OPTIONS_PRESENT", "1", 1)
            setenv("CMUX_ORIGINAL_NODE_OPTIONS", normalizedNodeOptionsForRestore(existing), 1)
        } else {
            setenv("CMUX_ORIGINAL_NODE_OPTIONS_PRESENT", "0", 1)
            unsetenv("CMUX_ORIGINAL_NODE_OPTIONS")
        }
        setenv(
            "NODE_OPTIONS",
            mergedNodeOptions(
                existing: processEnvironment["NODE_OPTIONS"],
                restoreModulePath: restoreModuleURL.path
            ),
            1
        )
    }

    private func runOMC(
        commandArgs: [String],
        socketPath: String,
        explicitPassword: String?
    ) throws {
        let processEnvironment = ProcessInfo.processInfo.environment
        var launcherEnvironment = processEnvironment
        launcherEnvironment["CMUX_SOCKET_PATH"] = socketPath
        launcherEnvironment["CMUX_SOCKET"] = socketPath
        if let explicitPassword,
           !explicitPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            launcherEnvironment["CMUX_SOCKET_PASSWORD"] = explicitPassword
        }

        let omcExecutablePath = resolveOMCExecutable(searchPath: launcherEnvironment["PATH"])
        if omcExecutablePath == nil {
            let checkProcess = Process()
            checkProcess.executableURL = URL(fileURLWithPath: "/usr/bin/which")
            checkProcess.arguments = ["omc"]
            checkProcess.standardOutput = Pipe()
            checkProcess.standardError = Pipe()
            try? checkProcess.run()
            checkProcess.waitUntilExit()
            if checkProcess.terminationStatus != 0 {
                throw CLIError(message: "omc is not installed. Install it first:\n  npm install -g oh-my-claude-sisyphus\n\nThen run: cmux omc")
            }
        }

        let shimDirectory = try createOMCShimDirectory()
        let executablePath = resolvedExecutableURL()?.path ?? (args.first ?? "cmux")
        let focusedContext = tmuxCompatFocusedContext(
            processEnvironment: launcherEnvironment,
            explicitPassword: explicitPassword
        )
        configureOMCEnvironment(
            processEnvironment: launcherEnvironment,
            shimDirectory: shimDirectory,
            executablePath: executablePath,
            socketPath: socketPath,
            explicitPassword: explicitPassword,
            focusedContext: focusedContext
        )

        let launchPath = omcExecutablePath ?? "omc"
        exportAgentLaunchCommandEnvironment(
            launcher: "omc",
            executablePath: executablePath,
            arguments: [executablePath, "omc"] + commandArgs,
            workingDirectory: launcherEnvironment["PWD"]
        )
        var argv = ([launchPath] + commandArgs).map { strdup($0) }
        defer {
            for item in argv {
                free(item)
            }
        }
        argv.append(nil)

        if omcExecutablePath != nil {
            execv(launchPath, &argv)
        } else {
            execvp("omc", &argv)
        }
        let code = errno
        throw CLIError(message: "Failed to launch omc: \(String(cString: strerror(code)))\n\nIs oh-my-claude-sisyphus installed? Install with:\n  npm install -g oh-my-claude-sisyphus")
    }

    private func runClaudeTeamsTmuxCompat(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        let (command, rawArgs) = try splitTmuxCommand(commandArgs)

        switch command {
        case "new-session", "new":
            let parsed = try parseTmuxArguments(
                rawArgs,
                valueFlags: ["-c", "-F", "-n", "-s"],
                boolFlags: ["-A", "-d", "-P"]
            )
            if parsed.hasFlag("-A") {
                throw CLIError(message: "new-session -A is not supported in cmux claude-teams mode")
            }
            var params: [String: Any] = ["focus": false]
            if let cwd = parsed.value("-c") {
                params["cwd"] = resolvePath(cwd)
            }
            let created = try client.sendV2(method: "workspace.create", params: params)
            guard let workspaceId = created["workspace_id"] as? String else {
                throw CLIError(message: "workspace.create did not return workspace_id")
            }
            if let title = parsed.value("-n") ?? parsed.value("-s"),
               !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                _ = try client.sendV2(method: "workspace.rename", params: [
                    "workspace_id": workspaceId,
                    "title": title
                ])
            }
            if let text = tmuxShellCommandText(commandTokens: parsed.positional, cwd: parsed.value("-c")) {
                let surfaceId = try resolveSurfaceId(nil, workspaceId: workspaceId, client: client)
                _ = try client.sendV2(method: "surface.send_text", params: [
                    "workspace_id": workspaceId,
                    "surface_id": surfaceId,
                    "text": text
                ])
            }
            if parsed.hasFlag("-P") {
                let context = try tmuxFormatContext(workspaceId: workspaceId, client: client)
                print(tmuxRenderFormat(parsed.value("-F"), context: context, fallback: "@\(workspaceId)"))
            }

        case "new-window", "neww":
            let parsed = try parseTmuxArguments(
                rawArgs,
                valueFlags: ["-c", "-F", "-n", "-t"],
                boolFlags: ["-d", "-P"]
            )
            if parsed.value("-t") != nil {
                throw CLIError(message: "new-window -t is not supported in cmux claude-teams mode")
            }
            var params: [String: Any] = ["focus": false]
            if let cwd = parsed.value("-c") {
                params["cwd"] = resolvePath(cwd)
            }
            let created = try client.sendV2(method: "workspace.create", params: params)
            guard let workspaceId = created["workspace_id"] as? String else {
                throw CLIError(message: "workspace.create did not return workspace_id")
            }
            if let title = parsed.value("-n"),
               !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                _ = try client.sendV2(method: "workspace.rename", params: [
                    "workspace_id": workspaceId,
                    "title": title
                ])
            }
            if let text = tmuxShellCommandText(commandTokens: parsed.positional, cwd: parsed.value("-c")) {
                let surfaceId = try resolveSurfaceId(nil, workspaceId: workspaceId, client: client)
                _ = try client.sendV2(method: "surface.send_text", params: [
                    "workspace_id": workspaceId,
                    "surface_id": surfaceId,
                    "text": text
                ])
            }
            if parsed.hasFlag("-P") {
                let context = try tmuxFormatContext(workspaceId: workspaceId, client: client)
                print(tmuxRenderFormat(parsed.value("-F"), context: context, fallback: "@\(workspaceId)"))
            }

        case "split-window", "splitw":
            let parsed = try parseTmuxArguments(
                rawArgs,
                valueFlags: ["-c", "-F", "-l", "-t"],
                boolFlags: ["-P", "-b", "-d", "-h", "-v"]
            )
            var target = try tmuxResolveSurfaceTarget(parsed.value("-t"), client: client)
            var direction: String
            var anchoredCallerSurfaceId: String?
            if parsed.hasFlag("-h") {
                direction = parsed.hasFlag("-b") ? "left" : "right"
            } else {
                direction = parsed.hasFlag("-b") ? "up" : "down"
            }

            // Claude's agent teams targets arbitrary panes (from list-panes),
            // not necessarily the leader pane from TMUX_PANE. Override the
            // target to anchor all teammate splits to the leader surface.
            // Only apply caller anchoring when the caller's workspace resolves
            // successfully. Falling back to target.workspaceId would pair
            // the caller's surface with a different workspace, creating an
            // invalid cross-workspace split.
            if let callerWorkspace = tmuxCallerWorkspaceHandle(),
               let wsId = try? resolveWorkspaceId(callerWorkspace, client: client),
               let anchoredTarget = tmuxAnchoredSplitTarget(workspaceId: wsId, client: client) {
                target = (wsId, nil, anchoredTarget.targetSurfaceId)
                direction = anchoredTarget.direction
                anchoredCallerSurfaceId = anchoredTarget.callerSurfaceId
            }

            // Keep the leader pane focused while agents spawn beside it.
            // -d explicitly means "don't focus the new pane".
            let focusNewPane = !parsed.hasFlag("-d")
            let created = try client.sendV2(method: "surface.split", params: [
                "workspace_id": target.workspaceId,
                "surface_id": target.surfaceId,
                "direction": direction,
                "focus": focusNewPane
            ])
            guard let surfaceId = created["surface_id"] as? String else {
                throw CLIError(message: "surface.split did not return surface_id")
            }
            let paneId = created["pane_id"] as? String

            // Track the newly created pane for main-vertical layout.
            do {
                var updatedStore = loadTmuxCompatStore()
                updatedStore.lastSplitSurface[target.workspaceId] = surfaceId
                if updatedStore.mainVerticalLayouts[target.workspaceId] != nil {
                    updatedStore.mainVerticalLayouts[target.workspaceId]?.lastColumnSurfaceId = surfaceId
                } else if direction == "right", let anchoredCallerSurfaceId {
                    // First right split created the column; seed main-vertical
                    // state so subsequent splits stack downward.
                    updatedStore.mainVerticalLayouts[target.workspaceId] = MainVerticalState(
                        mainSurfaceId: anchoredCallerSurfaceId,
                        lastColumnSurfaceId: surfaceId
                    )
                }
                try saveTmuxCompatStore(updatedStore)
            }

            // Equalize vertical splits so teammate panes are evenly distributed.
            // Use orientation: "vertical" to only equalize the agent column,
            // preserving the leader/column horizontal divider position.
            _ = try? client.sendV2(method: "workspace.equalize_splits", params: [
                "workspace_id": target.workspaceId,
                "orientation": "vertical"
            ])

            if let text = tmuxShellCommandText(commandTokens: parsed.positional, cwd: parsed.value("-c")) {
                _ = try client.sendV2(method: "surface.send_text", params: [
                    "workspace_id": target.workspaceId,
                    "surface_id": surfaceId,
                    "text": text
                ])
            }
            if parsed.hasFlag("-P") {
                let context = try tmuxFormatContext(
                    workspaceId: target.workspaceId,
                    paneId: paneId,
                    surfaceId: surfaceId,
                    client: client
                )
                let fallback = context["pane_id"] ?? surfaceId
                print(tmuxRenderFormat(parsed.value("-F"), context: context, fallback: fallback))
            }

        case "select-window", "selectw":
            let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-t"], boolFlags: [])
            let workspaceId = try tmuxResolveWorkspaceTarget(parsed.value("-t"), client: client)
            _ = try client.sendV2(method: "workspace.select", params: ["workspace_id": workspaceId])

        case "select-pane", "selectp":
            let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-P", "-T", "-t"], boolFlags: [])
            if parsed.value("-P") != nil || parsed.value("-T") != nil {
                return
            }
            let target = try tmuxResolvePaneTarget(parsed.value("-t"), client: client)
            _ = try client.sendV2(method: "pane.focus", params: [
                "workspace_id": target.workspaceId,
                "pane_id": target.paneId
            ])

        case "kill-window", "killw":
            let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-t"], boolFlags: [])
            let workspaceId = try tmuxResolveWorkspaceTarget(parsed.value("-t"), client: client)
            _ = try client.sendV2(method: "workspace.close", params: ["workspace_id": workspaceId])
            try? tmuxPruneCompatWorkspaceState(workspaceId: workspaceId)

        case "kill-pane", "killp":
            let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-t"], boolFlags: [])
            let target = try tmuxResolveSurfaceTarget(parsed.value("-t"), client: client)
            _ = try client.sendV2(method: "surface.close", params: [
                "workspace_id": target.workspaceId,
                "surface_id": target.surfaceId
            ])
            try? tmuxPruneCompatSurfaceState(
                workspaceId: target.workspaceId,
                surfaceId: target.surfaceId,
                client: client
            )
            // Re-equalize the agent column after removing a pane
            _ = try? client.sendV2(method: "workspace.equalize_splits", params: [
                "workspace_id": target.workspaceId,
                "orientation": "vertical"
            ])

        case "send-keys", "send":
            let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-t"], boolFlags: ["-l"])
            let target = try tmuxResolveSurfaceTarget(parsed.value("-t"), client: client)
            let text = tmuxSendKeysText(from: parsed.positional, literal: parsed.hasFlag("-l"))
            if !text.isEmpty {
                _ = try client.sendV2(method: "surface.send_text", params: [
                    "workspace_id": target.workspaceId,
                    "surface_id": target.surfaceId,
                    "text": text
                ])
            }

        case "capture-pane", "capturep":
            let parsed = try parseTmuxArguments(
                rawArgs,
                valueFlags: ["-E", "-S", "-t"],
                boolFlags: ["-J", "-N", "-p"]
            )
            let target = try tmuxResolveSurfaceTarget(parsed.value("-t"), client: client)
            var params: [String: Any] = [
                "workspace_id": target.workspaceId,
                "surface_id": target.surfaceId,
                "scrollback": true
            ]
            if let start = parsed.value("-S"), let lines = Int(start), lines < 0 {
                params["lines"] = abs(lines)
            }
            let payload = try client.sendV2(method: "surface.read_text", params: params)
            let text = (payload["text"] as? String) ?? ""
            if parsed.hasFlag("-p") {
                print(text)
            } else {
                var store = loadTmuxCompatStore()
                store.buffers["default"] = text
                try saveTmuxCompatStore(store)
            }

        case "display-message", "display", "displayp":
            let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-F", "-t"], boolFlags: ["-p"])
            let target = try tmuxResolveSurfaceTarget(parsed.value("-t"), client: client)
            var context = try tmuxFormatContext(
                workspaceId: target.workspaceId,
                paneId: target.paneId,
                surfaceId: target.surfaceId,
                client: client
            )
            // Enrich with geometry for format strings like #{pane_width},#{window_width}
            let panePayload = try client.sendV2(method: "pane.list", params: ["workspace_id": target.workspaceId])
            let panesList = panePayload["panes"] as? [[String: Any]] ?? []
            let containerFrame = panePayload["container_frame"] as? [String: Any]
            if let targetPaneId = target.paneId,
               let matchingPane = panesList.first(where: { ($0["id"] as? String) == targetPaneId }) {
                tmuxEnrichContextWithGeometry(&context, pane: matchingPane, containerFrame: containerFrame)
            } else if let firstPane = panesList.first(where: { ($0["focused"] as? Bool) == true }) ?? panesList.first {
                tmuxEnrichContextWithGeometry(&context, pane: firstPane, containerFrame: containerFrame)
            }
            let format = parsed.positional.isEmpty ? parsed.value("-F") : parsed.positional.joined(separator: " ")
            let rendered = tmuxRenderFormat(format, context: context, fallback: "")
            if parsed.hasFlag("-p") || !rendered.isEmpty {
                print(rendered)
            }

        case "list-windows", "lsw":
            let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-F", "-t"], boolFlags: [])
            let items = try tmuxWorkspaceItems(client: client)
            for item in items {
                guard let workspaceId = item["id"] as? String else { continue }
                let context = try tmuxFormatContext(workspaceId: workspaceId, client: client)
                let fallback = [
                    context["window_index"] ?? "?",
                    context["window_name"] ?? workspaceId
                ].joined(separator: " ")
                print(tmuxRenderFormat(parsed.value("-F"), context: context, fallback: fallback))
            }

        case "list-panes", "lsp":
            let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-F", "-t"], boolFlags: [])
            // Resolve target: can be a pane (%uuid) or workspace. In tmux,
            // list-panes -t %<pane> lists all panes in the window containing that pane.
            let workspaceId: String
            if let target = parsed.value("-t"), tmuxPaneSelector(from: target) != nil {
                let paneTarget = try tmuxResolvePaneTarget(target, client: client)
                workspaceId = paneTarget.workspaceId
            } else {
                workspaceId = try tmuxResolveWorkspaceTarget(parsed.value("-t"), client: client)
            }
            let payload = try client.sendV2(method: "pane.list", params: ["workspace_id": workspaceId])
            let panes = payload["panes"] as? [[String: Any]] ?? []
            let containerFrame = payload["container_frame"] as? [String: Any]
            for pane in panes {
                guard let paneId = pane["id"] as? String else { continue }
                var context = try tmuxFormatContext(workspaceId: workspaceId, paneId: paneId, client: client)
                tmuxEnrichContextWithGeometry(&context, pane: pane, containerFrame: containerFrame)
                let fallback = context["pane_id"] ?? paneId
                print(tmuxRenderFormat(parsed.value("-F"), context: context, fallback: fallback))
            }

        case "rename-window", "renamew":
            let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-t"], boolFlags: [])
            let title = parsed.positional.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else {
                throw CLIError(message: "rename-window requires a title")
            }
            let workspaceId = try tmuxResolveWorkspaceTarget(parsed.value("-t"), client: client)
            _ = try client.sendV2(method: "workspace.rename", params: [
                "workspace_id": workspaceId,
                "title": title
            ])

        case "resize-pane", "resizep":
            let parsed = try parseTmuxArguments(
                rawArgs,
                valueFlags: ["-t", "-x", "-y"],
                boolFlags: ["-D", "-L", "-R", "-U"]
            )
            let hasDirectionalFlags = parsed.hasFlag("-L")
                || parsed.hasFlag("-R")
                || parsed.hasFlag("-U")
                || parsed.hasFlag("-D")
            let target = try tmuxResolvePaneTarget(parsed.value("-t"), client: client)

            if !hasDirectionalFlags, let absWidth = parsed.value("-x").flatMap({ Int($0.replacingOccurrences(of: "%", with: "")) }) {
                // Absolute width: resize-pane -t <pane> -x <columns>
                // Compute pixel delta from current width to desired width.
                let panePayload = try client.sendV2(method: "pane.list", params: ["workspace_id": target.workspaceId])
                let panes = panePayload["panes"] as? [[String: Any]] ?? []
                if let matchingPane = panes.first(where: { ($0["id"] as? String) == target.paneId }),
                   let cellW = matchingPane["cell_width_px"] as? Int, cellW > 0,
                   let currentCols = matchingPane["columns"] as? Int {
                    let delta = absWidth - currentCols
                    if delta != 0 {
                        _ = try? client.sendV2(method: "pane.resize", params: [
                            "workspace_id": target.workspaceId,
                            "pane_id": target.paneId,
                            "direction": delta > 0 ? "right" : "left",
                            "amount": abs(delta) * cellW
                        ])
                    }
                }
            } else if hasDirectionalFlags {
                let direction: String
                if parsed.hasFlag("-L") {
                    direction = "left"
                } else if parsed.hasFlag("-U") {
                    direction = "up"
                } else if parsed.hasFlag("-D") {
                    direction = "down"
                } else {
                    direction = "right"
                }
                let rawAmount = (parsed.value("-x") ?? parsed.value("-y") ?? "5")
                    .replacingOccurrences(of: "%", with: "")
                let amount = Int(rawAmount) ?? 5
                _ = try client.sendV2(method: "pane.resize", params: [
                    "workspace_id": target.workspaceId,
                    "pane_id": target.paneId,
                    "direction": direction,
                    "amount": max(1, amount)
                ])
            }

        case "wait-for":
            try runTmuxCompatCommand(
                command: "wait-for",
                commandArgs: rawArgs,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat,
                windowOverride: windowOverride
            )

        case "last-pane":
            let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-t"], boolFlags: [])
            let workspaceId = try tmuxResolveWorkspaceTarget(parsed.value("-t"), client: client)
            _ = try client.sendV2(method: "pane.last", params: ["workspace_id": workspaceId])

        case "show-buffer", "showb":
            let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-b"], boolFlags: [])
            let name = parsed.value("-b") ?? "default"
            let store = loadTmuxCompatStore()
            if let buffer = store.buffers[name] {
                print(buffer)
            }

        case "save-buffer", "saveb":
            let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-b"], boolFlags: [])
            let name = parsed.value("-b") ?? "default"
            let store = loadTmuxCompatStore()
            guard let buffer = store.buffers[name] else {
                throw CLIError(message: "Buffer not found: \(name)")
            }
            if let outputPath = parsed.positional.last, !outputPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try buffer.write(toFile: resolvePath(outputPath), atomically: true, encoding: .utf8)
            } else {
                print(buffer)
            }

        case "last-window", "next-window", "previous-window", "set-hook", "set-buffer", "list-buffers":
            try runTmuxCompatCommand(
                command: command,
                commandArgs: rawArgs,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat,
                windowOverride: windowOverride
            )

        case "has-session", "has":
            let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-t"], boolFlags: [])
            _ = try tmuxResolveWorkspaceTarget(parsed.value("-t"), client: client)

        case "select-layout":
            let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-t"], boolFlags: [])
            let layoutName = parsed.positional.first ?? ""
            // select-layout -t accepts pane targets (e.g. %1) in real tmux.
            // Try pane target first, then workspace target. Only fall back to
            // the caller's current workspace when no -t was provided; an
            // explicit -t that fails to resolve should error, not silently
            // apply to the wrong workspace.
            let workspaceId: String = {
                if let target = parsed.value("-t") {
                    if let resolved = try? tmuxResolvePaneTarget(target, client: client) {
                        return resolved.workspaceId
                    }
                    return (try? tmuxResolveWorkspaceTarget(target, client: client)) ?? ""
                }
                return (try? tmuxResolveWorkspaceTarget(nil, client: client)) ?? ""
            }()
            guard !workspaceId.isEmpty else {
                throw CLIError(message: "Could not resolve workspace for select-layout")
            }
            if layoutName == "main-vertical" || layoutName == "main-horizontal" {
                // For main-* layouts, only equalize the agent column (vertical splits),
                // not the top-level horizontal split between main and agents.
                let orientation = layoutName == "main-vertical" ? "vertical" : "horizontal"
                _ = try? client.sendV2(method: "workspace.equalize_splits", params: [
                    "workspace_id": workspaceId,
                    "orientation": orientation
                ])
            } else {
                // For tiled/even-* layouts, equalize everything
                _ = try? client.sendV2(method: "workspace.equalize_splits", params: ["workspace_id": workspaceId])
            }
            if layoutName == "main-vertical" {
                if let callerSurface = tmuxCallerSurfaceHandle() {
                    var store = loadTmuxCompatStore()
                    let existingColumn = store.mainVerticalLayouts[workspaceId]?.lastColumnSurfaceId
                    let seedColumn = existingColumn ?? store.lastSplitSurface[workspaceId]
                    store.mainVerticalLayouts[workspaceId] = MainVerticalState(
                        mainSurfaceId: callerSurface,
                        lastColumnSurfaceId: seedColumn
                    )
                    try saveTmuxCompatStore(store)
                }
            } else if !layoutName.isEmpty {
                // Non-main-vertical layout selected: clear stale state so
                // future splits don't incorrectly redirect to the old column.
                try tmuxPruneCompatWorkspaceState(workspaceId: workspaceId)
            }

        case "set-option", "set", "set-window-option", "setw", "source-file", "refresh-client", "attach-session", "detach-client":
            return

        case "-V", "-v":
            print("tmux 3.4")
            return

        default:
            throw CLIError(message: "Unsupported tmux compatibility command: \(command)")
        }
    }

    private struct MainVerticalState: Codable {
        /// The surface ID of the "main" (leader) pane on the left side.
        var mainSurfaceId: String
        /// The surface ID of the bottom-most pane in the right column.
        /// Subsequent teammate splits target this pane with direction "down".
        var lastColumnSurfaceId: String?
    }

    private struct TmuxCompatStore: Codable {
        var buffers: [String: String] = [:]
        var hooks: [String: String] = [:]
        /// Tracks main-vertical layout state per workspace, keyed by workspace ID.
        var mainVerticalLayouts: [String: MainVerticalState] = [:]
        /// Tracks the last surface created by split-window per workspace.
        /// Used to seed lastColumnSurfaceId when select-layout main-vertical
        /// is called after the first split.
        var lastSplitSurface: [String: String] = [:]

        /// Custom decoder so older store files missing newer keys
        /// (mainVerticalLayouts, lastSplitSurface) decode gracefully
        /// instead of throwing and resetting the entire store.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            buffers = try container.decodeIfPresent([String: String].self, forKey: .buffers) ?? [:]
            hooks = try container.decodeIfPresent([String: String].self, forKey: .hooks) ?? [:]
            mainVerticalLayouts = try container.decodeIfPresent([String: MainVerticalState].self, forKey: .mainVerticalLayouts) ?? [:]
            lastSplitSurface = try container.decodeIfPresent([String: String].self, forKey: .lastSplitSurface) ?? [:]
        }

        init() {}
    }

    private func tmuxCompatStoreURL() -> URL {
        let homePath = ProcessInfo.processInfo.environment["HOME"]
            ?? NSString(string: "~").expandingTildeInPath
        return URL(fileURLWithPath: homePath)
            .appendingPathComponent(".cmuxterm")
            .appendingPathComponent("tmux-compat-store.json")
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

    private func tmuxPruneCompatWorkspaceState(workspaceId: String) throws {
        var store = loadTmuxCompatStore()
        let removedLayout = store.mainVerticalLayouts.removeValue(forKey: workspaceId) != nil
        let removedSplit = store.lastSplitSurface.removeValue(forKey: workspaceId) != nil
        if removedLayout || removedSplit {
            try saveTmuxCompatStore(store)
        }
    }

    private func tmuxCompatPaneAnchorSurfaceId(_ pane: [String: Any]) -> String? {
        if let selected = pane["selected_surface_id"] as? String, !selected.isEmpty {
            return selected
        }
        let surfaceIds = pane["surface_ids"] as? [String] ?? []
        return surfaceIds.first
    }

    private func tmuxCompatPanePixelFrame(_ pane: [String: Any]) -> (x: Double, y: Double)? {
        guard let frame = pane["pixel_frame"] as? [String: Any],
              let x = doubleFromAny(frame["x"]),
              let y = doubleFromAny(frame["y"]) else {
            return nil
        }
        return (x, y)
    }

    private func tmuxReplacementColumnSurfaceId(
        workspaceId: String,
        layout: MainVerticalState,
        client: SocketClient
    ) -> String? {
        guard let payload = try? client.sendV2(method: "pane.list", params: ["workspace_id": workspaceId]) else {
            return nil
        }
        let panes = payload["panes"] as? [[String: Any]] ?? []
        guard !panes.isEmpty else { return nil }

        guard let mainPane = panes.first(where: { pane in
            let surfaceIds = pane["surface_ids"] as? [String] ?? []
            if surfaceIds.contains(layout.mainSurfaceId) {
                return true
            }
            return (pane["selected_surface_id"] as? String) == layout.mainSurfaceId
        }) else {
            return nil
        }

        let mainPaneId = mainPane["id"] as? String
        let nonMainPanes = panes.filter { ($0["id"] as? String) != mainPaneId }
        guard !nonMainPanes.isEmpty else { return nil }

        let candidatePanes: [[String: Any]]
        if let mainFrame = tmuxCompatPanePixelFrame(mainPane) {
            let rightColumn = nonMainPanes.filter { pane in
                guard let frame = tmuxCompatPanePixelFrame(pane) else { return false }
                return frame.x > mainFrame.x + 0.5
            }
            candidatePanes = rightColumn.isEmpty ? nonMainPanes : rightColumn
        } else {
            candidatePanes = nonMainPanes
        }

        let bottomMostPane = candidatePanes.max { lhs, rhs in
            let lhsFrame = tmuxCompatPanePixelFrame(lhs)
            let rhsFrame = tmuxCompatPanePixelFrame(rhs)
            switch (lhsFrame, rhsFrame) {
            case let (.some(lhsFrame), .some(rhsFrame)):
                if lhsFrame.y == rhsFrame.y {
                    return lhsFrame.x < rhsFrame.x
                }
                return lhsFrame.y < rhsFrame.y
            case (.none, .some):
                return true
            case (.some, .none):
                return false
            case (.none, .none):
                return false
            }
        }

        return bottomMostPane.flatMap { tmuxCompatPaneAnchorSurfaceId($0) }
    }

    private func tmuxPruneCompatSurfaceState(
        workspaceId: String,
        surfaceId: String,
        client: SocketClient
    ) throws {
        var store = loadTmuxCompatStore()
        var changed = false

        if store.lastSplitSurface[workspaceId] == surfaceId {
            store.lastSplitSurface.removeValue(forKey: workspaceId)
            changed = true
        }

        if let layout = store.mainVerticalLayouts[workspaceId] {
            if layout.mainSurfaceId == surfaceId {
                store.mainVerticalLayouts.removeValue(forKey: workspaceId)
                store.lastSplitSurface.removeValue(forKey: workspaceId)
                changed = true
            } else if layout.lastColumnSurfaceId == surfaceId {
                var updatedLayout = layout
                let replacementSurfaceId = tmuxReplacementColumnSurfaceId(
                    workspaceId: workspaceId,
                    layout: layout,
                    client: client
                )
                updatedLayout.lastColumnSurfaceId = replacementSurfaceId
                store.mainVerticalLayouts[workspaceId] = updatedLayout
                if let replacementSurfaceId {
                    store.lastSplitSurface[workspaceId] = replacementSurfaceId
                } else {
                    store.lastSplitSurface.removeValue(forKey: workspaceId)
                }
                changed = true
            }
        }

        if changed {
            try saveTmuxCompatStore(store)
        }
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
            do {
                try SocketClient.waitForFilesystemPath(signalURL.path, timeout: max(0, deadline.timeIntervalSinceNow))
                try? FileManager.default.removeItem(at: signalURL)
                print("OK")
                return
            } catch {
                if FileManager.default.fileExists(atPath: signalURL.path) {
                    try? FileManager.default.removeItem(at: signalURL)
                    print("OK")
                    return
                }
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

        switch subcommand {
        case "session-start", "active":
            telemetry.breadcrumb("claude-hook.session-start")
            let workspaceId = try resolvePreferredWorkspaceIdForClaudeHook(
                preferred: nil,
                fallback: workspaceArg,
                client: client
            )
            let surfaceId = try resolvePreferredSurfaceIdForClaudeHook(
                preferred: nil,
                fallback: surfaceArg,
                workspaceId: workspaceId,
                client: client
            )
            let claudePid: Int? = {
                guard let raw = ProcessInfo.processInfo.environment["CMUX_CLAUDE_PID"]?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                    let pid = Int(raw),
                    pid > 0 else {
                    return nil
                }
                return pid
            }()
            let launchCommand = agentLaunchCommandFromEnvironment(
                ProcessInfo.processInfo.environment,
                fallbackPID: claudePid,
                fallbackKind: "claude",
                cwd: parsedInput.cwd
            )
            if let sessionId = parsedInput.sessionId {
                try? sessionStore.upsert(
                    sessionId: sessionId,
                    workspaceId: workspaceId,
                    surfaceId: surfaceId,
                    cwd: parsedInput.cwd,
                    pid: claudePid,
                    launchCommand: launchCommand
                )
            }
            // Register PID for stale-session detection and OSC suppression,
            // but don't set a visible status. "Running" only appears when the
            // user submits a prompt (UserPromptSubmit) or Claude starts working
            // (PreToolUse).
            if let claudePid {
                _ = try? sendV1Command(
                    "set_agent_pid claude_code \(claudePid) --tab=\(workspaceId)",
                    client: client
                )
            }
            print("OK")

        case "stop", "idle":
            telemetry.breadcrumb("claude-hook.stop")
            do {
                // Turn ended. Don't consume session or clear PID — Claude is still alive.
                // Notification hook handles user-facing notifications; SessionEnd handles cleanup.
                let mappedSession = parsedInput.sessionId.flatMap { try? sessionStore.lookup(sessionId: $0) }
                let workspaceId = try resolvePreferredWorkspaceIdForClaudeHook(
                    preferred: mappedSession?.workspaceId,
                    fallback: workspaceArg,
                    client: client
                )
                let surfaceId = try resolvePreferredSurfaceIdForClaudeHook(
                    preferred: mappedSession?.surfaceId,
                    fallback: surfaceArg,
                    workspaceId: workspaceId,
                    client: client
                )

                // Update session with transcript summary and send completion notification.
                let completion = summarizeClaudeHookStop(
                    parsedInput: parsedInput,
                    sessionRecord: mappedSession
                )
                if let sessionId = parsedInput.sessionId, let completion {
                    try? sessionStore.upsert(
                        sessionId: sessionId,
                        workspaceId: workspaceId,
                        surfaceId: surfaceId,
                        cwd: parsedInput.cwd,
                        lastSubtitle: completion.subtitle,
                        lastBody: completion.body
                    )
                }

                if let completion {
                    let title = "Claude Code"
                    let subtitle = sanitizeNotificationField(completion.subtitle)
                    let body = sanitizeNotificationField(completion.body)
                    let payload = "\(title)|\(subtitle)|\(body)"
                    _ = try? sendV1Command("notify_target \(workspaceId) \(surfaceId) \(payload)", client: client)
                }

                try? setClaudeStatus(
                    client: client,
                    workspaceId: workspaceId,
                    value: "Idle",
                    icon: "pause.circle.fill",
                    color: "#8E8E93"
                )
                print("OK")
            } catch {
                if shouldIgnoreClaudeHookTeardownError(error) {
                    telemetry.breadcrumb("claude-hook.stop.ignored", data: ["error": String(describing: error)])
                    print("OK")
                    return
                }
                throw error
            }

        case "prompt-submit":
            telemetry.breadcrumb("claude-hook.prompt-submit")
            let mappedSession = parsedInput.sessionId.flatMap { try? sessionStore.lookup(sessionId: $0) }
            let workspaceId = try resolvePreferredWorkspaceIdForClaudeHook(
                preferred: mappedSession?.workspaceId,
                fallback: workspaceArg,
                client: client
            )
            _ = try sendV1Command("clear_notifications --tab=\(workspaceId)", client: client)
            try setClaudeStatus(
                client: client,
                workspaceId: workspaceId,
                value: "Running",
                icon: "bolt.fill",
                color: "#4C8DFF"
            )
            print("OK")

        case "notification", "notify":
            telemetry.breadcrumb("claude-hook.notification")
            var summary = summarizeClaudeHookNotification(parsedInput: parsedInput)

            let mappedSession = parsedInput.sessionId.flatMap { try? sessionStore.lookup(sessionId: $0) }
            let workspaceId = try resolvePreferredWorkspaceIdForClaudeHook(
                preferred: mappedSession?.workspaceId,
                fallback: workspaceArg,
                client: client
            )
            if let mappedSession,
               let savedBody = mappedSession.lastBody, !savedBody.isEmpty,
               summary.body.contains("needs your attention") || summary.body.contains("needs your input") {
                summary = (subtitle: mappedSession.lastSubtitle ?? summary.subtitle, body: savedBody)
            }

            let surfaceId = try resolvePreferredSurfaceIdForClaudeHook(
                preferred: mappedSession?.surfaceId,
                fallback: surfaceArg,
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

            let response = try client.send(command: "notify_target \(workspaceId) \(surfaceId) \(payload)")
            _ = try? setClaudeStatus(
                client: client,
                workspaceId: workspaceId,
                value: "Needs input",
                icon: "bell.fill",
                color: "#4C8DFF"
            )
            print(response)

        case "session-end":
            telemetry.breadcrumb("claude-hook.session-end")
            // Final cleanup when Claude process exits.
            // Only clear when we are the primary cleanup path (Stop didn't fire first).
            // If Stop already consumed the session, consumedSession is nil and we skip
            // to avoid wiping the completion notification that Stop just delivered.
            let mappedSession = parsedInput.sessionId.flatMap { try? sessionStore.lookup(sessionId: $0) }
            let fallbackWorkspaceId = try? resolvePreferredWorkspaceIdForClaudeHook(
                preferred: mappedSession?.workspaceId,
                fallback: workspaceArg,
                client: client
            )
            let fallbackSurfaceId: String? = {
                guard let fallbackWorkspaceId else { return nil }
                return try? resolvePreferredSurfaceIdForClaudeHook(
                    preferred: mappedSession?.surfaceId,
                    fallback: surfaceArg,
                    workspaceId: fallbackWorkspaceId,
                    client: client
                )
            }()
            let consumedSession = try? sessionStore.consume(
                sessionId: parsedInput.sessionId,
                workspaceId: fallbackWorkspaceId,
                surfaceId: fallbackSurfaceId
            )
            if let consumedSession {
                let workspaceId = consumedSession.workspaceId
                _ = try? clearClaudeStatus(client: client, workspaceId: workspaceId)
                _ = try? sendV1Command("clear_agent_pid claude_code --tab=\(workspaceId)", client: client)
                _ = try? sendV1Command("clear_notifications --tab=\(workspaceId)", client: client)
            }
            print("OK")

        case "pre-tool-use":
            telemetry.breadcrumb("claude-hook.pre-tool-use")
            // Clears "Needs input" status and notification when Claude resumes work
            // (e.g. after permission grant). Runs async so it doesn't block tool execution.
            let mappedSession = parsedInput.sessionId.flatMap { try? sessionStore.lookup(sessionId: $0) }
            let workspaceId = try resolvePreferredWorkspaceIdForClaudeHook(
                preferred: mappedSession?.workspaceId,
                fallback: workspaceArg,
                client: client
            )
            let claudePid = mappedSession?.pid

            // AskUserQuestion means Claude is about to ask the user something.
            // Save question text in session so the Notification handler can use it
            // instead of the generic "Claude Code needs your attention".
            if let toolName = parsedInput.object?["tool_name"] as? String,
               toolName == "AskUserQuestion",
               let question = describeAskUserQuestion(parsedInput.object),
               let sessionId = parsedInput.sessionId {
                // Preserve the existing surfaceId from SessionStart; passing ""
                // would overwrite it and cause notifications to target the wrong workspace.
                let existingSurfaceId = (try? sessionStore.lookup(sessionId: sessionId))?.surfaceId ?? ""
                try? sessionStore.upsert(
                    sessionId: sessionId,
                    workspaceId: workspaceId,
                    surfaceId: existingSurfaceId,
                    cwd: parsedInput.cwd,
                    lastSubtitle: "Waiting",
                    lastBody: question
                )
                // Don't clear notifications or set status here.
                // The Notification hook fires right after and will use the saved question.
                print("OK")
                return
            }

            _ = try? sendV1Command("clear_notifications --tab=\(workspaceId)", client: client)

            let statusValue: String
            if UserDefaults.standard.bool(forKey: "claudeCodeVerboseStatus"),
               let toolStatus = describeToolUse(parsedInput.object) {
                statusValue = toolStatus
            } else {
                statusValue = "Running"
            }
            try setClaudeStatus(
                client: client,
                workspaceId: workspaceId,
                value: statusValue,
                icon: "bolt.fill",
                color: "#4C8DFF",
                pid: claudePid
            )
            print("OK")

        case "help", "--help", "-h":
            telemetry.breadcrumb("claude-hook.help")
            print(
                """
                cmux claude-hook <session-start|stop|session-end|notification|prompt-submit|pre-tool-use> [--workspace <id|index>] [--surface <id|index>]
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
        color: String,
        pid: Int? = nil
    ) throws {
        var cmd = "set_status claude_code \(value) --icon=\(icon) --color=\(color) --tab=\(workspaceId)"
        if let pid {
            cmd += " --pid=\(pid)"
        }
        _ = try client.send(command: cmd)
    }

    private func clearClaudeStatus(client: SocketClient, workspaceId: String) throws {
        _ = try client.send(command: "clear_status claude_code --tab=\(workspaceId)")
    }

    private func resolvePreferredWorkspaceIdForClaudeHook(
        preferred: String?,
        fallback: String?,
        client: SocketClient
    ) throws -> String {
        if let preferred = nonEmptyClaudeHookIdentifier(preferred) {
            if isUUID(preferred) {
                return preferred
            }
            return try resolveWorkspaceIdForClaudeHook(preferred, client: client)
        }
        if let fallback = nonEmptyClaudeHookIdentifier(fallback), isUUID(fallback) {
            return fallback
        }
        return try resolveWorkspaceIdForClaudeHook(fallback, client: client)
    }

    private func resolvePreferredSurfaceIdForClaudeHook(
        preferred: String?,
        fallback: String?,
        workspaceId: String,
        client: SocketClient
    ) throws -> String {
        if let preferred = nonEmptyClaudeHookIdentifier(preferred) {
            if isUUID(preferred) {
                return preferred
            }
            return try resolveSurfaceIdForClaudeHook(preferred, workspaceId: workspaceId, client: client)
        }
        if let fallback = nonEmptyClaudeHookIdentifier(fallback), isUUID(fallback) {
            return fallback
        }
        return try resolveSurfaceIdForClaudeHook(fallback, workspaceId: workspaceId, client: client)
    }

    private func nonEmptyClaudeHookIdentifier(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private func shouldIgnoreClaudeHookTeardownError(_ error: Error) -> Bool {
        let message = String(describing: error).lowercased()
        let benignFragments = [
            "tabmanager not available",
            "no workspace selected",
            "workspace not found",
            "workspace ref not found",
            "workspace index not found",
            "surface not found",
            "surface ref not found",
            "surface index not found",
            "unable to resolve surface id",
            "panel not found",
            "tab not found",
            "failed to write to socket",
            "socket read error",
            "not connected"
        ]
        return benignFragments.contains { message.contains($0) }
    }

    private func describeAskUserQuestion(_ object: [String: Any]?) -> String? {
        guard let object,
              let input = object["tool_input"] as? [String: Any],
              let questions = input["questions"] as? [[String: Any]],
              let first = questions.first else { return nil }

        var parts: [String] = []

        if let question = first["question"] as? String, !question.isEmpty {
            parts.append(question)
        } else if let header = first["header"] as? String, !header.isEmpty {
            parts.append(header)
        }

        if let options = first["options"] as? [[String: Any]] {
            let labels = options.compactMap { $0["label"] as? String }
            if !labels.isEmpty {
                parts.append(labels.map { "[\($0)]" }.joined(separator: " "))
            }
        }

        if parts.isEmpty { return "Asking a question" }
        return parts.joined(separator: "\n")
    }

    private func describeToolUse(_ object: [String: Any]?) -> String? {
        guard let object, let toolName = object["tool_name"] as? String else { return nil }
        let input = object["tool_input"] as? [String: Any]

        switch toolName {
        case "Read":
            if let path = input?["file_path"] as? String {
                return "Reading \(shortenPath(path))"
            }
            return "Reading file"
        case "Edit":
            if let path = input?["file_path"] as? String {
                return "Editing \(shortenPath(path))"
            }
            return "Editing file"
        case "Write":
            if let path = input?["file_path"] as? String {
                return "Writing \(shortenPath(path))"
            }
            return "Writing file"
        case "Bash":
            if let cmd = input?["command"] as? String {
                let first = cmd.components(separatedBy: .whitespacesAndNewlines).first ?? cmd
                let short = String(first.prefix(30))
                return "Running \(short)"
            }
            return "Running command"
        case "Glob":
            if let pattern = input?["pattern"] as? String {
                return "Searching \(String(pattern.prefix(30)))"
            }
            return "Searching files"
        case "Grep":
            if let pattern = input?["pattern"] as? String {
                return "Grep \(String(pattern.prefix(30)))"
            }
            return "Searching code"
        case "Agent":
            if let desc = input?["description"] as? String {
                return String(desc.prefix(40))
            }
            return "Subagent"
        case "WebFetch":
            return "Fetching URL"
        case "WebSearch":
            if let query = input?["query"] as? String {
                return "Search: \(String(query.prefix(30)))"
            }
            return "Web search"
        default:
            return toolName
        }
    }

    private func shortenPath(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        return name.isEmpty ? String(path.suffix(30)) : name
    }

    private func resolveWorkspaceIdForClaudeHook(_ raw: String?, client: SocketClient) throws -> String {
        try resolveWorkspaceIdAllowingFallback(raw, client: client)
    }

    private func resolveSurfaceIdForClaudeHook(
        _ raw: String?,
        workspaceId: String,
        client: SocketClient
    ) throws -> String {
        try resolveSurfaceIdAllowingFallback(raw, workspaceId: workspaceId, client: client)
    }

    private func resolveWorkspaceIdAllowingFallback(
        _ raw: String?,
        client: SocketClient
    ) throws -> String {
        if let raw,
           !raw.isEmpty,
           let candidate = try? resolveWorkspaceId(raw, client: client),
           (try? client.sendV2(method: "surface.list", params: ["workspace_id": candidate])) != nil {
            return candidate
        }
        if let callerWorkspaceId = resolveCallerWorkspaceIdByTTY(client: client),
           (try? client.sendV2(method: "surface.list", params: ["workspace_id": callerWorkspaceId])) != nil {
            return callerWorkspaceId
        }
        return try resolveWorkspaceId(nil, client: client)
    }

    private func resolveSurfaceIdAllowingFallback(
        _ raw: String?,
        workspaceId: String,
        client: SocketClient
    ) throws -> String {
        if let raw,
           !raw.isEmpty,
           let candidate = try? resolveSurfaceId(raw, workspaceId: workspaceId, client: client),
           let listed = try? client.sendV2(method: "surface.list", params: ["workspace_id": workspaceId]) {
            let items = listed["surfaces"] as? [[String: Any]] ?? []
            if items.contains(where: {
                ($0["id"] as? String) == candidate || ($0["ref"] as? String) == candidate
            }) {
                return candidate
            }
        }
        if let callerSurfaceId = resolveCallerSurfaceIdByTTY(workspaceId: workspaceId, client: client),
           let listed = try? client.sendV2(method: "surface.list", params: ["workspace_id": workspaceId]) {
            let items = listed["surfaces"] as? [[String: Any]] ?? []
            if items.contains(where: {
                ($0["id"] as? String) == callerSurfaceId || ($0["ref"] as? String) == callerSurfaceId
            }) {
                return callerSurfaceId
            }
        }
        return try resolveSurfaceId(nil, workspaceId: workspaceId, client: client)
    }

    private struct CallerTerminalBinding {
        let workspaceId: String
        let surfaceId: String
    }

    private func resolveCallerWorkspaceIdByTTY(client: SocketClient) -> String? {
        resolveCallerTerminalBindingByTTY(client: client)?.workspaceId
    }

    private func resolveCallerSurfaceIdByTTY(workspaceId: String, client: SocketClient) -> String? {
        guard let binding = resolveCallerTerminalBindingByTTY(client: client),
              binding.workspaceId == workspaceId else {
            return nil
        }
        return binding.surfaceId
    }

    private func resolveCallerTerminalBindingByTTY(client: SocketClient) -> CallerTerminalBinding? {
        guard let ttyName = resolveCallerTTYName() else {
            return nil
        }
        guard let payload = try? client.sendV2(method: "debug.terminals") else {
            return nil
        }
        let terminals = payload["terminals"] as? [[String: Any]] ?? []
        for terminal in terminals {
            guard normalizedTTYName(terminal["tty"] as? String) == ttyName,
                  let workspaceId = normalizedHandleValue(terminal["workspace_id"] as? String),
                  let surfaceId = normalizedHandleValue(terminal["surface_id"] as? String) else {
                continue
            }
            return CallerTerminalBinding(workspaceId: workspaceId, surfaceId: surfaceId)
        }
        return nil
    }

    private func resolveCallerTTYName() -> String? {
        let env = ProcessInfo.processInfo.environment
        for key in ["CMUX_CLI_TTY_NAME", "CMUX_TTY_NAME", "TTY", "SSH_TTY"] {
            if let ttyName = normalizedTTYName(env[key]) {
                return ttyName
            }
        }
        for fileDescriptor in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            if let rawTTYName = ttyname(fileDescriptor),
               let ttyName = normalizedTTYName(String(cString: rawTTYName)) {
                return ttyName
            }
        }
        return nil
    }

    private func normalizedTTYName(_ raw: String?) -> String? {
        guard let trimmed = normalizedHandleValue(raw == "not a tty" ? nil : raw) else {
            return nil
        }
        let components = trimmed.split(separator: "/")
        if let last = components.last, !last.isEmpty {
            return String(last)
        }
        return trimmed
    }

    private func normalizedHandleValue(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        return raw
    }

    private func parseClaudeHookInput(rawInput: String) -> ClaudeHookParsedInput {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data, options: []),
              let object = json as? [String: Any] else {
            let fallback = trimmed.isEmpty ? nil : truncate(
                normalizedSingleLine(redactClaudeSensitiveSpans(trimmed)),
                maxLength: 180
            )
            return ClaudeHookParsedInput(object: nil, rawFallback: fallback, sessionId: nil, cwd: nil, transcriptPath: nil)
        }

        let sessionId = extractClaudeHookSessionId(from: object)
        let cwd = extractClaudeHookCWD(from: object)
        let transcriptPath = firstString(in: object, keys: ["transcript_path", "transcriptPath"])
        let compactObject = compactClaudeHookObject(object)
        return ClaudeHookParsedInput(
            object: compactObject,
            rawFallback: nil,
            sessionId: sessionId,
            cwd: cwd,
            transcriptPath: transcriptPath
        )
    }

    private func compactClaudeHookObject(_ object: [String: Any]) -> [String: Any] {
        var compact: [String: Any] = [:]

        for key in [
            "tool_name",
            "last_assistant_message",
            "lastAssistantMessage",
            "event",
            "event_name",
            "hook_event_name",
            "type",
            "kind",
            "notification_type",
            "matcher",
            "reason",
            "message",
            "body",
            "text",
            "prompt",
            "error",
            "description",
        ] {
            if let value = compactClaudeHookStringValue(
                object[key],
                maxLength: claudeHookCompactFieldLimit(for: key)
            ) {
                compact[key] = value
            }
        }

        if let toolInput = object["tool_input"] as? [String: Any] {
            var compactToolInput: [String: Any] = [:]
            for key in ["file_path", "command", "pattern", "description", "query"] {
                if let value = compactClaudeHookToolInputValue(toolInput[key], key: key) {
                    compactToolInput[key] = value
                }
            }
            if let questions = toolInput["questions"] as? [[String: Any]] {
                compactToolInput["questions"] = questions.prefix(1).map { question in
                    var compactQuestion: [String: Any] = [:]
                    if let value = compactClaudeHookStringValue(question["question"], maxLength: 180) {
                        compactQuestion["question"] = value
                    }
                    if let value = compactClaudeHookStringValue(question["header"], maxLength: 80) {
                        compactQuestion["header"] = value
                    }
                    if let options = question["options"] as? [[String: Any]] {
                        let compactOptions: [[String: Any]] = options.compactMap { option in
                            guard let label = compactClaudeHookStringValue(option["label"], maxLength: 60) else {
                                return nil
                            }
                            return ["label": label] as [String: Any]
                        }
                        compactQuestion["options"] = compactOptions
                    }
                    return compactQuestion
                }
            }
            if !compactToolInput.isEmpty {
                compact["tool_input"] = compactToolInput
            }
        }

        for key in ["notification", "data"] {
            guard let nested = object[key] as? [String: Any] else { continue }
            var compactNested: [String: Any] = [:]
            for nestedKey in ["type", "kind", "reason", "message", "body", "text", "prompt", "error", "description"] {
                if let value = compactClaudeHookStringValue(
                    nested[nestedKey],
                    maxLength: claudeHookCompactFieldLimit(for: nestedKey)
                ) {
                    compactNested[nestedKey] = value
                }
            }
            if !compactNested.isEmpty {
                compact[key] = compactNested
            }
        }

        return compact
    }

    private func claudeHookCompactFieldLimit(for key: String) -> Int {
        switch key {
        case "tool_name", "event", "event_name", "hook_event_name", "type", "kind", "notification_type", "matcher", "reason":
            return 80
        case "last_assistant_message", "lastAssistantMessage", "message", "body", "text", "prompt", "error", "description":
            return 240
        default:
            return 160
        }
    }

    private func compactClaudeHookToolInputValue(_ rawValue: Any?, key: String) -> String? {
        switch key {
        case "file_path":
            return compactClaudeHookStringValue(rawValue, maxLength: 240, keepSuffix: true)
        case "command":
            return compactClaudeHookStringValue(rawValue, maxLength: 120)
        case "pattern", "query":
            return compactClaudeHookStringValue(rawValue, maxLength: 120)
        case "description":
            return compactClaudeHookStringValue(rawValue, maxLength: 180)
        default:
            return compactClaudeHookStringValue(rawValue, maxLength: 160)
        }
    }

    private func compactClaudeHookStringValue(
        _ rawValue: Any?,
        maxLength: Int,
        keepSuffix: Bool = false
    ) -> String? {
        guard let rawString = rawValue as? String else { return nil }
        let previewLength = max(maxLength, min(maxLength * 4, 1024))
        let preview = keepSuffix
            ? String(rawString.suffix(previewLength))
            : String(rawString.prefix(previewLength))
        let normalized = normalizedSingleLine(preview)
        guard !normalized.isEmpty else { return nil }
        if keepSuffix, normalized.count > maxLength {
            return "…" + String(normalized.suffix(maxLength - 1))
        }
        return truncate(normalized, maxLength: maxLength)
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

    private func summarizeClaudeHookNotification(parsedInput: ClaudeHookParsedInput) -> (subtitle: String, body: String) {
        guard let object = parsedInput.object else {
            if let fallback = parsedInput.rawFallback, !fallback.isEmpty {
                return classifyClaudeNotification(signal: fallback, message: fallback)
            }
            return ("Waiting", "Claude is waiting for your input")
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
        let message = messageCandidates.compactMap { $0 }.first ?? "Claude needs your input"
        let normalizedMessage = normalizedSingleLine(message)
        let signal = signalParts.compactMap { $0 }.joined(separator: " ")
        var classified = classifyClaudeNotification(signal: signal, message: normalizedMessage)

        classified.body = truncate(classified.body, maxLength: 180)
        return classified
    }

    private func classifyClaudeNotification(signal: String, message: String) -> (subtitle: String, body: String) {
        let lower = "\(signal) \(message)".lowercased()
        if lower.contains("permission") || lower.contains("approve") || lower.contains("approval") || lower.contains("permission_prompt") {
            let body = message.isEmpty ? "Approval needed" : message
            return ("Permission", body)
        }
        if lower.contains("error") || lower.contains("failed") || lower.contains("exception") {
            let body = message.isEmpty ? "Claude reported an error" : message
            return ("Error", body)
        }
        if lower.contains("complet") || lower.contains("finish") || lower.contains("done") || lower.contains("success") {
            let body = message.isEmpty ? "Task completed" : message
            return ("Completed", body)
        }
        if lower.contains("idle") || lower.contains("wait") || lower.contains("input") || lower.contains("idle_prompt") {
            let body = message.isEmpty ? "Waiting for input" : message
            return ("Waiting", body)
        }
        // Use the message directly if it's meaningful (not a generic placeholder).
        if !message.isEmpty, message != "Claude needs your input" {
            return ("Attention", message)
        }
        return ("Attention", "Claude needs your attention")
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
        return normalizedSingleLine(value)
            .replacingOccurrences(of: "|", with: "¦")
    }

    private func redactClaudeSensitiveSpans(_ value: String) -> String {
        let patterns: [(pattern: String, replacement: String)] = [
            (#"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, "<email>"),
            (#"(?:~|/)[^\s\"']+"#, "<path>"),
            (#"\b(?:sk|rk|sess|token|key|secret|api[_-]?key)[A-Za-z0-9._:-]{8,}\b"#, "<token>"),
            (#"\b[A-Za-z0-9_-]{24,}\b"#, "<token>")
        ]
        return patterns.reduce(value) { partial, entry in
            partial.replacingOccurrences(
                of: entry.pattern,
                with: entry.replacement,
                options: [.regularExpression, .caseInsensitive]
            )
        }
    }

    private func mergedNodeOptions(existing: String?, restoreModulePath: String) -> String {
        let requireOption = "--require=\(restoreModulePath)"
        let memoryOption = "--max-old-space-size=4096"
        let cleanedExisting = cleanedNodeOptions(existing)
        guard !cleanedExisting.isEmpty else {
            return "\(requireOption) \(memoryOption)"
        }
        return "\(requireOption) \(memoryOption) \(cleanedExisting)"
    }

    private func cleanedNodeOptions(_ existing: String?) -> String {
        let tokens = (existing ?? "")
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !tokens.isEmpty else { return "" }

        var filtered: [String] = []
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if token == "--max-old-space-size" {
                index += min(2, tokens.count - index)
                continue
            }
            if token.hasPrefix("--max-old-space-size=") {
                index += 1
                continue
            }
            filtered.append(token)
            index += 1
        }
        return filtered.joined(separator: " ")
    }

    private func normalizedNodeOptionsForRestore(_ existing: String) -> String {
        let tokens = existing
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !tokens.isEmpty else { return "" }

        var normalized: [String] = []
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if token == "--max-old-space-size", index + 1 < tokens.count {
                normalized.append("--max-old-space-size=\(tokens[index + 1])")
                index += 2
                continue
            }
            normalized.append(token)
            index += 1
        }
        return normalized.joined(separator: " ")
    }

    // MARK: - Codex hooks

    /// The hooks.json content that cmux installs into ~/.codex/.
    /// Each hook calls `cmux codex-hook <event>` which gracefully no-ops
    /// when not running inside cmux. The command checks for cmux on PATH
    /// first so it silently succeeds even when cmux is not installed
    /// (e.g. user opened codex in a non-cmux terminal).

    // MARK: - Agent PID inference

    private func inferredCodexAgentPID() -> Int? {
        var candidate = getppid()
        var remainingWrapperSkips = 8

        while candidate > 1, remainingWrapperSkips > 0 {
            guard let processName = processName(for: candidate) else { break }
            if !codexHookWrapperProcessNames.contains(processName) {
                break
            }
            let next = parentPID(of: candidate)
            guard next > 1, next != candidate else { break }
            candidate = next
            remainingWrapperSkips -= 1
        }

        return candidate > 1 ? Int(candidate) : nil
    }

    private func parentPID(of pid: pid_t) -> pid_t {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else {
            return -1
        }
        return info.kp_eproc.e_ppid
    }

    private func processName(for pid: pid_t) -> String? {
        let process = Process()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(pid), "-o", "comm="]
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !output.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: output).lastPathComponent.lowercased()
    }

    private func processArguments(for pid: pid_t) -> [String]? {
        var argMax: Int32 = 0
        var argMaxSize = MemoryLayout<Int32>.size
        var argMaxMib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&argMaxMib, UInt32(argMaxMib.count), &argMax, &argMaxSize, nil, 0) == 0,
              argMax > 0 else {
            return nil
        }

        var buffer = [UInt8](repeating: 0, count: Int(argMax))
        var size = buffer.count
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        let status = buffer.withUnsafeMutableBytes { rawBuffer in
            sysctl(&mib, UInt32(mib.count), rawBuffer.baseAddress, &size, nil, 0)
        }
        guard status == 0, size > MemoryLayout<Int32>.size else {
            return nil
        }

        var argc: Int32 = 0
        withUnsafeMutableBytes(of: &argc) { argcBytes in
            for offset in 0..<MemoryLayout<Int32>.size {
                argcBytes[offset] = buffer[offset]
            }
        }
        guard argc > 0 else { return nil }

        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 {
            index += 1
        }
        while index < size, buffer[index] == 0 {
            index += 1
        }

        var arguments: [String] = []
        for _ in 0..<argc {
            guard index < size else { break }
            let start = index
            while index < size, buffer[index] != 0 {
                index += 1
            }
            guard index > start else { break }
            if let value = String(bytes: buffer[start..<index], encoding: .utf8) {
                arguments.append(value)
            }
            while index < size, buffer[index] == 0 {
                index += 1
            }
        }

        return arguments.isEmpty ? nil : arguments
    }

    private func agentLaunchCommandFromEnvironment(
        _ env: [String: String],
        fallbackPID: Int?,
        fallbackKind: String,
        cwd: String?
    ) -> AgentHookLaunchCommandRecord? {
        let envArguments = decodeNULSeparatedBase64(env["CMUX_AGENT_LAUNCH_ARGV_B64"])
        let processArguments = fallbackPID.flatMap { self.processArguments(for: pid_t($0)) }
        let arguments = envArguments ?? processArguments
        guard let arguments, !arguments.isEmpty else { return nil }

        let executablePath = normalizedHookValue(env["CMUX_AGENT_LAUNCH_EXECUTABLE"]) ?? arguments.first
        let workingDirectory = normalizedHookValue(env["CMUX_AGENT_LAUNCH_CWD"])
            ?? normalizedHookValue(cwd)
            ?? normalizedHookValue(env["PWD"])
        let launcher = normalizedHookValue(env["CMUX_AGENT_LAUNCH_KIND"]) ?? fallbackKind
        guard let sanitizedArguments = sanitizedAgentLaunchArguments(
            arguments,
            launcher: launcher,
            fallbackKind: fallbackKind
        ) else {
            return nil
        }
        let source = envArguments == nil ? "process" : "environment"
        let environment = selectedAgentLaunchEnvironment(from: env)

        return AgentHookLaunchCommandRecord(
            launcher: launcher,
            executablePath: executablePath,
            arguments: sanitizedArguments,
            workingDirectory: workingDirectory,
            environment: environment.isEmpty ? nil : environment,
            capturedAt: Date().timeIntervalSince1970,
            source: source
        )
    }

    private func decodeNULSeparatedBase64(_ rawValue: String?) -> [String]? {
        guard let rawValue = normalizedHookValue(rawValue),
              let data = Data(base64Encoded: rawValue) else {
            return nil
        }
        var parts: [String] = []
        var start = data.startIndex
        var index = data.startIndex
        while index < data.endIndex {
            if data[index] == 0 {
                guard let value = String(data: data[start..<index], encoding: .utf8) else {
                    return nil
                }
                parts.append(value)
                start = data.index(after: index)
            }
            index = data.index(after: index)
        }
        if start < data.endIndex {
            guard let value = String(data: data[start..<data.endIndex], encoding: .utf8) else {
                return nil
            }
            parts.append(value)
        }
        return parts.isEmpty ? nil : parts
    }

    private func selectedAgentLaunchEnvironment(from env: [String: String]) -> [String: String] {
        let allowedKeys = [
            "ANTHROPIC_MODEL",
            "CLAUDE_CONFIG_DIR",
            "CMUX_CUSTOM_CLAUDE_PATH",
            "CODEX_HOME",
            "OPENCODE_CONFIG_DIR"
        ]
        var result: [String: String] = [:]
        for key in allowedKeys {
            guard let value = env[key] else { continue }
            result[key] = value
        }
        if let nodeOptions = selectedAgentLaunchNodeOptions(from: env) {
            result["NODE_OPTIONS"] = nodeOptions
        }
        return result
    }

    private func selectedAgentLaunchNodeOptions(from env: [String: String]) -> String? {
        switch normalizedHookValue(env["CMUX_ORIGINAL_NODE_OPTIONS_PRESENT"]) {
        case "1":
            return sanitizedAgentLaunchNodeOptions(env["CMUX_ORIGINAL_NODE_OPTIONS"])
        case "0":
            return nil
        default:
            return sanitizedAgentLaunchNodeOptions(env["NODE_OPTIONS"])
        }
    }

    private func sanitizedAgentLaunchNodeOptions(_ rawValue: String?) -> String? {
        let tokens = rawValue?
            .split(whereSeparator: \.isWhitespace)
            .map(String.init) ?? []
        guard !tokens.isEmpty else { return nil }

        var sanitized: [String] = []
        var index = 0
        var shouldDropInjectedHeapCap = false
        while index < tokens.count {
            let token = tokens[index]

            if shouldDropInjectedHeapCap, isInjectedNodeHeapCap(tokens, index: index) {
                index += nodeHeapCapWidth(tokens, index: index)
                shouldDropInjectedHeapCap = false
                continue
            }
            shouldDropInjectedHeapCap = false

            if isRequireOption(token), index + 1 < tokens.count,
               isCmuxNodeOptionsRestoreModulePath(tokens[index + 1]) {
                index += 2
                shouldDropInjectedHeapCap = true
                continue
            }
            if let path = inlineRequireOptionPath(token),
               isCmuxNodeOptionsRestoreModulePath(path) {
                index += 1
                shouldDropInjectedHeapCap = true
                continue
            }

            sanitized.append(token)
            index += 1
        }

        let joined = sanitized.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    private func isRequireOption(_ token: String) -> Bool {
        token == "--require" || token == "-r"
    }

    private func inlineRequireOptionPath(_ token: String) -> String? {
        for prefix in ["--require=", "-r="] where token.hasPrefix(prefix) {
            return String(token.dropFirst(prefix.count))
        }
        return nil
    }

    private func isCmuxNodeOptionsRestoreModulePath(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        guard URL(fileURLWithPath: trimmed).lastPathComponent == "restore-node-options.cjs" else {
            return false
        }
        return trimmed.contains("/cmux-")
    }

    private func isInjectedNodeHeapCap(_ tokens: [String], index: Int) -> Bool {
        guard index < tokens.count else { return false }
        let token = tokens[index]
        if token == "--max-old-space-size" {
            return index + 1 < tokens.count && tokens[index + 1] == "4096"
        }
        return token == "--max-old-space-size=4096"
    }

    private func nodeHeapCapWidth(_ tokens: [String], index: Int) -> Int {
        guard index < tokens.count else { return 1 }
        return tokens[index] == "--max-old-space-size" ? min(2, tokens.count - index) : 1
    }

    private func normalizedHookValue(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private func agentHookStatePath(sessionStoreSuffix: String, env: [String: String]) -> String {
        let filename = "\(sessionStoreSuffix)-hook-sessions.json"
        guard let overrideDirectory = normalizedHookValue(env["CMUX_AGENT_HOOK_STATE_DIR"]) else {
            return "~/.cmuxterm/\(filename)"
        }
        return URL(fileURLWithPath: NSString(string: overrideDirectory).expandingTildeInPath, isDirectory: true)
            .appendingPathComponent(filename, isDirectory: false)
            .path
    }

    private func sanitizedAgentLaunchArguments(
        _ arguments: [String],
        launcher: String,
        fallbackKind: String
    ) -> [String]? {
        guard let executable = arguments.first, !executable.isEmpty else { return nil }
        var tail = Array(arguments.dropFirst())

        switch launcher {
        case "claudeTeams":
            if tail.first == "claude-teams" {
                tail.removeFirst()
            }
            guard let preserved = sanitizedAgentOptions(
                tail,
                valueOptions: Self.claudeLaunchValueOptions,
                optionalValueOptions: Self.claudeLaunchOptionalValueOptions,
                variadicOptions: Self.claudeLaunchVariadicOptions,
                nonRestorableCommands: Self.claudeLaunchNonRestorableCommands,
                droppedOptions: Self.claudeLaunchDroppedOptions,
                droppedOptionPrefixes: Self.claudeLaunchDroppedOptionPrefixes,
                rejectOptions: Self.claudeLaunchRejectOptions,
                preserveFirstPositional: false
            ) else {
                return nil
            }
            return [executable, "claude-teams"] + preserved
        case "omo":
            if tail.first == "omo" {
                tail.removeFirst()
            }
            guard let preserved = sanitizedAgentOptions(
                tail,
                valueOptions: Self.openCodeLaunchValueOptions,
                optionalValueOptions: [],
                variadicOptions: ["--cors"],
                nonRestorableCommands: Self.openCodeLaunchNonRestorableCommands,
                droppedOptions: Self.openCodeLaunchDroppedOptions,
                droppedOptionPrefixes: Self.openCodeLaunchDroppedOptionPrefixes,
                rejectOptions: [],
                preserveFirstPositional: true
            ) else {
                return nil
            }
            return [executable, "omo"] + preserved
        case "omx", "omc":
            return nil
        default:
            break
        }

        switch fallbackKind {
        case "claude":
            return sanitizedAgentOptions(
                tail,
                valueOptions: Self.claudeLaunchValueOptions,
                optionalValueOptions: Self.claudeLaunchOptionalValueOptions,
                variadicOptions: Self.claudeLaunchVariadicOptions,
                nonRestorableCommands: Self.claudeLaunchNonRestorableCommands,
                droppedOptions: Self.claudeLaunchDroppedOptions,
                droppedOptionPrefixes: Self.claudeLaunchDroppedOptionPrefixes,
                rejectOptions: Self.claudeLaunchRejectOptions,
                preserveFirstPositional: false
            ).map { [executable] + $0 }
        case "codex":
            return sanitizedAgentOptions(
                tail,
                valueOptions: Self.codexLaunchValueOptions,
                optionalValueOptions: [],
                variadicOptions: ["--image", "-i", "--add-dir"],
                nonRestorableCommands: Self.codexLaunchNonRestorableCommands,
                droppedOptions: ["--last", "--all"],
                droppedOptionPrefixes: [],
                rejectOptions: [],
                resumeSubcommand: "resume",
                preserveFirstPositional: false
            ).map { [executable] + $0 }
        case "opencode":
            return sanitizedAgentOptions(
                tail,
                valueOptions: Self.openCodeLaunchValueOptions,
                optionalValueOptions: [],
                variadicOptions: ["--cors"],
                nonRestorableCommands: Self.openCodeLaunchNonRestorableCommands,
                droppedOptions: Self.openCodeLaunchDroppedOptions,
                droppedOptionPrefixes: Self.openCodeLaunchDroppedOptionPrefixes,
                rejectOptions: [],
                preserveFirstPositional: true
            ).map { [executable] + $0 }
        default:
            return nil
        }
    }

    private func sanitizedAgentOptions(
        _ args: [String],
        valueOptions: Set<String>,
        optionalValueOptions: Set<String>,
        variadicOptions: Set<String>,
        nonRestorableCommands: Set<String>,
        droppedOptions: Set<String>,
        droppedOptionPrefixes: [String],
        rejectOptions: Set<String>,
        resumeSubcommand: String? = nil,
        preserveFirstPositional: Bool
    ) -> [String]? {
        var result: [String] = []
        var index = 0
        var consumedFirstPositional = false
        var skippingResumePositionals = false

        while index < args.count {
            let arg = args[index]
            if arg == "--" {
                break
            }
            if !arg.hasPrefix("-") || arg == "-" {
                if let resumeSubcommand, arg == resumeSubcommand {
                    skippingResumePositionals = true
                    index += 1
                    continue
                }
                if skippingResumePositionals {
                    break
                }
                if nonRestorableCommands.contains(arg) {
                    return nil
                }
                if preserveFirstPositional && !consumedFirstPositional {
                    result.append(arg)
                    consumedFirstPositional = true
                    index += 1
                    continue
                }
                break
            }
            if Self.shouldDropAgentOption(arg, droppedOptions: rejectOptions) {
                return nil
            }

            if droppedOptionPrefixes.contains(where: { arg.hasPrefix($0) }) {
                index += 1
                continue
            }
            let width = Self.agentOptionWidth(
                args,
                index: index,
                valueOptions: valueOptions,
                optionalValueOptions: optionalValueOptions,
                variadicOptions: variadicOptions
            )
            if Self.shouldDropAgentOption(arg, droppedOptions: droppedOptions) {
                index += width
                continue
            }
            if Self.isClaudeHookSettingsOption(args, index: index) {
                index += width
                continue
            }
            result.append(contentsOf: args[index..<min(args.count, index + width)])
            index += width
        }

        return result
    }

    private static func shouldDropAgentOption(_ arg: String, droppedOptions: Set<String>) -> Bool {
        if droppedOptions.contains(arg) { return true }
        guard let equals = arg.firstIndex(of: "=") else { return false }
        return droppedOptions.contains(String(arg[..<equals]))
    }

    private static func agentOptionWidth(
        _ args: [String],
        index: Int,
        valueOptions: Set<String>,
        optionalValueOptions: Set<String>,
        variadicOptions: Set<String>
    ) -> Int {
        let arg = args[index]
        if arg.contains("=") {
            return 1
        }
        if optionalValueOptions.contains(arg) {
            guard index + 1 < args.count,
                  Self.looksLikeOptionalAgentOptionValue(
                    args[index + 1],
                    following: index + 2 < args.count ? args[index + 2] : nil
                  ) else {
                return 1
            }
            return 2
        }
        guard valueOptions.contains(arg), index + 1 < args.count else {
            return 1
        }
        if variadicOptions.contains(arg) {
            var end = index + 1
            while end < args.count, !args[end].hasPrefix("-") {
                end += 1
            }
            return max(1, end - index)
        }
        return 2
    }

    private static func looksLikeOptionalAgentOptionValue(_ value: String, following: String?) -> Bool {
        guard !value.isEmpty,
              !value.hasPrefix("-"),
              value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            return false
        }
        return value.contains(",") || (following?.hasPrefix("-") == true)
    }

    private static func isClaudeHookSettingsOption(_ args: [String], index: Int) -> Bool {
        let arg = args[index]
        if arg.hasPrefix("--settings=") {
            return arg.contains("claude-hook")
        }
        guard arg == "--settings", index + 1 < args.count else {
            return false
        }
        return args[index + 1].contains("claude-hook")
    }

    private static let claudeLaunchValueOptions: Set<String> = [
        "--add-dir",
        "--agent",
        "--agents",
        "--allowedTools",
        "--allowed-tools",
        "--append-system-prompt",
        "--betas",
        "--debug-file",
        "--disallowedTools",
        "--disallowed-tools",
        "--effort",
        "--fallback-model",
        "--file",
        "--fork-session",
        "--from-pr",
        "--input-format",
        "--json-schema",
        "--max-budget-usd",
        "--mcp-config",
        "--model",
        "--name",
        "-n",
        "--output-format",
        "--permission-mode",
        "--plugin-dir",
        "--remote-control-session-name-prefix",
        "--resume",
        "-r",
        "--session-id",
        "--setting-sources",
        "--settings",
        "--system-prompt",
        "--teammate-mode",
        "--tmux",
        "--tools",
        "--worktree",
        "-w"
    ]

    private static let claudeLaunchOptionalValueOptions: Set<String> = [
        "--debug"
    ]

    private static let claudeLaunchVariadicOptions: Set<String> = [
        "--add-dir",
        "--allowedTools",
        "--allowed-tools",
        "--betas",
        "--disallowedTools",
        "--disallowed-tools",
        "--file",
        "--mcp-config",
        "--tools"
    ]

    private static let claudeLaunchNonRestorableCommands: Set<String> = [
        "agents",
        "auth",
        "auto-mode",
        "api-key",
        "config",
        "doctor",
        "install",
        "mcp",
        "plugin",
        "plugins",
        "rc",
        "remote-control",
        "setup-token",
        "update",
        "upgrade"
    ]

    private static let claudeLaunchDroppedOptions: Set<String> = [
        "--continue",
        "-c",
        "--fork-session",
        "--from-pr",
        "--resume",
        "-r",
        "--session-id",
        "--tmux",
        "--worktree",
        "-w"
    ]

    private static let claudeLaunchDroppedOptionPrefixes = [
        "--fork-session=",
        "--from-pr=",
        "--resume=",
        "--session-id=",
        "--tmux=",
        "--worktree="
    ]

    private static let claudeLaunchRejectOptions: Set<String> = [
        "--print",
        "-p",
        "--no-session-persistence"
    ]

    private static let codexLaunchValueOptions: Set<String> = [
        "--config",
        "-c",
        "--remote",
        "--remote-auth-token-env",
        "--image",
        "-i",
        "--model",
        "-m",
        "--local-provider",
        "--profile",
        "-p",
        "--sandbox",
        "-s",
        "--ask-for-approval",
        "-a",
        "--cd",
        "-C",
        "--add-dir",
        "--enable",
        "--disable"
    ]

    private static let codexLaunchNonRestorableCommands: Set<String> = [
        "exec",
        "e",
        "review",
        "login",
        "logout",
        "mcp",
        "mcp-server",
        "app-server",
        "app",
        "completion",
        "sandbox",
        "debug",
        "apply",
        "a",
        "fork",
        "cloud",
        "exec-server",
        "features",
        "help"
    ]

    private static let openCodeLaunchValueOptions: Set<String> = [
        "--log-level",
        "--port",
        "--hostname",
        "--mdns-domain",
        "--cors",
        "--model",
        "-m",
        "--session",
        "-s",
        "--prompt",
        "--agent"
    ]

    private static let openCodeLaunchNonRestorableCommands: Set<String> = [
        "completion",
        "acp",
        "mcp",
        "attach",
        "run",
        "debug",
        "providers",
        "auth",
        "agent",
        "upgrade",
        "uninstall",
        "serve",
        "web",
        "models",
        "stats",
        "export",
        "import",
        "pr",
        "github",
        "session",
        "plugin",
        "plug",
        "db"
    ]

    private static let openCodeLaunchDroppedOptions: Set<String> = [
        "--continue",
        "-c",
        "--fork",
        "--session",
        "-s",
        "--prompt"
    ]

    private static let openCodeLaunchDroppedOptionPrefixes = [
        "--session=",
        "--prompt="
    ]

    // MARK: - Generic agent hook system

    /// Configuration for a hook-based agent integration.
    private struct AgentHookDef {
        let name: String            // CLI name: "cursor", "gemini", etc.
        let displayName: String     // Human-readable: "Cursor", "Gemini"
        let statusKey: String       // Key for set_status: "cursor", "gemini"
        let configDir: String       // Relative to ~: ".cursor", ".gemini"
        let configFile: String      // File name: "hooks.json", "settings.json"
        let configDirEnvOverride: String? // e.g. "CODEX_HOME" overrides configDir
        let sessionStoreSuffix: String // e.g. "cursor" -> ~/.cmuxterm/cursor-hook-sessions.json
        let disableEnvVar: String   // e.g. "CMUX_CURSOR_HOOKS_DISABLED"
        let hookMarker: String      // Marker in commands: "cmux cursor-hook"
        let format: HookFormat
        let events: [HookEvent]
        let postInstallAction: PostInstallAction?

        enum HookFormat {
            case flat       // Cursor: {"hooks": {"event": [{"command": "..."}]}, "version": 1}
            case nested(timeoutMs: Int)  // Codex/Gemini: nested with type/command/timeout
        }

        struct HookEvent {
            let agentEvent: String
            let cmuxSubcommand: String
        }

        enum PostInstallAction {
            case codexConfigToml // write codex_hooks = true to config.toml on install, remove on uninstall
        }

        /// Resolves the config directory, respecting env override if set.
        func resolvedConfigDir() -> String {
            if let envKey = configDirEnvOverride,
               let envValue = ProcessInfo.processInfo.environment[envKey],
               !envValue.isEmpty {
                return NSString(string: envValue).expandingTildeInPath
            }
            return NSString(string: "~/\(configDir)").expandingTildeInPath
        }

        init(name: String, displayName: String, statusKey: String,
             configDir: String, configFile: String, configDirEnvOverride: String? = nil,
             sessionStoreSuffix: String, disableEnvVar: String, hookMarker: String,
             format: HookFormat, events: [HookEvent], postInstallAction: PostInstallAction? = nil) {
            self.name = name; self.displayName = displayName; self.statusKey = statusKey
            self.configDir = configDir; self.configFile = configFile
            self.configDirEnvOverride = configDirEnvOverride
            self.sessionStoreSuffix = sessionStoreSuffix; self.disableEnvVar = disableEnvVar
            self.hookMarker = hookMarker; self.format = format; self.events = events
            self.postInstallAction = postInstallAction
        }
    }

    private enum AgentHookAction {
        case sessionStart, promptSubmit, stop, sessionEnd, noop
    }

    private static let subcommandActions: [String: AgentHookAction] = [
        "session-start": .sessionStart,
        "prompt-submit": .promptSubmit,
        "stop": .stop,
        "agent-response": .stop,
        "shell-exec": .promptSubmit,
        "shell-done": .noop,
        "session-end": .sessionEnd,
    ]

    // MARK: Agent definitions

    private static let agentDefs: [AgentHookDef] = [
        AgentHookDef(
            name: "codex", displayName: "Codex", statusKey: "codex",
            configDir: ".codex", configFile: "hooks.json", configDirEnvOverride: "CODEX_HOME",
            sessionStoreSuffix: "codex", disableEnvVar: "CMUX_CODEX_HOOKS_DISABLED",
            hookMarker: "cmux codex-hook", format: .nested(timeoutMs: 5000),
            events: [
                .init(agentEvent: "SessionStart", cmuxSubcommand: "session-start"),
                .init(agentEvent: "UserPromptSubmit", cmuxSubcommand: "prompt-submit"),
                .init(agentEvent: "Stop", cmuxSubcommand: "stop"),
            ],
            postInstallAction: .codexConfigToml
        ),
        AgentHookDef(
            name: "opencode", displayName: "OpenCode", statusKey: "opencode",
            configDir: ".config/opencode", configFile: "plugins/cmux-session.js", configDirEnvOverride: "OPENCODE_CONFIG_DIR",
            sessionStoreSuffix: "opencode", disableEnvVar: "CMUX_OPENCODE_HOOKS_DISABLED",
            hookMarker: "cmux opencode-hook", format: .flat,
            events: []
        ),
        AgentHookDef(
            name: "cursor", displayName: "Cursor", statusKey: "cursor",
            configDir: ".cursor", configFile: "hooks.json",
            sessionStoreSuffix: "cursor", disableEnvVar: "CMUX_CURSOR_HOOKS_DISABLED",
            hookMarker: "cmux cursor-hook", format: .flat,
            events: [
                .init(agentEvent: "beforeSubmitPrompt", cmuxSubcommand: "prompt-submit"),
                .init(agentEvent: "stop", cmuxSubcommand: "stop"),
                .init(agentEvent: "afterAgentResponse", cmuxSubcommand: "agent-response"),
                .init(agentEvent: "beforeShellExecution", cmuxSubcommand: "shell-exec"),
                .init(agentEvent: "afterShellExecution", cmuxSubcommand: "shell-done"),
            ]
        ),
        AgentHookDef(
            name: "gemini", displayName: "Gemini", statusKey: "gemini",
            configDir: ".gemini", configFile: "settings.json",
            sessionStoreSuffix: "gemini", disableEnvVar: "CMUX_GEMINI_HOOKS_DISABLED",
            hookMarker: "cmux gemini-hook", format: .nested(timeoutMs: 10000),
            events: [
                .init(agentEvent: "SessionStart", cmuxSubcommand: "session-start"),
                .init(agentEvent: "BeforeAgent", cmuxSubcommand: "prompt-submit"),
                .init(agentEvent: "AfterAgent", cmuxSubcommand: "stop"),
                .init(agentEvent: "SessionEnd", cmuxSubcommand: "session-end"),
            ]
        ),
        AgentHookDef(
            name: "copilot", displayName: "Copilot", statusKey: "copilot",
            configDir: ".copilot", configFile: "config.json",
            sessionStoreSuffix: "copilot", disableEnvVar: "CMUX_COPILOT_HOOKS_DISABLED",
            hookMarker: "cmux copilot-hook", format: .nested(timeoutMs: 5000),
            events: [
                .init(agentEvent: "SessionStart", cmuxSubcommand: "session-start"),
                .init(agentEvent: "Stop", cmuxSubcommand: "stop"),
                .init(agentEvent: "Notification", cmuxSubcommand: "stop"),
                .init(agentEvent: "SessionEnd", cmuxSubcommand: "session-end"),
            ]
        ),
        AgentHookDef(
            name: "codebuddy", displayName: "CodeBuddy", statusKey: "codebuddy",
            configDir: ".codebuddy", configFile: "settings.json",
            sessionStoreSuffix: "codebuddy", disableEnvVar: "CMUX_CODEBUDDY_HOOKS_DISABLED",
            hookMarker: "cmux codebuddy-hook", format: .nested(timeoutMs: 5000),
            events: [
                .init(agentEvent: "SessionStart", cmuxSubcommand: "session-start"),
                .init(agentEvent: "Stop", cmuxSubcommand: "stop"),
                .init(agentEvent: "Notification", cmuxSubcommand: "stop"),
                .init(agentEvent: "SessionEnd", cmuxSubcommand: "session-end"),
            ]
        ),
        AgentHookDef(
            name: "factory", displayName: "Factory", statusKey: "factory",
            configDir: ".factory", configFile: "settings.json",
            sessionStoreSuffix: "factory", disableEnvVar: "CMUX_FACTORY_HOOKS_DISABLED",
            hookMarker: "cmux factory-hook", format: .nested(timeoutMs: 5000),
            events: [
                .init(agentEvent: "SessionStart", cmuxSubcommand: "session-start"),
                .init(agentEvent: "Stop", cmuxSubcommand: "stop"),
                .init(agentEvent: "Notification", cmuxSubcommand: "stop"),
                .init(agentEvent: "SessionEnd", cmuxSubcommand: "session-end"),
            ]
        ),
        AgentHookDef(
            name: "qoder", displayName: "Qoder", statusKey: "qoder",
            configDir: ".qoder", configFile: "settings.json",
            sessionStoreSuffix: "qoder", disableEnvVar: "CMUX_QODER_HOOKS_DISABLED",
            hookMarker: "cmux qoder-hook", format: .nested(timeoutMs: 5000),
            events: [
                .init(agentEvent: "SessionStart", cmuxSubcommand: "session-start"),
                .init(agentEvent: "Stop", cmuxSubcommand: "stop"),
                .init(agentEvent: "SessionEnd", cmuxSubcommand: "session-end"),
            ]
        ),
    ]

    private static func agentDef(named name: String) -> AgentHookDef? {
        agentDefs.first { $0.name == name }
    }

    // MARK: Generic hook install/uninstall

    private func hookCommand(for def: AgentHookDef, event: AgentHookDef.HookEvent) -> String {
        "[ -n \"$CMUX_SURFACE_ID\" ] && [ \"$\(def.disableEnvVar)\" != \"1\" ] && command -v cmux >/dev/null 2>&1 && cmux \(def.name)-hook \(event.cmuxSubcommand) || echo '{}'"
    }

    private func buildHooksDict(for def: AgentHookDef) -> [String: Any] {
        var result: [String: Any] = [:]
        for event in def.events {
            let cmd = hookCommand(for: def, event: event)
            switch def.format {
            case .flat:
                result[event.agentEvent] = [["command": cmd]]
            case .nested(let timeoutMs):
                result[event.agentEvent] = [["hooks": [["type": "command", "command": cmd, "timeout": timeoutMs] as [String: Any]]] as [String: Any]]
            }
        }
        return result
    }

    private static let openCodeSessionPluginMarker = "cmux-opencode-session-plugin-marker"
    private static let openCodeSessionPluginFilename = "cmux-session.js"
    private static let openCodeSessionPluginSource = #"""
// cmux-opencode-session-plugin-marker v1
// Bridges OpenCode session lifecycle events into cmux's restorable session store.
// Installed by `cmux opencode install-hooks` or `cmux setup-hooks`.
// DO NOT EDIT MANUALLY. cmux upgrades this file in place.

import { spawnSync } from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";

const CMUX_PLUGIN_INSTALLED_KEY = Symbol.for("cmux.session.restore.plugin.installed");

function firstString(...values) {
  for (const value of values) {
    if (typeof value === "string" && value.trim().length > 0) return value.trim();
  }
  return null;
}

function eventProperties(event) {
  return (event && typeof event === "object" && event.properties) || {};
}

function sessionIdFor(event) {
  const props = eventProperties(event);
  return firstString(
    props.info && props.info.id,
    props.sessionID,
    props.sessionId,
    props.session_id,
    props.session && props.session.id,
    event && event.sessionID,
    event && event.sessionId,
    event && event.id
  );
}

function cwdFor(ctx, event) {
  const props = eventProperties(event);
  return firstString(
    props.info && props.info.directory,
    props.cwd,
    props.directory,
    ctx && ctx.directory,
    process.cwd()
  );
}

function resolveExecutable(name) {
  const pathEnv = process.env.PATH || "";
  for (const dir of pathEnv.split(path.delimiter)) {
    if (!dir) continue;
    const candidate = path.join(dir, name);
    try {
      fs.accessSync(candidate, fs.constants.X_OK);
      return candidate;
    } catch (_) {}
  }
  return name;
}

function looksLikeOpenCodeScript(value) {
  if (!value) return false;
  const lower = String(value).toLowerCase();
  return lower.includes("opencode") || lower.includes("open-code");
}

function isOpenCodeInternalWorkerArg(value) {
  if (!value) return false;
  const normalized = String(value).replaceAll("\\", "/");
  return normalized.includes("/$bunfs/") && normalized.includes("/src/cli/cmd/tui/worker.js");
}

function withoutOpenCodeInternalWorkerArgs(argv) {
  const result = [];
  for (let i = 0; i < argv.length; i += 1) {
    const value = argv[i];
    if (i > 0 && isOpenCodeInternalWorkerArg(value)) continue;
    result.push(value);
  }
  return result.length > 0 ? result : [resolveExecutable("opencode")];
}

function normalizedLaunchArgv() {
  const raw = Array.isArray(process.argv) ? process.argv.map((value) => String(value)) : [];
  if (raw.length === 0) return [resolveExecutable("opencode")];

  const firstBase = path.basename(raw[0]).toLowerCase();
  if (looksLikeOpenCodeScript(firstBase)) return withoutOpenCodeInternalWorkerArgs(raw);

  let tail = raw.slice(1);
  if (tail.length > 0 && looksLikeOpenCodeScript(tail[0])) {
    tail = tail.slice(1);
  }
  return withoutOpenCodeInternalWorkerArgs([resolveExecutable("opencode"), ...tail]);
}

function base64NulSeparated(values) {
  const bytes = [];
  for (const value of values) {
    bytes.push(Buffer.from(String(value), "utf8"));
    bytes.push(Buffer.from([0]));
  }
  return Buffer.concat(bytes).toString("base64");
}

function hookEnvironment(cwd) {
  const env = { ...process.env };
  if (!env.CMUX_AGENT_LAUNCH_ARGV_B64) {
    const argv = normalizedLaunchArgv();
    env.CMUX_AGENT_LAUNCH_KIND = "opencode";
    env.CMUX_AGENT_LAUNCH_EXECUTABLE = argv[0] || resolveExecutable("opencode");
    env.CMUX_AGENT_LAUNCH_ARGV_B64 = base64NulSeparated(argv);
    env.CMUX_AGENT_LAUNCH_CWD = cwd || process.cwd();
  }
  return env;
}

function sendHook(subcommand, ctx, event, extra = {}) {
  if (process.env.CMUX_OPENCODE_HOOKS_DISABLED === "1") return;
  if (!process.env.CMUX_SURFACE_ID) return;

  const sessionId = sessionIdFor(event);
  if (!sessionId) return;

  const cwd = cwdFor(ctx, event);
  const payload = {
    session_id: sessionId,
    cwd,
    event: event && event.type,
    hook_event_name: event && event.type,
    ...extra,
  };
  const cmux = process.env.CMUX_OPENCODE_CMUX_BIN || "cmux";
  try {
    spawnSync(cmux, ["opencode-hook", subcommand], {
      input: JSON.stringify(payload),
      encoding: "utf8",
      env: hookEnvironment(cwd),
      stdio: ["pipe", "ignore", "ignore"],
      timeout: 5000,
    });
  } catch (_) {}
}

const CMUXSessionRestore = async (ctx) => {
  if (globalThis[CMUX_PLUGIN_INSTALLED_KEY]) return {};
  globalThis[CMUX_PLUGIN_INSTALLED_KEY] = true;
  return {
    event: async ({ event }) => {
      const props = eventProperties(event);
      switch (event && event.type) {
        case "session.created":
          sendHook("session-start", ctx, event);
          break;
        case "session.updated":
          if (props.info && props.info.time && props.info.time.archived) {
            sendHook("session-end", ctx, event);
          } else {
            sendHook("session-start", ctx, event);
          }
          break;
        case "session.status":
          if (props.status && props.status.type === "idle") {
            sendHook("stop", ctx, event);
          }
          break;
        case "session.idle":
          sendHook("stop", ctx, event);
          break;
        case "session.deleted":
          sendHook("session-end", ctx, event);
          break;
        default:
          break;
      }
    },
  };
};

export { CMUXSessionRestore };
export default CMUXSessionRestore;
"""#

    private func openCodeSessionPluginURL(for def: AgentHookDef) -> URL {
        URL(fileURLWithPath: def.resolvedConfigDir(), isDirectory: true)
            .appendingPathComponent("plugins", isDirectory: true)
            .appendingPathComponent(Self.openCodeSessionPluginFilename, isDirectory: false)
    }

    private func writeOpenCodeSessionPlugin(in configDir: URL) throws {
        let pluginURL = configDir
            .appendingPathComponent("plugins", isDirectory: true)
            .appendingPathComponent(Self.openCodeSessionPluginFilename, isDirectory: false)
        let fm = FileManager.default
        try fm.createDirectory(at: pluginURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.openCodeSessionPluginSource.write(to: pluginURL, atomically: true, encoding: .utf8)
    }

    private static func openCodePluginListContains(
        _ plugins: [Any],
        spec: String,
        allowVersionSuffix: Bool = false
    ) -> Bool {
        plugins.contains { entry in
            let value: String?
            if let string = entry as? String {
                value = string
            } else if let tuple = entry as? [Any], let string = tuple.first as? String {
                value = string
            } else {
                value = nil
            }
            guard let value else { return false }
            if value == spec { return true }
            if allowVersionSuffix, value.hasPrefix("\(spec)@") { return true }
            if spec == Self.openCodeSessionPluginConfigSpec {
                return value == "./plugins/\(Self.openCodeSessionPluginFilename)"
                    || value.hasSuffix("/plugins/\(Self.openCodeSessionPluginFilename)")
                    || value.hasSuffix("/\(Self.openCodeSessionPluginFilename)")
            }
            return false
        }
    }

    private static func openCodePluginListRemovingSessionPlugin(_ plugins: [Any]) -> [Any] {
        plugins.filter { entry in
            guard let value = (entry as? String) ?? ((entry as? [Any])?.first as? String) else {
                return true
            }
            return value != Self.openCodeSessionPluginConfigSpec
                && value != "./plugins/\(Self.openCodeSessionPluginFilename)"
                && !value.hasSuffix("/plugins/\(Self.openCodeSessionPluginFilename)")
                && !value.hasSuffix("/\(Self.openCodeSessionPluginFilename)")
        }
    }

    private func updateOpenCodePluginRegistration(configDir: URL, shouldInstall: Bool) throws {
        let configURL = configDir.appendingPathComponent("opencode.json", isDirectory: false)
        var config: [String: Any]
        if let data = try? Data(contentsOf: configURL) {
            guard let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CLIError(message: "Failed to parse \(configURL.path). Fix the JSON syntax and retry.")
            }
            config = decoded
        } else {
            config = [:]
        }

        var plugins = Self.openCodePluginListRemovingSessionPlugin((config["plugin"] as? [Any]) ?? [])
        if shouldInstall,
           !Self.openCodePluginListContains(plugins, spec: Self.openCodeSessionPluginConfigSpec) {
            plugins.append(Self.openCodeSessionPluginConfigSpec)
        }
        config["plugin"] = plugins

        let output = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try output.write(to: configURL, options: .atomic)
    }

    private func installOpenCodePluginHooks(_ def: AgentHookDef) throws {
        let pluginURL = openCodeSessionPluginURL(for: def)
        let skipConfirm = ProcessInfo.processInfo.arguments.contains("--yes")
            || ProcessInfo.processInfo.arguments.contains("-y")

        if !skipConfirm {
            print("Will write OpenCode cmux plugin to \(pluginURL.path):")
            print(Self.openCodeSessionPluginSource)
            print("\nProceed? [y/N] ", terminator: "")
            guard readLine()?.lowercased().hasPrefix("y") == true else {
                print("Aborted.")
                return
            }
        }

        let configDir = URL(fileURLWithPath: def.resolvedConfigDir(), isDirectory: true)
        try writeOpenCodeSessionPlugin(in: configDir)
        try updateOpenCodePluginRegistration(configDir: configDir, shouldInstall: true)
        print("OpenCode hooks installed at \(pluginURL.path)")
    }

    private func uninstallOpenCodePluginHooks(_ def: AgentHookDef) throws {
        let fm = FileManager.default
        let pluginURL = openCodeSessionPluginURL(for: def)
        guard fm.fileExists(atPath: pluginURL.path) else {
            print("No OpenCode cmux plugin found at \(pluginURL.path)")
            return
        }

        let existing = (try? String(contentsOf: pluginURL, encoding: .utf8)) ?? ""
        guard existing.contains(Self.openCodeSessionPluginMarker) else {
            print("Refusing to remove \(pluginURL.path): missing cmux marker")
            return
        }

        try fm.removeItem(at: pluginURL)
        try updateOpenCodePluginRegistration(
            configDir: URL(fileURLWithPath: def.resolvedConfigDir(), isDirectory: true),
            shouldInstall: false
        )
        print("Removed OpenCode cmux plugin from \(pluginURL.path)")
    }

    private func installAgentHooks(_ def: AgentHookDef) throws {
        if def.name == "opencode" {
            try installOpenCodePluginHooks(def)
            return
        }

        let fm = FileManager.default
        let configDir = def.resolvedConfigDir()
        let filePath = "\(configDir)/\(def.configFile)"
        let skipConfirm = ProcessInfo.processInfo.arguments.contains("--yes")
            || ProcessInfo.processInfo.arguments.contains("-y")

        guard fm.fileExists(atPath: configDir) else {
            print("~/\(def.configDir)/ does not exist. Install \(def.displayName) first.")
            return
        }

        var existing: [String: Any] = [:]
        if let data = fm.contents(atPath: filePath) {
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CLIError(message: "\(filePath) exists but is not valid JSON. Fix or remove it before installing hooks.")
            }
            existing = json
        }

        var hooks = existing["hooks"] as? [String: Any] ?? [:]
        let newHooks = buildHooksDict(for: def)

        // Remove existing cmux-owned entries
        for (event, value) in hooks {
            switch def.format {
            case .flat:
                guard var entries = value as? [[String: Any]] else { continue }
                entries.removeAll { ($0["command"] as? String)?.contains(def.hookMarker) == true }
                hooks[event] = entries.isEmpty ? nil : entries
            case .nested:
                guard var groups = value as? [[String: Any]] else { continue }
                groups.removeAll { group in
                    guard let hookList = group["hooks"] as? [[String: Any]] else { return false }
                    return hookList.allSatisfy { ($0["command"] as? String)?.contains(def.hookMarker) == true }
                }
                hooks[event] = groups.isEmpty ? nil : groups
            }
        }

        // Add new cmux entries
        for (event, value) in newHooks {
            switch def.format {
            case .flat:
                var entries = hooks[event] as? [[String: Any]] ?? []
                if let newEntries = value as? [[String: Any]] { entries.append(contentsOf: newEntries) }
                hooks[event] = entries
            case .nested:
                var groups = hooks[event] as? [[String: Any]] ?? []
                if let newGroups = value as? [[String: Any]] { groups.append(contentsOf: newGroups) }
                hooks[event] = groups
            }
        }

        existing["hooks"] = hooks
        if case .flat = def.format { existing["version"] = 1 }

        let newData = try JSONSerialization.data(withJSONObject: existing, options: [.prettyPrinted, .sortedKeys])

        if !skipConfirm {
            print("Will write to \(filePath):")
            print(String(data: newData, encoding: .utf8) ?? "{}")
            print("\nProceed? [y/N] ", terminator: "")
            guard readLine()?.lowercased().hasPrefix("y") == true else {
                print("Aborted.")
                return
            }
        }

        try newData.write(to: URL(fileURLWithPath: filePath), options: .atomic)
        print("\(def.displayName) hooks installed at \(filePath)")

        // Post-install actions
        if let action = def.postInstallAction {
            switch action {
            case .codexConfigToml:
                let configPath = "\(configDir)/config.toml"
                let existingContent: String = fm.fileExists(atPath: configPath)
                    ? ((try? String(contentsOfFile: configPath, encoding: .utf8)) ?? "")
                    : ""
                let newContent: String
                if existingContent.contains("codex_hooks") {
                    // Replace existing value (might be false) with true
                    newContent = existingContent.replacingOccurrences(
                        of: "codex_hooks\\s*=\\s*\\w+",
                        with: "codex_hooks = true",
                        options: .regularExpression
                    )
                } else if existingContent.contains("[features]") {
                    newContent = existingContent.replacingOccurrences(
                        of: "[features]",
                        with: "[features]\ncodex_hooks = true"
                    )
                } else {
                    newContent = existingContent + "\n[features]\ncodex_hooks = true\n"
                }
                if newContent != existingContent {
                    try newContent.write(toFile: configPath, atomically: true, encoding: .utf8)
                    print("Enabled codex_hooks in \(configPath)")
                }
            }
        }
    }

    private func uninstallAgentHooks(_ def: AgentHookDef) throws {
        if def.name == "opencode" {
            try uninstallOpenCodePluginHooks(def)
            return
        }

        let fm = FileManager.default
        let configDir = def.resolvedConfigDir()
        let filePath = "\(configDir)/\(def.configFile)"

        guard let data = fm.contents(atPath: filePath),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("No \(def.configFile) found at \(filePath)")
            return
        }

        var hooks = json["hooks"] as? [String: Any] ?? [:]
        var removed = 0

        for (event, value) in hooks {
            switch def.format {
            case .flat:
                guard var entries = value as? [[String: Any]] else { continue }
                let before = entries.count
                entries.removeAll { ($0["command"] as? String)?.contains(def.hookMarker) == true }
                removed += before - entries.count
                hooks[event] = entries.isEmpty ? nil : entries
            case .nested:
                guard var groups = value as? [[String: Any]] else { continue }
                let before = groups.count
                groups.removeAll { group in
                    guard let hookList = group["hooks"] as? [[String: Any]] else { return false }
                    return hookList.allSatisfy { ($0["command"] as? String)?.contains(def.hookMarker) == true }
                }
                removed += before - groups.count
                hooks[event] = groups.isEmpty ? nil : groups
            }
        }

        json["hooks"] = hooks
        let newData = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try newData.write(to: URL(fileURLWithPath: filePath), options: .atomic)
        print("Removed \(removed) cmux hook(s) from \(filePath)")

        // Post-uninstall actions
        if let action = def.postInstallAction {
            switch action {
            case .codexConfigToml:
                let configPath = "\(configDir)/config.toml"
                guard fm.fileExists(atPath: configPath),
                      let content = try? String(contentsOfFile: configPath, encoding: .utf8),
                      content.contains("codex_hooks") else { return }
                // Remove the codex_hooks line
                let newContent = content.replacingOccurrences(
                    of: "\\n?codex_hooks\\s*=\\s*\\w+",
                    with: "",
                    options: .regularExpression
                )
                if newContent != content {
                    try newContent.write(toFile: configPath, atomically: true, encoding: .utf8)
                    print("Removed codex_hooks from \(configPath)")
                }
            }
        }
    }

    // MARK: Generic hook handler

    private func runGenericAgentHook(def: AgentHookDef, commandArgs: [String], client: SocketClient, telemetry: CLISocketSentryTelemetry) throws {
        let env = ProcessInfo.processInfo.environment
        let subcommand = commandArgs.first?.lowercased() ?? ""
        let hookArgs = Array(commandArgs.dropFirst())
        telemetry.breadcrumb("\(def.name)-hook.\(subcommand)")

        // Workspace/surface resolution: prefer --workspace/--surface flags, then session store, then env
        let hookWsFlag = optionValue(hookArgs, name: "--workspace")
        let workspaceArg = hookWsFlag ?? env["CMUX_WORKSPACE_ID"]
        let surfaceArg = optionValue(hookArgs, name: "--surface") ?? (hookWsFlag == nil ? env["CMUX_SURFACE_ID"] : nil)

        let rawInput = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let input = parseClaudeHookInput(rawInput: rawInput)

        let store = ClaudeHookSessionStore(
            processEnv: env.merging(
                ["CMUX_CLAUDE_HOOK_STATE_PATH": agentHookStatePath(sessionStoreSuffix: def.sessionStoreSuffix, env: env)],
                uniquingKeysWith: { _, new in new }
            )
        )

        let sessionId = input.sessionId ?? env["CMUX_SURFACE_ID"] ?? ""
        let action = Self.subcommandActions[subcommand] ?? .noop
        let pidKey = "\(def.statusKey).\(sessionId.isEmpty ? "default" : sessionId)"

        switch action {
        case .sessionStart:
            let workspaceId = try resolvePreferredWorkspaceIdForClaudeHook(preferred: nil, fallback: workspaceArg, client: client)
            let surfaceId = try resolvePreferredSurfaceIdForClaudeHook(preferred: nil, fallback: surfaceArg, workspaceId: workspaceId, client: client)
            let pid = inferredCodexAgentPID()
            let launchCommand = agentLaunchCommandFromEnvironment(
                env,
                fallbackPID: pid,
                fallbackKind: def.name,
                cwd: input.cwd
            )
            if !sessionId.isEmpty {
                try? store.upsert(
                    sessionId: sessionId,
                    workspaceId: workspaceId,
                    surfaceId: surfaceId,
                    cwd: input.cwd,
                    pid: pid,
                    launchCommand: launchCommand
                )
            }
            if let pid {
                _ = try? sendV1Command("set_agent_pid \(pidKey) \(pid) --tab=\(workspaceId)", client: client)
            }

        case .promptSubmit:
            let mapped = sessionId.isEmpty ? nil : (try? store.lookup(sessionId: sessionId))
            let workspaceId = try resolvePreferredWorkspaceIdForClaudeHook(preferred: mapped?.workspaceId, fallback: workspaceArg, client: client)
            let pid = mapped?.pid ?? inferredCodexAgentPID()
            let launchCommand = agentLaunchCommandFromEnvironment(
                env,
                fallbackPID: pid,
                fallbackKind: def.name,
                cwd: input.cwd ?? mapped?.cwd
            )
            if !sessionId.isEmpty {
                try? store.upsert(
                    sessionId: sessionId,
                    workspaceId: workspaceId,
                    surfaceId: mapped?.surfaceId ?? (surfaceArg ?? ""),
                    cwd: input.cwd ?? mapped?.cwd,
                    pid: pid,
                    launchCommand: launchCommand
                )
            }
            if let pid {
                _ = try? sendV1Command("set_agent_pid \(pidKey) \(pid) --tab=\(workspaceId)", client: client)
            }
            _ = try? sendV1Command("clear_notifications --tab=\(workspaceId)", client: client)
            _ = try sendV1Command("set_status \(def.statusKey) Running --icon=bolt.fill --color=#4C8DFF --tab=\(workspaceId)", client: client)

        case .stop:
            do {
                let mapped = sessionId.isEmpty ? nil : (try? store.lookup(sessionId: sessionId))
                let workspaceId = try resolvePreferredWorkspaceIdForClaudeHook(preferred: mapped?.workspaceId, fallback: workspaceArg, client: client)
                let surfaceId = try resolvePreferredSurfaceIdForClaudeHook(preferred: mapped?.surfaceId, fallback: surfaceArg, workspaceId: workspaceId, client: client)
                let pid = mapped?.pid ?? inferredCodexAgentPID()

                let lastMsg = input.object?["last_assistant_message"] as? String
                    ?? input.object?["lastAssistantMessage"] as? String
                let cwd = input.cwd ?? mapped?.cwd
                let projectName: String? = {
                    guard let cwd, !cwd.isEmpty else { return nil }
                    return URL(fileURLWithPath: NSString(string: cwd).expandingTildeInPath).lastPathComponent
                }()

                if !sessionId.isEmpty {
                    let launchCommand = agentLaunchCommandFromEnvironment(
                        env,
                        fallbackPID: pid,
                        fallbackKind: def.name,
                        cwd: cwd
                    )
                    try? store.upsert(sessionId: sessionId, workspaceId: workspaceId, surfaceId: surfaceId, cwd: cwd, pid: pid,
                                      launchCommand: launchCommand,
                                      lastSubtitle: "Completed", lastBody: lastMsg.map { truncate($0, maxLength: 200) })
                }
                if let pid {
                    _ = try? sendV1Command("set_agent_pid \(pidKey) \(pid) --tab=\(workspaceId)", client: client)
                }

                var subtitle = "Completed"
                if let projectName, !projectName.isEmpty { subtitle = "Completed in \(projectName)" }
                let body = sanitizeNotificationField(
                    lastMsg.map { truncate(normalizedSingleLine($0), maxLength: 200) }
                        ?? "\(def.displayName) session completed"
                )
                let payload = "\(def.displayName)|\(sanitizeNotificationField(subtitle))|\(body)"
                _ = try? sendV1Command("notify_target \(workspaceId) \(surfaceId) \(payload)", client: client)
                _ = try? sendV1Command("set_status \(def.statusKey) Idle --icon=pause.circle.fill --color=#8E8E93 --tab=\(workspaceId)", client: client)
            } catch {
                if shouldIgnoreClaudeHookTeardownError(error) {
                    telemetry.breadcrumb("\(def.name)-hook.stop.ignored", data: ["error": String(describing: error)])
                } else {
                    throw error
                }
            }

        case .sessionEnd:
            if let mapped = try? store.consume(sessionId: sessionId, workspaceId: nil, surfaceId: nil) {
                _ = try? sendV1Command("clear_status \(def.statusKey) --tab=\(mapped.workspaceId)", client: client)
                _ = try? sendV1Command("clear_agent_pid \(pidKey) --tab=\(mapped.workspaceId)", client: client)
            }

        case .noop:
            break
        }

        print("{}")
    }

    // MARK: Convenience wrappers

    private func runCursorInstallHooks() throws { try installAgentHooks(Self.agentDef(named: "cursor")!) }
    private func runCursorUninstallHooks() throws { try uninstallAgentHooks(Self.agentDef(named: "cursor")!) }
    private func runCursorHook(commandArgs: [String], client: SocketClient, telemetry: CLISocketSentryTelemetry) throws {
        try runGenericAgentHook(def: Self.agentDef(named: "cursor")!, commandArgs: commandArgs, client: client, telemetry: telemetry)
    }

    private func runGeminiInstallHooks() throws { try installAgentHooks(Self.agentDef(named: "gemini")!) }
    private func runGeminiUninstallHooks() throws { try uninstallAgentHooks(Self.agentDef(named: "gemini")!) }
    private func runGeminiHook(commandArgs: [String], client: SocketClient, telemetry: CLISocketSentryTelemetry) throws {
        try runGenericAgentHook(def: Self.agentDef(named: "gemini")!, commandArgs: commandArgs, client: client, telemetry: telemetry)
    }

    // MARK: - Unified setup-hooks

    private func runSetupHooks(uninstall: Bool = false) throws {
        let args = ProcessInfo.processInfo.arguments
        let agentFilter = optionValue(args, name: "--agent")
        let isUninstall = uninstall || args.contains("--uninstall")
        let fm = FileManager.default
        let verb = isUninstall ? "uninstalling" : "installing"

        print("cmux \(isUninstall ? "uninstall" : "setup")-hooks: \(verb) agent hooks")
        if !isUninstall {
            print("  (Claude Code hooks are injected automatically via the claude wrapper)")
        }
        print("")

        var count = 0
        var skipped = 0

        for def in Self.agentDefs {
            if let filter = agentFilter, filter.lowercased() != def.name { continue }
            let configDir = def.resolvedConfigDir()
            if def.name != "opencode", !fm.fileExists(atPath: configDir) {
                print("  \(def.name): skipped (not found)")
                skipped += 1
                continue
            }
            print("  \(def.name):")
            if isUninstall {
                try uninstallAgentHooks(def)
            } else {
                try installAgentHooks(def)
            }
            count += 1
            print("")
        }

        print("Done: \(count) \(isUninstall ? "uninstalled" : "installed"), \(skipped) skipped")
    }


    private func versionSummary() -> String {
        let info = resolvedVersionInfo()
        let commit = info["CMUXCommit"].flatMap { normalizedCommitHash($0) }
        let baseSummary: String
        if let version = info["CFBundleShortVersionString"], let build = info["CFBundleVersion"] {
            baseSummary = "cmux \(version) (\(build))"
        } else if let version = info["CFBundleShortVersionString"] {
            baseSummary = "cmux \(version)"
        } else if let build = info["CFBundleVersion"] {
            baseSummary = "cmux build \(build)"
        } else {
            baseSummary = "cmux version unknown"
        }
        guard let commit else { return baseSummary }
        return "\(baseSummary) [\(commit)]"
    }

    private func printWelcome() {
        let reset = "\u{001B}[0m"
        let bold = "\u{001B}[1m"
        func trueColor(_ red: Int, _ green: Int, _ blue: Int) -> String {
            "\u{001B}[38;2;\(red);\(green);\(blue)m"
        }

        let isDark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"

        let c1 = trueColor(0, 212, 255)
        let c2 = trueColor(24, 181, 250)
        let c3 = trueColor(48, 150, 245)
        let c4 = trueColor(72, 119, 241)
        let c5 = trueColor(96, 88, 239)
        let c6 = trueColor(110, 73, 238)
        let c7 = trueColor(124, 58, 237)

        let tagline: String
        let subdued: String

        if isDark {
            tagline = trueColor(130, 130, 140)
            subdued = "\u{001B}[2m"
        } else {
            tagline = trueColor(90, 90, 98)
            subdued = trueColor(100, 100, 108)
        }

        let logo = """
        \(c1)  ::\(reset)
        \(c2)    ::::\(reset)              \(c1)c\(c2)m\(c3)u\(c7)x\(reset)
        \(c3)      ::::::\(reset)
        \(c4)        ::::::\(reset)        \(tagline)the open source terminal\(reset)
        \(c5)      ::::::\(reset)          \(tagline)built for coding agents\(reset)
        \(c6)    ::::\(reset)
        \(c7)  ::\(reset)
        """

        let shortcuts = """
          \(bold)Shortcuts\(reset)

          \(bold)\u{2318}N\(reset)\(subdued)                  New workspace\(reset)
          \(bold)\u{2318}T\(reset)\(subdued)                  New tab\(reset)
          \(bold)\u{2318}P\(reset)\(subdued)                  Go to workspace\(reset)
          \(bold)\u{2318}D\(reset)\(subdued)                  Split right\(reset)
          \(bold)\u{2318}\u{21E7}D\(reset)\(subdued)                 Split down\(reset)
          \(bold)\u{2318}\u{21E7}P\(reset)\(subdued)                 Command palette\(reset)
          \(bold)\u{2318}\u{21E7}R\(reset)\(subdued)                 Rename workspace\(reset)
          \(bold)\u{2318}\u{21E7}L\(reset)\(subdued)                 New browser\(reset)
          \(bold)\u{2318}\u{21E7}U\(reset)\(subdued)                 Jump to latest unread\(reset)
        """

        print()
        print(logo)
        print()
        print(shortcuts)
        print()
        print("  \(bold)Docs\(reset)\(subdued)                https://cmux.com/docs\(reset)")
        print("  \(bold)Discord\(reset)\(subdued)             https://discord.gg/xsgFEVrWCZ\(reset)")
        print("  \(bold)GitHub\(reset)\(subdued)              https://github.com/manaflow-ai/cmux (please leave a star ⭐)\(reset)")
        print("  \(bold)Email\(reset)\(subdued)               founders@manaflow.com\(reset)")
        print()
        print("  \(subdued)Run \(reset)\(bold)cmux --help\(reset)\(subdued) for all commands.\(reset)")
        print("  \(subdued)Run \(reset)\(bold)cmux shortcuts\(reset)\(subdued) to edit shortcuts.\(reset)")
        print("  \(subdued)Run \(reset)\(bold)cmux feedback\(reset)\(subdued) to report a bug.\(reset)")
        print()
    }

    private func resolvedVersionInfo() -> [String: String] {
        var info: [String: String] = [:]
        if let main = versionInfo(from: Bundle.main.infoDictionary) {
            info.merge(main, uniquingKeysWith: { current, _ in current })
        }

        let needsPlistFallback =
            info["CFBundleShortVersionString"] == nil ||
            info["CFBundleVersion"] == nil ||
            info["CMUXCommit"] == nil
        if needsPlistFallback {
            for plistURL in candidateInfoPlistURLs() {
                guard let data = try? Data(contentsOf: plistURL),
                      let raw = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
                      let dictionary = raw as? [String: Any],
                      let parsed = versionInfo(from: dictionary)
                else {
                    continue
                }
                info.merge(parsed, uniquingKeysWith: { current, _ in current })
                if info["CFBundleShortVersionString"] != nil,
                   info["CFBundleVersion"] != nil,
                   info["CMUXCommit"] != nil {
                    break
                }
            }
        }

        let needsProjectFallback =
            info["CFBundleShortVersionString"] == nil ||
            info["CFBundleVersion"] == nil ||
            info["CMUXCommit"] == nil
        if needsProjectFallback, let fromProject = versionInfoFromProjectFile() {
            info.merge(fromProject, uniquingKeysWith: { current, _ in current })
        }

        if info["CMUXCommit"] == nil,
           let commit = normalizedCommitHash(ProcessInfo.processInfo.environment["CMUX_COMMIT"]) {
            info["CMUXCommit"] = commit
        }

        return info
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
        if let commit = dictionary["CMUXCommit"] as? String,
           let normalizedCommit = normalizedCommitHash(commit) {
            info["CMUXCommit"] = normalizedCommit
        }
        return info.isEmpty ? nil : info
    }

    private func versionInfoFromProjectFile() -> [String: String]? {
        guard let executableURL = resolvedExecutableURL() else {
            return nil
        }

        let fileManager = FileManager.default
        var current = executableURL.deletingLastPathComponent().standardizedFileURL

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
                if let commit = gitCommitHash(at: current) {
                    info["CMUXCommit"] = commit
                }
                if !info.isEmpty {
                    return info
                }
            }

            guard let parent = parentSearchURL(for: current) else {
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

    private func gitCommitHash(at directory: URL) -> String? {
        let process = Process()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", directory.path, "rev-parse", "--short=9", "HEAD"]
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return nil
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else {
            return nil
        }
        return normalizedCommitHash(output)
    }

    private func normalizedCommitHash(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("$(") else {
            return nil
        }
        let normalized = trimmed.lowercased()
        let allowed = CharacterSet(charactersIn: "0123456789abcdef")
        guard normalized.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return nil
        }
        return String(normalized.prefix(12))
    }

    // Foundation can walk past "/" into "/.." when repeatedly deleting path
    // components, so stop once the canonical root is reached.
    private func parentSearchURL(for url: URL) -> URL? {
        let standardized = url.standardizedFileURL
        let path = standardized.path
        guard !path.isEmpty, path != "/" else {
            return nil
        }

        let parent = standardized.deletingLastPathComponent().standardizedFileURL
        guard parent.path != path else {
            return nil
        }
        return parent
    }

    private func candidateInfoPlistURLs() -> [URL] {
        guard let executableURL = resolvedExecutableURL() else {
            return []
        }

        let fileManager = FileManager.default

        var candidates: [URL] = []
        var seen: Set<String> = []
        func appendIfExisting(_ url: URL) {
            let path = url.path
            guard !path.isEmpty else { return }
            guard seen.insert(path).inserted else { return }
            guard fileManager.fileExists(atPath: path) else { return }
            candidates.append(url)
        }

        var current = executableURL.deletingLastPathComponent().standardizedFileURL
        while true {
            if current.pathExtension == "app" {
                appendIfExisting(current.appendingPathComponent("Contents/Info.plist"))
            }
            if current.lastPathComponent == "Contents" {
                appendIfExisting(current.appendingPathComponent("Info.plist"))
            }

            let projectMarker = current.appendingPathComponent("GhosttyTabs.xcodeproj/project.pbxproj")
            let repoInfo = current.appendingPathComponent("Resources/Info.plist")
            if fileManager.fileExists(atPath: projectMarker.path),
               fileManager.fileExists(atPath: repoInfo.path) {
                appendIfExisting(repoInfo)
                break
            }

            guard let parent = parentSearchURL(for: current) else {
                break
            }
            current = parent
        }

        // If we already found an ancestor bundle or repo Info.plist, avoid scanning
        // sibling app bundles. Large Resources directories can otherwise balloon RSS.
        guard candidates.isEmpty else {
            return candidates
        }

        let searchRoots = [
            executableURL.deletingLastPathComponent().standardizedFileURL,
            executableURL.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL
        ]
        for root in searchRoots {
            guard let entries = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants],
                errorHandler: { _, _ in true }
            ) else {
                continue
            }
            for case let entry as URL in entries where entry.pathExtension == "app" {
                appendIfExisting(entry.appendingPathComponent("Contents/Info.plist"))
            }
        }

        return candidates
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

    private func resolvedExecutableURL() -> URL? {
        guard let executable = currentExecutablePath(), !executable.isEmpty else {
            return nil
        }

        let expanded = (executable as NSString).expandingTildeInPath
        if let resolvedPath = realpath(expanded, nil) {
            defer { free(resolvedPath) }
            return URL(fileURLWithPath: String(cString: resolvedPath)).standardizedFileURL
        }

        return URL(fileURLWithPath: expanded).standardizedFileURL
    }

    private func usage() -> String {
        return """
        cmux - control cmux via Unix socket

        Usage:
          cmux <path>                Open a directory in a new workspace (launches cmux if needed)
          cmux [global-options] <command> [options]

        Handle Inputs:
          Use UUIDs, short refs (window:1/workspace:2/pane:3/surface:4), or indexes where commands accept window, workspace, pane, or surface inputs.
          `tab-action` also accepts `tab:<n>` in addition to `surface:<n>`.
          Output defaults to refs; pass --id-format uuids or --id-format both to include UUIDs.

        Socket Auth:
          --password takes precedence, then CMUX_SOCKET_PASSWORD env var, then password saved in Settings.

        Commands:
          welcome
          shortcuts
          restore-session
          feedback [--email <email> --body <text> [--image <path> ...]]
          themes [list|set|clear]
          claude-teams [claude-args...]
          omo [opencode-args...]
          omx [omx-args...]
          omc [omc-args...]
          codex <install-hooks|uninstall-hooks>
          opencode <install-hooks|uninstall-hooks>
          ping
          version
          capabilities
          auth <status|login|logout>
          rpc <method> [json-params]
          identify [--workspace <id|ref|index>] [--surface <id|ref|index>] [--no-caller]
          list-windows
          current-window
          new-window
          focus-window --window <id>
          close-window --window <id>
          move-workspace-to-window --workspace <id|ref> --window <id|ref>
          reorder-workspace --workspace <id|ref|index> (--index <n> | --before <id|ref|index> | --after <id|ref|index>) [--window <id|ref|index>]
          workspace-action --action <name> [--workspace <id|ref|index>] [--title <text>] [--color <name|#hex>] [--description <text>]
          list-workspaces
          new-workspace [--name <title>] [--description <text>] [--cwd <path>] [--command <text>] [--layout <json>]
          ssh <destination> [--name <title>] [--port <n>] [--identity <path>] [--ssh-option <opt>] [--no-focus] [-- <remote-command-args>]
          remote-daemon-status [--os <darwin|linux>] [--arch <arm64|amd64>]
          new-split <left|right|up|down> [--workspace <id|ref>] [--surface <id|ref>] [--panel <id|ref>]
          list-panes [--workspace <id|ref>]
          list-pane-surfaces [--workspace <id|ref>] [--pane <id|ref>]
          tree [--all] [--workspace <id|ref|index>]
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
          reload-config
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
          opencode-hook <session-start|prompt-submit|stop|session-end> [--workspace <id|ref>] [--surface <id|ref>]
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

          markdown [open] <path>             (open markdown file in formatted viewer panel with live reload)

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
          browser screenshot [--out <path>] [--json]
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
          browser identify [--surface <id|ref|index>]
          help

        Environment:
          CMUX_WORKSPACE_ID   Auto-set in cmux terminals. Used as default --workspace for
                              ALL commands (send, list-panels, new-split, notify, etc.).
          CMUX_TAB_ID         Optional alias used by `tab-action`/`rename-tab` as default --tab.
          CMUX_SURFACE_ID     Auto-set in cmux terminals. Used as default --surface.
          CMUX_SOCKET_PATH    Override the Unix socket path. Without this, the CLI defaults
                              to ~/Library/Application Support/cmux/cmux.sock and auto-discovers tagged/debug sockets.
        """
    }

#if DEBUG
    func debugUsageTextForTesting() -> String {
        usage()
    }

    func debugFormatDebugTerminalsPayloadForTesting(
        _ payload: [String: Any],
        idFormat: CLIIDFormat = .refs
    ) -> String {
        formatDebugTerminalsPayload(payload, idFormat: idFormat)
    }
#endif
}

@main
struct CMUXTermMain {
    static func main() {
        // CLI tools should ignore SIGPIPE so closed stdout pipes do not terminate the process.
        _ = signal(SIGPIPE, SIG_IGN)
        let cli = CMUXCLI(args: CommandLine.arguments)
        do {
            try cli.run()
        } catch {
            FileHandle.standardError.write(Data("Error: \(error)\n".utf8))
            exit(1)
        }
    }
}

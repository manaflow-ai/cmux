import Darwin
import Foundation
#if canImport(Sentry)
import Sentry
#endif

final class CLISocketSentryTelemetry {
    private struct PendingBreadcrumb {
        let message: String
        let data: [String: Any]
    }

    private let command: String
    private let subcommand: String
    private let socketPath: String
    private let envSocketPath: String?
    private let workspaceId: String?
    private let surfaceId: String?
    private let disabledByEnv: Bool
    private var pendingBreadcrumbs: [PendingBreadcrumb] = []

    deinit {}

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
        self.envSocketPath = CLISocketEnvironment.socketPathForTelemetry(in: processEnv)
        self.workspaceId = processEnv["CMUX_WORKSPACE_ID"]
        self.surfaceId = processEnv["CMUX_SURFACE_ID"]
        self.disabledByEnv =
            processEnv["CMUX_CLI_SENTRY_DISABLED"] == "1" ||
            processEnv["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] == "1"
    }

    func breadcrumb(_ message: String, data: [String: Any] = [:]) {
        guard shouldEmit else { return }
#if canImport(Sentry)
        pendingBreadcrumbs.append(PendingBreadcrumb(message: message, data: data))
#endif
    }

    func captureError(stage: String, error: Error, data: [String: Any] = [:]) {
        guard shouldEmit else { return }
#if canImport(Sentry)
        Self.ensureStarted()
        flushPendingBreadcrumbs()
        var context = baseContext()
        context["stage"] = stage
        context["error"] = String(describing: error)
        for (key, value) in socketDiagnostics() {
            context[key] = value
        }
        for (key, value) in data {
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

#if canImport(Sentry)
    private func flushPendingBreadcrumbs() {
        for pending in pendingBreadcrumbs {
            addBreadcrumb(message: pending.message, data: pending.data)
        }
        pendingBreadcrumbs.removeAll()
    }

    private func addBreadcrumb(message: String, data: [String: Any]) {
        var payload = baseContext()
        for (key, value) in data {
            payload[key] = value
        }
        let crumb = Breadcrumb(level: .info, category: "cmux.cli")
        crumb.message = message
        crumb.data = payload
        SentrySDK.addBreadcrumb(crumb)
    }
#endif

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
            "has_cwd": !FileManager.default.currentDirectoryPath.isEmpty,
            "has_env_socket_path": !(envSocketPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        ]

        var st = stat()
        if lstat(socketPath, &st) == 0 {
            context["socket_exists"] = true
            context["socket_mode"] = String(format: "%o", Int(st.st_mode & 0o7777))
            context["socket_owned_by_current_user"] = Int(st.st_uid) == Int(geteuid())
            context["socket_file_type"] = Self.fileTypeDescription(mode: st.st_mode)
        } else {
            let code = errno
            context["socket_exists"] = false
            context["socket_errno"] = Int(code)
            context["socket_errno_description"] = String(cString: strerror(code))
        }

        let tmpSockets = Self.discoverSockets(in: "/tmp", limit: 10)
        let taggedSockets = tmpSockets.filter { $0 != CLISocketPathResolver.legacyDefaultSocketPath }
        context["tmp_cmux_socket_count"] = tmpSockets.count
        context["tagged_tmp_cmux_socket_count"] = taggedSockets.count
        if CLISocketPathResolver.isImplicitDefaultPath(socketPath),
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
            options.enableAppHangTracking = false
            options.enableWatchdogTerminationTracking = false
            options.enableAutoSessionTracking = false
            options.enableCaptureFailedRequests = false
            options.enableMetricKit = false
        }
        started = true
    }
#endif
}

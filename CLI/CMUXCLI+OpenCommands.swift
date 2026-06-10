import Foundation
import CMUXAgentLaunch
import CmuxFoundation
import CmuxSocketControl
import CoreFoundation
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


// MARK: - Markdown, project, and path open commands
extension CMUXCLI {
    /// Validates a `cmux markdown open --font-size <points>` value. The viewer
    /// clamps the rendered size to 8...96 points, so reject anything outside
    /// that range here instead of silently clamping the user's input.
    private func parseMarkdownViewerFontSize(_ rawValue: String) throws -> Double {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let size = Double(trimmed), size >= 8, size <= 96 else {
            throw CLIError(message: "--font-size must be a number between 8 and 96")
        }
        return (size * 100).rounded() / 100
    }

    func resolvePath(_ path: String) -> String {
        let expanded = NSString(string: path).expandingTildeInPath
        if expanded.hasPrefix("/") { return expanded }
        let cwd = FileManager.default.currentDirectoryPath
        return (cwd as NSString).appendingPathComponent(expanded)
    }

    func sanitizedFilenameComponent(_ raw: String) -> String {
        let sanitized = raw.replacingOccurrences(
            of: #"[^\p{L}\p{N}._-]+"#,
            with: "-",
            options: .regularExpression
        )
        let trimmed = sanitized.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return trimmed.isEmpty ? "item" : trimmed
    }

    func bestEffortPruneTemporaryFiles(
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

    func runMarkdownCommand(
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
        let (focusOpt, argsAfterFocus) = parseOption(argsAfterDirection, name: "--focus")
        let (fontSizeOpt, argsAfterFontSize) = parseOption(argsAfterFocus, name: "--font-size")
        args = argsAfterFontSize

        let fontSize = try fontSizeOpt.map(parseMarkdownViewerFontSize)

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
                        "markdown open: unknown flag '\(first)'. Usage: cmux markdown open <path> [--workspace <id|ref|index>] [--surface <id|ref|index>] [--window <id|ref|index>] [--direction right|down|left|up] [--focus <true|false>] [--font-size <points>]"
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
                    "markdown open: unknown flag '\(unknownFlag)'. Usage: cmux markdown open <path> [--workspace <id|ref|index>] [--surface <id|ref|index>] [--window <id|ref|index>] [--direction right|down|left|up] [--focus <true|false>] [--font-size <points>]"
            )
        }
        if let extraArg = trailingArgs.first {
            throw CLIError(
                message:
                    "markdown open: unexpected argument '\(extraArg)'. Usage: cmux markdown open <path> [--workspace <id|ref|index>] [--surface <id|ref|index>] [--window <id|ref|index>] [--direction right|down|left|up] [--focus <true|false>] [--font-size <points>]"
            )
        }

        let absolutePath = resolvePath(rawPath)

        // Build params
        let direction = directionOpt ?? "right"
        var params: [String: Any] = ["path": absolutePath, "direction": direction]
        if let fontSize {
            params["font_size"] = fontSize
        }
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
        try applyFocusOption(focusOpt, defaultValue: false, to: &params)

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

    func runProjectCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        var args = commandArgs
        let (workspaceOpt, argsAfterWorkspace) = parseOption(args, name: "--workspace")
        let (windowOpt, argsAfterWindow) = parseOption(argsAfterWorkspace, name: "--window")
        let (focusOpt, argsAfterFocus) = parseOption(argsAfterWindow, name: "--focus")
        args = argsAfterFocus

        // Treat first token as subcommand if it's "open", else require it.
        guard let first = args.first?.lowercased() else {
            throw CLIError(message: "project requires a subcommand. Usage: cmux project open <path-to-.xcodeproj-or-.xcworkspace>")
        }
        let subArgs: [String]
        if first == "open" {
            subArgs = Array(args.dropFirst())
        } else if args.count == 1 {
            subArgs = args
        } else {
            throw CLIError(message: "Unknown project subcommand: \(first). Usage: cmux project open <path>")
        }

        guard let rawPath = subArgs.first, !rawPath.isEmpty else {
            throw CLIError(message: "project open requires a path. Usage: cmux project open <path-to-.xcodeproj-or-.xcworkspace>")
        }
        let absolutePath = resolvePath(rawPath)
        var params: [String: Any] = ["path": absolutePath]
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
        try applyFocusOption(focusOpt, defaultValue: true, to: &params)

        let payload = try client.sendV2(method: "project.open", params: params)

        if jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
        } else {
            let surfaceText = formatHandle(payload, kind: "surface", idFormat: idFormat) ?? "unknown"
            let paneText = formatHandle(payload, kind: "pane", idFormat: idFormat) ?? "unknown"
            let path = (payload["path"] as? String) ?? absolutePath
            print("OK surface=\(surfaceText) pane=\(paneText) project=\(path)")
        }
    }

    /// Returns true if the argument looks like a filesystem path rather than a CLI command.
    private func looksLikePath(_ arg: String) -> Bool {
        if arg == "." || arg == ".." { return true }
        if arg.hasPrefix("/") || arg.hasPrefix("./") || arg.hasPrefix("../") || arg.hasPrefix("~") { return true }
        if arg.contains("/") { return true }
        return false
    }

    func shouldOpenAsPathArgument(_ arg: String) -> Bool {
        if looksLikePath(arg) {
            return true
        }
        guard !arg.hasPrefix("-"),
              !Self.topLevelCommandNames.contains(arg) else {
            return false
        }
        return FileManager.default.fileExists(atPath: resolvePath(arg))
    }

    private static let topLevelCommandNames: Set<String> = [
        "__codex-teams-watch",
        "__tmux-compat",
        "agent-hibernation",
        "auth",
        "bind-key",
        "break-pane",
        "browser",
        "browser-back",
        "browser-forward",
        "browser-reload",
        "browser-status",
        "capabilities",
        "capture-pane",
        "claude-hook",
        "claude-teams",
        "clear-history",
        "clear-log",
        "clear-notifications",
        "clear-progress",
        "clear-status",
        "close-surface",
        "close-window",
        "close-workspace",
        "cloud",
        "codex",
        "codex-hook",
        "codex-teams",
        "config",
        "copy-mode",
        "current-window",
        "current-workspace",
        "debug-terminals",
        "detach-tab",
        "diff",
        "disable-browser",
        "dismiss-notification",
        "display-message",
        "docs",
        "drag-surface-to-split",
        "enable-browser",
        "events",
        "feedback",
        "feed",
        "feed-hook",
        "find-window",
        "focus-pane",
        "focus-panel",
        "focus-webview",
        "focus-window",
        "get-url",
        "help",
        "hooks",
        "identify",
        "is-webview-focused",
        "join-pane",
        "jump-to-unread",
        "last-pane",
        "last-window",
        "list-buffers",
        "list-log",
        "list-notifications",
        "list-pane-surfaces",
        "list-panels",
        "list-panes",
        "list-status",
        "list-windows",
        "list-workspaces",
        "log",
        "login",
        "logout",
        "markdown",
        "mark-notification-read",
        "memory",
        "move-surface",
        "move-tab-to-new-workspace",
        "move-workspace-to-window",
        "navigate",
        "new-pane",
        "new-split",
        "new-surface",
        "new-window",
        "new-workspace",
        "next-window",
        "notify",
        "omc",
        "omo",
        "omx",
        "open",
        "open-browser",
        "open-notification",
        "paste-buffer",
        "ping",
        "pipe-pane",
        "popup",
        "previous-window",
        "read-screen",
        "refresh-surfaces",
        "reload-config",
        "remote-daemon-status",
        "rename-tab",
        "rename-window",
        "rename-workspace",
        "reorder-surface",
        "reorder-workspace",
        "reorder-workspaces",
        "resize-pane",
        "respawn-pane",
        "restore-session",
        "right-sidebar",
        "rpc",
        "select-workspace",
        "send",
        "send-key",
        "send-key-panel",
        "send-panel",
        "set-app-focus",
        "set-buffer",
        "set-hook",
        "set-progress",
        "set-status",
        "settings",
        "setup-hooks",
        "shortcuts",
        "simulate-app-active",
        "sidebar",
        "sidebar-state",
        "split-off",
        "ssh",
        "ssh-pty-attach",
        "ssh-session-attach",
        "ssh-session-cleanup",
        "ssh-session-end",
        "ssh-session-list",
        "surface",
        "surface-health",
        "surface-resume",
        "swap-pane",
        "tab-action",
        "themes",
        "top",
        "tree",
        "trigger-flash",
        "unbind-key",
        "uninstall-hooks",
        "version",
        "vm",
        "vm-pty-attach",
        "vm-pty-connect",
        "vm-ssh-attach",
        "wait-for",
        "welcome",
        "workspace",
        "workspace-action",
        "workspace-group",
    ]

    /// Open a path in cmux by asking LaunchServices to deliver a directory URL to the app.
    func openPath(_ path: String) throws {
        let directory = try directoryForPathOpen(path)
        try openDirectoryWithLaunchServices(directory)
        print(String(localized: "common.ok", defaultValue: "OK"))
    }

    /// Open a path through an explicitly selected socket, preserving deliberate instance routing.
    func openPathViaExplicitSocket(_ path: String, socketPath: String, explicitPassword: String?) throws {
        let directory = try directoryForPathOpen(path)
        let client = try connectClient(
            socketPath: socketPath,
            explicitPassword: explicitPassword,
            launchIfNeeded: true
        )
        defer { client.close() }

        let response = try client.sendV2(method: "workspace.create", params: ["cwd": directory])
        let wsRef = (response["workspace_ref"] as? String) ?? (response["workspace_id"] as? String) ?? ""
        let okText = String(localized: "common.ok", defaultValue: "OK")
        print(wsRef.isEmpty ? okText : "\(okText) \(wsRef)")
        try activateApp()
    }

    private func directoryForPathOpen(_ path: String) throws -> String {
        let resolved = URL(fileURLWithPath: resolvePath(path)).standardizedFileURL.path
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir)

        if exists && isDir.boolValue {
            return resolved
        }
        if exists {
            return (resolved as NSString).deletingLastPathComponent
        }

        throw CLIError(message: localizedFormat("cli.pathOpen.error.pathDoesNotExist", defaultValue: "Path does not exist: %@", resolved))
    }

    private func openDirectoryWithLaunchServices(_ directory: String) throws {
        try runOpenTool(
            arguments: ["-a", appLaunchTarget(), directory],
            failureMessage: localizedFormat("cli.pathOpen.error.openFailed", defaultValue: "Failed to open %@ in cmux", directory),
            environment: launchServicesPathOpenEnvironment()
        )
    }

    func runOpenTool(
        arguments: [String],
        failureMessage: String,
        environment: [String: String]? = nil
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: openToolPath())
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()

        if try !waitForProcessExit(process, timeout: 10) {
            process.terminate()
            if try !waitForProcessExit(process, timeout: 1) {
                kill(process.processIdentifier, SIGKILL)
                _ = try? waitForProcessExit(process, timeout: 1)
            }
            throw CLIError(message: localizedFormat("cli.pathOpen.error.timedOut", defaultValue: "%@ (timed out)", failureMessage))
        }

        guard process.terminationStatus == 0 else {
            throw CLIError(message: failureMessage)
        }
    }

    private static let launchServicesPathOpenScrubbedEnvironmentKeys: Set<String> = [
        "CMUX_ALLOW_SOCKET_OVERRIDE",
        "CMUX_SOCKET",
        "CMUX_SOCKET_ENABLE",
        "CMUX_SOCKET_MODE",
        "CMUX_SOCKET_PASSWORD",
        "CMUX_SOCKET_PATH",
        "CMUX_PANEL_ID",
        "CMUX_SURFACE_ID",
        "CMUX_TAB_ID",
        "CMUX_WORKSPACE_ID",
    ]

    private func launchServicesPathOpenEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for key in Self.launchServicesPathOpenScrubbedEnvironmentKeys {
            environment.removeValue(forKey: key)
        }
        return environment
    }

    private func waitForProcessExit(_ process: Process, timeout: TimeInterval) throws -> Bool {
        if !process.isRunning {
            process.waitUntilExit()
            return true
        }

        let queue = kqueue()
        guard queue >= 0 else {
            throw CLIError(message: String(localized: "cli.pathOpen.error.processMonitorFailed", defaultValue: "Failed to monitor process exit"))
        }
        defer { close(queue) }

        var event = kevent(
            ident: UInt(process.processIdentifier),
            filter: Int16(EVFILT_PROC),
            flags: UInt16(EV_ADD | EV_ENABLE | EV_ONESHOT),
            fflags: UInt32(NOTE_EXIT),
            data: 0,
            udata: nil
        )
        guard kevent(queue, &event, 1, nil, 0, nil) == 0 else {
            if errno == ESRCH {
                process.waitUntilExit()
                return true
            }
            throw CLIError(message: String(localized: "cli.pathOpen.error.processMonitorFailed", defaultValue: "Failed to monitor process exit"))
        }

        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                return false
            }

            var timeoutSpec = timespec(
                tv_sec: Int(remaining),
                tv_nsec: Int((remaining - floor(remaining)) * 1_000_000_000)
            )
            var triggeredEvent = kevent()
            let result = kevent(queue, nil, 0, &triggeredEvent, 1, &timeoutSpec)
            if result > 0 {
                process.waitUntilExit()
                return true
            }
            if result == 0 {
                return false
            }
            if errno != EINTR {
                throw CLIError(message: String(localized: "cli.pathOpen.error.processMonitorFailed", defaultValue: "Failed to monitor process exit"))
            }
        }
    }

    private func localizedFormat(_ key: String, defaultValue: String, _ arguments: CVarArg...) -> String {
        let format = NSLocalizedString(key, bundle: .main, value: defaultValue, comment: "")
        return String(format: format, locale: Locale.current, arguments: arguments)
    }

    private func openToolPath() -> String {
#if DEBUG
        if let override = ProcessInfo.processInfo.environment["CMUX_TEST_OPEN_TOOL_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return NSString(string: override).expandingTildeInPath
        }
#endif
        return "/usr/bin/open"
    }

    func appLaunchTarget() -> String {
        CLIExecutableLocator.enclosingAppBundle()?.bundleURL.path ?? "cmux"
    }

}

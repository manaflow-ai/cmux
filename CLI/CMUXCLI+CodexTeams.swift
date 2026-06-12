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


// MARK: - cmux codex-teams command
extension CMUXCLI {
    static func codexTeamsFeedEvent(
        method: String,
        requestId: Any,
        params: [String: Any],
        workspaceId: String,
        relatedItem: [String: Any]? = nil
    ) -> [String: Any] {
        CodexTeamsApprovalBridge.feedEvent(
            method: method,
            requestId: requestId,
            params: params,
            workspaceId: workspaceId,
            relatedItem: relatedItem
        )
    }

    static func codexTeamsPermissionMode(fromFeedPushResponse response: [String: Any]) -> String? {
        CodexTeamsApprovalBridge.permissionMode(fromFeedPushResponse: response)
    }

    static func codexTeamsAppServerApprovalResponse(
        method: String,
        params: [String: Any],
        mode: String
    ) -> [String: Any]? {
        CodexTeamsApprovalBridge.appServerApprovalResponse(
            method: method,
            params: params,
            mode: mode
        )
    }

    static func codexTeamsApprovalItemSnapshot(_ item: [String: Any]) -> [String: Any] {
        CodexTeamsApprovalBridge.approvalItemSnapshot(item)
    }

    static func requestIdString(_ requestId: Any) -> String {
        CodexTeamsApprovalBridge.requestIdString(requestId)
    }

    static func stringValue(in object: [String: Any], keys: [String]) -> String? {
        CodexTeamsApprovalBridge.stringValue(in: object, keys: keys)
    }

    static func codexTeamsThreadCanResume(appServerURL: String, threadId: String) -> Bool {
        guard let url = URL(string: appServerURL) else {
            return false
        }
        let connection = CodexTeamsAppServerConnection(url: url)
        connection.resume()
        do {
            defer { connection.close() }
            try connection.initialize(
                clientName: codexTeamsProbeClientName,
                version: codexTeamsClientVersion,
                responseTimeout: 1
            )
            return connection.canResumeThread(threadId: threadId)
        } catch {
            return false
        }
    }

    static func codexTeamsThread(from object: [String: Any]) -> CodexTeamsThread? {
        guard let id = object["id"] as? String, !id.isEmpty else { return nil }
        return CodexTeamsThread(
            id: id,
            cwd: object["cwd"] as? String,
            statusType: codexTeamsStatusType(from: object),
            agentNickname: object["agentNickname"] as? String,
            agentRole: object["agentRole"] as? String,
            spawn: codexTeamsSpawn(from: object)
        )
    }

    private static func codexTeamsStatusType(from threadObject: [String: Any]) -> String? {
        guard let status = threadObject["status"] as? [String: Any] else {
            return nil
        }
        return status["type"] as? String
    }

    static func codexTeamsThreadMayBeAttachable(_ thread: CodexTeamsThread) -> Bool {
        guard let statusType = thread.statusType?.trimmingCharacters(in: .whitespacesAndNewlines),
              !statusType.isEmpty else {
            return false
        }
        let normalized = statusType
            .replacingOccurrences(of: "_", with: "")
            .lowercased()
        return normalized != "notloaded"
    }

    private static func codexTeamsSpawn(from threadObject: [String: Any]) -> CodexTeamsSpawn? {
        guard let source = threadObject["source"] as? [String: Any] else { return nil }
        let subagentSource = source["subAgent"] ?? source["subagent"]
        guard let subagent = subagentSource as? [String: Any] else { return nil }
        let spawnSource = subagent["thread_spawn"] ?? subagent["threadSpawn"]
        guard let spawn = spawnSource as? [String: Any],
              let parentThreadId = (spawn["parent_thread_id"] as? String) ?? (spawn["parentThreadId"] as? String),
              !parentThreadId.isEmpty else {
            return nil
        }

        let sourceDepth: Int?
        if let depth = spawn["depth"] as? Int {
            sourceDepth = depth
        } else if let depth = spawn["depth"] as? NSNumber {
            sourceDepth = depth.intValue
        } else {
            sourceDepth = nil
        }

        return CodexTeamsSpawn(
            parentThreadId: parentThreadId,
            sourceDepth: sourceDepth,
            agentNickname: spawn["agent_nickname"] as? String ?? spawn["agentNickname"] as? String,
            agentRole: spawn["agent_role"] as? String ?? spawn["agentRole"] as? String
        )
    }

    static func codexTeamsResumeCommandText(
        codexExecutable: String,
        appServerURL: String,
        threadId: String,
        parentThreadId: String,
        depth: Int,
        launchPath: String?
    ) -> String {
        var parts = ["env"]
        if let launchPath,
           !launchPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("PATH=\(launchPath)")
        }
        parts += [
            "CMUX_CODEX_TEAMS_APP_SERVER_URL=\(appServerURL)",
            "\(managedSubagentEnvironmentKey)=1",
            "\(codexTeamsThreadEnvironmentKey)=\(threadId)",
            "\(codexTeamsParentThreadEnvironmentKey)=\(parentThreadId)",
            "\(codexTeamsDepthEnvironmentKey)=\(max(1, depth))",
            codexExecutable,
            "resume",
            "--remote",
            appServerURL,
            threadId
        ]
        return parts
            .map { codexTeamsShellQuote($0) }
            .joined(separator: " ")
    }

    private static func codexTeamsShellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    static func codexTeamsStartupScript(commandText: String, cwd: String?) -> String? {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-teams-\(UUID().uuidString.lowercased()).sh")
        var lines = [
            "#!/bin/sh",
            "rm -f -- \"$0\" 2>/dev/null || true"
        ]
        if let cwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines), !cwd.isEmpty {
            let quotedCwd = codexTeamsShellQuote(cwd)
            lines.append("{ cd -- \(quotedCwd) 2>/dev/null || [ ! -d \(quotedCwd) ]; } || exit $?")
        }
        lines.append("exec \"${SHELL:-/bin/sh}\" -lc \(codexTeamsShellQuote(commandText))")
        do {
            try (lines.joined(separator: "\n") + "\n").write(
                to: scriptURL,
                atomically: true,
                encoding: .utf8
            )
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
            return scriptURL.path
        } catch {
            return nil
        }
    }

    static func codexTeamsTitle(
        thread: CodexTeamsThread,
        spawn: CodexTeamsSpawn,
        depth: Int
    ) -> String {
        let label = [
            spawn.agentRole,
            thread.agentRole,
            spawn.agentNickname,
            thread.agentNickname
        ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
            ?? String(thread.id.prefix(8))
        return "Codex d\(depth): \(label)"
    }

    func runCodexTeams(
        commandArgs: [String],
        socketPath: String,
        explicitPassword: String?
    ) throws {
        let processEnvironment = ProcessInfo.processInfo.environment
        var launcherEnvironment = codexTeamsAugmentedEnvironment(processEnvironment)
        launcherEnvironment["CMUX_SOCKET_PATH"] = socketPath
        launcherEnvironment.removeValue(forKey: "CMUX_SOCKET")
        if let explicitPassword,
           !explicitPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            launcherEnvironment["CMUX_SOCKET_PASSWORD"] = explicitPassword
        }

        guard let focusedContext = try tmuxCompatFocusedContext(
            processEnvironment: launcherEnvironment,
            explicitPassword: explicitPassword
        ) else {
            throw CLIError(message: "cmux codex-teams must be started from a cmux terminal surface")
        }
        // The codex-teams root identity is the LAUNCH surface (this process's own env), not the
        // operator's focused pane, so the watcher records the surface codex actually runs in (#4920).
        let rootIdentity = AgentSpawnIdentity().resolve(
            ownWorkspaceId: launcherEnvironment["CMUX_WORKSPACE_ID"],
            ownSurfaceId: launcherEnvironment["CMUX_SURFACE_ID"],
            focusedWorkspaceId: focusedContext.workspaceId,
            focusedSurfaceId: focusedContext.surfaceId
        )
        guard let rootSurfaceId = rootIdentity.surfaceId, !rootSurfaceId.isEmpty else {
            throw CLIError(message: "cmux codex-teams must be started from a cmux terminal surface")
        }
        let rootWorkspaceId = rootIdentity.workspaceId ?? focusedContext.workspaceId
        try Self.validateCodexTeamsWorkingDirectory(
            commandArgs: commandArgs,
            baseDirectory: launcherEnvironment["PWD"] ?? FileManager.default.currentDirectoryPath
        )

        guard let codexExecutablePath = resolveCodexExecutable(searchPath: launcherEnvironment["PATH"]) else {
            throw CLIError(message: missingProviderExecutableMessage(
                displayName: "Codex",
                executableName: "codex"
            ))
        }
        launcherEnvironment["PATH"] = providerExecutableSearchPath(
            searchPath: launcherEnvironment["PATH"],
            includingExecutableAt: codexExecutablePath
        )
        let codexExecutableForShell = codexExecutablePath
        let appServerPort = omoBindableLoopbackPort(0) ?? 0
        guard appServerPort > 0 else {
            throw CLIError(message: "Failed to allocate a localhost port for Codex app-server")
        }
        let appServerURL = "ws://127.0.0.1:\(appServerPort)"

        let appServerLogURL = codexTeamsLogURL(port: appServerPort, name: "app-server")
        let watcherLogURL = codexTeamsLogURL(port: appServerPort, name: "watcher")
        let appServer = try startCodexTeamsProcess(
            executablePath: codexExecutablePath,
            arguments: ["app-server", "--listen", appServerURL],
            environment: launcherEnvironment,
            logURL: appServerLogURL
        )
        var watcher: Process?
        var rootCodex: Process?
        let originalForegroundProcessGroup = isatty(STDIN_FILENO) == 1 ? tcgetpgrp(STDIN_FILENO) : -1
        var didForegroundRootCodex = false
        func restoreRootCodexForegroundIfNeeded() {
            guard didForegroundRootCodex else { return }
            try? setTerminalForegroundProcessGroup(originalForegroundProcessGroup)
            didForegroundRootCodex = false
        }
        defer {
            restoreRootCodexForegroundIfNeeded()
            codexTeamsTerminateProcess(watcher)
            codexTeamsTerminateProcess(rootCodex)
            codexTeamsTerminateProcess(appServer)
        }

        do {
            try waitForCodexTeamsAppServer(appServerURL: appServerURL)
        } catch {
            throw CLIError(message: "\(error)\nCodex app-server log: \(appServerLogURL.path)")
        }

        setenv("CMUX_SOCKET_PATH", socketPath, 1)
        unsetenv("CMUX_SOCKET")
        if let explicitPassword,
           !explicitPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            setenv("CMUX_SOCKET_PASSWORD", explicitPassword, 1)
        }
        setenv("CMUX_CODEX_TEAMS_APP_SERVER_URL", appServerURL, 1)
        setenv("CMUX_CODEX_TEAMS_MAX_AUTO_DEPTH", String(Self.codexTeamsMaxAutoDepth), 1)
        let launchExecutable = resolvedExecutableURL()?.path ?? (args.first ?? "cmux")
        let launchArguments = [launchExecutable, "codex-teams"] + commandArgs
        exportAgentLaunchCommandEnvironment(
            launcher: "codexTeams",
            executablePath: launchExecutable,
            arguments: launchArguments,
            workingDirectory: launcherEnvironment["PWD"]
        )

        var rootEnvironment = launcherEnvironment
        rootEnvironment["CMUX_CODEX_TEAMS_APP_SERVER_URL"] = appServerURL
        rootEnvironment["CMUX_CODEX_TEAMS_MAX_AUTO_DEPTH"] = String(Self.codexTeamsMaxAutoDepth)
        rootEnvironment["CMUX_AGENT_LAUNCH_KIND"] = "codexTeams"
        rootEnvironment["CMUX_AGENT_LAUNCH_EXECUTABLE"] = launchExecutable
        rootEnvironment["CMUX_AGENT_LAUNCH_ARGV_B64"] = Self.nulSeparatedBase64(launchArguments)
        if let workingDirectory = launcherEnvironment["PWD"],
           !workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            rootEnvironment["CMUX_AGENT_LAUNCH_CWD"] = workingDirectory
        } else {
            rootEnvironment.removeValue(forKey: "CMUX_AGENT_LAUNCH_CWD")
        }

        rootCodex = try startCodexTeamsProcess(
            executablePath: codexExecutablePath,
            arguments: codexTeamsRootArguments(appServerURL: appServerURL, commandArgs: commandArgs),
            environment: rootEnvironment,
            standardInput: FileHandle.standardInput,
            standardOutput: FileHandle.standardOutput,
            standardError: FileHandle.standardError
        )
        if originalForegroundProcessGroup > 0,
           let rootCodex {
            let childProcessGroup = getpgid(rootCodex.processIdentifier)
            if childProcessGroup > 0 && childProcessGroup != originalForegroundProcessGroup {
                try setTerminalForegroundProcessGroup(childProcessGroup)
                _ = Darwin.kill(-childProcessGroup, SIGCONT)
                didForegroundRootCodex = true
            }
        }

        let executablePath = resolvedExecutableURL()?.path ?? (args.first ?? "cmux")
        var watcherArguments = [
            "--socket",
            socketPath,
            "__codex-teams-watch",
            "--workspace-id",
            rootWorkspaceId,
            "--surface-id",
            rootSurfaceId,
            "--app-server-url",
            appServerURL,
            "--codex-path",
            codexExecutableForShell,
            "--launch-path",
            codexTeamsSubagentLaunchPath(launcherEnvironment["PATH"]),
            "--max-auto-depth",
            String(Self.codexTeamsMaxAutoDepth)
        ]
        if let explicitPassword,
           !explicitPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            watcherArguments.insert(contentsOf: ["--password", explicitPassword], at: 2)
        }
        if let rootPid = rootCodex?.processIdentifier {
            watcherArguments += ["--owner-pid", String(rootPid)]
        }
        watcherArguments += ["--app-server-pid", String(appServer.processIdentifier)]

        watcher = try startCodexTeamsProcess(
            executablePath: executablePath,
            arguments: watcherArguments,
            environment: launcherEnvironment,
            logURL: watcherLogURL
        )

        rootCodex?.waitUntilExit()
        let status = rootCodex?.terminationStatus ?? 0
        restoreRootCodexForegroundIfNeeded()
        codexTeamsTerminateProcess(watcher)
        codexTeamsTerminateProcess(appServer)
        exit(status)
    }

    private func codexTeamsAugmentedEnvironment(_ environment: [String: String]) -> [String: String] {
        var result = environment
        result["PATH"] = codexTeamsAugmentedPath(environment: environment)
        return result
    }

    private func codexTeamsAugmentedPath(environment: [String: String]) -> String {
        var entries: [String] = []
        var seen = Set<String>()

        func appendPathList(_ path: String?) {
            for entry in path?.split(separator: ":").map(String.init) ?? [] {
                codexTeamsAppendPathEntry(entry, entries: &entries, seen: &seen)
            }
        }

        appendPathList(environment["PATH"])
        appendPathList(codexTeamsLoginShellPath(environment: environment))

        guard let home = environment["HOME"], !home.isEmpty else {
            return entries.joined(separator: ":")
        }

        [
            "\(home)/.nvm/current/bin",
            "\(home)/.volta/bin",
            "\(home)/.fnm/current/bin",
            "\(home)/.bun/bin",
            "\(home)/.local/share/mise/shims",
            "\(home)/.asdf/shims",
            "/opt/homebrew/bin",
            "/usr/local/bin"
        ].forEach { codexTeamsAppendPathEntry($0, entries: &entries, seen: &seen) }

        codexTeamsAppendNodeVersionBins(
            root: "\(home)/.nvm/versions/node",
            suffix: "bin",
            entries: &entries,
            seen: &seen
        )
        codexTeamsAppendNodeVersionBins(
            root: "\(home)/Library/Application Support/fnm/node-versions",
            suffix: "installation/bin",
            entries: &entries,
            seen: &seen
        )
        codexTeamsAppendNodeVersionBins(
            root: "\(home)/.local/share/fnm/node-versions",
            suffix: "installation/bin",
            entries: &entries,
            seen: &seen
        )

        return entries.joined(separator: ":")
    }

    private func codexTeamsSubagentLaunchPath(_ path: String?) -> String {
        return path?
            .split(separator: ":")
            .map(String.init)
            .filter { !$0.isEmpty }
            .joined(separator: ":") ?? ""
    }

    private static func validateCodexTeamsWorkingDirectory(
        commandArgs: [String],
        baseDirectory: String
    ) throws {
        do {
            try CodexTeamsApprovalBridge.validateWorkingDirectory(
                commandArgs: commandArgs,
                baseDirectory: baseDirectory
            )
        } catch {
            throw CLIError(message: error.localizedDescription)
        }
    }

    private func codexTeamsAppendPathEntry(
        _ entry: String,
        entries: inout [String],
        seen: inout Set<String>
    ) {
        let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !seen.contains(trimmed) else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: trimmed, isDirectory: &isDirectory),
              isDirectory.boolValue else { return }
        seen.insert(trimmed)
        entries.append(trimmed)
    }

    private func codexTeamsAppendNodeVersionBins(
        root: String,
        suffix: String,
        entries: inout [String],
        seen: inout Set<String>
    ) {
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        guard let versionURLs = try? FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for versionURL in versionURLs.sorted(by: codexTeamsNodeVersionURLSortPrecedes) {
            let binURL = suffix.split(separator: "/").reduce(versionURL) { partial, component in
                partial.appendingPathComponent(String(component), isDirectory: true)
            }
            codexTeamsAppendPathEntry(binURL.path, entries: &entries, seen: &seen)
        }
    }

    private func codexTeamsNodeVersionURLSortPrecedes(_ lhs: URL, _ rhs: URL) -> Bool {
        let comparison = lhs.lastPathComponent.compare(
            rhs.lastPathComponent,
            options: [.caseInsensitive, .numeric]
        )
        if comparison != .orderedSame {
            return comparison == .orderedDescending
        }
        return lhs.path > rhs.path
    }

    private func codexTeamsLoginShellPath(environment: [String: String]) -> String? {
        let shellPath = environment["SHELL"].flatMap { shell -> String? in
            guard shell.hasPrefix("/"),
                  FileManager.default.isExecutableFile(atPath: shell) else {
                return nil
            }
            return shell
        } ?? "/bin/zsh"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shellPath)
        process.arguments = ["-lc", "printf %s \"$PATH\""]
        process.environment = environment

        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle(forWritingAtPath: "/dev/null")

        do {
            try process.run()
        } catch {
            return nil
        }

        let outputBox = CodexTeamsAsyncBox<Data>()
        let outputReadSemaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            outputBox.set(ProcessPipeReader.readDataToEndOfFileOrEmpty(from: output.fileHandleForReading))
            outputReadSemaphore.signal()
        }

        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 2) != .timedOut else {
            process.terminate()
            return nil
        }

        _ = outputReadSemaphore.wait(timeout: .now() + 1)
        let data = outputBox.take() ?? Data()
        let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return path?.isEmpty == false ? path : nil
    }

    private func codexTeamsRootArguments(appServerURL: String, commandArgs: [String]) -> [String] {
        guard let first = commandArgs.first, first == "resume" || first == "fork" else {
            return ["--remote", appServerURL] + commandArgs
        }
        return [first, "--remote", appServerURL] + Array(commandArgs.dropFirst())
    }

    private func codexTeamsLogURL(port: UInt16, name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-teams-\(port)-\(name).log")
    }

    private func waitForCodexTeamsAppServer(appServerURL: String) throws {
        guard let url = URL(string: appServerURL) else {
            throw CLIError(message: "Invalid Codex app-server URL: \(appServerURL)")
        }
        var lastError: Error?
        let deadline = Date().addingTimeInterval(8)
        let retryWaiter = DispatchSemaphore(value: 0)
        while Date() < deadline {
            let connection = CodexTeamsAppServerConnection(url: url)
            connection.resume()
            do {
                defer { connection.close() }
                let responseTimeout = max(0.1, min(1, deadline.timeIntervalSinceNow))
                try connection.initialize(
                    clientName: Self.codexTeamsProbeClientName,
                    version: Self.codexTeamsClientVersion,
                    responseTimeout: responseTimeout
                )
                return
            } catch {
                lastError = error
                let retryDelay = max(0.01, min(0.1, deadline.timeIntervalSinceNow))
                _ = retryWaiter.wait(timeout: .now() + retryDelay)
            }
        }
        throw CLIError(message: "Codex app-server did not become ready: \(lastError.map { String(describing: $0) } ?? "unknown error")")
    }

    private func startCodexTeamsProcess(
        executablePath: String,
        arguments: [String],
        environment: [String: String]? = nil,
        logURL: URL? = nil,
        standardInput: Any? = nil,
        standardOutput: Any? = nil,
        standardError: Any? = nil
    ) throws -> Process {
        let process = Process()
        if executablePath.hasPrefix("/") {
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executablePath] + arguments
        }
        process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        process.environment = environment

        if let logURL {
            process.standardInput = standardInput ?? FileHandle(forReadingAtPath: "/dev/null")
            let descriptor = Darwin.open(
                logURL.path,
                O_WRONLY | O_CREAT | O_TRUNC | O_APPEND,
                S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH
            )
            guard descriptor >= 0 else {
                throw CLIError(message: "Failed to open Codex Teams log \(logURL.path): \(String(cString: strerror(errno)))")
            }
            let logHandle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            process.standardOutput = logHandle
            process.standardError = logHandle
        } else {
            process.standardInput = standardInput
            process.standardOutput = standardOutput
            process.standardError = standardError
        }

        try process.run()
        return process
    }

    private func codexTeamsTerminateProcess(_ process: Process?) {
        guard let process, process.isRunning else { return }
        process.terminate()
    }

    func runCodexTeamsWatcher(commandArgs: [String], client: SocketClient, socketPassword: String?) throws {
        let (workspaceId, rem0) = parseOption(commandArgs, name: "--workspace-id")
        let (surfaceId, rem1) = parseOption(rem0, name: "--surface-id")
        let (appServerURL, rem2) = parseOption(rem1, name: "--app-server-url")
        let (codexPath, rem3) = parseOption(rem2, name: "--codex-path")
        let (launchPath, rem4) = parseOption(rem3, name: "--launch-path")
        let (maxDepthRaw, rem5a) = parseOption(rem4, name: "--max-auto-depth")
        let (ownerPidRaw, rem5) = parseOption(rem5a, name: "--owner-pid")
        let (appServerPidRaw, remaining) = parseOption(rem5, name: "--app-server-pid")
        if let unknown = remaining.first(where: { $0.hasPrefix("--") }) {
            throw CLIError(message: "__codex-teams-watch: unknown flag '\(unknown)'")
        }
        guard let workspaceId, !workspaceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLIError(message: "__codex-teams-watch requires --workspace-id")
        }
        guard let surfaceId, !surfaceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLIError(message: "__codex-teams-watch requires --surface-id")
        }
        guard let appServerURL, !appServerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLIError(message: "__codex-teams-watch requires --app-server-url")
        }
        let codexExecutable = codexPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        let maxDepth = Int(maxDepthRaw ?? "") ?? Self.codexTeamsMaxAutoDepth
        let ownerPid = ownerPidRaw.flatMap { Int32($0) } ?? 0
        let appServerPid = appServerPidRaw.flatMap { Int32($0) } ?? 0

        var ownerSource: DispatchSourceProcess?
        if ownerPid > 0 {
            if !codexTeamsProcessExists(ownerPid) {
                if appServerPid > 0 { kill(appServerPid, SIGTERM) }
                return
            }
            let source = DispatchSource.makeProcessSource(
                identifier: pid_t(ownerPid),
                eventMask: .exit,
                queue: DispatchQueue.global(qos: .utility)
            )
            source.setEventHandler {
                if appServerPid > 0 {
                    kill(appServerPid, SIGTERM)
                }
                exit(0)
            }
            source.resume()
            ownerSource = source
        }

        let watcher = CodexTeamsWatcher(
            appServerURL: appServerURL,
            workspaceId: workspaceId,
            rootSurfaceId: surfaceId,
            codexExecutable: (codexExecutable?.isEmpty == false ? codexExecutable! : "codex"),
            launchPath: launchPath,
            maxAutoDepth: maxDepth,
            socketClient: client,
            socketPassword: socketPassword
        )
        withExtendedLifetime(ownerSource) {
            do {
                try watcher.run()
            } catch {
                fputs("cmux codex-teams watcher stopped: \(error)\n", stderr)
            }
        }
    }

    private func codexTeamsProcessExists(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 {
            return true
        }
        return errno == EPERM
    }

    // MARK: - cmux omo (OpenCode + oh-my-openagent)

}

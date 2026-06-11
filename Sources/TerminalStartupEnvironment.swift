import Foundation
import CMUXAgentLaunch
import OSLog

extension TerminalSurface {
    typealias ClaudeCommandShim = TerminalSurfaceClaudeCommandShim
    typealias CmuxContextEnvironment = TerminalSurfaceCmuxContextEnvironment

    static let managedTerminalType = "xterm-256color"
    static let managedTerminalProgram = "ghostty"
    static let managedColorTerm = "truecolor"

    private static let inheritedClaudeAuthSelectionEnvironmentKeys: Set<String> = [
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_MODEL",
        "ANTHROPIC_SMALL_FAST_MODEL",
        "CLAUDE_CODE_USE_BEDROCK",
        "CLAUDE_CODE_USE_VERTEX"
    ]

    static func applyManagedTerminalIdentityEnvironment(
        to environment: inout [String: String],
        protectedKeys: inout Set<String>
    ) {
        environment["TERM"] = managedTerminalType
        protectedKeys.insert("TERM")
        environment["COLORTERM"] = managedColorTerm
        protectedKeys.insert("COLORTERM")
        environment["TERM_PROGRAM"] = managedTerminalProgram
        protectedKeys.insert("TERM_PROGRAM")
    }

    static func applyManagedCmuxContextEnvironment(
        _ context: CmuxContextEnvironment,
        to environment: inout [String: String],
        protectedKeys: inout Set<String>
    ) {
        let values = [
            "CMUX_SURFACE_ID": context.surfaceId.uuidString,
            "CMUX_WORKSPACE_ID": context.workspaceId.uuidString,
            "CMUX_PANEL_ID": context.surfaceId.uuidString,
            "CMUX_TAB_ID": context.workspaceId.uuidString,
            "CMUX_SOCKET_PATH": context.socketPath
        ]

        for (key, value) in values {
            environment[key] = value
            protectedKeys.insert(key)
        }
    }

    static func applyManagedGitWatchEnvironment(
        watchGitStatusEnabled: Bool,
        showPullRequestsEnabled: Bool = true,
        to environment: inout [String: String],
        protectedKeys: inout Set<String>
    ) {
        environment["CMUX_NO_GIT_WATCH"] = watchGitStatusEnabled ? "" : "1"
        protectedKeys.insert("CMUX_NO_GIT_WATCH")
        environment["CMUX_NO_PR_WATCH"] = (watchGitStatusEnabled && showPullRequestsEnabled) ? "" : "1"
        protectedKeys.insert("CMUX_NO_PR_WATCH")
    }

    static func pathByPrependingUniqueDirectory(_ directory: String, to path: String) -> String {
        let trimmedDirectory = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDirectory.isEmpty else { return path }
        let standardizedDirectory = URL(fileURLWithPath: trimmedDirectory, isDirectory: true)
            .standardizedFileURL
            .path
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return standardizedDirectory
        }
        var entries = path
            .split(separator: ":", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { entry in
                let trimmedEntry = entry.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedEntry.isEmpty else { return true }
                return URL(fileURLWithPath: trimmedEntry, isDirectory: true)
                    .standardizedFileURL
                    .path != standardizedDirectory
            }
        entries.insert(standardizedDirectory, at: 0)
        return entries.joined(separator: ":")
    }

    static func installClaudeCommandShimIfPossible(
        wrapperURL: URL?,
        surfaceId: UUID,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        fileManager: FileManager = .default
    ) -> ClaudeCommandShim? {
        guard let wrapperURL = wrapperURL?.standardizedFileURL,
              fileManager.isExecutableFile(atPath: wrapperURL.path) else {
            return nil
        }

        let shimDirectory = temporaryDirectory
            .appendingPathComponent("cmux-cli-shims", isDirectory: true)
            .appendingPathComponent(surfaceId.uuidString, isDirectory: true)
            .standardizedFileURL
        let shimURL = shimDirectory.appendingPathComponent("claude", isDirectory: false)
        do {
            try fileManager.createDirectory(at: shimDirectory, withIntermediateDirectories: true)
            let script = """
            #!/usr/bin/env bash
            export CMUX_CLAUDE_WRAPPER_SHIM=\(shellSingleQuoted(shimURL.path))
            export CMUX_CLAUDE_WRAPPER_SHIM_ROOT=\(shellSingleQuoted(shimDirectory.path))
            exec \(shellSingleQuoted(wrapperURL.path)) "$@"
            """
            try script.write(to: shimURL, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shimURL.path)
            return ClaudeCommandShim(
                directoryPath: shimDirectory.path,
                executablePath: shimURL.path
            )
        } catch {
            return nil
        }
    }

    static func mergedStartupEnvironment(
        base: [String: String],
        protectedKeys: Set<String>,
        additionalEnvironment: [String: String],
        initialEnvironmentOverrides: [String: String],
        ambientEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        applyHermesCodexDefaults: Bool = false
    ) -> [String: String] {
        var merged = base
        for key in inheritedClaudeAuthSelectionEnvironmentKeys where merged[key] != nil || ambientEnvironment[key] != nil {
            merged[key] = ""
        }
        for (key, value) in additionalEnvironment where !key.isEmpty && !value.isEmpty && !protectedKeys.contains(key) {
            merged[key] = value
        }
        for (key, value) in initialEnvironmentOverrides where !protectedKeys.contains(key) {
            merged[key] = value
        }
        if let claudeConfigDir = merged["CLAUDE_CONFIG_DIR"], !claudeConfigDir.isEmpty {
            merged["CLAUDE_CONFIG_DIR"] = ClaudeConfigDirectoryPath.preferredPath(claudeConfigDir)
        }
        if applyHermesCodexDefaults {
            merged = HermesAgentCodexEnvironment.applyingDefaultCodexBaseURL(
                to: merged,
                ambientEnvironment: ambientEnvironment
            )
        }
        return merged
    }

    static func applyManagedFishStartupEnvironment(
        integrationDir: String,
        to environment: inout [String: String],
        protectedKeys: inout Set<String>
    ) {
        let normalizedIntegrationDir = URL(fileURLWithPath: integrationDir, isDirectory: true)
            .standardizedFileURL
            .path
        let integrationFile = URL(fileURLWithPath: normalizedIntegrationDir, isDirectory: true)
            .appendingPathComponent("fish/config.fish")
            .path

        environment["CMUX_FISH_INTEGRATION_FILE"] = integrationFile
        environment["CMUX_FISH_USER_CONFIG_ALREADY_LOADED"] = "1"
        protectedKeys.insert("CMUX_FISH_INTEGRATION_FILE")
        protectedKeys.insert("CMUX_FISH_USER_CONFIG_ALREADY_LOADED")
    }

    /// Whether the bundled shell-integration dir is present on disk. The dir
    /// lives inside the app bundle, which can be deleted while the app runs
    /// (e.g. a tagged dev build's DerivedData gets pruned); when it is gone,
    /// callers must not advertise it (CMUX_SHELL_INTEGRATION_DIR) or redirect
    /// shell startup at it.
    static func shellIntegrationDirectoryExists(
        _ integrationDir: String,
        fileManager: FileManager = .default
    ) -> Bool {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: integrationDir, isDirectory: &isDirectory), isDirectory.boolValue {
            return true
        }
        Logger(subsystem: "com.cmuxterm.app", category: "ghostty.initialization")
            .error("cmux shell-integration dir missing at \(integrationDir, privacy: .private); spawning shell without cmux shell integration so the user's shell config still loads")
        return false
    }

    static func applyManagedShellSpecificStartupEnvironment(
        shell: String,
        integrationDir: String,
        userGhosttyShellIntegrationMode: String,
        to environment: inout [String: String],
        protectedKeys: inout Set<String>,
        readFile: (String) throws -> String = { try String(contentsOfFile: $0, encoding: .utf8) }
    ) -> String? {
        let shellName = URL(fileURLWithPath: shell).lastPathComponent
        func setManagedEnvironmentValue(_ key: String, _ value: String) {
            environment[key] = value
            protectedKeys.insert(key)
        }
        // The integration dir lives inside the app bundle, which can disappear
        // while the app is running (e.g. a tagged dev build's DerivedData gets
        // pruned). Redirecting shell startup at a missing bootstrap would make
        // the shell silently skip the user's own config (for zsh, ZDOTDIR would
        // point at a dir with no .zshenv to restore the real ZDOTDIR, so
        // ~/.zshenv, ~/.zprofile, and ~/.zshrc all stop loading). When the
        // bundled bootstrap is unreadable, skip the shell-startup redirection
        // (set no keys here) so the shell starts vanilla, and log so the
        // degradation is diagnosable.
        func bundledBootstrapIsReadable(_ relativePath: String) -> Bool {
            let path = (integrationDir as NSString).appendingPathComponent(relativePath)
            if FileManager.default.isReadableFile(atPath: path) { return true }
            Logger(subsystem: "com.cmuxterm.app", category: "ghostty.initialization")
                .error("cmux \(shellName, privacy: .public) bootstrap unreadable at \(path, privacy: .private); skipping cmux shell-startup redirection so the user's shell config still loads")
            return false
        }
        switch shellName {
        case "zsh":
            guard bundledBootstrapIsReadable(".zshenv") else { return nil }
            if userGhosttyShellIntegrationMode != "none" { setManagedEnvironmentValue("CMUX_LOAD_GHOSTTY_ZSH_INTEGRATION", "1") }
            let candidateZdotdir = (environment["ZDOTDIR"]?.isEmpty == false ? environment["ZDOTDIR"] : nil)
                ?? getenv("ZDOTDIR").map { String(cString: $0) }
                ?? (ProcessInfo.processInfo.environment["ZDOTDIR"]?.isEmpty == false ? ProcessInfo.processInfo.environment["ZDOTDIR"] : nil)
            if let candidateZdotdir, !candidateZdotdir.isEmpty {
                let ghosttyResources = (environment["GHOSTTY_RESOURCES_DIR"]?.isEmpty == false ? environment["GHOSTTY_RESOURCES_DIR"] : nil)
                    ?? getenv("GHOSTTY_RESOURCES_DIR").map { String(cString: $0) }
                    ?? (ProcessInfo.processInfo.environment["GHOSTTY_RESOURCES_DIR"]?.isEmpty == false ? ProcessInfo.processInfo.environment["GHOSTTY_RESOURCES_DIR"] : nil)
                let ghosttyZdotdir = ghosttyResources.map { URL(fileURLWithPath: $0).appendingPathComponent("shell-integration/zsh").path }
                if candidateZdotdir != ghosttyZdotdir { setManagedEnvironmentValue("CMUX_ZSH_ZDOTDIR", candidateZdotdir) }
            }
            setManagedEnvironmentValue("ZDOTDIR", integrationDir)
        case "bash":
            if userGhosttyShellIntegrationMode != "none" { setManagedEnvironmentValue("CMUX_LOAD_GHOSTTY_BASH_INTEGRATION", "1") }
            let bashBootstrapPath = (integrationDir as NSString).appendingPathComponent("cmux-bash-bootstrap.bash")
            do {
                let bootstrap = try readFile(bashBootstrapPath)
                    .components(separatedBy: "\n")
                    .filter {
                        let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                        return !trimmed.isEmpty && !trimmed.hasPrefix("#")
                    }
                    .joined(separator: "\n")
                if !bootstrap.isEmpty { setManagedEnvironmentValue("PROMPT_COMMAND", bootstrap) }
            } catch {
                Logger(subsystem: "com.cmuxterm.app", category: "ghostty.initialization")
                    .error("cmux bash bootstrap unreadable at \(bashBootstrapPath, privacy: .private): \(error.localizedDescription, privacy: .public); bash shell integration will not load")
            }
        case "fish":
            guard bundledBootstrapIsReadable("fish/config.fish") else { return nil }
            applyManagedFishStartupEnvironment(integrationDir: integrationDir, to: &environment, protectedKeys: &protectedKeys)
            return managedFishShellCommand(shell: shell)
        default:
            break
        }
        return nil
    }

    static func managedFishShellCommand(shell: String) -> String {
        let initCommand = #"source "$CMUX_FISH_INTEGRATION_FILE""#
        return "\(shellSingleQuoted(shell)) -il --init-command \(shellSingleQuoted(initCommand))"
    }

    static func shellSingleQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

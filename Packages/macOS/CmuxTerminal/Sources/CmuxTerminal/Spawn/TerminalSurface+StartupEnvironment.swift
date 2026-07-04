public import Foundation
internal import CMUXAgentLaunch
internal import Darwin
internal import OSLog

// MARK: - Managed startup-environment assembly (pure helpers)
//
// Lifted from the app's TerminalStartupEnvironment.swift extension; bodies
// are unchanged. They are `static` because they are pure transforms used by
// spawn assembly and exercised directly by environment tests.

extension TerminalSurface {
    /// The managed `TERM` value exported to spawned shells.
    public static let managedTerminalType = "xterm-256color"

    /// The managed `TERM_PROGRAM` value exported to spawned shells.
    public static let managedTerminalProgram = "ghostty"

    /// The managed `COLORTERM` value exported to spawned shells.
    public static let managedColorTerm = "truecolor"

    private static let inheritedClaudeAuthSelectionEnvironmentKeys: Set<String> = [
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_MODEL",
        "ANTHROPIC_SMALL_FAST_MODEL",
        "CLAUDE_CODE_USE_BEDROCK",
        "CLAUDE_CODE_USE_VERTEX"
    ]

    /// Applies the managed terminal identity (`TERM`, `COLORTERM`,
    /// `TERM_PROGRAM`) and protects those keys.
    public static func applyManagedTerminalIdentityEnvironment(
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

    /// Applies the managed cmux context identity keys and protects them.
    public static func applyManagedCmuxContextEnvironment(
        _ context: CmuxContextEnvironment,
        to environment: inout [String: String],
        protectedKeys: inout Set<String>
    ) {
        var values = [
            "CMUX_SURFACE_ID": context.surfaceId.uuidString,
            "CMUX_WORKSPACE_ID": context.workspaceId.uuidString,
            "CMUX_PANEL_ID": context.surfaceId.uuidString,
            "CMUX_TAB_ID": context.workspaceId.uuidString,
            "CMUX_SOCKET_PATH": context.socketPath
        ]
        if let notesDir = context.workspaceNotesDir, !notesDir.isEmpty {
            values["CMUX_WORKSPACE_NOTES_DIR"] = notesDir
        }

        for (key, value) in values {
            environment[key] = value
            protectedKeys.insert(key)
        }
    }

    /// Applies the sidebar git/PR watch flags and protects them.
    public static func applyManagedGitWatchEnvironment(
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

    /// Prepends `directory` to a `PATH`-style string exactly once.
    public static func pathByPrependingUniqueDirectory(_ directory: String, to path: String) -> String {
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

    /// Writes the per-surface `claude` wrapper shim to disk, if the bundled
    /// wrapper exists.
    public static func installClaudeCommandShimIfPossible(
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
            cmux_wrapper=\(shellSingleQuoted(wrapperURL.path))
            if [[ ! -x "$cmux_wrapper" && -n "${CMUX_BUNDLED_CLI_PATH:-}" ]]; then
                cmux_candidate="$(dirname "$CMUX_BUNDLED_CLI_PATH")/cmux-claude-wrapper"
                if [[ -x "$cmux_candidate" ]]; then
                    cmux_wrapper="$cmux_candidate"
                fi
            fi
            if [[ ! -x "$cmux_wrapper" ]]; then
                cmux_cli="$(command -v cmux 2>/dev/null || true)"
                if [[ -n "$cmux_cli" ]]; then
                    cmux_candidate="$(dirname "$cmux_cli")/cmux-claude-wrapper"
                    if [[ -x "$cmux_candidate" ]]; then
                        cmux_wrapper="$cmux_candidate"
                    fi
                fi
            fi
            export CMUX_CLAUDE_WRAPPER_SHIM=\(shellSingleQuoted(shimURL.path))
            export CMUX_CLAUDE_WRAPPER_SHIM_ROOT=\(shellSingleQuoted(shimDirectory.path))
            if [[ -x "$cmux_wrapper" ]]; then
                exec "$cmux_wrapper" "$@"
            fi
            cmux_path_without_shim=""
            cmux_old_ifs="$IFS"
            IFS=:
            for cmux_entry in ${PATH:-}; do
                if [[ "$cmux_entry" == "$CMUX_CLAUDE_WRAPPER_SHIM_ROOT" || "$cmux_entry" == */cmux-cli-shims/* || "$cmux_entry" == */cmux-cli-shims ]]; then
                    continue
                fi
                if [[ -z "$cmux_path_without_shim" ]]; then
                    cmux_path_without_shim="$cmux_entry"
                else
                    cmux_path_without_shim="$cmux_path_without_shim:$cmux_entry"
                fi
            done
            IFS="$cmux_old_ifs"
            export PATH="$cmux_path_without_shim"
            exec claude "$@"
            """
            try script.write(to: shimURL, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shimURL.path)
            // Best-effort: write a sibling `codex` shim into the same per-surface
            // dir so typed `codex` resolves to cmux-codex-wrapper through the
            // PATH entry already prepended for the claude shim. Failure here
            // never blocks the claude shim (codex detection degrades, claude is
            // unaffected). The returned codex shim is carried on the claude shim
            // so runtime surface creation can export CMUX_CODEX_WRAPPER_SHIM into
            // the managed env, which a resumed `codex` session needs to route its
            // resume through the wrapper and keep cmux hooks.
            let codexShim = installCodexCommandShimIfPossible(
                claudeWrapperURL: wrapperURL,
                shimDirectory: shimDirectory,
                fileManager: fileManager
            )
            return ClaudeCommandShim(
                directoryPath: shimDirectory.path,
                executablePath: shimURL.path,
                codexCommandShim: codexShim
            )
        } catch {
            return nil
        }
    }

    /// Writes the per-surface `codex` wrapper shim into `shimDirectory`, if the
    /// bundled `cmux-codex-wrapper` exists alongside `cmux-claude-wrapper`. The
    /// shim resolves and execs the codex wrapper; if the wrapper is gone it
    /// strips every cmux shim dir from `PATH` and execs the real `codex`, so the
    /// user's `codex` keeps working even when the app bundle is pruned.
    ///
    /// The directory is already prepended to the spawned shell's `PATH` for the
    /// claude shim, so no extra `PATH` handling is required.
    @discardableResult
    public static func installCodexCommandShimIfPossible(
        claudeWrapperURL: URL,
        shimDirectory: URL,
        fileManager: FileManager = .default
    ) -> CodexCommandShim? {
        let codexWrapperURL = claudeWrapperURL
            .deletingLastPathComponent()
            .appendingPathComponent("cmux-codex-wrapper", isDirectory: false)
            .standardizedFileURL
        guard fileManager.isExecutableFile(atPath: codexWrapperURL.path) else {
            return nil
        }

        let shimURL = shimDirectory.appendingPathComponent("codex", isDirectory: false)
        do {
            let script = """
            #!/usr/bin/env bash
            cmux_wrapper=\(shellSingleQuoted(codexWrapperURL.path))
            if [[ ! -x "$cmux_wrapper" && -n "${CMUX_BUNDLED_CLI_PATH:-}" ]]; then
                cmux_candidate="$(dirname "$CMUX_BUNDLED_CLI_PATH")/cmux-codex-wrapper"
                if [[ -x "$cmux_candidate" ]]; then
                    cmux_wrapper="$cmux_candidate"
                fi
            fi
            if [[ ! -x "$cmux_wrapper" ]]; then
                cmux_cli="$(command -v cmux 2>/dev/null || true)"
                if [[ -n "$cmux_cli" ]]; then
                    cmux_candidate="$(dirname "$cmux_cli")/cmux-codex-wrapper"
                    if [[ -x "$cmux_candidate" ]]; then
                        cmux_wrapper="$cmux_candidate"
                    fi
                fi
            fi
            export CMUX_CODEX_WRAPPER_SHIM=\(shellSingleQuoted(shimURL.path))
            export CMUX_CODEX_WRAPPER_SHIM_ROOT=\(shellSingleQuoted(shimDirectory.path))
            if [[ -x "$cmux_wrapper" ]]; then
                exec "$cmux_wrapper" "$@"
            fi
            cmux_path_without_shim=""
            cmux_old_ifs="$IFS"
            IFS=:
            for cmux_entry in ${PATH:-}; do
                if [[ "$cmux_entry" == "$CMUX_CODEX_WRAPPER_SHIM_ROOT" || "$cmux_entry" == */cmux-cli-shims/* || "$cmux_entry" == */cmux-cli-shims ]]; then
                    continue
                fi
                if [[ -z "$cmux_path_without_shim" ]]; then
                    cmux_path_without_shim="$cmux_entry"
                else
                    cmux_path_without_shim="$cmux_path_without_shim:$cmux_entry"
                fi
            done
            IFS="$cmux_old_ifs"
            export PATH="$cmux_path_without_shim"
            exec codex "$@"
            """
            try script.write(to: shimURL, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shimURL.path)
            return CodexCommandShim(
                directoryPath: shimDirectory.path,
                executablePath: shimURL.path
            )
        } catch {
            return nil
        }
    }

    /// Merges base, additional, and override environments with key
    /// protection, Claude auth-selection inheritance, and config-dir
    /// normalization.
    public static func mergedStartupEnvironment(
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
        applyManagedLocaleSanitization(to: &merged, ambientEnvironment: ambientEnvironment)
        return merged
    }

    /// Locale categories that can silently collapse a spawned shell's
    /// `LC_CTYPE` to the non-UTF-8 `C` locale when set to a value libc cannot
    /// resolve. `LC_ALL` overrides every other category; `LC_CTYPE` governs
    /// character classification directly.
    private static let sanitizedLocaleEnvironmentKeys = ["LC_ALL", "LC_CTYPE"]

    /// Returns whether `value` is a POSIX-style locale name that libc can
    /// resolve — `language[_TERRITORY[_SCRIPT]][.codeset][@modifier]`, or the
    /// special `C` / `POSIX` names, or empty (unset).
    ///
    /// Foundation CLDR/BCP-47 identifiers such as
    /// `en-US-u-ca-gregory-co-standard-cu-usd-fw-sun-hc-h12-ms-ussystem-tz-usphx`
    /// or `en_US@calendar=gregorian;currency=USD` use hyphen-separated subtags
    /// and/or `@key=value;…` keyword syntax, so they return `false`. Passing
    /// such a value to `setlocale`/`newlocale` fails and forces the category to
    /// the `C` fallback (see https://github.com/manaflow-ai/cmux/issues/7152).
    public static func isPOSIXCompatibleLocaleName(_ value: String) -> Bool {
        if value.isEmpty { return true }
        if value == "C" || value == "POSIX" { return true }
        return value.range(
            of: #"^[A-Za-z]{1,8}(_[A-Za-z0-9]{1,8}){0,2}(\.[A-Za-z0-9][A-Za-z0-9._-]*)?(@[A-Za-z0-9]+)?$"#,
            options: .regularExpression
        ) != nil
    }

    /// Clears a malformed inherited `LC_ALL`/`LC_CTYPE` so a spawned shell keeps
    /// the valid UTF-8 `LANG` (which Ghostty derives from the macOS region as
    /// `xx_YY.UTF-8`) instead of collapsing `LC_CTYPE` to `C` and corrupting
    /// UTF-8 text.
    ///
    /// The spawned shell resolves each category from the surface's env override
    /// when present, otherwise from the inherited process environment; both are
    /// checked. A malformed value is replaced with the empty string, which
    /// `setlocale` treats as unset for the category so `LANG` governs. Empty and
    /// legitimate POSIX values (including an explicit `C`/`POSIX`) are left
    /// untouched. See https://github.com/manaflow-ai/cmux/issues/7152.
    public static func applyManagedLocaleSanitization(
        to environment: inout [String: String],
        ambientEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        for key in sanitizedLocaleEnvironmentKeys {
            guard let effective = environment[key] ?? ambientEnvironment[key],
                  !effective.isEmpty,
                  !isPOSIXCompatibleLocaleName(effective)
            else { continue }
            environment[key] = ""
        }
    }

    /// Applies the managed fish-shell startup keys and protects them.
    public static func applyManagedFishStartupEnvironment(
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
    public static func shellIntegrationDirectoryExists(
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

    /// Applies the shell-specific startup redirection (zsh/bash/fish) and
    /// returns a replacement launch command when one is required (fish).
    public static func applyManagedShellSpecificStartupEnvironment(
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

    /// The managed fish launch command sourcing the cmux integration file.
    public static func managedFishShellCommand(shell: String) -> String {
        let initCommand = #"source "$CMUX_FISH_INTEGRATION_FILE""#
        return "\(shellSingleQuoted(shell)) -il --init-command \(shellSingleQuoted(initCommand))"
    }

    /// Single-quotes a value for POSIX shells.
    public static func shellSingleQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    static func mergedNormalizedEnvironment(
        base: [String: String],
        overrides: [String: String]
    ) -> [String: String] {
        var merged: [String: String] = [:]
        merged.reserveCapacity(base.count + overrides.count)
        for (rawKey, value) in base {
            let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            merged[key] = value
        }
        for (rawKey, value) in overrides {
            let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            merged[key] = value
        }
        return merged
    }
}

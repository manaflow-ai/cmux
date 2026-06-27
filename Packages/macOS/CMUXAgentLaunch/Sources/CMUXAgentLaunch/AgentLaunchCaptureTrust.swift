import Foundation

/// Decides whether captured agent launch metadata can be trusted for a stored agent kind.
///
/// `CMUX_AGENT_LAUNCH_*` is exported into the agent's process environment by the
/// cmux launch wrappers and therefore leaks to every descendant process: an agent
/// started from inside another agent's session (codex under claude, claude under
/// codex, …) inherits the ANCESTOR's launch capture. A hook that stores that
/// capture verbatim poisons resume/fork for the session — the rendered command
/// runs the wrong binary with the wrong flags.
public struct AgentLaunchCaptureTrust: Sendable, Equatable {
    /// Wrapper launchers that legitimately differ from the hook kind they launch.
    private let wrapperLaunchersByKind: [String: Set<String>]
    private let nativeProcessAliasesByKind: [String: Set<String>]
    private let shellExecutableBasenames: Set<String>

    /// Creates a launch-capture trust policy with cmux's built-in agent and shell aliases.
    public init() {
        wrapperLaunchersByKind = [
            "claude": ["claudeteams"],
            "codex": ["codexteams"],
            "opencode": ["omo", "omx", "omc"],
            "pi": ["omp"],
        ]

        nativeProcessAliasesByKind = [
            "antigravity": ["agy"],
            "claude": ["claude"],
            "codex": ["codex"],
            "codebuddy": ["codebuddy"],
            "copilot": ["copilot"],
            "cursor": ["cursor-agent", "cursor"],
            "factory": ["droid", "factory"],
            "gemini": ["gemini"],
            "grok": ["grok", "grok-macos-aarch64", "grok-macos-aarch"],
            "kiro": ["kiro", "kiro-cli"],
            "omp": ["omp"],
            "opencode": ["opencode", "omo", "omx", "omc"],
            "pi": ["pi", "omp"],
            "qoder": ["qodercli", "qoder"],
            "rovodev": ["rovodev", "rovo", "rovo-dev"],
        ]

        shellExecutableBasenames = [
            "bash",
            "csh",
            "dash",
            "fish",
            "ksh",
            "login",
            "sh",
            "tcsh",
            "zsh",
        ]
    }

    /// True when `launcher` plausibly describes a launch of agent `kind`.
    ///
    /// A nil/empty launcher is trusted: hooks fall back to their own kind.
    /// - Parameters:
    ///   - launcher: The captured launcher label, if any.
    ///   - kind: The agent kind that owns the captured session.
    /// - Returns: Whether the launcher belongs to the supplied kind.
    public func launcherDescribesKind(_ launcher: String?, kind: String) -> Bool {
        guard let launcher = launcher?.trimmingCharacters(in: .whitespacesAndNewlines),
              !launcher.isEmpty else {
            return true
        }
        let normalizedLauncher = launcher.lowercased()
        let normalizedKind = kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedLauncher == normalizedKind {
            return true
        }
        return wrapperLaunchersByKind[normalizedKind]?.contains(normalizedLauncher) == true
    }

    /// True when `executable` is a known shell or login executable, not an agent binary.
    /// - Parameter executable: The captured executable path or argv token.
    /// - Returns: Whether the executable basename matches a known shell.
    public func executableLooksLikeShell(_ executable: String?) -> Bool {
        guard let executable = executable?.trimmingCharacters(in: .whitespacesAndNewlines),
              !executable.isEmpty else {
            return false
        }
        let basename = (executable as NSString).lastPathComponent
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            .lowercased()
        return shellExecutableBasenames.contains(basename)
    }

    /// True when a captured argv describes a shell dispatcher (`sh -c …`,
    /// `zsh -lc …`) rather than an agent launch. This happens when the
    /// launch-capture PID fallback resolves to the hook's own dispatch shell
    /// instead of the agent process. Requires both a shell argv[0] basename and
    /// shell dispatcher/profile-startup flags, so an agent that merely shares a
    /// shell's name (e.g. a wrapper script named `fish`) is not misclassified.
    /// - Parameter arguments: The captured process argv, including argv[0].
    /// - Returns: Whether argv is a shell command-string dispatcher.
    public func argvLooksLikeShellWrapper(_ arguments: [String]) -> Bool {
        guard executableLooksLikeShell(arguments.first) else { return false }
        var sawShellStartupOnlyFlag = false
        var index = arguments.index(after: arguments.startIndex)
        while index < arguments.endIndex {
            let argument = arguments[index]
            if shellCommandStringFlag(argument) {
                return true
            }
            if shellStartupOnlyFlag(argument) {
                sawShellStartupOnlyFlag = true
                index = arguments.index(after: index)
                continue
            }
            if shellOptionConsumesNextValue(argument), arguments.index(after: index) < arguments.endIndex {
                index = arguments.index(index, offsetBy: 2)
                continue
            }
            if argument == "--" || !argument.hasPrefix("-") {
                return false
            }
            return false
        }
        return sawShellStartupOnlyFlag
    }

    private func shellCommandStringFlag(_ flag: String) -> Bool {
        guard flag.hasPrefix("-"), !flag.hasPrefix("--") else { return false }
        let letters = flag.dropFirst()
        return !letters.isEmpty
            && letters.contains("c")
            && letters.allSatisfy { "cilms".contains($0) }
    }

    private func shellStartupOnlyFlag(_ flag: String) -> Bool {
        switch flag {
        case "--no-config", "--no-rcs", "--noprofile", "--norc":
            return true
        default:
            return false
        }
    }

    private func shellOptionConsumesNextValue(_ flag: String) -> Bool {
        switch flag {
        case "-o", "+o", "-O", "+O", "--init-file", "--rcfile":
            return true
        default:
            return false
        }
    }

    /// True when PID-derived process metadata describes the same native agent as
    /// the hook kind. This keeps unrelated parents, including Xcode test hosts
    /// and the cmux app executable, from becoming persisted resume commands.
    /// - Parameters:
    ///   - processName: The process name reported by the system, if any.
    ///   - arguments: The captured process argv.
    ///   - kind: The hook kind that owns the session.
    /// - Returns: Whether the process metadata describes the hook kind.
    public func nativeProcessDescribesKind(
        processName: String?,
        arguments: [String]?,
        kind: String
    ) -> Bool {
        guard let expectedKind = normalizedAgentName(kind),
              let arguments else {
            return false
        }
        return nativeProcessDescriptors(processName: processName, arguments: arguments).contains { descriptor in
            descriptor == expectedKind
                || nativeProcessAliasesByKind[expectedKind]?.contains(descriptor) == true
                || descriptor == "\(expectedKind)-cli"
        }
    }

    /// True when PID-derived process metadata describes any built-in agent.
    /// - Parameters:
    ///   - processName: The process name reported by the system, if any.
    ///   - arguments: The captured process argv.
    /// - Returns: Whether the metadata matches a known agent alias.
    public func nativeProcessDescribesKnownAgent(
        processName: String?,
        arguments: [String]
    ) -> Bool {
        let knownNames = Set(nativeProcessAliasesByKind.keys).union(nativeProcessAliasesByKind.values.flatMap { $0 })
        return nativeProcessDescriptors(processName: processName, arguments: arguments).contains { descriptor in
            knownNames.contains(descriptor)
        }
    }

    private func nativeProcessDescriptors(
        processName: String?,
        arguments: [String]
    ) -> Set<String> {
        var descriptors = Set<String>()
        let nameBase = processBasename(processName)
        let executableBase = processBasename(arguments.first)
        if let nameBase {
            descriptors.insert(nameBase)
        }
        if let executableBase {
            descriptors.insert(executableBase)
        }
        if nameBase == "node" || nameBase == "bun" || executableBase == "node" || executableBase == "bun" {
            if arguments.dropFirst().contains(where: { argument in
                let lowered = argument.lowercased()
                return processBasename(argument) == "claude"
                    || lowered.contains("/.claude/")
                    || lowered.contains("/claude/versions/")
            }) {
                descriptors.insert("claude")
            }
            return descriptors
        }

        let executable = arguments.first?.lowercased() ?? ""
        if nameBase == "codex" || executableBase == "codex" || executable.contains("/codex/codex") {
            descriptors.insert("codex")
        }
        if nameBase == "claude" || executableBase == "claude" || executable.contains("/claude/versions/") {
            descriptors.insert("claude")
        }
        return descriptors
    }

    private func normalizedAgentName(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value.lowercased()
    }

    private func processBasename(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: value).lastPathComponent.lowercased()
    }
}

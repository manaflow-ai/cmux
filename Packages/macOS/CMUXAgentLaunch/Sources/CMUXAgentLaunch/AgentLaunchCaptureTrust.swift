import Foundation

/// Decides whether a captured agent launch command can be trusted for the agent
/// kind it is stored under.
///
/// `CMUX_AGENT_LAUNCH_*` is exported into the agent's process environment by the
/// cmux launch wrappers and therefore leaks to every descendant process: an agent
/// started from inside another agent's session (codex under claude, claude under
/// codex, …) inherits the ANCESTOR's launch capture. A hook that stores that
/// capture verbatim poisons resume/fork for the session — the rendered command
/// runs the wrong binary with the wrong flags.
public enum AgentLaunchCaptureTrust {
    /// Wrapper launchers that legitimately differ from the hook kind they launch.
    private static let wrapperLaunchersByKind: [String: Set<String>] = [
        "claude": ["claudeteams"],
        "codex": ["codexteams"],
        "opencode": ["omo", "omx", "omc"],
        "pi": ["omp"],
    ]

    private static let nativeProcessAliasesByKind: [String: Set<String>] = [
        "amp": ["amp"],
        "antigravity": ["agy"],
        "campfire": ["campfire"],
        "claude": ["claude"],
        "codex": ["codex"],
        "codebuddy": ["codebuddy"],
        "copilot": ["copilot"],
        "cursor": ["cursor-agent", "cursor"],
        "factory": ["droid", "factory"],
        "gemini": ["gemini"],
        "grok": ["grok", "grok-macos-aarch64", "grok-macos-aarch"],
        "hermes-agent": ["hermes", "hermes-agent"],
        "kiro": ["kiro", "kiro-cli"],
        "kimi": ["kimi"],
        "omp": ["omp"],
        "opencode": ["opencode", "omo", "omx", "omc"],
        "pi": ["pi", "omp"],
        "qoder": ["qodercli", "qoder"],
        "rovodev": ["acli", "rovodev", "rovo", "rovo-dev"],
    ]

    private static let interpreterHostBases: Set<String> = [
        "bun", "deno", "node", "python", "python3", "ruby", "ts-node", "tsx",
    ]

    /// Script paths whose entrypoint name is generic (`cli.js`, `index.ts`, ...).
    /// Direct entrypoints are recognized from their basename without an entry here.
    private static let scriptPathMarkersByKind: [String: Set<String>] = [
        "campfire": ["/packages/session/bin/campfire.ts", "/packages/session/dist/campfire"],
        "claude": ["/.claude/", "/@anthropic-ai/claude-code/", "/claude/versions/"],
        "opencode": ["/@opencode-ai/", "/opencode-ai/", "/opencode/"],
    ]

    /// True when `launcher` plausibly describes a launch of agent `kind`.
    /// A nil/empty launcher is trusted: hooks fall back to their own kind.
    public static func launcherDescribesKind(_ launcher: String?, kind: String) -> Bool {
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

    /// Validates argv captured under a declared launcher. Wrapper launchers
    /// legitimately differ from the hook kind and retain their own sanitizer.
    /// An exact launcher, however, must also have argv that identifies that
    /// agent. This rejects interpreter-only prefixes such as `node --max-…`
    /// after Node has hidden the script path from `KERN_PROCARGS2`.
    public static func capturedArgumentsDescribeKind(
        launcher: String?,
        executablePath: String?,
        arguments: [String],
        kind: String
    ) -> Bool {
        guard launcherDescribesKind(launcher, kind: kind),
              let normalizedKind = normalizedAgentName(kind) else {
            return false
        }
        // Older hook wrappers can provide argv without a launch-kind marker.
        // `launcherDescribesKind` intentionally trusts that absence, so treat
        // it as the hook's own kind rather than invalidating the capture here.
        let normalizedLauncher = normalizedAgentName(launcher) ?? normalizedKind
        if normalizedLauncher != normalizedKind {
            return true
        }
        return nativeProcessDescribesKind(
            processName: executablePath,
            arguments: arguments,
            kind: normalizedKind
        )
    }

    /// True when a captured argv describes a shell dispatcher (`sh -c …`,
    /// `zsh -lc …`) rather than an agent launch. This happens when the
    /// launch-capture PID fallback resolves to the hook's own dispatch shell
    /// instead of the agent process. Requires both a shell argv[0] basename and
    /// a command-string flag, so an agent that merely shares a shell's name
    /// (e.g. a wrapper script named `fish`) is not misclassified.
    public static func argvLooksLikeShellWrapper(_ arguments: [String]) -> Bool {
        guard let argv0 = arguments.first?.trimmingCharacters(in: .whitespacesAndNewlines),
              !argv0.isEmpty else {
            return false
        }
        let name = (argv0 as NSString).lastPathComponent.lowercased()
        let shells: Set<String> = ["sh", "bash", "zsh", "dash", "fish", "csh", "tcsh", "ksh"]
        guard shells.contains(name) else { return false }
        guard arguments.count >= 2 else { return false }
        // A combined short option whose letters are shell mode flags and that
        // includes `c` (-c, -lc, -ic, -lic, …): the command-string form.
        let flag = arguments[1]
        guard flag.hasPrefix("-"), !flag.hasPrefix("--") else { return false }
        let letters = flag.dropFirst()
        return !letters.isEmpty
            && letters.contains("c")
            && letters.allSatisfy { "cilms".contains($0) }
    }

    /// True when PID-derived process metadata describes the same native agent as
    /// the hook kind. This keeps unrelated parents, including Xcode test hosts
    /// and the cmux app executable, from becoming persisted resume commands.
    public static func nativeProcessDescribesKind(
        processName: String?,
        arguments: [String]?,
        kind: String
    ) -> Bool {
        guard let expectedKind = normalizedAgentName(kind),
              let arguments else {
            return false
        }
        if nativeProcessDescriptors(processName: processName, arguments: arguments).contains(where: { descriptor in
            descriptor == expectedKind
                || nativeProcessAliasesByKind[expectedKind]?.contains(descriptor) == true
                || descriptor == "\(expectedKind)-cli"
        }) {
            return true
        }
        guard let entrypointIndex = interpreterScriptEntrypointIndex(
            processName: processName,
            arguments: arguments
        ) else {
            return false
        }
        return scriptArgument(arguments[entrypointIndex], describes: expectedKind)
    }

    public static func nativeProcessDescribesKnownAgent(
        processName: String?,
        arguments: [String]
    ) -> Bool {
        let knownNames = Set(nativeProcessAliasesByKind.keys).union(nativeProcessAliasesByKind.values.flatMap { $0 })
        return nativeProcessDescriptors(processName: processName, arguments: arguments).contains { descriptor in
            knownNames.contains(descriptor)
        }
    }

    /// Returns only the provider-owned argv tail for a trusted live process.
    /// Interpreter and package-manager flags before the agent script are not
    /// provider launch options and must not affect restorability classification.
    static func nativeAgentLaunchArguments(
        processName: String?,
        arguments: [String],
        kind: String
    ) -> [String]? {
        guard let normalizedKind = normalizedAgentName(kind),
              nativeProcessDescribesKind(
                  processName: processName,
                  arguments: arguments,
                  kind: normalizedKind
              ),
              !arguments.isEmpty else {
            return nil
        }
        let hostBases = Set([
            processBasename(processName),
            processBasename(arguments.first),
        ].compactMap { $0 })
        guard hostBases.contains(where: isInterpreterHost) else {
            return Array(arguments.dropFirst())
        }
        guard let entrypointIndex = interpreterScriptEntrypointIndex(
            processName: processName,
            arguments: arguments
        ), scriptArgument(arguments[entrypointIndex], describes: normalizedKind) else {
            return nil
        }
        return Array(arguments[arguments.index(after: entrypointIndex)...])
    }

    /// True when `parent` is a thin interpreter launcher that immediately
    /// relays into the real process for the same agent. Package-manager shims
    /// commonly use `node <agent>` and then either exec a native binary or
    /// re-exec Node with runtime options. That relay is one launch, not a
    /// parent agent session.
    public static func nativeProcessIsSameAgentLauncherRelay(
        parentProcessName: String?,
        parentArguments: [String],
        childProcessName: String?,
        childArguments: [String],
        kind: String
    ) -> Bool {
        guard !parentArguments.isEmpty,
              let parentExecutable = processBasename(parentArguments.first),
              isInterpreterHost(parentExecutable),
              let parentEntrypointIndex = interpreterScriptEntrypointIndex(
                  processName: parentProcessName,
                  arguments: parentArguments
              ),
              nativeProcessDescribesKind(
                  processName: parentProcessName,
                  arguments: parentArguments,
                  kind: kind
              ),
              nativeProcessDescribesKind(
                  processName: childProcessName,
                  arguments: childArguments,
                  kind: kind
              ) else {
            return false
        }

        let forwardedArguments = parentArguments[parentEntrypointIndex...]
        let childHosts = Set([
            processBasename(childProcessName),
            processBasename(childArguments.first),
        ].compactMap { $0 })
        if !childHosts.contains(where: isInterpreterHost) {
            // Codex's JavaScript package entrypoint is a known thin shim for
            // its native worker. Other interpreter-hosted providers may be the
            // real interactive agent, so treating their native descendants as
            // relays would hide a nested same-provider session.
            guard normalizedAgentName(kind) == "codex",
                  directScriptArgument(parentArguments[parentEntrypointIndex], describes: "codex") else {
                return false
            }
            return true
        }
        guard normalizedAgentName(kind) == "gemini",
              let childEntrypointIndex = interpreterScriptEntrypointIndex(
                  processName: childProcessName,
                  arguments: childArguments
              ),
              childEntrypointIndex > childArguments.startIndex + 1 else {
            return false
        }
        return childArguments[childEntrypointIndex...].elementsEqual(forwardedArguments)
    }

    /// True when a process is running a script but its argv cannot identify a
    /// supported agent. Lineage callers treat this as uncertain ownership and
    /// fail closed, preventing future interpreter-hosted child agents from
    /// taking restore authority before a dedicated adapter is added.
    public static func nativeProcessIsAmbiguousInterpreterHost(
        processName: String?,
        arguments: [String]
    ) -> Bool {
        let hostBases = Set([processBasename(processName), processBasename(arguments.first)].compactMap { $0 })
        guard hostBases.contains(where: isInterpreterHost),
              arguments.dropFirst().contains(where: looksLikeScriptPath) else {
            return false
        }
        return !nativeProcessDescribesKnownAgent(processName: processName, arguments: arguments)
    }

    private static func nativeProcessDescriptors(
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
        let hostBases = Set([nameBase, executableBase].compactMap { $0 })
        if hostBases.contains(where: isInterpreterHost) {
            let knownNames = Set(nativeProcessAliasesByKind.keys)
                .union(nativeProcessAliasesByKind.values.flatMap { $0 })
            guard let entrypointIndex = interpreterScriptEntrypointIndex(
                processName: processName,
                arguments: arguments
            ) else {
                return descriptors
            }
            let argument = arguments[entrypointIndex]
            if looksLikeScriptPath(argument) {
                let normalizedPath = "/" + argument
                    .replacingOccurrences(of: "\\", with: "/")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    .lowercased()
                if let basename = scriptDescriptorBasename(argument), knownNames.contains(basename) {
                    descriptors.insert(basename)
                }
                for (kind, markers) in scriptPathMarkersByKind
                    where markers.contains(where: normalizedPath.contains) {
                    descriptors.insert(kind)
                }
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

    private static func normalizedAgentName(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value.lowercased()
    }

    private static func processBasename(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: value).lastPathComponent.lowercased()
    }

    private static func isInterpreterHost(_ basename: String) -> Bool {
        interpreterHostBases.contains(basename) || basename.hasPrefix("python3.")
    }

    /// Returns the script token interpreted by a runtime, excluding runtime
    /// flags and their values. Only this token can establish agent identity:
    /// later argv may be a prompt, input file, or unrelated executable path.
    private static func interpreterScriptEntrypointIndex(
        processName: String?,
        arguments: [String]
    ) -> Int? {
        guard !arguments.isEmpty else { return nil }
        let argumentHost = processBasename(arguments.first)
        let host = [argumentHost, processBasename(processName)]
            .compactMap { $0 }
            .first(where: isInterpreterHost)
        guard let host else { return nil }

        var index = argumentHost.map(isInterpreterHost) == true ? 1 : 0
        switch normalizedInterpreterHost(host) {
        case "node":
            return scriptIndex(
                in: arguments,
                startingAt: index,
                evaluationOptions: ["-c", "--check", "-e", "--eval", "-i", "--interactive", "-p", "--print"],
                valueOptions: [
                    "-C", "--conditions", "--diagnostic-dir", "--icu-data-dir", "--import",
                    "--inspect-port", "--loader", "--openssl-config", "-r", "--require",
                    "--snapshot-blob", "--test-name-pattern", "--test-reporter",
                    "--test-reporter-destination", "--title", "--experimental-loader",
                ],
                booleanOptions: [
                    "--enable-source-maps", "--experimental-strip-types",
                    "--experimental-transform-types", "--no-addons", "--no-deprecation",
                    "--no-warnings", "--preserve-symlinks", "--preserve-symlinks-main",
                    "--test", "--trace-deprecation", "--trace-warnings", "--use-bundled-ca",
                    "--use-openssl-ca", "--use-system-ca", "--watch",
                ]
            )
        case "bun":
            if index < arguments.count, arguments[index] == "run" { index += 1 }
            guard index >= arguments.count || !["build", "create", "install", "test", "x"].contains(arguments[index]) else {
                return nil
            }
            return scriptIndex(
                in: arguments,
                startingAt: index,
                evaluationOptions: ["-e", "--eval", "-p", "--print"],
                valueOptions: ["--config", "--cwd", "--env-file", "--preload", "-r", "--require", "--title"],
                booleanOptions: [
                    "--bun", "--hot", "--no-clear-screen", "--no-install", "--silent",
                    "--smol", "--watch",
                ]
            )
        case "deno":
            while index < arguments.count {
                let argument = arguments[index]
                if argument == "run" {
                    index += 1
                    break
                }
                if !argument.hasPrefix("-") {
                    return looksLikeScriptPath(argument) ? index : nil
                }
                guard let width = runtimeOptionWidth(
                    argument,
                    evaluationOptions: ["eval"],
                    valueOptions: ["--config", "--import-map", "--location", "--lock", "--node-modules-dir", "--seed"],
                    booleanOptions: ["--no-config", "--no-lock", "--quiet", "-q", "--unstable"]
                ) else { return nil }
                index += width
            }
            return scriptIndex(
                in: arguments,
                startingAt: index,
                evaluationOptions: [],
                valueOptions: ["--cert", "--config", "--env-file", "--import-map", "--location", "--lock", "--seed"],
                booleanOptions: [
                    "-A", "--allow-all", "--allow-env", "--allow-ffi", "--allow-hrtime",
                    "--allow-net", "--allow-read", "--allow-run", "--allow-sys", "--allow-write",
                    "--cached-only", "--no-check", "--no-config", "--no-lock", "--quiet", "-q",
                    "--reload", "--unstable", "--watch",
                ]
            )
        case "python":
            return scriptIndex(
                in: arguments,
                startingAt: index,
                evaluationOptions: ["-c", "-m"],
                valueOptions: ["-W", "-X"],
                booleanOptions: ["-B", "-b", "-bb", "-d", "-E", "-I", "-i", "-O", "-OO", "-q", "-s", "-S", "-u", "-v", "-V"]
            )
        case "ruby":
            return scriptIndex(
                in: arguments,
                startingAt: index,
                evaluationOptions: ["-e", "-S"],
                valueOptions: ["-C", "-I", "-r"],
                booleanOptions: ["-d", "-w", "-W0", "-W1", "-W2"]
            )
        case "ts-node", "tsx":
            if index < arguments.count, arguments[index] == "watch" { index += 1 }
            return scriptIndex(
                in: arguments,
                startingAt: index,
                evaluationOptions: ["-e", "--eval", "-i", "--interactive", "-p", "--print"],
                valueOptions: ["--compiler", "--compiler-options", "--cwd", "--project", "-P", "--require", "-r", "--swc"],
                booleanOptions: ["--esm", "--files", "--skip-project", "--transpile-only", "-T", "--type-check"]
            )
        default:
            return nil
        }
    }

    private static func normalizedInterpreterHost(_ host: String) -> String {
        host.hasPrefix("python3.") || host == "python3" ? "python" : host
    }

    private static func scriptIndex(
        in arguments: [String],
        startingAt startIndex: Int,
        evaluationOptions: Set<String>,
        valueOptions: Set<String>,
        booleanOptions: Set<String>
    ) -> Int? {
        var index = startIndex
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                let scriptIndex = index + 1
                return scriptIndex < arguments.count ? scriptIndex : nil
            }
            if !argument.hasPrefix("-") || argument == "-" {
                return argument == "-" ? nil : index
            }
            guard let width = runtimeOptionWidth(
                argument,
                evaluationOptions: evaluationOptions,
                valueOptions: valueOptions,
                booleanOptions: booleanOptions
            ), index + width <= arguments.count else {
                return nil
            }
            index += width
        }
        return nil
    }

    /// Unknown split-form runtime options fail closed because the following
    /// path could be their value rather than the executed script. Equals-form
    /// options are self-contained and cannot shift the entrypoint boundary.
    private static func runtimeOptionWidth(
        _ argument: String,
        evaluationOptions: Set<String>,
        valueOptions: Set<String>,
        booleanOptions: Set<String>
    ) -> Int? {
        let name = argument.split(separator: "=", maxSplits: 1).first.map(String.init) ?? argument
        if evaluationOptions.contains(name) { return nil }
        if argument.contains("=") { return 1 }
        if valueOptions.contains(name) { return 2 }
        if booleanOptions.contains(name) { return 1 }
        return nil
    }

    private static func looksLikeScriptPath(_ argument: String) -> Bool {
        guard !argument.hasPrefix("-") else { return false }
        let normalized = argument.replacingOccurrences(of: "\\", with: "/").lowercased()
        let scriptExtensions = [".cjs", ".js", ".mjs", ".py", ".rb", ".ts"]
        return normalized.contains("/") || scriptExtensions.contains(where: normalized.hasSuffix)
    }

    private static func scriptArgument(_ argument: String, describes kind: String) -> Bool {
        guard looksLikeScriptPath(argument) else { return false }
        let aliases = nativeProcessAliasesByKind[kind] ?? []
        if let basename = scriptDescriptorBasename(argument),
           basename == kind || aliases.contains(basename) || basename == "\(kind)-cli" {
            return true
        }
        let normalizedPath = "/" + argument
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
        return scriptPathMarkersByKind[kind]?.contains(where: normalizedPath.contains) == true
    }

    private static func directScriptArgument(_ argument: String, describes kind: String) -> Bool {
        guard let basename = scriptDescriptorBasename(argument) else { return false }
        let aliases = nativeProcessAliasesByKind[kind] ?? []
        return basename == kind || aliases.contains(basename) || basename == "\(kind)-cli"
    }

    private static func scriptDescriptorBasename(_ argument: String) -> String? {
        guard var basename = processBasename(argument) else { return nil }
        for suffix in [".cjs", ".js", ".mjs", ".py", ".rb", ".ts"] where basename.hasSuffix(suffix) {
            basename.removeLast(suffix.count)
            break
        }
        return basename
    }
}

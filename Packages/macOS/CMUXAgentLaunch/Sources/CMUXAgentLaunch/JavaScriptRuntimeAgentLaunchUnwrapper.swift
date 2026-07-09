import Foundation

/// Rewrites cmux-wrapper-launched JavaScript runtime argv back to the agent executable.
public struct JavaScriptRuntimeAgentLaunchUnwrapper {
    private let isKnownAgentExecutableName: (String) -> Bool
    private let stripsCmuxHookArguments: Bool
    private let cmuxHookInjectionDetector: AgentCmuxHookInjectionDetector

    /// Creates an unwrapper that recognizes agent executable basenames through `isKnownAgentExecutableName`.
    ///
    /// - Parameter isKnownAgentExecutableName: Predicate that returns true for supported agent executable names.
    /// - Parameter stripsCmuxHookArguments: Whether cmux-owned hook injection should be removed
    ///   while sanitizing package-manager entrypoint tails.
    /// - Parameter cmuxHookInjectionDetector: Detector used to decide when stripped hook payloads
    ///   require replay through the bare wrapper name.
    public init(
        isKnownAgentExecutableName: @escaping (String) -> Bool,
        stripsCmuxHookArguments: Bool = false,
        cmuxHookInjectionDetector: AgentCmuxHookInjectionDetector = AgentCmuxHookInjectionDetector()
    ) {
        self.isKnownAgentExecutableName = isKnownAgentExecutableName
        self.stripsCmuxHookArguments = stripsCmuxHookArguments
        self.cmuxHookInjectionDetector = cmuxHookInjectionDetector
    }

    /// Rewrites or sanitizes node/bun-hosted known agent argv.
    ///
    /// Captured foreground argv may look like `node .../claude.js <flags>`.
    /// Known package-manager agent entrypoints keep the captured runtime and
    /// script path, but their agent tail is sanitized so stale resume/session
    /// artifacts are not saved back into workspace layouts.
    ///
    /// A basename match alone is not enough: a user's own script named like an
    /// agent (`node ./tools/claude.js`, or a project-local pinned
    /// `node_modules` install launched directly) must never be rewritten into
    /// whatever the bare name resolves to on PATH. Package entrypoints can be
    /// sanitized because replay still uses the captured runtime and script path.
    ///
    /// A future non-user-controllable wrapper marker may still rewrite to a bare
    /// agent name. When `stripsCmuxHookArguments` is enabled, a package entrypoint
    /// whose tail starts with cmux-owned hook injection also routes through the
    /// bare wrapper name so replay re-injects fresh hooks.
    public func unwrappedArgv(_ argv: [String]) -> [String]? {
        guard let executable = argv.first else { return nil }
        let runtimeName = (executable as NSString).lastPathComponent.lowercased()
        guard runtimeName == "node" || runtimeName == "bun",
              let scriptIndex = javaScriptRuntimeScriptArgumentIndex(argv) else {
            return nil
        }
        let scriptTail = Array(argv.dropFirst(scriptIndex + 1))
        let scriptName = (argv[scriptIndex] as NSString).lastPathComponent
        let scriptAgentName: String?
        if isKnownAgentExecutableName(scriptName) {
            scriptAgentName = scriptName
        } else if let strippedName = scriptName.removingSingleJavaScriptExtension(),
                  isKnownAgentExecutableName(strippedName) {
            scriptAgentName = strippedName
        } else {
            scriptAgentName = nil
        }
        let packageAgentName = agentPackageName(forScriptPath: argv[scriptIndex])
        if let packageAgentName {
            let routesThroughWrapper = stripsCmuxHookArguments && cmuxHookInjectionDetector.contains(
                kind: packageAgentName,
                args: scriptTail
            )
            switch packageAgentName {
            case "codex":
                let preservedTail = preservedCodexLaunchArguments(
                    args: scriptTail,
                    stripCmuxHooks: stripsCmuxHookArguments
                ) ?? []
                return (routesThroughWrapper ? [packageAgentName] : Array(argv.prefix(scriptIndex + 1))) + preservedTail
            case "claude":
                let preservedTail = ClaudeLaunchArgumentsPreserver().preservedArguments(
                    args: scriptTail,
                    stripCmuxHookSettings: stripsCmuxHookArguments
                ) ?? []
                return (routesThroughWrapper ? [packageAgentName] : Array(argv.prefix(scriptIndex + 1))) + preservedTail
            default:
                break
            }
        }
        guard let markerAgentName = cmuxWrapperInjectedAgentNameFromArgumentPrefix(scriptTail) else {
            return nil
        }
        let matchedName: String
        if let scriptAgentName {
            guard scriptAgentName == markerAgentName else { return nil }
            matchedName = scriptAgentName
        } else if isKnownAgentExecutableName(markerAgentName),
                  packageAgentName == markerAgentName {
            matchedName = markerAgentName
        } else {
            return nil
        }
        return [matchedName] + scriptTail
    }

    /// Whether captured argv carries cmux wrapper-injected hook arguments for
    /// any known agent with a wrapper marker specific enough to prove cmux's
    /// per-surface PATH shim wrapper spawned this process from a bare agent
    /// name. Capture uses this to save the bare name instead of the resolved
    /// absolute binary path, so replay routes back through the shim and hooks
    /// are re-injected fresh.
    public func containsCmuxWrapperInjectedHookArguments(_ argv: [String]) -> Bool {
        guard !argv.isEmpty else { return false }
        return cmuxWrapperInjectedAgentNameFromArgumentPrefix(Array(argv.dropFirst())) != nil
    }
}

/// The npm package directory each marker agent's runtime entrypoint lives in.
/// The marker-derived fallback name is only trusted when the script path sits
/// inside its agent's own package, so an unrelated script whose argv happens
/// to contain hook-looking contents is never rewritten into an agent command.
private let cmuxWrapperAgentPackageDirectories: [String: String] = [
    "codex": "node_modules/@openai/codex/",
    "claude": "node_modules/@anthropic-ai/claude-code/",
]

private func agentPackageName(forScriptPath path: String) -> String? {
    cmuxWrapperAgentPackageDirectories.first { _, packageDirectory in
        path.contains(packageDirectory)
    }?.key
}

private func javaScriptRuntimeScriptArgumentIndex(_ argv: [String]) -> Int? {
    var index = 1
    while index < argv.count {
        let argument = argv[index]
        if argument == "--" {
            let nextIndex = index + 1
            return nextIndex < argv.count ? nextIndex : nil
        }
        if argument.hasPrefix("-") {
            if nodeOptionConsumesScript(argument) {
                return nil
            }
            index += 1 + nodeOptionValueCount(argument)
            continue
        }
        return index
    }
    return nil
}

private func nodeOptionConsumesScript(_ argument: String) -> Bool {
    let option = argument.split(separator: "=", maxSplits: 1).first.map(String.init) ?? argument
    switch option {
    case "-e", "--eval", "-p", "--print", "-c", "--check":
        return true
    default:
        return false
    }
}

private func nodeOptionValueCount(_ argument: String) -> Int {
    if argument.contains("=") {
        return 0
    }
    switch argument {
    case "-r", "--require", "--import", "--loader", "--experimental-loader",
         "--conditions", "-C", "--title":
        return 1
    default:
        return 0
    }
}

private extension String {
    func removingSingleJavaScriptExtension() -> String? {
        for suffix in [".js", ".mjs", ".cjs"] where hasSuffix(suffix) {
            return String(dropLast(suffix.count))
        }
        return nil
    }
}

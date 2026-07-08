import Foundation

/// Rewrites cmux-wrapper-launched JavaScript runtime argv back to the agent executable.
public struct JavaScriptRuntimeAgentLaunchUnwrapper {
    private let isKnownAgentExecutableName: (String) -> Bool

    /// Creates an unwrapper that recognizes agent executable basenames through `isKnownAgentExecutableName`.
    ///
    /// - Parameter isKnownAgentExecutableName: Predicate that returns true for supported agent executable names.
    public init(isKnownAgentExecutableName: @escaping (String) -> Bool) {
        self.isKnownAgentExecutableName = isKnownAgentExecutableName
    }

    /// Rewrites or sanitizes node/bun-hosted known agent argv.
    ///
    /// Captured foreground argv may look like `node .../claude.js <flags>` when
    /// cmux launched the agent through a JavaScript runtime wrapper. Returning a
    /// bare executable name such as `claude` deliberately routes replay through
    /// the per-surface PATH shim and cmux wrapper, so hooks are re-injected fresh
    /// instead of persisting the runtime script path.
    ///
    /// A basename match alone is not enough: a user's own script named like an
    /// agent (`node ./tools/claude.js`, or a project-local pinned
    /// `node_modules` install launched directly) must never be rewritten into
    /// whatever the bare name resolves to on PATH. Argv without an agent marker
    /// that is specific enough to prove cmux's wrapper launched the process keeps
    /// its original form.
    ///
    /// The marker also identifies which wrapper injected it, so when the
    /// script basename is not itself an agent name (Claude Code's real npm
    /// entrypoint is `.../@anthropic-ai/claude-code/cli.js`), the agent name
    /// derived from the marker is used — but only when the script also lives
    /// inside that agent's own npm package directory, so hook-looking argv
    /// contents on an unrelated script can never rewrite it into an agent.
    /// If the script basename already identifies an agent, it must agree with
    /// the marker; mismatched marker/script identity fails closed.
    ///
    /// Codex hook config is weaker: it is normal user-controllable argv, so it
    /// can strip cmux's hook prefix from a node/bun-hosted Codex command, but it
    /// keeps the captured runtime and script path instead of rewriting identity
    /// to bare `codex`.
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
        if scriptAgentName == "codex" || scriptPathIsAgentPackageEntrypoint(argv[scriptIndex], agentName: "codex") {
            let strippedTail = removingCmuxInjectedCodexHookArguments(scriptTail)
            if strippedTail.count != scriptTail.count {
                let preservedTail = preservedCodexLaunchArguments(args: scriptTail) ?? []
                return Array(argv.prefix(scriptIndex + 1)) + preservedTail
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
                  scriptPathIsAgentPackageEntrypoint(argv[scriptIndex], agentName: markerAgentName) {
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

private func scriptPathIsAgentPackageEntrypoint(_ path: String, agentName: String) -> Bool {
    guard let packageDirectory = cmuxWrapperAgentPackageDirectories[agentName] else { return false }
    return path.contains(packageDirectory)
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

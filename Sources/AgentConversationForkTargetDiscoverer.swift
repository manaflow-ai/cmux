import Foundation

/// Immutable inputs for one installed-harness discovery pass.
struct AgentConversationForkTargetDiscoverer: Sendable {
    let environment: [String: String]
    let defaultHomeDirectory: String
    let bundleResourcePath: String?
    let configuredExecutablePaths: [AgentSessionProviderID: String]
    let includeStandardSearchDirectories: Bool

    @MainActor
    static func live() -> AgentConversationForkTargetDiscoverer {
        AgentConversationForkTargetDiscoverer(
            environment: ProcessInfo.processInfo.environment,
            defaultHomeDirectory: NSHomeDirectory(),
            bundleResourcePath: Bundle.main.resourceURL?.path,
            configuredExecutablePaths: AgentExecutableResolver.cmuxConfiguredExecutablePaths(),
            includeStandardSearchDirectories: true
        )
    }

    /// Computes the search directories once, then resolves every supported
    /// harness against that snapshot.
    func discover() -> [AgentConversationForkTarget] {
        let home = environment["HOME"] ?? defaultHomeDirectory
        let supplementalDirectories = [
            ".grok/bin",
            ".amp/bin",
            ".cargo/bin",
            ".cursor/bin",
            ".deno/bin",
            ".gemini/bin",
            ".kiro/bin",
            ".antigravity/bin",
            ".factory/bin",
            ".hermes/bin",
            ".local/share/pnpm",
            ".npm-global/bin",
            "Library/pnpm",
        ].map { "\(home)/\($0)" }
        let resolver = AgentExecutableResolver(
            environment: environment,
            fileManager: FileManager(),
            bundleResourceURL: bundleResourcePath.map {
                URL(fileURLWithPath: $0, isDirectory: true)
            },
            extraSearchDirectories: supplementalDirectories,
            includeStandardSearchDirectories: includeStandardSearchDirectories,
            configuredExecutablePaths: configuredExecutablePaths
        )
        let searchDirectories = resolver.resolvedSearchDirectories()

        return AgentConversationForkTargetHarness.allCases.compactMap { harness in
            guard harness != .current else { return nil }
            let resolution: (executableURL: URL, runtimeSearchPath: String?)?
            if let provider = harness.providerID {
                let plan = try? resolver.resolve(
                    provider,
                    searchDirectories: searchDirectories,
                    executableNames: harness.executableNames
                )
                resolution = plan.map {
                    ($0.executableURL, $0.environment["PATH"])
                }
            } else {
                let executableURL = resolver.resolveExecutable(
                    named: harness.executableNames,
                    searchDirectories: searchDirectories
                )
                resolution = executableURL.map {
                    (
                        $0,
                        resolver.runtimeSearchPath(
                            searchDirectories: searchDirectories,
                            includingExecutableAt: $0
                        )
                    )
                }
            }
            guard let resolution else { return nil }
            return AgentConversationForkTarget(
                harness: harness,
                executablePath: resolution.executableURL.path,
                runtimeSearchPath: resolution.runtimeSearchPath
            )
        }
    }
}

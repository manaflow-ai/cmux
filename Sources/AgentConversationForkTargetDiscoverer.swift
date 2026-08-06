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
    func discover() async -> [AgentConversationForkTarget] {
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

        let candidateGroups = AgentConversationForkTargetHarness.allCases.compactMap { harness -> [AgentConversationForkTargetCandidate]? in
            guard harness != .current else { return nil }
            let candidates: [AgentConversationForkTargetCandidate]
            if let provider = harness.providerID {
                candidates = resolver.resolveCandidates(
                    provider,
                    searchDirectories: searchDirectories,
                    executableNames: harness.executableNames
                ).map {
                    AgentConversationForkTargetCandidate(
                        harness: harness,
                        executableURL: $0.executableURL,
                        runtimeSearchPath: $0.environment["PATH"]
                    )
                }
            } else {
                candidates = resolver.resolveExecutables(
                    named: harness.executableNames,
                    searchDirectories: searchDirectories
                ).map {
                    AgentConversationForkTargetCandidate(
                        harness: harness,
                        executableURL: $0,
                        runtimeSearchPath: resolver.runtimeSearchPath(
                            searchDirectories: searchDirectories,
                            includingExecutableAt: $0
                        )
                    )
                }
            }
            return candidates.isEmpty ? nil : candidates
        }
        return candidateGroups.compactMap { candidates in
            guard !Task.isCancelled else { return nil }
            let stableCandidates = candidates.filter { candidate in
                guard let identity = AgentConversationForkExecutableIdentity.capture(
                    executablePath: candidate.executableURL.path,
                    runtimeSearchPath: candidate.runtimeSearchPath
                ) else {
                    return false
                }
                return AgentConversationForkExecutableBinding(identity: identity) != nil
            }
            guard let primary = stableCandidates.first,
                  let primaryIdentity = AgentConversationForkExecutableIdentity.capture(
                      executablePath: primary.executableURL.path,
                      runtimeSearchPath: primary.runtimeSearchPath
                  ) else {
                return nil
            }
            return AgentConversationForkTarget(
                harness: primary.harness,
                executablePath: primary.executableURL.path,
                runtimeSearchPath: primary.runtimeSearchPath,
                executableIdentity: primaryIdentity,
                executableCandidates: stableCandidates
            )
        }
    }
}

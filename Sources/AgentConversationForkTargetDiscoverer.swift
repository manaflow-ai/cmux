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
        return await withTaskGroup(
            of: (Int, AgentConversationForkTarget?).self,
            returning: [AgentConversationForkTarget].self
        ) { group in
            for (index, candidates) in candidateGroups.enumerated() {
                group.addTask {
                    (index, await firstValidatedTarget(in: candidates))
                }
            }
            var validated = Array<AgentConversationForkTarget?>(
                repeating: nil,
                count: candidateGroups.count
            )
            for await (index, target) in group {
                validated[index] = target
            }
            return validated.compactMap { $0 }
        }
    }

    private func firstValidatedTarget(
        in candidates: [AgentConversationForkTargetCandidate]
    ) async -> AgentConversationForkTarget? {
        for candidate in candidates {
            if let target = await validatedTarget(candidate) {
                return target
            }
        }
        return nil
    }

    private func validatedTarget(
        _ candidate: AgentConversationForkTargetCandidate
    ) async -> AgentConversationForkTarget? {
        guard !Task.isCancelled else { return nil }
        let executablePath = candidate.executableURL.path
        guard let identityBeforeProbe = AgentConversationForkExecutableIdentity.capture(
            executablePath: executablePath,
            runtimeSearchPath: candidate.runtimeSearchPath
        ) else {
            return nil
        }
        var probeEnvironment = environment
        if let runtimeSearchPath = candidate.runtimeSearchPath {
            probeEnvironment["PATH"] = runtimeSearchPath
        }
        guard let output = await AgentForkSupport.commandOutput(
            executable: executablePath,
            arguments: ["--version"],
            environment: probeEnvironment,
            workingDirectory: nil
        ),
              candidate.harness.versionProbeMatches(
                  output: output,
                  resolvedExecutablePath: identityBeforeProbe.realPath
              ),
              let identityAfterProbe = AgentConversationForkExecutableIdentity.capture(
                  executablePath: executablePath,
                  runtimeSearchPath: candidate.runtimeSearchPath
              ),
              identityAfterProbe == identityBeforeProbe,
              !Task.isCancelled else {
            return nil
        }
        return AgentConversationForkTarget(
            harness: candidate.harness,
            executablePath: executablePath,
            runtimeSearchPath: candidate.runtimeSearchPath,
            executableIdentity: identityAfterProbe
        )
    }
}

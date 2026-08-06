import Foundation

/// Immutable inputs for one installed-harness discovery pass.
struct AgentConversationForkTargetDiscoverer: Sendable {
    private struct Candidate: Sendable {
        let harness: AgentConversationForkTargetHarness
        let executableURL: URL
        let runtimeSearchPath: String?
    }

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

        let candidates = AgentConversationForkTargetHarness.allCases.compactMap { harness -> Candidate? in
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
            return Candidate(
                harness: harness,
                executableURL: resolution.executableURL,
                runtimeSearchPath: resolution.runtimeSearchPath
            )
        }
        return await withTaskGroup(
            of: (Int, AgentConversationForkTarget?).self,
            returning: [AgentConversationForkTarget].self
        ) { group in
            for (index, candidate) in candidates.enumerated() {
                group.addTask {
                    (index, await validatedTarget(candidate))
                }
            }
            var validated = Array<AgentConversationForkTarget?>(
                repeating: nil,
                count: candidates.count
            )
            for await (index, target) in group {
                validated[index] = target
            }
            return validated.compactMap { $0 }
        }
    }

    private func validatedTarget(_ candidate: Candidate) async -> AgentConversationForkTarget? {
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

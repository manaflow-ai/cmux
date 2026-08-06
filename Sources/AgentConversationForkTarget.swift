import Foundation

/// One installed harness target. Discovery records candidates without running
/// them; an explicit fork selection validates and pins one candidate before
/// any transcript is read.
struct AgentConversationForkTarget: Equatable, Hashable, Identifiable, Sendable {
    let harness: AgentConversationForkTargetHarness
    let executablePath: String?
    let runtimeSearchPath: String?
    let executableIdentity: AgentConversationForkExecutableIdentity?
    let executableCandidates: [AgentConversationForkTargetCandidate]

    var id: String { harness.rawValue }
    var title: String { harness.title }

    init(
        harness: AgentConversationForkTargetHarness,
        executablePath: String?,
        runtimeSearchPath: String? = nil,
        executableIdentity: AgentConversationForkExecutableIdentity? = nil,
        executableCandidates: [AgentConversationForkTargetCandidate] = []
    ) {
        self.harness = harness
        if harness == .current {
            self.executablePath = nil
            self.runtimeSearchPath = nil
            self.executableIdentity = nil
            self.executableCandidates = []
        } else {
            let normalized = executablePath?.trimmingCharacters(in: .whitespacesAndNewlines)
            precondition(normalized?.isEmpty == false, "Installed fork targets require an executable path")
            self.executablePath = normalized
            let normalizedSearchPath = runtimeSearchPath?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            self.runtimeSearchPath = normalizedSearchPath?.isEmpty == false
                ? normalizedSearchPath
                : nil
            self.executableIdentity = executableIdentity
            self.executableCandidates = executableCandidates
        }
    }

    static let current = AgentConversationForkTarget(
        harness: .current,
        executablePath: nil
    )

    static func canonical(
        _ harness: AgentConversationForkTargetHarness
    ) -> AgentConversationForkTarget {
        guard harness != .current else { return .current }
        return AgentConversationForkTarget(
            harness: harness,
            executablePath: harness.preferredExecutableName
        )
    }

    func startupCommand(handoffMessage: String) -> String? {
        let executableBinding: AgentConversationForkExecutableBinding?
        if let executableIdentity {
            guard let binding = AgentConversationForkExecutableBinding(
                identity: executableIdentity
            ) else {
                return nil
            }
            executableBinding = binding
        } else {
            executableBinding = nil
        }
        return harness.startupCommand(
            handoffMessage: handoffMessage,
            executablePath: executableBinding?.boundPath ?? executablePath,
            runtimeSearchPath: runtimeSearchPath,
            executableBinding: executableBinding,
            executableLookupPath: executablePath,
            recipientExecutablePath: executableBinding?.sourcePath
                ?? executablePath
        )
    }

    /// Validates candidates only after the user selects this target. Version
    /// and help output must be compatible with the harness without using the
    /// filename, and the executable inode must remain stable across the probe.
    /// Transcript submission still requires confirmation of the exact path.
    func validatedForTransfer(
        using executableIdentityResolver: AgentForkExecutableIdentityResolver? = nil
    ) async throws -> AgentConversationForkTarget {
        guard !executableCandidates.isEmpty else { return self }
        guard let executableIdentityResolver else {
            throw AgentConversationForkRequestError.targetExecutableUnverified
        }
        for candidate in executableCandidates {
            try Task.checkCancellation()
            guard let identityAfterProbe = await validatedIdentity(
                for: candidate,
                using: executableIdentityResolver
            ) else {
                continue
            }
            return AgentConversationForkTarget(
                harness: harness,
                executablePath: candidate.executableURL.path,
                runtimeSearchPath: candidate.runtimeSearchPath,
                executableIdentity: identityAfterProbe,
                executableCandidates: [candidate]
            )
        }
        throw AgentConversationForkRequestError.targetExecutableUnverified
    }

    /// Canonical test targets do not carry a discovered file identity. Every
    /// installed UI target does, and must still resolve to the same file before
    /// cmux reads a transcript or launches it.
    func executableIdentityIsCurrent(
        using executableIdentityResolver: AgentForkExecutableIdentityResolver? = nil
    ) async -> Bool {
        guard harness != .current,
              let executableIdentity else {
            return true
        }
        guard let executableIdentityResolver else { return false }
        return await executableIdentityResolver
            .conversationTransferExecutableIdentity(
            executablePath: executableIdentity.lookupPath,
            runtimeSearchPath: runtimeSearchPath,
            hashContents: executableIdentity.contentSHA256 != nil
        ) == executableIdentity
    }

    private func validatedIdentity(
        for candidate: AgentConversationForkTargetCandidate,
        using executableIdentityResolver: AgentForkExecutableIdentityResolver
    ) async -> AgentConversationForkExecutableIdentity? {
        guard let prepared = await executableIdentityResolver
            .prepareConversationTransferExecutable(
                executablePath: candidate.executableURL.path,
                runtimeSearchPath: candidate.runtimeSearchPath
            ) else {
            return nil
        }
        let identityBeforeProbe = prepared.identity
        let validationBinding = prepared.binding
        defer { validationBinding.removeArtifacts() }

        var probeEnvironment = ProcessInfo.processInfo.environment
        if let runtimeSearchPath = candidate.runtimeSearchPath {
            probeEnvironment["PATH"] = runtimeSearchPath
        }
        let versionOutput = await AgentForkSupport.commandOutput(
            executable: validationBinding.boundPath,
            arguments: harness.versionProbeArguments(
                resolvedExecutablePath: candidate.executableURL.path
            ),
            environment: probeEnvironment,
            workingDirectory: nil
        )
        let versionMatches = versionOutput.map {
            harness.versionProbeMatches(
                output: $0,
                resolvedExecutablePath: candidate.executableURL.path
            )
        } == true
        let helpMatches: Bool
        if versionMatches {
            helpMatches = false
        } else {
            helpMatches = await AgentForkSupport.commandOutput(
                executable: validationBinding.boundPath,
                arguments: harness.helpProbeArguments(
                    resolvedExecutablePath: candidate.executableURL.path
                ),
                environment: probeEnvironment,
                workingDirectory: nil,
                acceptedExitStatuses: [0, 2]
            ).map(harness.helpProbeMatches) == true
        }
        guard !Task.isCancelled,
              versionMatches || helpMatches,
              let identityAfterProbe = await executableIdentityResolver
                .conversationTransferExecutableIdentity(
                  executablePath: candidate.executableURL.path,
                  runtimeSearchPath: candidate.runtimeSearchPath,
                  hashContents: true,
                  validatedBinding: validationBinding
              ),
              identityAfterProbe == identityBeforeProbe else {
            return nil
        }
        return identityAfterProbe
    }
}

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
            executableBinding: executableBinding
        )
    }

    /// Validates candidates only after the user selects this target. Version
    /// and help output must identify the harness without using filename text as
    /// evidence, and the executable inode must remain stable across the probe.
    func validatedForTransfer() async throws -> AgentConversationForkTarget {
        guard !executableCandidates.isEmpty else { return self }
        for candidate in executableCandidates {
            try Task.checkCancellation()
            guard let identityAfterProbe = await validatedIdentity(
                for: candidate
            ),
                  AgentConversationForkExecutableBinding(
                      identity: identityAfterProbe
                  ) != nil else {
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
    func executableIdentityIsCurrent() -> Bool {
        guard harness != .current,
              let executableIdentity else {
            return true
        }
        return AgentConversationForkExecutableIdentity.capture(
            executablePath: executableIdentity.lookupPath,
            runtimeSearchPath: runtimeSearchPath,
            hashContents: executableIdentity.contentSHA256 != nil
        ) == executableIdentity
    }

    private func validatedIdentity(
        for candidate: AgentConversationForkTargetCandidate
    ) async -> AgentConversationForkExecutableIdentity? {
        guard let identityBeforeProbe = AgentConversationForkExecutableIdentity.capture(
            executablePath: candidate.executableURL.path,
            runtimeSearchPath: candidate.runtimeSearchPath,
            hashContents: true
        ),
        let validationBinding = AgentConversationForkExecutableBinding(
            identity: identityBeforeProbe
        ),
        validationBinding.materializeImmutableCopy() else {
            return nil
        }
        defer { validationBinding.removeArtifacts() }

        var probeEnvironment = ProcessInfo.processInfo.environment
        if let runtimeSearchPath = candidate.runtimeSearchPath {
            probeEnvironment["PATH"] = runtimeSearchPath
        }
        let versionOutput = await AgentForkSupport.commandOutput(
            executable: validationBinding.boundPath,
            arguments: ["--version"],
            environment: probeEnvironment,
            workingDirectory: nil
        )
        let versionMatches = versionOutput.map {
            harness.versionProbeMatches(
                output: $0,
                resolvedExecutablePath: validationBinding.boundPath
            )
        } == true
        let helpMatches: Bool
        if versionMatches {
            helpMatches = false
        } else {
            helpMatches = await AgentForkSupport.commandOutput(
                executable: validationBinding.boundPath,
                arguments: ["--help"],
                environment: probeEnvironment,
                workingDirectory: nil,
                acceptedExitStatuses: [0, 2]
            ).map(harness.helpProbeMatches) == true
        }
        guard !Task.isCancelled,
              versionMatches || helpMatches,
              validationBinding.boundArtifactIsValid(),
              let identityAfterProbe = AgentConversationForkExecutableIdentity.capture(
                  executablePath: candidate.executableURL.path,
                  runtimeSearchPath: candidate.runtimeSearchPath,
                  hashContents: true
              ),
              identityAfterProbe == identityBeforeProbe else {
            return nil
        }
        return identityAfterProbe
    }
}

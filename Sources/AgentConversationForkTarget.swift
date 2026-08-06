import Foundation

/// One concrete installed harness target. The executable identity is retained
/// from discovery through launch so custom paths and nonstandard aliases work.
struct AgentConversationForkTarget: Equatable, Hashable, Identifiable, Sendable {
    let harness: AgentConversationForkTargetHarness
    let executablePath: String?
    let runtimeSearchPath: String?
    let executableIdentity: AgentConversationForkExecutableIdentity?

    var id: String { harness.rawValue }
    var title: String { harness.title }

    init(
        harness: AgentConversationForkTargetHarness,
        executablePath: String?,
        runtimeSearchPath: String? = nil,
        executableIdentity: AgentConversationForkExecutableIdentity? = nil
    ) {
        self.harness = harness
        if harness == .current {
            self.executablePath = nil
            self.runtimeSearchPath = nil
            self.executableIdentity = nil
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
        harness.startupCommand(
            handoffMessage: handoffMessage,
            executablePath: executablePath,
            runtimeSearchPath: runtimeSearchPath
        )
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
            runtimeSearchPath: runtimeSearchPath
        ) == executableIdentity
    }
}

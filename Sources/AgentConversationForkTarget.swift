import Foundation

/// One concrete installed harness target. The executable identity is retained
/// from discovery through launch so custom paths and nonstandard aliases work.
struct AgentConversationForkTarget: Equatable, Hashable, Identifiable, Sendable {
    let harness: AgentConversationForkTargetHarness
    let executablePath: String?
    let runtimeSearchPath: String?

    var id: String { harness.rawValue }
    var title: String { harness.title }

    init(
        harness: AgentConversationForkTargetHarness,
        executablePath: String?,
        runtimeSearchPath: String? = nil
    ) {
        self.harness = harness
        if harness == .current {
            self.executablePath = nil
            self.runtimeSearchPath = nil
        } else {
            let normalized = executablePath?.trimmingCharacters(in: .whitespacesAndNewlines)
            precondition(normalized?.isEmpty == false, "Installed fork targets require an executable path")
            self.executablePath = normalized
            let normalizedSearchPath = runtimeSearchPath?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            self.runtimeSearchPath = normalizedSearchPath?.isEmpty == false
                ? normalizedSearchPath
                : nil
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
}

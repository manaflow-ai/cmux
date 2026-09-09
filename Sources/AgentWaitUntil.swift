import Foundation

enum AgentWaitUntil: String, Sendable, Equatable {
    case idle
    case needsInput = "needs-input"
    case exit

    init?(cliValue: String) {
        let normalized = cliValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacing("_", with: "-")
        switch normalized {
        case "idle":
            self = .idle
        case "needs-input", "needsinput":
            self = .needsInput
        case "exit":
            self = .exit
        default:
            return nil
        }
    }

    func isSatisfied(by state: AgentLifecyclePublicState) -> Bool {
        switch (self, state) {
        case (.idle, .idle), (.needsInput, .needsInput), (.exit, .exit):
            return true
        default:
            return false
        }
    }
}

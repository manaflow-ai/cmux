import Foundation

enum AgentGUITerminalInjectionResult: Hashable, Sendable {
    case accepted
    case bindingLost
    case inputQueueFull
    case processExited

    var accepted: Bool {
        switch self {
        case .accepted:
            true
        case .bindingLost, .inputQueueFull, .processExited:
            false
        }
    }

    var failureCode: String {
        switch self {
        case .accepted:
            "accepted"
        case .bindingLost:
            "binding_lost"
        case .inputQueueFull:
            "input_queue_full"
        case .processExited:
            "process_exited"
        }
    }
}

import CmuxNextSettings

extension ControlRouter {
    /// The error `action.run` returns for an outcome other than `.ran`.
    static func error(for outcome: ControlActionOutcome, action id: String) -> ControlError {
        let action: JSONValue = .object(["action": .string(id)])
        switch outcome {
        case .ran, .unknownAction: // `.ran` is handled by the caller.
            return ControlError(code: "not_found", message: "Unknown action '\(id)'")
        case .notBound:
            return ControlError(code: "not_bound", message: "\(id) has no handler in this build", data: action)
        case .unavailable:
            return ControlError(code: "unavailable", message: "\(id) is not available in the current context", data: action)
        case .disabled:
            return ControlError(code: "disabled", message: "\(id) is disabled right now", data: action)
        case .unsupported(let reason):
            return unsupported(id, reason: reason)
        case .failed(let reason):
            return ControlError(code: "failed", message: "\(id) failed: \(reason)", data: ["action": .string(id), "reason": .string(reason)])
        }
    }

    /// Typed "unavailable: <reason>" for actions this build cannot run.
    static func unsupported(_ id: String, reason: String) -> ControlError {
        ControlError(code: "unavailable", message: "\(id) unavailable: \(reason)", data: ["action": .string(id), "reason": .string(reason)])
    }
}

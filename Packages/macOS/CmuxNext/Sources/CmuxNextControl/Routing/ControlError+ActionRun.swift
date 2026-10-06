import CmuxNextActions
import CmuxNextSettings

/// The errors `action.run` answers (moved out of ControlRouter): an outcome that did not run, a
/// failure of the action's background work, and a destructive run without `confirm: true`.
extension ControlError {
    /// The error of a non-`ran` outcome; nil for `ran`.
    static func actionOutcome(_ outcome: ControlActionOutcome, action: String) -> ControlError? {
        switch outcome {
        case .ran:
            return nil
        case .unknownAction:
            return ControlError(code: "not_found", message: ControlStrings.format("control.error.unknownAction", "Unknown action '%@'", action))
        case .notBound:
            return ControlError(code: "not_bound", message: ControlStrings.format("control.error.actionNotBound", "%@ has no handler in this build", action), data: ["action": .string(action)])
        case .unavailable:
            return ControlError(code: "unavailable", message: ControlStrings.format("control.error.actionNotAvailableInContext", "%@ is not available in the current context", action), data: ["action": .string(action)])
        case .disabled:
            return ControlError(code: "disabled", message: ControlStrings.format("control.error.actionDisabled", "%@ is disabled right now", action), data: ["action": .string(action)])
        case .refused(let reason):
            return ControlError(code: "unavailable", message: ControlStrings.format("control.error.actionUnavailableReason", "%1$@ unavailable: %2$@", action, reason), data: ["action": .string(action), "reason": .string(reason)])
        case .notFound(let reason):
            return ControlError(code: "not_found", message: reason, data: ["action": .string(action), "reason": .string(reason)])
        case .featureDisabled(let feature):
            return featureDisabled(action, feature: feature)
        case .confirmationRequired:
            return confirmationRequired(action)
        }
    }

    /// The control error for failed action work. A terminal start that
    /// missed its deadline is a `timeout` that says the terminal may still
    /// appear; a command whose reply missed its deadline is a `timeout` that
    /// says it may still apply; a typed refusal answers as the same refusal
    /// made at once (``actionOutcome(_:action:)``); anything else is a `daemon_error`.
    static func actionWork(_ failure: ActionWorkFailure, action: String, method: String) -> ControlError {
        if let refusal = failure.refusal {
            let outcome: ControlActionOutcome = switch refusal {
            case .unavailable: .refused(failure.message)
            case .notFound: .notFound(failure.message)
            }
            if let error = actionOutcome(outcome, action: action) { return error }
        }
        guard failure.terminalMayAppear else {
            guard failure.mayHaveApplied else {
                return ControlError(code: "daemon_error", message: failure.message, data: ["action": .string(action)])
            }
            // The command's reply missed its deadline: it may still apply.
            var error = Self.timeout(method, after: .zero)
            error.message = failure.message
            error.data = ["action": .string(action), "detail": .string(failure.message)]
            return error
        }
        var error = Self.terminalStartTimeout(method, after: TerminalStartDeadline.daemon)
        if case .object(var members) = error.data {
            members["action"] = .string(action)
            members["detail"] = .string(failure.message)
            error.data = .object(members)
        }
        return error
    }

    /// Typed refusal for a destructive action run without `confirm: true`.
    static func confirmationRequired(_ id: String) -> ControlError {
        ControlError(code: "confirmation_required", message: ActionRegistry.confirmationRequiredReason(forRawID: id),
                     data: ["action": .string(id), "argument": .string(ActionArgument.confirmName)])
    }
}

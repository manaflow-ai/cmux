public import CmuxNextActions
import Foundation

/// An action run and the asynchronous work its handler started.
public struct ControlActionRun: Sendable {
    public var outcome: ControlActionOutcome
    /// Each task's value is nil on success, else the failure.
    public var work: [ActionWork]

    public init(outcome: ControlActionOutcome, work: [ActionWork] = []) {
        self.outcome = outcome
        self.work = work
    }
}

extension ControlActionExecutor {
    @MainActor public func performActionTracked(_ request: ControlActionRequest) -> ControlActionRun {
        ControlActionRun(outcome: performAction(request))
    }
}

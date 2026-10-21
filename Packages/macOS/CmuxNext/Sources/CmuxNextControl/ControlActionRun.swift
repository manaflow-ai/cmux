public import CmuxNextActions
import Foundation

/// An action run and the asynchronous work its handler started.
public struct ControlActionRun: Sendable {
    public var outcome: ControlActionOutcome
    /// Each task's value is nil on success, else the failure.
    public var work: [ActionWork]
    /// The value-producing tasks among `work` (`ActionRegistry.track(result:)`):
    /// `action.run` answers their fields as `result`.
    public var results: [ActionResultWork]

    public init(outcome: ControlActionOutcome, work: [ActionWork] = [], results: [ActionResultWork] = []) {
        self.outcome = outcome
        self.work = work
        self.results = results
    }
}

extension ControlActionExecutor {
    @MainActor public func performActionTracked(_ request: ControlActionRequest) -> ControlActionRun {
        ControlActionRun(outcome: performAction(request))
    }
}

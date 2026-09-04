import Foundation

/// The bounded result returned by an automation process or webhook action.
nonisolated struct AutomationActionExecutionResult: Sendable {
    let succeeded: Bool
    let detail: String

    static func success(_ detail: String = "ok") -> AutomationActionExecutionResult {
        AutomationActionExecutionResult(succeeded: true, detail: detail)
    }

    static func failure(_ detail: String) -> AutomationActionExecutionResult {
        AutomationActionExecutionResult(succeeded: false, detail: detail)
    }
}

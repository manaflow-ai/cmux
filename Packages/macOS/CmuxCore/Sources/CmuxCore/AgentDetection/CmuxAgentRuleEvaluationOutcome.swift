/// Deadline-aware outcome shared by compiled process and state rules.
enum CmuxAgentRuleEvaluationOutcome: Equatable, Sendable {
    case matched
    case notMatched
    case budgetExceeded
}

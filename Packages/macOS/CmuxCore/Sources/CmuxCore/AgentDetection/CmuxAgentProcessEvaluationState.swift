/// Mutable, request-local caches and budgets shared by candidate process
/// matchers. It never escapes one synchronous detection call.
struct CmuxAgentProcessEvaluationState {
    var regexDeadline: CmuxAgentEvaluationDeadline?
    var workBudget = CmuxAgentEvaluationWorkBudget()
    private var spaceJoinedArguments: String?
    private var isolatedArguments: String?

    mutating func argumentsJoinedWithSpaces(_ arguments: [String]) -> String {
        if let spaceJoinedArguments { return spaceJoinedArguments }
        let joined = arguments.joined(separator: " ")
        spaceJoinedArguments = joined
        return joined
    }

    mutating func argumentsKeptSeparate(_ arguments: [String]) -> String {
        if let isolatedArguments { return isolatedArguments }
        let joined = arguments.joined(separator: "\u{0}")
        isolatedArguments = joined
        return joined
    }
}

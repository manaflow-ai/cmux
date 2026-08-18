import Foundation

/// One state rule with precompiled regexes and canonical OSC conditions.
struct CmuxAgentCompiledStateRule: Sendable {
    struct Match: Sendable {
        let outcome: CmuxAgentRuleEvaluationOutcome
        let conditionID: String?
        let detail: String
    }

    private struct OSCCondition: Sendable {
        let sequence: String
        let mode: CmuxAgentOSCMatchMode
    }

    let rule: CmuxAgentStateRule
    private let screenContains: [String]
    private let screenRegex: [CmuxAgentCompiledRegex]
    private let combinedScreenRegex: CmuxAgentCompiledRegex?
    private let oscConditions: [OSCCondition]

    init(
        rule: CmuxAgentStateRule,
        reportsRegexProgress: Bool
    ) {
        self.rule = rule
        self.screenContains = rule.screenContains
        self.screenRegex = rule.screenRegex.compactMap {
            CmuxAgentCompiledRegex(
                $0,
                reportsProgress: reportsRegexProgress
            )
        }
        self.combinedScreenRegex = CmuxAgentCompiledRegex(
            combining: rule.screenRegex,
            reportsProgress: reportsRegexProgress
        )
        self.oscConditions = rule.osc.map {
            OSCCondition(sequence: Self.canonicalOSCIntroducer($0.sequence), mode: $0.mode)
        }
    }

    func match(
        screen: String,
        searchableScreen: NSString,
        screenByteCount: Int,
        screenRange: NSRange,
        canonicalOSC: String,
        regexDeadline: inout CmuxAgentEvaluationDeadline?,
        workBudget: inout CmuxAgentEvaluationWorkBudget
    ) -> Match {
        for (index, literal) in screenContains.enumerated() {
            guard workBudget.consume(bytes: screenByteCount) else {
                return Self.budgetExceeded
            }
            if searchableScreen.range(
                of: literal,
                options: [.caseInsensitive, .literal]
            ).location != NSNotFound {
                return Match(
                    outcome: .matched,
                    conditionID: "screenContains[\(index)]",
                    detail: "screen.contains"
                )
            }
        }

        let regexesAreAvailable = screenRegex.count == rule.screenRegex.count
        var combinedRegexMatched = regexesAreAvailable
        if regexesAreAvailable, let combinedScreenRegex {
            guard workBudget.consume(bytes: screenByteCount) else {
                return Self.budgetExceeded
            }
            let deadline = regexDeadline ?? CmuxAgentEvaluationDeadline()
            regexDeadline = deadline
            switch combinedScreenRegex.firstMatch(
                in: screen,
                range: screenRange,
                deadline: deadline
            ) {
            case .matched:
                break
            case .notMatched:
                combinedRegexMatched = false
            case .budgetExceeded:
                return Self.budgetExceeded
            }
        }
        for (index, regex) in screenRegex.enumerated()
        where regexesAreAvailable && combinedRegexMatched {
            guard workBudget.consume(bytes: screenByteCount) else {
                return Self.budgetExceeded
            }
            let deadline = regexDeadline ?? CmuxAgentEvaluationDeadline()
            regexDeadline = deadline
            switch regex.firstMatch(in: screen, range: screenRange, deadline: deadline) {
            case .matched:
                return Match(
                    outcome: .matched,
                    conditionID: "screenRegex[\(index)]",
                    detail: "screen.regex"
                )
            case .notMatched:
                break
            case .budgetExceeded:
                return Self.budgetExceeded
            }
        }

        for (index, condition) in oscConditions.enumerated() {
            guard workBudget.consume(bytes: canonicalOSC.utf8.count) else {
                return Self.budgetExceeded
            }
            let matched: Bool
            switch condition.mode {
            case .contains:
                matched = canonicalOSC.range(of: condition.sequence, options: [.literal]) != nil
            case .prefix:
                matched = canonicalOSC.hasPrefix(condition.sequence)
            case .exact:
                matched = canonicalOSC == condition.sequence
            }
            if matched {
                return Match(
                    outcome: .matched,
                    conditionID: "osc[\(index)]",
                    detail: "osc.matched"
                )
            }
        }
        return Match(outcome: .notMatched, conditionID: nil, detail: "state.not-matched")
    }

    static func canonicalOSCIntroducer(_ value: String) -> String {
        // OSC may arrive as either seven-bit `ESC ]` or the C1 `0x9d` byte.
        var result = ""
        result.reserveCapacity(value.utf8.count + 2)
        for scalar in value.unicodeScalars {
            if scalar.value == 0x9D {
                result.append("\u{1B}]")
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    private static var budgetExceeded: Match {
        Match(
            outcome: .budgetExceeded,
            conditionID: nil,
            detail: "state.budget-exceeded"
        )
    }
}

import Foundation

/// Immutable compiled ICU regex shared by every evaluation in one catalog
/// generation.
///
/// `NSRegularExpression` is immutable after initialization and Foundation
/// documents its matching APIs as safe to invoke concurrently. The unchecked
/// conformance is confined to this wrapper because older SDK annotations do
/// not expose that guarantee to Swift 6.
final class CmuxAgentCompiledRegex: @unchecked Sendable {
    private let expression: NSRegularExpression
    private let reportsProgress: Bool

    init?(
        _ pattern: CmuxAgentRegexPattern,
        reportsProgress: Bool = true
    ) {
        var options: NSRegularExpression.Options = []
        if pattern.caseInsensitive { options.insert(.caseInsensitive) }
        if pattern.dotMatchesNewlines { options.insert(.dotMatchesLineSeparators) }
        guard let expression = try? NSRegularExpression(
            pattern: pattern.pattern,
            options: options
        ) else {
            return nil
        }
        self.expression = expression
        self.reportsProgress = reportsProgress
    }

    /// Combines equivalent-option alternatives into one miss-path scan.
    convenience init?(
        combining patterns: [CmuxAgentRegexPattern],
        reportsProgress: Bool
    ) {
        guard patterns.count > 1, let first = patterns.first,
              patterns.dropFirst().allSatisfy({
                  $0.caseInsensitive == first.caseInsensitive
                      && $0.dotMatchesNewlines == first.dotMatchesNewlines
              }) else {
            return nil
        }
        let source = patterns.map { "(?:\($0.pattern))" }.joined(separator: "|")
        self.init(CmuxAgentRegexPattern(
            pattern: source,
            caseInsensitive: first.caseInsensitive,
            dotMatchesNewlines: first.dotMatchesNewlines
        ), reportsProgress: reportsProgress)
    }

    func firstMatch(
        in value: String,
        range: NSRange,
        deadline: CmuxAgentEvaluationDeadline
    ) -> CmuxAgentRuleEvaluationOutcome {
        if !reportsProgress {
            return expression.firstMatch(in: value, options: [], range: range) == nil
                ? .notMatched
                : .matched
        }
        guard !deadline.isExceeded else { return .budgetExceeded }
        var outcome = CmuxAgentRuleEvaluationOutcome.notMatched
        expression.enumerateMatches(
            in: value,
            options: [.reportProgress],
            range: range
        ) { result, _, stop in
            if deadline.isExceeded {
                outcome = .budgetExceeded
                stop.pointee = true
            } else if result != nil {
                outcome = .matched
                stop.pointee = true
            }
        }
        return outcome
    }
}

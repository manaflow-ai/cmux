import Foundation

/// Why ``MobilePushFilterSettings/addTitleRule(pattern:)`` refused a pattern,
/// surfaced as a short inline error under the add row.
public enum MobilePushFilterPatternRejection: Equatable, Sendable {
    /// The trimmed pattern was empty.
    case empty
    /// The pattern does not compile as an `NSRegularExpression`.
    case invalidPattern
    /// An identical (case-insensitive) pattern rule already exists.
    case duplicate
    /// The pattern exceeds ``MobilePushFilterRule/maxStringLength``.
    case tooLong
    /// The document already holds ``MobilePushFilterRules/maxRuleCount`` rules.
    case limitReached
}

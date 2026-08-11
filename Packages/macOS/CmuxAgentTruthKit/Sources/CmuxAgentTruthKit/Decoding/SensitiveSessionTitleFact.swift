import Foundation

/// Captures sensitive Claude session-title values for later session-list enrichment.
public struct SensitiveSessionTitleFact: Hashable, Sendable {
    /// The transcript line that carried the title-like value.
    public let line: Int
    /// The bookkeeping source field, such as `ai-title` or `agent-name`.
    public let source: String
    /// The sensitive title-like value. Do not use this value as a counter key.
    public let sensitiveValue: String

    /// Creates a sensitive session-title fact.
    /// - Parameters:
    ///   - line: The transcript line that carried the title-like value.
    ///   - source: The bookkeeping source field.
    ///   - sensitiveValue: The sensitive title-like value.
    public init(line: Int, source: String, sensitiveValue: String) {
        self.line = line
        self.source = source
        self.sensitiveValue = sensitiveValue
    }
}

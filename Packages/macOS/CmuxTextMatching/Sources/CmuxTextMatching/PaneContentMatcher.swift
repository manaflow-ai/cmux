/// Finds a query in lines of pane text.
public struct PaneContentMatcher: Sendable {
    /// Compiles `query`.
    public init(query: String, syntax: PaneContentSyntax, caseMode: PaneContentCaseMode) throws {}
    /// Whether the query is empty.
    public var isEmpty: Bool { true }
    /// The first match in `line`.
    public func firstMatch(in line: String) -> Range<String.Index>? { nil }
    /// Up to `limit` non-overlapping matches in `line`.
    public func matches(in line: String, limit: Int) -> [Range<String.Index>] { [] }
}

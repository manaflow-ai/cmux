/// The localized words a ``FindPillView`` shows and speaks. Each surface's module owns its
/// strings catalog, so the caller resolves them.
public struct FindPillLabels: Sendable {
    /// The field's placeholder and accessibility label ("Find").
    public var placeholder: String
    /// The previous-match button's tooltip and accessibility label.
    public var previous: String
    /// The next-match button's tooltip and accessibility label.
    public var next: String
    /// The close button's tooltip and accessibility label.
    public var close: String
    /// The match-case toggle's tooltip, or nil where the search cannot match case (the
    /// terminal: Ghostty matches case-insensitively), which leaves the toggle out.
    public var matchCase: String?

    /// - Parameters:
    ///   - placeholder: The field's placeholder.
    ///   - previous: The previous-match button's label.
    ///   - next: The next-match button's label.
    ///   - close: The close button's label.
    ///   - matchCase: The match-case toggle's label; nil leaves the toggle out.
    public init(placeholder: String, previous: String, next: String, close: String, matchCase: String? = nil) {
        self.placeholder = placeholder
        self.previous = previous
        self.next = next
        self.close = close
        self.matchCase = matchCase
    }
}

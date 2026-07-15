/// An existing terminal path together with an optional source location.
public nonisolated struct TerminalPathResolution: Equatable, Sendable {
    /// The standardized absolute path that passed the existence probe.
    public let path: String

    /// The one-based line parsed from a `:line` suffix, when present.
    public let line: Int?

    /// The one-based column parsed from a `:line:column` suffix, when present.
    public let column: Int?

    /// Creates a resolved path reference.
    ///
    /// - Parameters:
    ///   - path: A standardized absolute path. Resolver-produced values are
    ///     guaranteed to exist at resolution time.
    ///   - line: An optional one-based line.
    ///   - column: An optional one-based column.
    public init(path: String, line: Int?, column: Int?) {
        self.path = path
        self.line = line
        self.column = column
    }
}

/// An existing file resolved from terminal text, optionally with a one-based
/// source location parsed from a conventional terminal suffix.
public struct TerminalFileReference: Equatable, Sendable {
    public let path: String
    public let line: Int?
    public let column: Int?

    public init(path: String, line: Int? = nil, column: Int? = nil) {
        self.path = path
        self.line = line
        self.column = column
    }
}

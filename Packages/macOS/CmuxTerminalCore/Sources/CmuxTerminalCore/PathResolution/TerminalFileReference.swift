import Foundation

/// An existing local file referenced by terminal text, optionally at a source
/// location.
public struct TerminalFileReference: Equatable, Sendable {
    public let path: String
    public let line: Int?
    public let column: Int?

    /// Creates a reference for a local file and optional location.
    ///
    /// - Parameters:
    ///   - path: The local file path.
    ///   - line: An optional one-based source line.
    ///   - column: An optional one-based source column.
    public init(path: String, line: Int? = nil, column: Int? = nil) {
        self.path = path
        self.line = line
        self.column = column
    }
}

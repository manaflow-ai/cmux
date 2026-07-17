/// One parsed line inside a unified-diff hunk.
public struct DiffLine: Sendable, Equatable, Identifiable {
    /// Stable line identity within a parsed result.
    public let id: Int
    /// The line's semantic kind.
    public let kind: DiffLineKind
    /// The line text without the leading unified-diff marker.
    public let text: String
    /// The old-file line number, when this line exists in the old file.
    public let oldLine: Int?
    /// The new-file line number, when this line exists in the new file.
    public let newLine: Int?

    /// Creates a parsed diff line.
    ///
    /// - Parameters:
    ///   - id: Stable line identity within a parsed result.
    ///   - kind: The line's semantic kind.
    ///   - text: The line text without the leading unified-diff marker.
    ///   - oldLine: The old-file line number, when present.
    ///   - newLine: The new-file line number, when present.
    public init(id: Int, kind: DiffLineKind, text: String, oldLine: Int?, newLine: Int?) {
        self.id = id
        self.kind = kind
        self.text = text
        self.oldLine = oldLine
        self.newLine = newLine
    }
}

/// The formatted text segments rendered inside a workspace changes chip.
public struct WorkspaceChangesChipText: Sendable, Equatable {
    /// The leading text segment, or the complete text for a file-count chip.
    public let primary: String
    /// The deletion segment for a line-count chip; `nil` for a file-count chip.
    public let secondary: String?

    /// The complete unstyled text for accessibility and test assertions.
    public var combined: String {
        guard let secondary else { return primary }
        return "\(primary) \(secondary)"
    }

    init(primary: String, secondary: String?) {
        self.primary = primary
        self.secondary = secondary
    }
}

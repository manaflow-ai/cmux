/// Current working-tree lines plus any revision fingerprints observed while fetching them.
public struct DiffExpansionCurrentFile: Sendable, Equatable {
    /// Current working-tree text split into lines.
    public let lines: [String]
    /// Fingerprints reported by stat and chunk responses, preserving missing values.
    public let contentFingerprints: [String?]

    /// Creates fetched expansion content.
    /// - Parameters:
    ///   - lines: Current working-tree text split into lines.
    ///   - contentFingerprints: Revision fingerprints observed during the fetch.
    public init(lines: [String], contentFingerprints: [String?]) {
        self.lines = lines
        self.contentFingerprints = contentFingerprints
    }
}

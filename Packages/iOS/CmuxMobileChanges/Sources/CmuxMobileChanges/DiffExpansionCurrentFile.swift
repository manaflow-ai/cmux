/// Current working-tree lines plus any revision fingerprints observed while fetching them.
public struct DiffExpansionCurrentFile: Sendable, Equatable {
    /// Current working-tree text split into lines.
    public let lines: [String]
    /// Nonempty fingerprints reported by stat and chunk responses.
    public let contentFingerprints: [String]

    /// Creates fetched expansion content.
    /// - Parameters:
    ///   - lines: Current working-tree text split into lines.
    ///   - contentFingerprints: Revision fingerprints observed during the fetch.
    public init(lines: [String], contentFingerprints: [String]) {
        self.lines = lines
        self.contentFingerprints = contentFingerprints
    }
}

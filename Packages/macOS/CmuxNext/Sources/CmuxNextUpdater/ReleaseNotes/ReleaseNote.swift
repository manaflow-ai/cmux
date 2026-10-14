/// A user-facing release note, produced at publication from PR notes or the
/// editorial summarizer. PR numbers link to the repository's public history.
nonisolated public struct ReleaseNote: Codable, Equatable, Sendable {
    /// Product area identifier; the page localizes its label.
    public var area: String
    /// One sentence describing the observable change.
    public var title: String
    /// Pull requests supporting this note, including folded duplicates.
    public var prs: [Int]

    /// Creates an editorial note for a product area and its supporting PRs.
    public init(area: String, title: String, prs: [Int]) {
        self.area = area
        self.title = title
        self.prs = prs
    }
}

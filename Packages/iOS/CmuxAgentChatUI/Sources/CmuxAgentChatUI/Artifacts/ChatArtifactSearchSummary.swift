/// The small search-state snapshot needed by the SwiftUI search chrome.
struct ChatArtifactSearchSummary: Equatable, Sendable {
    static let empty = ChatArtifactSearchSummary(currentPosition: 0, matchCount: 0)

    let currentPosition: Int
    let matchCount: Int
}

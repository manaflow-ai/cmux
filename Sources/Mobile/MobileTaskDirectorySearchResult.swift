import Foundation

/// One bounded directory-search response together with an honest description
/// of how much of the Mac filesystem the search could cover.
struct MobileTaskDirectorySearchResult: Equatable, Sendable {
    enum Scope: String, Equatable, Sendable {
        /// Spotlight metadata from indexed local and user-mounted network volumes.
        case allIndexedVolumes = "all_indexed_volumes"
        /// Only contextual paths already known to cmux were available.
        case contextualCandidatesOnly = "contextual_candidates_only"
    }

    let directories: [String]
    let scope: Scope
    let gatheringComplete: Bool
    let filesystemComplete: Bool
    let truncated: Bool
    let indexedMatchCount: Int
}

import Foundation

/// One bounded directory-search response together with an honest description
/// of how much of the Mac filesystem the search could cover.
public struct MobileTaskDirectorySearchResult: Equatable, Sendable {
    public enum Scope: String, Equatable, Sendable {
        /// Spotlight metadata from indexed local and user-mounted network volumes.
        case allIndexedVolumes = "all_indexed_volumes"
        /// Only contextual paths already known to cmux were available.
        case contextualCandidatesOnly = "contextual_candidates_only"
    }

    public let directories: [String]
    public let scope: Scope
    public let gatheringComplete: Bool
    public let filesystemComplete: Bool
    public let truncated: Bool
    public let indexedMatchCount: Int

    public init(
        directories: [String],
        scope: Scope,
        gatheringComplete: Bool,
        filesystemComplete: Bool,
        truncated: Bool,
        indexedMatchCount: Int
    ) {
        self.directories = directories
        self.scope = scope
        self.gatheringComplete = gatheringComplete
        self.filesystemComplete = filesystemComplete
        self.truncated = truncated
        self.indexedMatchCount = indexedMatchCount
    }
}

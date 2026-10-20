public import Foundation

/// Typed result for `mobile.directory.search`.
public struct MobileTaskDirectorySearchResponse: Decodable, Equatable, Sendable {
    /// The source whose coverage produced the returned matches.
    public enum SearchScope: String, Decodable, Equatable, Sendable {
        /// Spotlight metadata from indexed local and mounted network volumes.
        case allIndexedVolumes = "all_indexed_volumes"
        /// Only open, recent, or otherwise contextual cmux paths were available.
        case contextualCandidatesOnly = "contextual_candidates_only"
        /// A host predating coverage metadata returned its bounded legacy index.
        case legacyBounded = "legacy_bounded"
    }

    /// Ranked directory paths, capped to the wire maximum.
    public let directories: [String]

    /// The indexed source searched by the Mac.
    public let searchScope: SearchScope

    /// Whether Spotlight finished gathering before the host deadline.
    public let gatheringComplete: Bool

    /// Whether every reachable filesystem directory was searched.
    public let filesystemComplete: Bool

    /// Whether additional ranked or indexed matches exceeded the response cap.
    public let truncated: Bool

    /// The number of raw matches reported by Spotlight before wire ranking.
    public let indexedMatchCount: Int

    /// Creates a bounded directory-search response.
    ///
    /// - Parameters:
    ///   - directories: Ranked absolute paths from the Mac.
    ///   - searchScope: The source whose coverage produced the matches.
    ///   - gatheringComplete: Whether indexed gathering reached completion.
    ///   - filesystemComplete: Whether the result covers the full filesystem.
    ///   - truncated: Whether additional matches were omitted.
    ///   - indexedMatchCount: Raw Spotlight match count before ranking.
    public init(
        directories: [String],
        searchScope: SearchScope = .legacyBounded,
        gatheringComplete: Bool = false,
        filesystemComplete: Bool = false,
        truncated: Bool = false,
        indexedMatchCount: Int = 0
    ) {
        let validDirectories = directories.filter(Self.isValidPath)
        self.directories = Array(validDirectories.prefix(64))
        self.searchScope = searchScope
        self.gatheringComplete = gatheringComplete
        self.filesystemComplete = filesystemComplete
        self.truncated = truncated || validDirectories.count > 64
        self.indexedMatchCount = max(0, indexedMatchCount)
    }

    /// Decodes the Mac response and re-applies the wire cap defensively.
    public static func decode(_ data: Data) throws -> Self {
        try JSONDecoder().decode(Self.self, from: data)
    }

    private enum CodingKeys: String, CodingKey {
        case directories
        case searchScope = "search_scope"
        case gatheringComplete = "gathering_complete"
        case filesystemComplete = "filesystem_complete"
        case truncated
        case indexedMatchCount = "indexed_match_count"
    }

    /// Decodes coverage metadata while accepting legacy directory-only hosts.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let directories = try container.decode([String].self, forKey: .directories)
        let searchScope = try container.decodeIfPresent(SearchScope.self, forKey: .searchScope)
            ?? .legacyBounded
        let gatheringComplete = try container.decodeIfPresent(Bool.self, forKey: .gatheringComplete)
            ?? false
        let filesystemComplete = try container.decodeIfPresent(Bool.self, forKey: .filesystemComplete)
            ?? false
        let truncated = try container.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
        let indexedMatchCount = try container.decodeIfPresent(Int.self, forKey: .indexedMatchCount) ?? 0
        guard indexedMatchCount >= 0, !filesystemComplete else {
            throw DecodingError.dataCorruptedError(
                forKey: filesystemComplete ? .filesystemComplete : .indexedMatchCount,
                in: container,
                debugDescription: filesystemComplete
                    ? "Indexed directory search cannot claim full filesystem coverage."
                    : "Indexed match count must be nonnegative."
            )
        }
        self.init(
            directories: directories,
            searchScope: searchScope,
            gatheringComplete: gatheringComplete,
            filesystemComplete: filesystemComplete,
            truncated: truncated,
            indexedMatchCount: indexedMatchCount
        )
    }

    private static func isValidPath(_ path: String) -> Bool {
        !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && path.utf8.count <= 4_096
    }
}

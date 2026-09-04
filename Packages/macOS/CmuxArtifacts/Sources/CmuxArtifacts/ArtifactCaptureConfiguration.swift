import Foundation

/// Bounded capture, retention, and search policy for one local catalog.
public struct ArtifactCaptureConfiguration: Codable, Equatable, Sendable {
    /// Enables automatic producer hooks such as terminal and browser capture.
    public var enabled: Bool
    /// Whether terminal-emitted file paths are accepted.
    public var includeFilePaths: Bool
    /// Whether optional public-page title fetching is enabled by the app layer.
    public var fetchTitles: Bool
    /// Host patterns ignored by URL capture.
    public var ignoreHosts: [String]
    /// Maximum records retained after a mutation.
    public var retentionLimit: Int
    /// Maximum record age in seconds; nonpositive disables age eviction.
    public var retentionAge: TimeInterval
    /// Maximum bytes copied from one source file.
    public var maximumFileBytes: Int64
    /// Maximum bytes retained in one inline text/HTML record.
    public var maximumInlineBytes: Int
    /// Maximum aggregate bytes represented by managed file payloads.
    public var maximumPayloadBytes: Int64
    /// Maximum encoded catalog size accepted during decode.
    public var maximumCatalogBytes: Int
    /// Maximum rows returned by one search.
    public var maximumSearchResults: Int
    /// Maximum records accepted in one producer batch.
    public var maximumBatchCount: Int
    /// Maximum UTF-8 bytes copied into the local search projection for a text file.
    public var maximumIndexedContentBytes: Int

    /// Conservative defaults that keep capture local and bounded.
    public static let defaultValue = ArtifactCaptureConfiguration(
        enabled: true,
        includeFilePaths: false,
        fetchTitles: false,
        ignoreHosts: ["localhost:31034"],
        retentionLimit: 500,
        retentionAge: 90 * 24 * 60 * 60,
        maximumFileBytes: 50 * 1024 * 1024,
        maximumInlineBytes: 1 * 1024 * 1024,
        maximumPayloadBytes: 512 * 1024 * 1024,
        maximumCatalogBytes: 16 * 1024 * 1024,
        maximumSearchResults: 500,
        maximumBatchCount: 64,
        maximumIndexedContentBytes: 64 * 1024
    )

    /// Creates a capture policy.
    public init(
        enabled: Bool = true,
        includeFilePaths: Bool = false,
        fetchTitles: Bool = false,
        ignoreHosts: [String] = ["localhost:31034"],
        retentionLimit: Int = 500,
        retentionAge: TimeInterval = 90 * 24 * 60 * 60,
        maximumFileBytes: Int64 = 50 * 1024 * 1024,
        maximumInlineBytes: Int = 1 * 1024 * 1024,
        maximumPayloadBytes: Int64 = 512 * 1024 * 1024,
        maximumCatalogBytes: Int = 16 * 1024 * 1024,
        maximumSearchResults: Int = 500,
        maximumBatchCount: Int = 64,
        maximumIndexedContentBytes: Int = 64 * 1024
    ) {
        self.enabled = enabled
        self.includeFilePaths = includeFilePaths
        self.fetchTitles = fetchTitles
        self.ignoreHosts = ignoreHosts
        self.retentionLimit = retentionLimit
        self.retentionAge = retentionAge
        self.maximumFileBytes = maximumFileBytes
        self.maximumInlineBytes = maximumInlineBytes
        self.maximumPayloadBytes = maximumPayloadBytes
        self.maximumCatalogBytes = maximumCatalogBytes
        self.maximumSearchResults = maximumSearchResults
        self.maximumBatchCount = maximumBatchCount
        self.maximumIndexedContentBytes = maximumIndexedContentBytes
    }

    /// Decodes a configuration written by any earlier catalog revision.
    /// Missing newer limits use the same conservative defaults as a fresh
    /// configuration instead of making an otherwise readable settings file
    /// fail closed as malformed.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true,
            includeFilePaths: try container.decodeIfPresent(Bool.self, forKey: .includeFilePaths) ?? false,
            fetchTitles: try container.decodeIfPresent(Bool.self, forKey: .fetchTitles) ?? false,
            ignoreHosts: try container.decodeIfPresent([String].self, forKey: .ignoreHosts) ?? ["localhost:31034"],
            retentionLimit: try container.decodeIfPresent(Int.self, forKey: .retentionLimit) ?? 500,
            retentionAge: try container.decodeIfPresent(TimeInterval.self, forKey: .retentionAge) ?? 90 * 24 * 60 * 60,
            maximumFileBytes: try container.decodeIfPresent(Int64.self, forKey: .maximumFileBytes) ?? 50 * 1024 * 1024,
            maximumInlineBytes: try container.decodeIfPresent(Int.self, forKey: .maximumInlineBytes) ?? 1 * 1024 * 1024,
            maximumPayloadBytes: try container.decodeIfPresent(Int64.self, forKey: .maximumPayloadBytes) ?? 512 * 1024 * 1024,
            maximumCatalogBytes: try container.decodeIfPresent(Int.self, forKey: .maximumCatalogBytes) ?? 16 * 1024 * 1024,
            maximumSearchResults: try container.decodeIfPresent(Int.self, forKey: .maximumSearchResults) ?? 500,
            maximumBatchCount: try container.decodeIfPresent(Int.self, forKey: .maximumBatchCount) ?? 64,
            maximumIndexedContentBytes: try container.decodeIfPresent(Int.self, forKey: .maximumIndexedContentBytes) ?? 64 * 1024
        )
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, includeFilePaths, fetchTitles, ignoreHosts, retentionLimit, retentionAge
        case maximumFileBytes, maximumInlineBytes, maximumPayloadBytes, maximumCatalogBytes
        case maximumSearchResults, maximumBatchCount, maximumIndexedContentBytes
    }

    /// Returns values clamped to safe resource bounds.
    public var normalized: ArtifactCaptureConfiguration {
        var value = self
        value.retentionLimit = min(max(retentionLimit, 10), 10_000)
        value.retentionAge = retentionAge.isFinite ? min(max(retentionAge, 0), 365 * 24 * 60 * 60) : 0
        value.maximumFileBytes = min(max(maximumFileBytes, 1), 512 * 1024 * 1024)
        value.maximumInlineBytes = min(max(maximumInlineBytes, 1), 8 * 1024 * 1024)
        value.maximumPayloadBytes = min(max(maximumPayloadBytes, 1), 4 * 1024 * 1024 * 1024)
        value.maximumCatalogBytes = min(max(maximumCatalogBytes, 64 * 1024), 128 * 1024 * 1024)
        value.maximumSearchResults = min(max(maximumSearchResults, 1), 5_000)
        value.maximumBatchCount = min(max(maximumBatchCount, 1), 256)
        value.maximumIndexedContentBytes = min(max(maximumIndexedContentBytes, 0), 512 * 1024)
        value.ignoreHosts = ignoreHosts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        return value
    }
}

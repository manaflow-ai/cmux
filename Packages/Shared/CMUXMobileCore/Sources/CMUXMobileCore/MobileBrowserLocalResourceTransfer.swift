import Foundation

/// Limits applied to a phone-local rendering of a Mac file URL.
///
/// Resources are fetched in ranges and are never materialized as a directory
/// on the phone. The resource and page limits keep an HTML dependency tree from
/// consuming unbounded disk or memory.
public struct MobileBrowserLocalResourcePolicy: Equatable, Sendable {
    /// Maximum bytes served for one file.
    public static let defaultMaximumResourceBytes: Int64 = 64 * 1024 * 1024
    /// Maximum bytes served by one top-level page and its dependencies.
    public static let defaultMaximumPageBytes: Int64 = 128 * 1024 * 1024
    /// Maximum raw bytes in one RPC response.
    public static let defaultMaximumChunkBytes = 1 * 1024 * 1024

    /// Maximum bytes served for one file.
    public let maximumResourceBytes: Int64
    /// Maximum aggregate bytes served during one page load.
    public let maximumPageBytes: Int64
    /// Maximum raw bytes requested in one range.
    public let maximumChunkBytes: Int

    /// Creates a transfer policy.
    public init(
        maximumResourceBytes: Int64 = Self.defaultMaximumResourceBytes,
        maximumPageBytes: Int64 = Self.defaultMaximumPageBytes,
        maximumChunkBytes: Int = Self.defaultMaximumChunkBytes
    ) {
        precondition(maximumResourceBytes > 0)
        precondition(maximumPageBytes >= maximumResourceBytes)
        precondition(maximumChunkBytes > 0)
        self.maximumResourceBytes = maximumResourceBytes
        self.maximumPageBytes = maximumPageBytes
        self.maximumChunkBytes = maximumChunkBytes
    }
}

/// Parameters for one bounded read from a Mac browser panel's current file.
public struct MobileBrowserLocalResourceFetchParameters: Codable, Equatable, Sendable {
    /// The Mac browser panel UUID string.
    public let panelID: String
    /// The logical path relative to the current file's read-access root.
    public let path: String
    /// The workspace UUID string used for ticket scoping.
    public let workspaceID: String
    /// The requested byte offset.
    public let offset: Int64
    /// The requested raw byte count.
    public let length: Int

    /// Creates a range request.
    public init(
        panelID: String,
        path: String,
        workspaceID: String,
        offset: Int64,
        length: Int
    ) {
        self.panelID = panelID
        self.path = path
        self.workspaceID = workspaceID
        self.offset = offset
        self.length = length
    }

    private enum CodingKeys: String, CodingKey {
        case panelID = "panel_id"
        case path
        case workspaceID = "workspace_id"
        case offset
        case length
    }
}

/// One bounded range returned by the Mac browser file service.
public struct MobileBrowserLocalResourceChunk: Codable, Equatable, Sendable {
    /// Logical path echoed from the request.
    public let path: String
    /// Offset of `data` in the resource.
    public let offset: Int64
    /// Total size of the resource.
    public let totalSize: Int64
    /// Raw bytes in this range.
    public let data: Data
    /// MIME type inferred by the Mac, when known.
    public let mimeType: String?
    /// Whether this range reaches the resource's end.
    public let eof: Bool

    /// Creates a resource chunk.
    public init(
        path: String,
        offset: Int64,
        totalSize: Int64,
        data: Data,
        mimeType: String?,
        eof: Bool
    ) {
        self.path = path
        self.offset = offset
        self.totalSize = totalSize
        self.data = data
        self.mimeType = mimeType
        self.eof = eof
    }

    private enum CodingKeys: String, CodingKey {
        case path
        case offset
        case totalSize = "total_size"
        case data = "data_b64"
        case mimeType = "mime_type"
        case eof
    }
}

/// A capability-safe range loader used by the local WebKit scheme handler.
public struct MobileBrowserLocalResourceLoader: Sendable {
    /// The asynchronous range-fetch operation.
    public typealias Fetch = @Sendable (
        _ panelID: String,
        _ path: String,
        _ offset: Int64,
        _ length: Int
    ) async throws -> MobileBrowserLocalResourceChunk

    private let fetchOperation: Fetch

    /// Creates a loader around an authenticated transport operation.
    public init(fetch: @escaping Fetch) {
        self.fetchOperation = fetch
    }

    /// Fetches one bounded range.
#if compiler(>=6.2)
    @concurrent
#endif
    public func fetch(
        panelID: String,
        path: String,
        offset: Int64,
        length: Int
    ) async throws -> MobileBrowserLocalResourceChunk {
        try await fetchOperation(panelID, path, offset, length)
    }
}

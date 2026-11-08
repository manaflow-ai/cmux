public import Foundation

/// A validated page request for the `mobile.directory.list` RPC method.
///
/// Paths are either absolute Mac paths or `~`-relative paths. Pagination uses
/// an entry offset so callers can continue until the response's
/// ``MobileTaskDirectoryListResponse/nextOffset`` becomes `nil`.
public struct MobileTaskDirectoryListRequest: Codable, Equatable, Sendable {
    /// The page size used when a caller does not choose one explicitly.
    public static let defaultPageSize = 50

    /// The largest page the client and host accept on the wire.
    public static let maximumPageSize = 100

    /// The absolute or `~`-relative directory path to list.
    public let path: String

    /// The zero-based entry offset in the directory's stable sort order.
    public let offset: Int

    /// The maximum number of entries to return in this page.
    public let limit: Int

    /// Creates a validated directory-list request.
    ///
    /// - Parameters:
    ///   - path: An absolute path, `~`, or a path beginning with `~/`.
    ///   - offset: A nonnegative entry offset in the stable directory order.
    ///   - limit: A page size from `1` through ``maximumPageSize``.
    /// - Returns: A request, or `nil` when any argument is outside the wire contract.
    public init?(
        path: String,
        offset: Int = 0,
        limit: Int = Self.defaultPageSize
    ) {
        guard Self.isValidPath(path), offset >= 0,
              (1...Self.maximumPageSize).contains(limit) else {
            return nil
        }
        self.path = path
        self.offset = offset
        self.limit = limit
    }

    /// Decodes and validates a raw JSON request payload.
    ///
    /// - Parameter data: JSON data containing `path`, `offset`, and `limit`.
    /// - Returns: A request whose fields satisfy the wire limits.
    /// - Throws: ``DecodingError/dataCorrupted(_:)`` when a field violates the contract.
    public static func decode(_ data: Data) throws -> Self {
        try JSONDecoder().decode(Self.self, from: data)
    }

    private enum CodingKeys: String, CodingKey {
        case path
        case offset
        case limit
    }

    /// Decodes and validates a request from a decoder.
    ///
    /// - Parameter decoder: The decoder containing the wire request.
    /// - Throws: ``DecodingError/dataCorrupted(_:)`` when a field violates the contract.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let path = try container.decode(String.self, forKey: .path)
        let offset = try container.decode(Int.self, forKey: .offset)
        let limit = try container.decode(Int.self, forKey: .limit)
        guard let request = Self(path: path, offset: offset, limit: limit) else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: container.codingPath,
                    debugDescription: "Directory-list request fields are outside the wire contract."
                )
            )
        }
        self = request
    }

    private static func isValidPath(_ path: String) -> Bool {
        guard !path.isEmpty, path.utf8.count <= 4_096,
              !path.unicodeScalars.contains(where: { $0.value == 0 }) else {
            return false
        }
        return path.hasPrefix("/") || path == "~" || path.hasPrefix("~/")
    }
}

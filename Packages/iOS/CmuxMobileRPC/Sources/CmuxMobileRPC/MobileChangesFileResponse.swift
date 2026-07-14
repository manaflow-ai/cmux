public import Foundation

/// Decodes one page from `mobile.workspace.changes.file`.
public struct MobileChangesFileResponse: Codable, Sendable, Equatable {
    /// Unified-diff hunks included in this page.
    public let hunks: [MobileChangesHunk]
    /// Whether the file is binary.
    public let isBinary: Bool
    /// Whether the requested diff is too large for the host's patch limits.
    public let tooLarge: Bool
    /// The opaque cursor for the next page, or `nil` when this is the last page.
    public let nextCursor: String?

    /// Creates a file-diff page response.
    /// - Parameters:
    ///   - hunks: Unified-diff hunks included in this page.
    ///   - isBinary: Whether the file is binary.
    ///   - tooLarge: Whether the requested diff exceeds the host's patch limits.
    ///   - nextCursor: The opaque cursor for the next page, when present.
    public init(hunks: [MobileChangesHunk], isBinary: Bool, tooLarge: Bool, nextCursor: String?) {
        self.hunks = hunks
        self.isBinary = isBinary
        self.tooLarge = tooLarge
        self.nextCursor = nextCursor
    }

    private enum CodingKeys: String, CodingKey {
        case hunks
        case isBinary = "is_binary"
        case tooLarge = "too_large"
        case nextCursor = "next_cursor"
    }

    /// Decodes a file-diff page from an RPC result payload.
    /// - Parameter data: The JSON result payload.
    /// - Returns: The decoded response.
    /// - Throws: A decoding error if the payload is malformed.
    public static func decode(_ data: Data) throws -> MobileChangesFileResponse {
        try JSONDecoder().decode(Self.self, from: data)
    }
}

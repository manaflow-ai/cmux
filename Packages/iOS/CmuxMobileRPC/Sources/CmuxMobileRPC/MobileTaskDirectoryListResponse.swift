public import Foundation

/// A complete, defensively validated page from `mobile.directory.list`.
///
/// The host reports an exact total and the next offset rather than truncating
/// silently. Callers can therefore browse directories of any size one page at
/// a time while preserving the host's stable bytewise name order.
public struct MobileTaskDirectoryListResponse: Decodable, Equatable, Sendable {
    /// The normalized absolute path whose children were listed.
    public let currentPath: String

    /// The normalized absolute parent path, or `nil` when ``currentPath`` is `/`.
    public let parentPath: String?

    /// Direct child directories in stable bytewise name order.
    public let entries: [MobileTaskDirectoryListEntry]

    /// The zero-based offset of ``entries`` in the full sorted directory.
    public let offset: Int

    /// The page-size limit applied by the host.
    public let limit: Int

    /// The exact number of directly browsable child directories.
    public let totalCount: Int

    /// The offset for the next page, or `nil` after the final page.
    public let nextOffset: Int?

    /// Creates a directory page after validating its sort and pagination invariants.
    ///
    /// - Parameters:
    ///   - currentPath: The normalized absolute directory path.
    ///   - parentPath: Its absolute parent, or `nil` only for `/`.
    ///   - entries: A complete page in stable bytewise name order.
    ///   - offset: The page's zero-based offset in the full listing.
    ///   - limit: The page-size limit applied by the host.
    ///   - totalCount: The exact number of browsable direct children.
    ///   - nextOffset: The next page offset, or `nil` after the final page.
    /// - Returns: A response, or `nil` when the supplied fields are inconsistent.
    public init?(
        currentPath: String,
        parentPath: String?,
        entries: [MobileTaskDirectoryListEntry],
        offset: Int,
        limit: Int,
        totalCount: Int,
        nextOffset: Int?
    ) {
        guard Self.isValid(
            currentPath: currentPath,
            parentPath: parentPath,
            entries: entries,
            offset: offset,
            limit: limit,
            totalCount: totalCount,
            nextOffset: nextOffset
        ) else {
            return nil
        }
        self.currentPath = currentPath
        self.parentPath = parentPath
        self.entries = entries
        self.offset = offset
        self.limit = limit
        self.totalCount = totalCount
        self.nextOffset = nextOffset
    }

    private enum CodingKeys: String, CodingKey {
        case currentPath = "current_path"
        case parentPath = "parent_path"
        case entries
        case offset
        case limit
        case totalCount = "total_count"
        case nextOffset = "next_offset"
    }

    /// Decodes and validates a paginated directory response.
    ///
    /// - Parameter decoder: The decoder containing the wire response.
    /// - Throws: A decoding error when pagination or entry invariants are inconsistent.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let currentPath = try container.decode(String.self, forKey: .currentPath)
        let parentPath = try container.decodeIfPresent(String.self, forKey: .parentPath)
        let entries = try container.decode(
            MobileTaskDirectoryListEntries.self,
            forKey: .entries
        ).values
        let offset = try container.decode(Int.self, forKey: .offset)
        let limit = try container.decode(Int.self, forKey: .limit)
        let totalCount = try container.decode(Int.self, forKey: .totalCount)
        let nextOffset = try container.decodeIfPresent(Int.self, forKey: .nextOffset)

        guard let response = Self(
            currentPath: currentPath,
            parentPath: parentPath,
            entries: entries,
            offset: offset,
            limit: limit,
            totalCount: totalCount,
            nextOffset: nextOffset
        ) else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: container.codingPath,
                    debugDescription: "Directory-list response fields are inconsistent or outside the wire contract."
                )
            )
        }

        self = response
    }

    /// Decodes and validates a raw directory-list result payload.
    ///
    /// - Parameter data: The JSON result returned by the Mac.
    /// - Returns: A page with internally consistent pagination metadata.
    /// - Throws: A decoding error for malformed, oversized, unsorted, duplicated, or truncated pages.
    public static func decode(_ data: Data) throws -> Self {
        try JSONDecoder().decode(Self.self, from: data)
    }

    private static func isValid(
        currentPath: String,
        parentPath: String?,
        entries: [MobileTaskDirectoryListEntry],
        offset: Int,
        limit: Int,
        totalCount: Int,
        nextOffset: Int?
    ) -> Bool {
        guard MobileTaskDirectoryListEntry.isValidAbsolutePath(currentPath),
              parentPath.map(MobileTaskDirectoryListEntry.isValidAbsolutePath) ?? true,
              (currentPath == "/") == (parentPath == nil),
              offset >= 0,
              (1...MobileTaskDirectoryListRequest.maximumPageSize).contains(limit),
              totalCount >= 0,
              offset <= totalCount,
              entries.count == min(limit, totalCount - offset),
              entries.count <= MobileTaskDirectoryListRequest.maximumPageSize else {
            return false
        }

        let expectedNextOffset = offset + entries.count < totalCount
            ? offset + entries.count
            : nil
        guard nextOffset == expectedNextOffset else { return false }

        var seenPaths = Set<Data>()
        guard entries.allSatisfy({ seenPaths.insert(Data($0.path.utf8)).inserted }) else {
            return false
        }
        let sortedEntries = entries.sorted(by: MobileTaskDirectoryListEntry.precedes)
        return zip(entries, sortedEntries).allSatisfy { actual, sorted in
            Data(actual.name.utf8) == Data(sorted.name.utf8) &&
                Data(actual.path.utf8) == Data(sorted.path.utf8)
        }
    }
}

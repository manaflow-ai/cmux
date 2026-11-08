import Foundation

/// Decodes a directory page without allocating an unbounded entry array first.
struct MobileTaskDirectoryListEntries: Decodable {
    let values: [MobileTaskDirectoryListEntry]

    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var values: [MobileTaskDirectoryListEntry] = []
        values.reserveCapacity(
            min(
                container.count ?? MobileTaskDirectoryListRequest.maximumPageSize,
                MobileTaskDirectoryListRequest.maximumPageSize
            )
        )
        while !container.isAtEnd {
            guard values.count < MobileTaskDirectoryListRequest.maximumPageSize else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Directory-list page exceeds the maximum entry count."
                )
            }
            values.append(try container.decode(MobileTaskDirectoryListEntry.self))
        }
        self.values = values
    }
}

import Foundation
import Testing
@testable import CmuxMobileRPC

@Suite struct MobileTaskDirectoryListDTOTests {
    @Test func requestRejectsInvalidPathsAndPagination() throws {
        #expect(MobileTaskDirectoryListRequest(path: "relative") == nil)
        #expect(MobileTaskDirectoryListRequest(path: "/tmp", offset: -1) == nil)
        #expect(MobileTaskDirectoryListRequest(path: "/tmp", limit: 0) == nil)
        #expect(MobileTaskDirectoryListRequest(path: "/tmp", limit: 101) == nil)

        let request = try #require(MobileTaskDirectoryListRequest(path: "~/Dev"))
        #expect(request.offset == 0)
        #expect(request.limit == MobileTaskDirectoryListRequest.defaultPageSize)

        let invalidData = Data(#"{"path":"relative","offset":0,"limit":50}"#.utf8)
        #expect(throws: DecodingError.self) {
            try MobileTaskDirectoryListRequest.decode(invalidData)
        }
    }

    @Test func responseDecodesExactSortedPagination() throws {
        let data = try Self.responseData(
            entries: [
                Self.entry(name: ".hidden", path: "/Users/test/.hidden", isHidden: true),
                Self.entry(name: "Bundle.app", path: "/Users/test/Bundle.app", isPackage: true),
            ],
            offset: 0,
            limit: 2,
            totalCount: 3,
            nextOffset: 2
        )

        let response = try MobileTaskDirectoryListResponse.decode(data)

        #expect(response.currentPath == "/Users/test")
        #expect(response.parentPath == "/Users")
        #expect(response.entries.map(\.name) == [".hidden", "Bundle.app"])
        #expect(response.entries[0].isHidden)
        #expect(response.entries[1].isPackage)
        #expect(response.nextOffset == 2)
    }

    @Test func responseRejectsSilentTruncationAndOversizedPages() throws {
        let truncated = try Self.responseData(
            entries: [Self.entry(name: "a", path: "/tmp/a")],
            offset: 0,
            limit: 2,
            totalCount: 3,
            nextOffset: 1
        )
        #expect(throws: DecodingError.self) {
            try MobileTaskDirectoryListResponse.decode(truncated)
        }

        let oversizedEntries = (0...MobileTaskDirectoryListRequest.maximumPageSize).map { index in
            Self.entry(
                name: String(format: "%03d", index),
                path: "/tmp/\(String(format: "%03d", index))"
            )
        }
        let oversized = try Self.responseData(
            entries: oversizedEntries,
            offset: 0,
            limit: MobileTaskDirectoryListRequest.maximumPageSize,
            totalCount: oversizedEntries.count,
            nextOffset: MobileTaskDirectoryListRequest.maximumPageSize
        )
        #expect(throws: DecodingError.self) {
            try MobileTaskDirectoryListResponse.decode(oversized)
        }
    }

    @Test func responseRejectsUnsortedAndDuplicateEntries() throws {
        let unsorted = try Self.responseData(
            entries: [
                Self.entry(name: "z", path: "/tmp/z"),
                Self.entry(name: "a", path: "/tmp/a"),
            ],
            offset: 0,
            limit: 2,
            totalCount: 2,
            nextOffset: nil
        )
        #expect(throws: DecodingError.self) {
            try MobileTaskDirectoryListResponse.decode(unsorted)
        }

        let duplicated = try Self.responseData(
            entries: [
                Self.entry(name: "a", path: "/tmp/a"),
                Self.entry(name: "b", path: "/tmp/a"),
            ],
            offset: 0,
            limit: 2,
            totalCount: 2,
            nextOffset: nil
        )
        #expect(throws: DecodingError.self) {
            try MobileTaskDirectoryListResponse.decode(duplicated)
        }
    }

    private static func entry(
        name: String,
        path: String,
        isHidden: Bool = false,
        isPackage: Bool = false,
        isSymbolicLink: Bool = false,
        isReadable: Bool = true
    ) -> [String: Any] {
        [
            "name": name,
            "path": path,
            "is_hidden": isHidden,
            "is_package": isPackage,
            "is_symbolic_link": isSymbolicLink,
            "is_readable": isReadable,
        ]
    }

    private static func responseData(
        entries: [[String: Any]],
        offset: Int,
        limit: Int,
        totalCount: Int,
        nextOffset: Int?
    ) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "current_path": "/Users/test",
            "parent_path": "/Users",
            "entries": entries,
            "offset": offset,
            "limit": limit,
            "total_count": totalCount,
            "next_offset": nextOffset.map { $0 as Any } ?? NSNull(),
        ])
    }
}

import Foundation
import Testing
@testable import CmuxMobileRPC

@Suite struct MobileTaskDirectorySearchResponseTests {
    @Test func decodesBoundedNonemptyPathsWithoutCanonicalizingThem() throws {
        let canonicallyDistinct = ["/tmp/café", "/tmp/cafe\u{301}"]
        let raw = canonicallyDistinct + ["   "] + (0..<80).map { "/tmp/project-\($0)" }
        let data = try JSONEncoder().encode(["directories": raw])

        let response = try MobileTaskDirectorySearchResponse.decode(data)

        #expect(response.directories.count == 64)
        #expect(Array(response.directories.prefix(2)).map { Array($0.utf8) } == canonicallyDistinct.map { Array($0.utf8) })
        #expect(!response.directories.contains("   "))
        #expect(response.searchScope == .legacyBounded)
        #expect(!response.gatheringComplete)
        #expect(!response.filesystemComplete)
        #expect(response.truncated)
        #expect(response.indexedMatchCount == 0)
    }

    @Test func decodesIndexedCoverageWithoutClaimingFilesystemCompleteness() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "directories": ["/Users/test/Dev/cmux", "/Volumes/External/cmux"],
            "search_scope": "all_indexed_volumes",
            "gathering_complete": false,
            "filesystem_complete": false,
            "truncated": true,
            "indexed_match_count": 81,
        ])

        let response = try MobileTaskDirectorySearchResponse.decode(data)

        #expect(response.directories.count == 2)
        #expect(response.searchScope == .allIndexedVolumes)
        #expect(!response.gatheringComplete)
        #expect(!response.filesystemComplete)
        #expect(response.truncated)
        #expect(response.indexedMatchCount == 81)
    }

    @Test func rejectsNegativeIndexedMatchCount() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "directories": [],
            "indexed_match_count": -1,
        ])

        #expect(throws: DecodingError.self) {
            try MobileTaskDirectorySearchResponse.decode(data)
        }
    }

    @Test func rejectsIndexedSearchClaimingCompleteFilesystemCoverage() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "directories": [],
            "search_scope": "all_indexed_volumes",
            "filesystem_complete": true,
        ])

        #expect(throws: DecodingError.self) {
            try MobileTaskDirectorySearchResponse.decode(data)
        }
    }
}

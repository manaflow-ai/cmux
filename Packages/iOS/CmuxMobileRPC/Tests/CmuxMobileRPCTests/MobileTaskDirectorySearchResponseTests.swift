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
    }
}

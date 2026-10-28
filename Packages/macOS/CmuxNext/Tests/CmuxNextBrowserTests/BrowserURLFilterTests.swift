@testable import CmuxNextBrowser
import Foundation
import Testing

/// Chrome's URLBlocklist / URLAllowlist filter format, with the examples of
/// Chrome's admin help (support.google.com/chrome/a/answer/9942583).
@Suite struct BrowserURLFilterTests {
    static func blocks(_ blocklist: [String], _ allowlist: [String], _ url: String) -> Bool {
        BrowserURLFilter(blocklist: blocklist, allowlist: allowlist).blocks(URL(string: url)!)
    }

    static func blocks(_ blocklist: [String], _ url: String) -> Bool {
        blocks(blocklist, [], url)
    }

    @Test func hostMatchesItselfAndSubdomains() {
        #expect(Self.blocks(["example.com"], "https://example.com"))
        #expect(Self.blocks(["example.com"], "http://mail.example.com/inbox"))
        #expect(Self.blocks(["example.com"], "https://EXAMPLE.com./"))
        #expect(!Self.blocks(["example.com"], "https://notexample.com"))
        #expect(!Self.blocks(["example.com"], "https://example.com.evil.org"))
    }

    @Test func leadingDotMatchesOnlyTheHost() {
        #expect(Self.blocks([".example.com"], "https://example.com/a"))
        #expect(!Self.blocks([".example.com"], "https://mail.example.com"))
    }

    @Test func schemePortPathAndQuery() {
        #expect(Self.blocks(["https://*"], "https://a.org"))
        #expect(!Self.blocks(["https://*"], "http://a.org"))
        #expect(Self.blocks(["example.com/path"], "https://example.com/path/more"))
        #expect(!Self.blocks(["example.com/path"], "https://example.com/other"))
        #expect(Self.blocks(["example.com:8080"], "http://example.com:8080/"))
        #expect(!Self.blocks(["example.com:8080"], "http://example.com/"))
        #expect(Self.blocks(["youtube.com/watch?v=V1"], "https://www.youtube.com/watch?v=V1&t=3"))
        #expect(!Self.blocks(["youtube.com/watch?v=V1"], "https://www.youtube.com/watch?v=V2"))
        #expect(Self.blocks(["file://*"], "file:///Users/me/secret.txt"))
        #expect(Self.blocks(["192.168.1.1"], "http://192.168.1.1/admin"))
    }

    /// Block everything except an allowlist: the classic kiosk policy.
    @Test func allowlistIsTheExceptionAndTheMoreSpecificFilterWins() {
        #expect(!Self.blocks(["*"], ["example.com"], "https://docs.example.com/a"))
        #expect(Self.blocks(["*"], ["example.com"], "https://other.org"))
        #expect(Self.blocks(["example.com/private"], ["example.com"], "https://example.com/private/x"))
        #expect(!Self.blocks(["example.com/private"], ["example.com"], "https://example.com/public"))
        #expect(!Self.blocks(["example.com"], ["example.com"], "https://example.com"))  // a tie: allowed
        #expect(!Self.blocks(["example.org/private"], ["example.org/private/handbook"], "https://example.org/private/handbook/1"))
    }

    @Test func cmuxPagesAndBlankAreNeverBlocked() {
        #expect(!Self.blocks(["*"], "about:blank"))
        #expect(!Self.blocks(["*"], "cmux-page://cmux/newtab"))
    }

    @Test func unreadableFiltersAreIgnored() {
        #expect(BrowserURLFilter(blocklist: ["*.example.com", "", "  "], allowlist: []).isEmpty)
        #expect(BrowserURLFilter.none.isEmpty)
        #expect(!Self.blocks([], "https://example.com"))
    }
}

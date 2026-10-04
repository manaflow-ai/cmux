import Testing

@testable import CmuxBrowser

/// `tabs.list` and `history.search` show URLs of tabs other sessions and the
/// user own; their credential values must not reach the session that lists.
@Suite struct BrowserReplListedURLsTests {
    static let signed = "https://user:hunter2@files.example/report.pdf?X-Amz-Signature=s1g&access_token=t0k&page=2"

    static func row(_ url: String = signed) -> [String: Any] {
        ["targetId": "T", "title": "Report", "url": url, "active": false]
    }

    @Test func anotherSessionsTabListsWithoutTheCredentialsInItsURL() throws {
        let listed = BrowserReplListedURLs(reader: "reader").tabRow(Self.row(), creator: "other")
        let url = try #require(listed["url"] as? String)
        for secret in ["hunter2", "s1g", "t0k"] {
            #expect(!url.contains(secret), "\(secret) of another session's tab reached the reader")
        }
        #expect(url.contains("page=2") && url.contains("files.example/report.pdf"))
        #expect(listed["title"] as? String == "Report" && listed["targetId"] as? String == "T")
    }

    @Test func aUsersTabListsWithoutTheCredentialsInItsURL() throws {
        let listed = BrowserReplListedURLs(reader: "reader").tabRow(Self.row(), creator: nil)
        let url = try #require(listed["url"] as? String)
        #expect(!url.contains("hunter2") && !url.contains("s1g") && !url.contains("t0k"), "a user's tab URL kept its credentials: \(url)")
    }

    @Test func theReadersOwnTabKeepsItsURL() {
        let listed = BrowserReplListedURLs(reader: "reader").tabRow(Self.row(), creator: "reader")
        #expect(listed["url"] as? String == Self.signed)
    }

    @Test func historyRowsListWithoutCredentials() throws {
        let row: [String: Any] = ["url": Self.signed, "title": "Report", "dateVisited": 1]
        let listed = BrowserReplListedURLs(reader: "reader").historyRow(row)
        let url = try #require(listed["url"] as? String)
        #expect(!url.contains("hunter2") && !url.contains("s1g") && !url.contains("t0k"), "a history URL kept its credentials: \(url)")
        #expect(listed["dateVisited"] as? Int == 1)
        let plain = BrowserReplListedURLs(reader: "reader").historyRow(["url": "https://app.example/search?q=tea"])
        #expect(plain["url"] as? String == "https://app.example/search?q=tea")
    }
}

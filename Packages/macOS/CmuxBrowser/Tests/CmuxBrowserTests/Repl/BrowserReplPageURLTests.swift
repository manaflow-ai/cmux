import Foundation
import Testing

@testable import CmuxBrowser

/// `tabs.list`, `frames.list` and `history.search` show URLs of tabs other
/// sessions and the user own (``BrowserReplPageURL``); their credential
/// values must not reach the session that lists.
@Suite struct BrowserReplPageURLTests {
    static let signed = "https://user:hunter2@files.example/report.pdf?X-Amz-Signature=s1g&access_token=t0k&page=2"

    /// `row` as `reader` reads it, its URL a page URL of `creator`'s tab.
    static func read(_ row: [String: Any], creator: String?, reader: String = "reader") -> [String: Any] {
        var typed = row
        typed["url"] = BrowserReplPageURL(row["url"] as? String ?? "", creator: creator)
        return JSONSerialization.browserReplObject(BrowserReplDriverOutput(reader: reader).result(typed) ?? "{}")
    }

    static func row(_ url: String = signed) -> [String: Any] {
        ["targetId": "T", "title": "Report", "url": url, "active": false]
    }

    /// A `requestfailed` event's `failure` is WebKit's error text, which
    /// can name a URL other than the request's (a redirect's target, the
    /// URL as the network layer spelled it): its credential values reach
    /// no session but the tab's live creator, as the event's `url` does.
    @Test func aFailureTextReachesOtherSessionsWithoutTheCredentialsOfTheURLsItNames() throws {
        let failure = "The operation couldn\u{2019}t be completed. (https://user:hunter2@cdn.example/x?access_token=t0k&page=2)"
        let payload: [String: Any] = [
            "requestId": "1",
            "url": BrowserReplPageURL("https://files.example/report.pdf", creator: "creator"),
            "failure": failure,
        ]
        for reader in ["reader", "creator"] {
            let event = JSONSerialization.browserReplObject(BrowserReplDriverOutput(reader: reader).event(payload) ?? "{}")
            let text = try #require(event["failure"] as? String)
            #expect(!text.contains("hunter2") && !text.contains("t0k"), "a failure text kept a URL's credentials for \(reader): \(text)")
            #expect(text.contains("cdn.example/x") && text.contains("page=2"))
        }
        // The tab's live creator reads the text as written when the driver
        // typed it for that creator.
        var typed = payload
        typed["failure"] = BrowserReplPageText(failure, creator: "creator")
        let own = JSONSerialization.browserReplObject(BrowserReplDriverOutput(reader: "creator").event(typed) ?? "{}")
        #expect(own["failure"] as? String == failure)
    }

    @Test func anotherSessionsTabListsWithoutTheCredentialsInItsURL() throws {
        let listed = Self.read(Self.row(), creator: "other")
        let url = try #require(listed["url"] as? String)
        for secret in ["hunter2", "s1g", "t0k"] {
            #expect(!url.contains(secret), "\(secret) of another session's tab reached the reader")
        }
        #expect(url.contains("page=2") && url.contains("files.example/report.pdf"))
        #expect(listed["title"] as? String == "Report" && listed["targetId"] as? String == "T")
    }

    @Test func aUsersTabListsWithoutTheCredentialsInItsURL() throws {
        let listed = Self.read(Self.row(), creator: nil)
        let url = try #require(listed["url"] as? String)
        #expect(!url.contains("hunter2") && !url.contains("s1g") && !url.contains("t0k"), "a user's tab URL kept its credentials: \(url)")
    }

    @Test func theReadersOwnTabKeepsItsURL() {
        let listed = Self.read(Self.row(), creator: "reader")
        #expect(listed["url"] as? String == Self.signed)
    }

    @Test func historyRowsListWithoutCredentials() throws {
        let row: [String: Any] = ["url": Self.signed, "title": "Report", "dateVisited": 1]
        let listed = Self.read(row, creator: nil)
        let url = try #require(listed["url"] as? String)
        #expect(!url.contains("hunter2") && !url.contains("s1g") && !url.contains("t0k"), "a history URL kept its credentials: \(url)")
        #expect(listed["dateVisited"] as? Int == 1)
        let plain = Self.read(["url": "https://app.example/search?q=tea"], creator: nil)
        #expect(plain["url"] as? String == "https://app.example/search?q=tea")
    }

    // MARK: frames.list

    static func frameRow(_ url: String = signed) -> [String: Any] {
        ["frameId": "F", "parentFrameId": "main", "url": url, "name": "pay", "crossOrigin": true]
    }

    /// A child frame of a user's tab, or another session's, can carry a
    /// sign-in code or a signed URL as much as its main frame can.
    @Test func aFrameOfAUsersTabListsWithoutTheCredentialsInItsURL() throws {
        for creator in [nil, "other"] as [String?] {
            let listed = Self.read(Self.frameRow(), creator: creator)
            let url = try #require(listed["url"] as? String)
            for secret in ["hunter2", "s1g", "t0k"] {
                #expect(!url.contains(secret), "\(secret) of a frame in a tab the reader did not create reached it")
            }
            #expect(url.contains("page=2") && url.contains("files.example/report.pdf"))
            #expect(listed["frameId"] as? String == "F" && listed["name"] as? String == "pay")
        }
    }

    /// The reader's domain policy keeps it out of a blocked frame, also in
    /// a tab it created: the driver gives that frame's URL no creator, so it
    /// comes without its credentials.
    @Test func aBlockedFrameListsWithoutTheCredentialsInItsURL() throws {
        let listed = Self.read(Self.frameRow(), creator: nil)
        let url = try #require(listed["url"] as? String)
        #expect(!url.contains("hunter2") && !url.contains("s1g") && !url.contains("t0k"), "a blocked frame's URL kept its credentials: \(url)")
    }

    @Test func anAllowedFrameOfTheReadersOwnTabKeepsItsURL() {
        let listed = Self.read(Self.frameRow(), creator: "reader")
        #expect(listed["url"] as? String == Self.signed)
    }
}

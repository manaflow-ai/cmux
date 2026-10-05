import Foundation
import Testing

@testable import CmuxBrowser

/// `tab.info`, `tab.navigate` and `tab.history` answer with the tab's
/// address, and a page's console text and errors can hold URLs. A session
/// reads such a URL as written only where it could read it itself: in a tab
/// it created, or from the main document it may script now (its
/// `location.href`). The address of a blocked page, a page whose script a
/// dialog holds, or a load that never became a document (a redirect's
/// stop) reaches it without its credential values.
@Suite struct BrowserReplTabAddressTests {
    static let callback = "https://user:hunter2@app.example/callback?code=c0de&state=s"

    private func shown(_ url: BrowserReplPageURL, to reader: String) -> String {
        let json = BrowserReplDriverOutput(reader: reader).result(["url": url]) ?? "{}"
        return JSONSerialization.browserReplObject(json)["url"] as? String ?? ""
    }

    @Test("The tab's live creator reads its tab's address as written")
    func creatorReadsTheAddress() {
        let url = BrowserReplPageURL.tabAddress(Self.callback, liveCreator: "me", reader: "me", documentLocation: nil)
        #expect(shown(url, to: "me") == Self.callback)
    }

    @Test("A session that read the main document's location reads that location as written")
    func readableDocumentKeepsItsLocation() {
        let url = BrowserReplPageURL.tabAddress(Self.callback, liveCreator: nil, reader: "me", documentLocation: Self.callback)
        #expect(shown(url, to: "me") == Self.callback)
        #expect(!shown(url, to: "other").contains("c0de"))
    }

    @Test("A user's tab whose document the session cannot read gives its address without credentials")
    func unreadableDocumentIsStripped() {
        let url = BrowserReplPageURL.tabAddress(Self.callback, liveCreator: nil, reader: "me", documentLocation: nil)
        let seen = shown(url, to: "me")
        #expect(!seen.contains("hunter2") && !seen.contains("c0de"), "\(seen)")
        #expect(seen.contains("app.example/callback") && seen.contains("state=s"), "\(seen)")
    }

    @Test("Console text and a page error's stack reach a session that did not create the tab without URL credentials")
    func pageTextIsStrippedForOtherSessions() throws {
        let stack = "boom@\(Self.callback):3:10\nload@https://cdn.example/app.js?sig=abc123:1:1"
        let payload: [String: Any] = [
            "targetId": "T",
            "message": BrowserReplPageText("failed at \(Self.callback)", creator: "creator"),
            "stack": BrowserReplPageText(stack, creator: "creator"),
        ]
        let other = JSONSerialization.browserReplObject(BrowserReplDriverOutput(reader: "other").event(payload) ?? "{}")
        let message = try #require(other["message"] as? String)
        let seenStack = try #require(other["stack"] as? String)
        for secret in ["hunter2", "c0de", "abc123"] {
            #expect(!message.contains(secret) && !seenStack.contains(secret), "\(message) \(seenStack)")
        }
        #expect(message.hasPrefix("failed at https://") && seenStack.contains("cdn.example/app.js"), "\(message) \(seenStack)")
        let creator = JSONSerialization.browserReplObject(BrowserReplDriverOutput(reader: "creator").event(payload) ?? "{}")
        #expect(creator["stack"] as? String == stack)
    }
}

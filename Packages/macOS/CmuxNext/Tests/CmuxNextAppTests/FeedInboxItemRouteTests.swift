@testable import CmuxNextApp
import CmuxNextFeedClient
import Foundation
import Testing

/// Review of #37378: Needs you's request whose own tab is gone opens the Inbox on it. The app
/// names the item in the Inbox route (`item=<id>`, the page's `routeItem` in model.ts), so a new
/// Inbox and one already open select it.
@Suite
struct FeedInboxItemRouteTests {
    func item(_ id: String) throws -> FeedDaemonItem {
        try .wire(#"{"id":"\#(id)","kind":"question","title":"Q","state":"open"}"#)
    }

    @Test func theInboxRouteNamesTheItem() throws {
        #expect(try item("fi_codex_question").inboxRoute == "#/inbox?surface=page&item=fi_codex_question")
    }

    @Test func anIdNeverAddsARouteParameter() throws {
        #expect(try item("a&surface=sidebar+b#c").inboxRoute == "#/inbox?surface=page&item=a%26surface%3Dsidebar%2Bb%23c")
    }
}

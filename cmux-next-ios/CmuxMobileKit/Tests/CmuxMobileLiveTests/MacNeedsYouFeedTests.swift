@testable import CmuxMobileFeed
@testable import CmuxMobileLive
import Foundation
import Testing

/// The Mac app's own Feed requests on the phone (manaflow-ai/cmux#33818): each open request
/// the Mac's host serves (`needs-you`) is a pinned Needs you row that opens its PR, and one the
/// Mac no longer lists (answered, cancelled, the hold came off) leaves the Feed and its push.
@MainActor
@Suite struct MacNeedsYouFeedTests {
    static let held = #"{"id":"fi_held","title":"Spaces switcher","body":"acme/app#30817","kind":"review","source":"GitHub","url":"https://github.com/acme/app/pull/30817","created_at_ms":1700000000000}"#
    static let signIn = #"{"id":"fi_signin","title":"Sign in to GitHub","kind":"signIn","source":"cmux","created_at_ms":1700000001000}"#

    static func message(_ rows: String...) -> Data { Data(#"{"items":[\#(rows.joined(separator: ","))]}"#.utf8) }

    static func turn() -> FeedItem {
        FeedItem(id: "turn", kind: .finished, workspaceID: "w1", tabID: "t", agentName: "Claude", harness: "claude",
                 workspaceTitle: "cmux", markdown: "done", quote: nil, createdAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test func anOpenRequestIsAPinnedRowThatOpensItsLink() throws {
        let store = FeedStore(items: [Self.turn()])
        let feed = MacNeedsYouFeed(store: store)
        feed.apply(Self.message(Self.held), macID: "mac-1")
        let id = MacNeedsYouFeed.itemID(macID: "mac-1", request: "fi_held")
        #expect(store.visibleItems.map(\.id) == [id, "turn"])
        #expect(store.needsYouIDs == [id])
        let item = try #require(store.item(id: id))
        #expect(item.kind == .needsInput)
        #expect(item.macID == "mac-1")
        #expect(item.agentName == "GitHub")
        #expect(item.link == URL(string: "https://github.com/acme/app/pull/30817"))
        #expect(item.markdown == "**Spaces switcher**\n\n[acme/app\\#30817](<https://github.com/acme/app/pull/30817>)")
        #expect(!item.opensTerminal)
    }

    @Test func aRequestTheMacNoLongerListsLeavesTheFeed() {
        let store = FeedStore(items: [])
        let feed = MacNeedsYouFeed(store: store)
        feed.apply(Self.message(Self.held, Self.signIn), macID: "mac-1")
        #expect(store.needsYouIDs.count == 2)
        // The same set again (a re-sent set, a reconnect): the open set stays as it was.
        let before = store.needsYouIDs
        feed.apply(Self.message(Self.held, Self.signIn), macID: "mac-1")
        #expect(store.needsYouIDs == before)
        // The held PR landed: it leaves; the sign-in stays.
        feed.apply(Self.message(Self.signIn), macID: "mac-1")
        #expect(store.needsYouIDs == [MacNeedsYouFeed.itemID(macID: "mac-1", request: "fi_signin")])
        #expect(store.item(id: MacNeedsYouFeed.itemID(macID: "mac-1", request: "fi_held")) == nil)
    }

    /// Its push leaves Notification Center once the Feed knows it closed, never before the
    /// Mac's list was read on the live link.
    @Test func onlyARequestTheMacsLiveListDropsCountsAsClosed() {
        let store = FeedStore(items: [])
        let feed = MacNeedsYouFeed(store: store)
        #expect(!store.isClosedMacRequest(eventID: "feed-fi_held", mac: "mac-1"))
        feed.apply(Self.message(Self.held), macID: "mac-1")
        #expect(!store.isClosedMacRequest(eventID: "feed-fi_held", mac: "mac-1"))
        #expect(!store.isClosedMacRequest(eventID: "feed-fi_held", mac: nil))
        feed.apply(Self.message(), macID: "mac-1")
        #expect(store.isClosedMacRequest(eventID: "feed-fi_held", mac: "mac-1"))
        // Another kind of push is never one of these.
        #expect(!store.isClosedMacRequest(eventID: "p-perm", mac: "mac-1"))
        // The link closed: nothing counts as read until the list comes again.
        feed.linkClosed(macID: "mac-1")
        #expect(!store.isClosedMacRequest(eventID: "feed-fi_held", mac: "mac-1"))
    }

    /// A PR title is anyone's text: it never becomes a link or markup on the row.
    @Test func thePostersTextIsShownNotRendered() throws {
        let store = FeedStore(items: [])
        MacNeedsYouFeed(store: store).apply(Self.message(#"{"id":"fi_x","title":"[pay](https://evil.example) **now**"}"#), macID: "mac-1")
        let item = try #require(store.item(id: MacNeedsYouFeed.itemID(macID: "mac-1", request: "fi_x")))
        #expect(item.markdown == #"**\[pay\]\(https://evil\.example\) \*\*now\*\***"#)
    }

    @Test func aRowWithoutAnHttpsLinkOrATitleIsNotTrusted() {
        let store = FeedStore(items: [])
        let feed = MacNeedsYouFeed(store: store)
        feed.apply(Self.message(#"{"id":"fi_x","title":"X","url":"javascript:alert(1)"}"#, #"{"id":"fi_y"}"#), macID: "mac-1")
        let items = store.visibleItems
        #expect(items.map(\.id) == [MacNeedsYouFeed.itemID(macID: "mac-1", request: "fi_x")])
        #expect(items.first?.link == nil)
    }
}

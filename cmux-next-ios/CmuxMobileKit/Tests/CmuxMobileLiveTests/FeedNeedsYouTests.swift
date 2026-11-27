import CmuxMobileAgentChat
@testable import CmuxMobileFeed
import Foundation
import Testing

/// The Feed's Needs you asks on the iPhone: pinned above the other events (as the Mac's Feed
/// pins its open requests), and the closed asks Notification Center may let go.
@MainActor
@Suite struct FeedNeedsYouTests {
    static func event(_ id: String, ago: TimeInterval, kind: FeedItem.Kind = .finished, mac: String? = "mac-1") -> FeedItem {
        var item = FeedItem(id: id, kind: kind, workspaceID: "w1", tabID: "t", agentName: "Claude", harness: "claude",
                            workspaceTitle: "cmux", markdown: "body", quote: nil,
                            createdAt: Date(timeIntervalSince1970: 1_000_000 - ago))
        item.macID = mac
        return item
    }

    static func ask(_ permissionID: String, ago: TimeInterval, mac: String? = "mac-1") -> FeedItem {
        let request = ACPPermissionRequest(id: permissionID, toolCall: .init(id: "c", title: "rm -rf build", kind: .execute),
                                           options: [ACPPermissionOption(id: "allow", name: "Allow once", kind: .allowOnce)])
        return event("ask-\(permissionID)", ago: ago, kind: .permission(request), mac: mac)
    }

    @Test func openAsksArePinnedAboveNewerEvents() {
        let store = FeedStore(items: [
            Self.event("turn-new", ago: 1), Self.ask("p-old", ago: 30), Self.event("turn-mid", ago: 10),
            Self.ask("p-new", ago: 5), Self.event("terminal", ago: 20, kind: .needsInput),
        ])
        // Asks first, newest first among them; then the rest newest first.
        #expect(store.visibleItems.map(\.id) == ["ask-p-new", "terminal", "ask-p-old", "turn-new", "turn-mid"])
        #expect(store.needsYouIDs == ["ask-p-new", "ask-p-old", "terminal"])
    }

    @Test func aClosedAskLeavesThePinsForItsPlaceInTime() {
        let store = FeedStore(items: [Self.event("turn-new", ago: 1), Self.ask("p1", ago: 30), Self.event("turn-old", ago: 40)])
        #expect(store.visibleItems.map(\.id) == ["ask-p1", "turn-new", "turn-old"])
        store.resolveElsewhere("ask-p1", text: "Answered")
        #expect(store.visibleItems.map(\.id) == ["turn-new", "ask-p1", "turn-old"])
        #expect(store.needsYouIDs.isEmpty)
        #expect(store.needsYouCount == 0)
    }

    @Test func aDoneAskIsNoLongerPinnedOrCounted() {
        let store = FeedStore(items: [Self.event("turn", ago: 1), Self.ask("p1", ago: 30)])
        store.markDone("ask-p1")
        #expect(store.visibleItems.map(\.id) == ["turn"])
        #expect(store.needsYouIDs.isEmpty)
    }

    /// A re-read of the same asks (the Mac re-reports on every tree change, a reconnect reloads
    /// them) leaves the open set as it was, so nothing keyed on it runs again.
    @Test func reReadingTheSameAsksKeepsTheOpenSet() {
        let store = FeedStore(items: [Self.ask("p1", ago: 30)])
        let before = store.needsYouIDs
        store.mergeHistory([Self.ask("p1", ago: 30), Self.event("turn", ago: 1)])
        store.upsert(Self.ask("p1", ago: 30), atTop: true)
        #expect(store.needsYouIDs == before)
    }

    @Test func onlyAnAskTheFeedKnowsClosedCountsAsClosed() {
        let store = FeedStore(items: [Self.ask("open", ago: 5), Self.ask("answered", ago: 10), Self.ask("done", ago: 15),
                                      Self.ask("other-mac", ago: 20, mac: "mac-2")])
        store.resolveElsewhere("ask-answered", text: "Answered")
        store.markDone("ask-done")
        store.resolveElsewhere("ask-other-mac", text: "Answered")
        #expect(!store.isClosedAsk(permissionID: "open", mac: "mac-1"))
        #expect(store.isClosedAsk(permissionID: "answered", mac: "mac-1"))
        #expect(store.isClosedAsk(permissionID: "done", mac: "mac-1"))
        // Not read yet (a reconnect before the Mac's asks reload): never closed.
        #expect(!store.isClosedAsk(permissionID: "unknown", mac: "mac-1"))
        // Another Mac's ask with the same id is not this push's ask.
        #expect(!store.isClosedAsk(permissionID: "other-mac", mac: "mac-1"))
        #expect(store.isClosedAsk(permissionID: "other-mac", mac: "mac-2"))
        // A push without its Mac (an older Worker) matches by id alone.
        #expect(store.isClosedAsk(permissionID: "answered", mac: nil))
    }
}

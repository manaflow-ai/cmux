import AppKit
@testable import CmuxNextFloating
import Foundation
import Testing

/// The Chief pet's notices: the bubble over the pet shows one per tab,
/// newest in front, at most three; the same content never re-animates; a finished turn leaves on
/// its own while a question or failure waits (and counts on the badge) until its tab is read.
@MainActor @Suite(.serialized) struct ChiefPetFeedTests {
    static func notice(_ id: UInt64, tab: String, title: String = "Claude finished", detail: String = "Ready for review",
                       kind: ChiefPetNotice.Kind = .done) -> ChiefPetNotice {
        ChiefPetNotice(id: id, tab: tab, surface: nil, title: title, detail: detail, kind: kind)
    }

    @Test func newestNoticeIsInFrontOnePerTab() {
        var feed = ChiefPetFeed()
        #expect(feed.arrive(Self.notice(1, tab: "a")) == .arrived)
        #expect(feed.arrive(Self.notice(2, tab: "b", title: "Codex finished")) == .arrived)
        #expect(feed.arrive(Self.notice(3, tab: "a", title: "Claude needs approval", kind: .needsYou)) == .arrived)
        #expect(feed.notices.map(\.id) == [3, 2])
        #expect(feed.front?.title == "Claude needs approval")
    }

    @Test func identicalContentDoesNotReanimate() {
        var feed = ChiefPetFeed()
        feed.arrive(Self.notice(1, tab: "a"))
        #expect(feed.arrive(Self.notice(2, tab: "a")) == .unchanged)
        // It keeps the newer id, so the newer notice's expiry applies.
        #expect(feed.notices.map(\.id) == [2])
        // The same content from behind the front comes forward: that is a change.
        feed.arrive(Self.notice(3, tab: "b", title: "Codex finished"))
        #expect(feed.arrive(Self.notice(4, tab: "a")) == .arrived)
    }

    @Test func deckKeepsThreeAndDropsAFinishedOneBeforeOneThatWaits() {
        var feed = ChiefPetFeed()
        feed.arrive(Self.notice(1, tab: "a", kind: .needsYou))
        feed.arrive(Self.notice(2, tab: "b"))
        feed.arrive(Self.notice(3, tab: "c", kind: .failed))
        feed.arrive(Self.notice(4, tab: "d"))
        #expect(feed.notices.map(\.id) == [4, 3, 1], "the finished one goes, the question stays")
        #expect(feed.attention == 2)
    }

    @Test func aFinishedTurnBehindThreeThatWaitShowsNothingNew() {
        var feed = ChiefPetFeed()
        for (id, tab) in [(1, "a"), (2, "b"), (3, "c")] { feed.arrive(Self.notice(UInt64(id), tab: tab, kind: .needsYou)) }
        #expect(feed.arrive(Self.notice(4, tab: "d")) == .unchanged, "the newcomer is the one dropped")
        #expect(feed.notices.map(\.id) == [3, 2, 1])
    }

    @Test func readAndExpiry() {
        var feed = ChiefPetFeed()
        feed.arrive(Self.notice(1, tab: "a", kind: .needsYou))
        feed.arrive(Self.notice(2, tab: "b"))
        feed.expire(id: 1)
        #expect(feed.notices.count == 2, "a notice that waits never expires")
        feed.expire(id: 2)
        #expect(feed.notices.map(\.id) == [1])
        feed.read(tab: "a")
        #expect(feed.notices.isEmpty)
        #expect(feed.attention == 0)
    }

    @Test func bubbleRedrawsOnlyWhenWhatItShowsChanges() {
        let view = ChiefPetBubbleView(frame: NSRect(x: 0, y: 0, width: 330, height: 72))
        let notice = Self.notice(1, tab: "a")
        let other = Self.notice(3, tab: "b", title: "Codex finished")
        #expect(view.show([notice], expanded: false))
        #expect(!view.show([Self.notice(2, tab: "a")], expanded: false), "same content, new id: nothing redraws")
        #expect(view.show([notice, other], expanded: false), "the deck grew")
        #expect(view.show([notice, other], expanded: true), "unfolded")
    }

    @Test func foldedOnlyTheFrontIsATargetUnfoldedEachIs() {
        let view = ChiefPetBubbleView(frame: NSRect(x: 0, y: 0, width: 330, height: ChiefPetBubblePanel.height(count: 2, expanded: true)))
        view.show([Self.notice(1, tab: "a"), Self.notice(2, tab: "b", title: "Codex finished")], expanded: true)
        view.layoutSubtreeIfNeeded()
        let pill = ChiefPetBubblePanel.pillHeight
        #expect(view.capsuleIndex(at: CGPoint(x: 160, y: view.bounds.height - pill / 2)) == 0)
        #expect(view.capsuleIndex(at: CGPoint(x: 160, y: pill / 2)) == 1)
        view.frame.size.height = ChiefPetBubblePanel.height(count: 2, expanded: false)
        view.show([Self.notice(1, tab: "a"), Self.notice(2, tab: "b", title: "Codex finished")], expanded: false)
        view.layoutSubtreeIfNeeded()
        #expect(view.capsuleIndex(at: CGPoint(x: 160, y: 2)) == nil, "the deck's peeking edge opens nothing")
    }

    @Test func heightsMatchTheReferenceDeck() {
        let one: CGFloat = 56, deck: CGFloat = 72, column: CGFloat = 184
        #expect(ChiefPetBubblePanel.height(count: 1, expanded: false) == one)
        #expect(ChiefPetBubblePanel.height(count: 3, expanded: false) == deck, "56 + 2 x 8")
        #expect(ChiefPetBubblePanel.height(count: 5, expanded: true) == column, "three at most: 3 x 56 + 2 x 8")
    }

    @Test func bubbleSitsAboveThePetOrBelowNearTheTop() {
        let visible = CGRect(x: 0, y: 25, width: 1440, height: 850)
        let pet = CGRect(x: 600, y: 100, width: 64, height: 77)
        let above = ChiefPetBubblePanel.frame(height: 62, over: pet, in: visible)
        #expect(above.minY == pet.maxY + ChiefPetBubblePanel.gap)
        #expect(above.minX == pet.minX, "a pet on the left half: the notices extend right from its leading edge")
        let high = CGRect(x: 1400, y: 820, width: 64, height: 77)
        let below = ChiefPetBubblePanel.frame(height: 62, over: high, in: visible)
        #expect(below.maxY <= high.minY)
        #expect(visible.contains(below))
    }

    @Test func chevronUnfoldsTheNoticesAndWithNoneOpensTheChief() {
        let name = "ChiefPetFeedTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        var opened = 0
        let controller = ChiefPetController(makePanel: { ChiefPetPanel(defaults: defaults) },
                                            actions: ChiefPetActions(open: { if $0 == .chief { opened += 1 } }, send: { _, _ in true }))
        defer { controller.sync(false) }
        controller.sync(true)
        controller.panel?.onExpand?()
        #expect(opened == 1, "no notices: the chevron opens the Chief")
        controller.arrive(Self.notice(1, tab: "a", kind: .needsYou))
        controller.arrive(Self.notice(2, tab: "b", title: "Codex finished", kind: .needsYou))
        #expect(controller.bubble?.frame.height == ChiefPetBubblePanel.height(count: 2, expanded: false))
        controller.panel?.onExpand?()
        #expect(controller.expanded)
        #expect(controller.bubble?.frame.height == ChiefPetBubblePanel.height(count: 2, expanded: true))
        controller.panel?.onExpand?()
        #expect(!controller.expanded)
        #expect(opened == 1)
        // Tab "a" was read on another client: its notice and badge go.
        controller.keepNotices { $0 != "a" }
        #expect(controller.feed.notices.map(\.tab) == ["b"])
        #expect(controller.panel?.pet.badge == 1)
    }
}

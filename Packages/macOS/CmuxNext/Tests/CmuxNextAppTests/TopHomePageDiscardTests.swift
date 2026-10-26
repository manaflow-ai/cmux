import AppKit
import CmuxHomeCore
@testable import CmuxNextApp
@testable import CmuxNextHome
import CmuxNextPages
import Foundation
import Testing

/// Classic Home, discarded and built again through its host (p07-memory-023), comes back on the
/// conversation it showed with that conversation's draft, its list where the person left it once the
/// rows are in (they arrive after the page is built), and its search. An unsent New Message, which
/// no store keeps, holds the page; a search does not.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2))) struct TopHomePageDiscardTests {
    static let conversations = (0..<60).map { String(format: "conv_discard_%02d", $0) }

    /// Services whose Home store lists 60 group conversations, in the test's own Chief home (never
    /// a real Chief's cache).
    static func services() async throws -> AppServices {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("top-home-discard-\(UUID().uuidString)", isDirectory: true)
        let services = HomeChiefHostedSettingsTests.withChiefHome(root) {
            let made = HomeChiefHostedSettingsTests.services()
            _ = made.home
            return made
        }
        let me = services.home.homeSource.me
        let date = Date(timeIntervalSince1970: 1_000)
        let summaries = conversations.enumerated().map { index, id in
            let people = (0..<2).map {
                Participant(id: ParticipantID("user_\(index)_\($0)"), kind: .human, displayName: "Person \(index) \($0)")
            }
            return CmuxHomeCore.ConversationSummary(id: ConversationID(id), owner: .local, title: "Group \(index)",
                                                    participants: [me] + people, createdAt: date,
                                                    updatedAt: date.addingTimeInterval(Double(index)))
        }
        services.home.homeSource.publish(.inbox(InboxSnapshot(me: me, conversations: summaries, rev: 1)))
        services.home.homeStore.start()
        let listed = await HomeChiefHostedSettingsTests.eventually { services.home.homeStore.rows.count >= conversations.count }
        try #require(listed, "the Home store does not list the test's conversations")
        return services
    }

    static func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    @Test func aReleasedHomeComesBackOnItsConversationDraftAndListScroll() async throws {
        let services = try await Self.services()
        let window = Self.window()
        defer { window.orderOut(nil) }
        let container = try #require(window.contentView)
        var at = ContinuousClock.now
        let make: (TopPageRoute, WindowController?) -> (view: NSView, key: String?)? = { route, _ in
            guard route == .home else { return nil }
            return (view: TopHomePageView(services: services, windowKey: { "top-home-discard" }), key: nil)
        }
        let host = TopPageHost(make: make, closed: { _, _ in }, discardable: { _, view in view as? TopHomePageView },
                               title: { $0.rawValue }, discards: true, hiddenLimit: 8, hosts: { [] }, deadline: ManualDeadline())
        host.now = { at }
        let first = try #require(host.view(for: .home, in: nil) as? TopHomePageView)
        first.frame = container.bounds
        container.addSubview(first)
        host.contentDidChange(shown: first)
        let filled = await HomeChiefHostedSettingsTests.eventually { first.rows.count >= Self.conversations.count }
        try #require(filled, "the page never listed the conversations")
        first.layoutSubtreeIfNeeded()
        let chosen = ConversationID(Self.conversations[7])
        first.show(chosen)
        services.home.homeStore.setDraft("half a thought", for: chosen)
        first.list.scroll(to: CGPoint(x: 0, y: 400))
        let scrolled = first.list.scrollOrigin
        try #require(scrolled.y > 0, "the list is too short to scroll")
        #expect(!first.holdsUnsavedInput(first))

        // Hidden past its timeout and out of the window: the host releases it, as its deadline does.
        first.removeFromSuperview()
        host.contentDidChange(shown: nil)
        at = at.advanced(by: .seconds(601))
        #expect(host.release(.home, for: .proactive), "a hidden Home with nothing unsent stayed")
        #expect(host.views[.home] == nil)
        #expect(host.homeSelection == chosen, "the released Home forgot its conversation")

        let second = try #require(host.view(for: .home, in: nil) as? TopHomePageView)
        #expect(second !== first)
        second.frame = container.bounds
        container.addSubview(second)
        host.contentDidChange(shown: second)
        host.didShow(.home)
        #expect(second.shown == chosen, "the rebuilt Home opened on another conversation")
        #expect(services.home.homeStore.draft(for: chosen) == "half a thought", "the conversation's draft went with the page")
        if second.rows.isEmpty {
            #expect(second.pendingListScroll == scrolled, "the list's scroll was applied before its rows")
        }
        let restored = await HomeChiefHostedSettingsTests.eventually { second.list.scrollOrigin == scrolled }
        #expect(restored, "the rebuilt list did not scroll back once its rows were in")
        #expect(second.pendingListScroll == nil)
        #expect(second.shown == chosen, "the rows' arrival moved the rebuilt Home to its default conversation")
    }

    @Test func theSearchComesBackAndAnUnsentNewMessageHoldsThePage() async throws {
        let services = try await Self.services()
        let window = Self.window()
        defer { window.orderOut(nil) }
        let page = TopHomePageView(services: services, windowKey: { "top-home-discard" })
        window.contentView = page
        page.list.setSearch("Group 1")
        var state = PageViewState(of: page)
        page.saveViewState(page, into: &state)
        #expect(state.search == "Group 1")
        #expect(!page.holdsUnsavedInput(page), "a search, which the record keeps, held the page")

        let again = TopHomePageView(services: services, windowKey: { "top-home-discard" })
        again.restoreViewState(state, in: again)
        #expect(again.list.searchQuery == "Group 1", "the rebuilt Home lost its search")

        page.presentNewMessage()
        #expect(!page.holdsUnsavedInput(page), "an untouched New Message held the page")
        var draft = HomeNewMessageDraft()
        draft.query = "ada"
        page.newMessage?.field.setDraft(draft)
        #expect(page.holdsUnsavedInput(page), "an unsent New Message, which no store keeps, did not hold the page")
    }
}

@MainActor
private final class ManualDeadline: PageDiscardDeadline {
    func arm(after delay: Duration, _ action: @escaping @MainActor () -> Void) {}
    func disarm() {}
}

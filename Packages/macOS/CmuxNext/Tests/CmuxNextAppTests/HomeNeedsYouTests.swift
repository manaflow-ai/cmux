import AppKit
import CmuxHomeCore
@testable import CmuxNextApp
@testable import CmuxNextFeed
@testable import CmuxNextHome
import CmuxNextTestSupport
import Foundation
import Testing

/// Chief Home's pinned Needs you section (Leo, via his Chief: "a pinned Needs you view in Chief
/// Home, Feed and iPhone listing items waiting on Leo"): it lists exactly the Feed's open
/// requests, in the order the Feed pins them, from the Feed's own model (no second store); it
/// shows only in a Chief's conversation and only while something waits; it sits under the header
/// over the transcript, so showing or hiding it moves no message.
@MainActor @Suite(.serialized, .closesItsWindows) struct HomeNeedsYouTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func request(_ id: String, ago minutes: Double, priority: FeedPriority? = nil,
                         state: FeedItemState = .open) -> FeedItem {
        FeedItem(id: id, title: "Allow \(id)?",
                 prompt: .approve(.init(action: .init(type: .command, summary: "Run", command: "make \(id)"))),
                 priority: priority, context: FeedContext(acpSession: "ses_\(id)"),
                 poster: FeedPoster(kind: .harness, label: "api-server", harness: "Claude Code"), state: state,
                 createdAt: now.addingTimeInterval(-minutes * 60))
    }

    private func notice(_ id: String, ago minutes: Double) -> FeedItem {
        FeedItem(id: id, title: "Finished \(id)", poster: FeedPoster(kind: .agent, label: "Agent"),
                 createdAt: now.addingTimeInterval(-minutes * 60))
    }

    private func feed(_ items: [FeedItem]) -> (FeedModel, InMemoryFeedSource) {
        let source = InMemoryFeedSource(snapshot: FeedSnapshot(revision: 1, user: "usr_me", device: "Mac", items: items))
        let model = FeedModel(source: source, clock: { [now] in now })
        model.start()
        return (model, source)
    }

    /// Lets main-actor tasks run until `condition` holds (bounded).
    private func until(_ condition: () -> Bool) async {
        var tries = 0
        while !condition(), tries < 400 {
            tries += 1
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func itListsExactlyTheFeedsOpenRequestsInTheFeedsOrder() {
        let (model, _) = feed([
            request("a", ago: 5), notice("n", ago: 0), request("b", ago: 10, priority: .high),
            request("c", ago: 1, state: .answered), request("d", ago: 1),
        ])
        // The Feed's own pinned order (FeedListKey: priority, then newest); no notice, no answered one.
        let pinned = model.listSections.requests.map(\.id)
        #expect(Set(pinned) == ["a", "b", "d"])
        #expect(model.needsYou.map(\.id) == pinned)
        let section = FeedNeedsYouView(model: model)
        #expect(section.shownIDs == pinned)
        #expect(section.moreCount == 0)
        #expect(!section.isEmpty)
    }

    @Test func pastItsRowsTheRestAreCountedNotDropped() {
        let (model, _) = feed((0..<5).map { request("r\($0)", ago: Double($0)) })
        let section = FeedNeedsYouView(model: model, limit: 3)
        #expect(section.shownIDs == ["r0", "r1", "r2"])
        #expect(section.moreCount == 2)
    }

    @Test func itHidesWhenNothingWaitsAndFollowsAnAnswer() async {
        let (empty, _) = feed([notice("n", ago: 0)])
        #expect(empty.needsYou.isEmpty)
        #expect(FeedNeedsYouView(model: empty).isEmpty)

        let (model, _) = feed([request("a", ago: 1), notice("n", ago: 0)])
        let section = FeedNeedsYouView(model: model)
        #expect(section.shownIDs == ["a"])
        // The Feed's own answer path (an Allow click on the row): the owner closes it, the row goes.
        model.answer("a", .approve(.init(.allow)))
        await until { model.needsYou.isEmpty }
        #expect(model.needsYou.isEmpty)
        #expect(section.isEmpty)
        #expect(section.shownIDs.isEmpty)
    }

    @Test func onlyAChiefsConversationShowsItAndOnlyWhileSomethingWaits() {
        #expect(FeedNeedsYouPin.shows(isChief: true, waiting: 1))
        #expect(!FeedNeedsYouPin.shows(isChief: true, waiting: 0))
        #expect(!FeedNeedsYouPin.shows(isChief: false, waiting: 3))
    }

    @Test func thePinnedSectionSitsUnderTheHeaderAndMovesNoMessage() async throws {
        let source = EmptyChiefSource()
        let id = ConversationID("conv_chief")
        let inbox = try await source.inbox()
        let store = HomeStore(source: source)
        store.start()
        let view = HomeNativeTranscriptView(store: store, conversation: id, me: inbox.me.id)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 800), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { view.stop(); store.stop(); window.close() }
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 800)
        window.contentView = view
        await view.binding.opened()
        view.layoutSubtreeIfNeeded()
        let transcriptFrame = view.transcript.frame
        #expect(view.pinnedSection == nil)

        let (model, _) = feed([request("a", ago: 1)])
        let section = FeedNeedsYouView(model: model)
        view.setPinnedSection(section)
        view.layoutSubtreeIfNeeded()
        #expect(view.pinnedSection === section)
        #expect(section.superview === view)
        #expect(section.frame.minY >= view.headerHeight, "under the header: \(section.frame) header \(view.headerHeight)")
        #expect(section.frame.height > 0)
        #expect(section.frame.maxY < view.transcript.fieldTop, "above the message box")
        #expect(view.transcript.frame == transcriptFrame, "the transcript keeps its frame: nothing shifts")

        view.setPinnedSection(nil)
        view.layoutSubtreeIfNeeded()
        #expect(view.pinnedSection == nil)
        #expect(section.superview == nil)
        #expect(view.transcript.frame == transcriptFrame)
    }
}

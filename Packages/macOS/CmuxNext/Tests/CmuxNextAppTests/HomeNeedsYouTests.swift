import AppKit
import CmuxHomeCore
@testable import CmuxNextApp
@testable import CmuxNextFeed
@testable import CmuxNextHome
import CmuxNextSettings
import CmuxNextTestSupport
import Foundation
import Observation
import Testing

/// Chief Home's pinned Needs you section (Leo, via his Chief: "a pinned Needs you view in Chief
/// Home, Feed and iPhone listing items waiting on Leo"): it lists exactly the Feed's open
/// requests, in the order the Feed pins them, from the Feed's own model (no second store); it
/// shows only in a Chief's conversation and only while something waits; it sits under the header
/// over the transcript, so showing or hiding it moves no message. It is opt-in (Leo 2026-11-03: "I just
/// wanted to see permission things, period, not a pinned thing by default. Toggle-on, yes"): off by
/// default (`feed.needsYouInChief`), nothing is pinned and the Feed still lists the requests.
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
        #expect(FeedNeedsYouPin.shows(isChief: true, enabled: true, waiting: 1))
        #expect(!FeedNeedsYouPin.shows(isChief: true, enabled: true, waiting: 0))
        #expect(!FeedNeedsYouPin.shows(isChief: false, enabled: true, waiting: 3))
        #expect(!FeedNeedsYouPin.shows(isChief: true, enabled: false, waiting: 3), "off: nothing pinned")
    }

    @Test func itIsOffByDefaultAndTheSettingTurnsItOn() throws {
        #expect(HomeNeedsYouSetting.fallback == false)
        let unset = CmuxConfigSnapshot.parse(.object([:]), validDensities: [], validMetrics: [])
        #expect(unset.homeNeedsYouInChief == false, "unset cmux.json: no pinned card")
        let on = CmuxConfigSnapshot.parse(try JSONValue.parse(Data(#"{"feed":{"needsYouInChief":true}}"#.utf8)),
                                          validDensities: [], validMetrics: [])
        #expect(on.homeNeedsYouInChief == true)
        let row = try #require(SettingsSchema.descriptor(for: HomeNeedsYouSetting.configPath))
        #expect(row.defaultValue == .bool(false), "Settings shows it off by default")
    }

    @Test func offPinsNothingAndOnPinsTheFeedsRequestsLive() async {
        let (model, _) = feed([request("a", ago: 1)])
        let host = PinHost(), toggle = PinToggle()
        let pin = FeedNeedsYouPin(model: model, isEnabled: { toggle.on }, prepare: {}, reveal: { _ in false }, showFeed: {})
        let watch = pin.watch(host: host)
        defer { watch.cancel() }
        await until { host.updates > 0 }
        #expect(host.pinnedSection == nil, "off by default: nothing pinned while a request waits")
        #expect(model.needsYou.map(\.id) == ["a"], "the Feed still lists the request")
        toggle.on = true // the app's setting is observable the same way, so turning it on pins at once
        await until { host.pinnedSection != nil }
        #expect((host.pinnedSection as? FeedNeedsYouView)?.shownIDs == ["a"])
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
        // The oldest message can still scroll out from under the card (Codex review, #33817).
        #expect(view.transcript.rowsTopClearance >= section.frame.maxY - view.headerHeight)

        view.setPinnedSection(nil)
        view.layoutSubtreeIfNeeded()
        #expect(view.pinnedSection == nil)
        #expect(section.superview == nil)
        #expect(view.transcript.rowsTopClearance == 0)
        #expect(view.transcript.frame == transcriptFrame)
    }
}

/// A stand-in for `feed.needsYouInChief` (the app reads it from the observable settings snapshot).
@MainActor @Observable private final class PinToggle { var on = false }

/// A stand-in for Chief Home's transcript: records what the pin puts under its header.
@MainActor private final class PinHost: FeedPinnedSectionHost {
    private(set) var pinnedSection: NSView?
    private(set) var updates = 0
    func setPinnedSection(_ view: NSView?) { pinnedSection = view; updates += 1 }
    func pinnedSectionDidResize() {}
}

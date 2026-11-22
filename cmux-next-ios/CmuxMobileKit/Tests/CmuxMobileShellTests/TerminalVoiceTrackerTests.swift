#if os(iOS)
import CmuxMobileFeed
import Foundation
import Testing
@testable import CmuxMobileShell

/// What voice mode reads of a terminal agent's Feed: only its new, open events.
@MainActor
@Suite struct TerminalVoiceTrackerTests {
    static let start = Date(timeIntervalSince1970: 1_000_000)

    static func item(_ id: String, _ kind: FeedItem.Kind, _ markdown: String, tab: String = "t1", at offset: TimeInterval = 10) -> FeedItem {
        FeedItem(id: id, kind: kind, workspaceID: "w1", tabID: tab, agentName: "Codex", harness: "codex",
                 workspaceTitle: "cmux", markdown: markdown, quote: nil, createdAt: start.addingTimeInterval(offset))
    }

    @Test func readsNewRepliesOfThisTabWithoutCode() {
        var tracker = TerminalVoiceTracker(workspaceID: "w1", tabID: "t1")
        tracker.baseline([Self.item("old", .response, "Old reply.", at: -60)], now: Self.start)
        let items = [
            Self.item("r1", .response, "Fixed it.\n```diff\n-a\n+b\n```"),
            Self.item("other", .response, "Another tab.", tab: "t2"),
            Self.item("old", .response, "Old reply.", at: -60),
        ]
        #expect(tracker.newSpeech(in: items) == ["Fixed it."])
        #expect(tracker.newSpeech(in: items).isEmpty)
    }

    @Test func historyMergedLaterAndResolvedItemsAreNotRead() {
        var tracker = TerminalVoiceTracker(workspaceID: "w1", tabID: "t1")
        tracker.baseline([], now: Self.start)
        var resolved = Self.item("p1", .finished, "Done.")
        resolved.isDone = true
        let items = [Self.item("h1", .response, "From an hour ago.", at: -3600), resolved]
        #expect(tracker.newSpeech(in: items).isEmpty)
    }

    @Test func aFinishThatRepeatsTheReplyIsSaidOnce() {
        var tracker = TerminalVoiceTracker(workspaceID: "w1", tabID: "t1")
        tracker.baseline([], now: Self.start)
        let items = [Self.item("r1", .response, "All tests pass.", at: 10), Self.item("f1", .finished, "All tests pass.", at: 11)]
        #expect(tracker.newSpeech(in: items) == ["All tests pass."])
    }
}
#endif

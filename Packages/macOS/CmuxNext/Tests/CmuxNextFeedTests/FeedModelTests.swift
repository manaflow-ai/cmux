@testable import CmuxNextFeed
import Foundation
import Testing

/// 2026-10-02 15:00 UTC: every seeded "today" item is on this UTC day.
let feedTestNow = Date(timeIntervalSince1970: 1_791_039_600)

@MainActor
func startedFeed(echo: Bool = true) -> (FeedModel, MockFeedSource) {
    let source = MockFeedSource(now: feedTestNow)
    source.echoImmediately = echo
    let model = FeedModel(source: source, clock: { feedTestNow })
    model.start()
    return (model, source)
}

@MainActor
struct FeedModelTests {
    @Test func pendingAnswerIsVisibleAndNeverWritesTheMirror() {
        let (model, _) = startedFeed(echo: false)
        model.answer("fi_claude_rm_build", .approve(.init(.allow, scope: .session)))
        #expect(model.pending.count == 1)
        let visible = model.item("fi_claude_rm_build")
        #expect(visible?.state == .answered)
        #expect(visible?.answer?.device == "MacBook Pro")
        #expect(model.confirmed["fi_claude_rm_build"]?.state == .open, "intents never write the mirror")
        #expect(model.isPending("fi_claude_rm_build"))
    }

    @Test func theEchoRemovesTheIntentBeforeTheSettleLine() {
        let source = ScriptedFeedSource()
        let model = FeedModel(source: source, clock: { feedTestNow })
        model.start()
        source.emit(.snapshot(FeedSnapshot(revision: 1, user: "usr_me", device: "Mac", items: [Self.openApprove])))
        let intent = model.answer("fi_a", .approve(.init(.deny)))
        #expect(model.pending.count == 1)
        var echoed = Self.openApprove
        echoed.state = .answered
        echoed.revision = 2
        echoed.answer = FeedAnswerRecord(value: .approve(.init(.deny)), by: "usr_me", device: "Mac", at: feedTestNow)
        source.emit(.event(FeedEvent(revision: 2, tx: intent?.key, change: .items([echoed]))))
        #expect(model.pending.isEmpty)
        #expect(model.confirmed["fi_a"]?.state == .answered)
        #expect(model.item("fi_a") == model.confirmed["fi_a"])
    }

    @Test func aRejectRestoresTheMirrorState() {
        let (model, source) = startedFeed(echo: false)
        model.decline("fi_codex_question")
        #expect(model.item("fi_codex_question")?.state == .cancelled)
        source.rejectKeys = Set(model.pending.map(\.key))
        source.deliverHeld()
        #expect(model.pending.isEmpty)
        #expect(model.item("fi_codex_question")?.state == .open)
        #expect(model.lastReject == .other("rejected by the owner"))
    }

    @Test func aLateAnswerShowsTheClosedState() {
        let (model, source) = startedFeed(echo: false)
        model.answer("fi_codex_edit", .approve(.init(.allow)))
        // The iPhone answered first; its event reaches this Mac while the
        // Mac's own answer is still pending.
        source.answerElsewhere("fi_codex_edit", value: .approve(.init(.deny)), device: "iPhone", at: feedTestNow)
        #expect(model.pending.count == 1)
        #expect(model.item("fi_codex_edit")?.answer?.device == "iPhone", "a pending answer never hides the owner's answer")
        source.deliverHeld()
        #expect(model.pending.isEmpty)
        #expect(model.lastReject?.closedItem?.answer?.device == "iPhone")
        #expect(model.item("fi_codex_edit")?.answer?.value == .approve(.init(.deny)))
    }

    @Test func anAnswerToAClosedItemIsNotSent() {
        let (model, _) = startedFeed(echo: false)
        #expect(model.answer("fi_expired_npm", .approve(.init(.allow))) == nil)
        #expect(model.pending.isEmpty)
        #expect(model.lastReject?.closedItem?.state == .expired)
    }

    @Test func nothingQueuesWhileDisconnected() {
        let (model, source) = startedFeed()
        source.disconnect()
        #expect(model.answer("fi_claude_rm_build", .approve(.init(.allow))) == nil)
        #expect(model.pending.isEmpty)
        #expect(model.lastReject == .disconnected)
    }

    @Test func openRequestsCannotBeArchivedOrSnoozed() {
        let (model, _) = startedFeed(echo: false)
        model.archive(["fi_claude_rm_build"])
        model.snooze(["fi_passkey_github"], for: 3_600)
        #expect(model.pending.isEmpty)
        model.archive(["fi_status_run"])
        #expect(model.pending.count == 1)
        #expect(model.item("fi_status_run")?.isArchived == true)
    }

    @Test func markAllReadReadsEveryUnreadItemInOneIntent() {
        let (model, source) = startedFeed(echo: false)
        #expect(model.counts.unreadNotices > 0)
        model.markAllRead()
        #expect(model.pending.count == 1)
        #expect(model.visibleItems.allSatisfy { !$0.isUnread })
        source.deliverHeld()
        #expect(model.pending.isEmpty)
        #expect(model.confirmed.values.allSatisfy { !$0.isUnread })
    }

    @Test func selectingAnItemReadsIt() {
        let (model, _) = startedFeed(echo: false)
        model.select("fi_github_review")
        #expect(model.selection == "fi_github_review")
        #expect(model.item("fi_github_review")?.isUnread == false)
    }

    /// Invariant 4 (projection convergence), seeded: random intents, random
    /// rejects and remote answers, random delivery points; once the log is
    /// empty, the visible state equals the mirror.
    @Test(arguments: 0..<30)
    func convergesWhenTheIntentLogIsEmpty(seed: UInt64) {
        var rng = SplitMix(seed: seed)
        let (model, source) = startedFeed(echo: false)
        let ids = model.confirmed.keys.sorted()
        for _ in 0..<25 {
            let id = ids[Int(rng.next() % UInt64(ids.count))]
            switch rng.next() % 5 {
            case 0: model.answer(id, .approve(.init(.allow)))
            case 1: model.decline(id)
            case 2: model.markRead([id])
            case 3: model.archive([id])
            default: source.answerElsewhere(id, value: .text("x"), device: "iPhone", at: feedTestNow)
            }
            if rng.next() % 4 == 0, let key = model.pending.last?.key { source.rejectKeys.insert(key) }
            if rng.next() % 3 == 0 { source.deliverHeld() }
        }
        source.deliverHeld()
        #expect(model.pending.isEmpty)
        #expect(model.visibleItems == model.confirmed.values.sorted(by: FeedOrder.newest))
    }

    static let openApprove = FeedItem(
        id: "fi_a", title: "Run make?",
        prompt: .approve(.init(action: .init(type: .command, summary: "make", command: "make"))),
        poster: FeedPoster(kind: .agent, label: "repo", harness: "Codex"), createdAt: feedTestNow)
}

/// A source the test drives event by event.
@MainActor
final class ScriptedFeedSource: FeedSource {
    private var sink: (@MainActor (FeedSourceEvent) -> Void)?
    private(set) var sent: [FeedIntent] = []

    func start(_ sink: @escaping @MainActor (FeedSourceEvent) -> Void) {
        self.sink = sink
        sink(.connection(.connected))
    }

    func send(_ intent: FeedIntent) { sent.append(intent) }
    func stop() { sink = nil }
    func emit(_ event: FeedSourceEvent) { sink?(event) }
}

struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

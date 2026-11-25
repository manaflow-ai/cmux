import AppKit
@testable import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// A streamed token costs Home's main thread nothing it cannot show (HOT PATH AUDIT, area F,
/// handoff/hot-path-audit/stream/AUDIT.md). Home's default is whole messages
/// (`HomeReplyDisplay.wholeMessages`, 0c0b107df48): while the Chief's reply streams the person
/// sees the Chief's typing dots and its activity line, and the reply only when it is posted. So a
/// talk token changes nothing on screen, and the floor of its main-thread work is the store's
/// append of the token: no projection pass, in any open Home view, however long the transcript.
///
/// The real view (`MessagesLabHomeView`) over a real `HomeStore` on the mock owner with a
/// 2,000-message history, the Chief's live run driven through the store's live path
/// (`chief-live-v1` deltas, `HomeLiveBook`), one view and then four views of the conversation open
/// (four Home tabs). Each token is the store's event, then each open view's observed pass (what
/// its store observation runs on the next main turn). `HOMETOKEN` lines carry the main-thread
/// time per token.
@MainActor @Suite(.serialized) struct HomeWholeMessageTokenCostTests {
    static let tokens = 1_500

    private static func line(_ name: String, _ xs: [Double]) -> String {
        String(format: "HOMETOKEN %@ n %d p50 %.4f p95 %.4f p99 %.4f max %.3f ms", name, xs.count,
               HomeStreamingPerfTests.p(xs, 0.5), HomeStreamingPerfTests.p(xs, 0.95),
               HomeStreamingPerfTests.p(xs, 0.99), xs.max() ?? 0)
    }

    @Test(arguments: [1, 4])
    func aTalkTokenRunsNoProjectionPassInWholeMessageMode(views count: Int) async throws {
        let rig = try await HomeChatRig(history: 2_000, replies: .wholeMessages)
        defer { rig.stop() }
        var extra: [MessagesLabHomeView] = []
        for _ in 1..<count {
            let view = MessagesLabHomeView(store: rig.store, conversation: HomeChatRig.conversation, me: rig.me,
                                           wake: HomeChatRig.NoWake(), replies: .wholeMessages)
            view.frame = NSRect(x: 0, y: 0, width: 700, height: 900)
            view.layoutSubtreeIfNeeded()
            extra.append(view)
        }
        defer { for view in extra { view.stop() } }
        let views = [rig.view] + extra
        // The run starts: its first token puts up the Chief's typing dots (one pass per view).
        rig.delta("token_cost", seq: 0, "\(HomeChatRig.tag)Here is the plan.")
        for view in views { view.projection.observedPass() }
        rig.frame()
        // The views' store observations run in their own main-actor tasks.
        for _ in 0..<4 { await Task.yield() }
        let before = views.map(\.projection.refreshPasses)
        let wakesBefore = views.map(\.projection.observedWakes)
        let words = HomeStreamingPerfTests.replyTokens(count: Self.tokens)
        var store: [Double] = [], passes: [Double] = [], total: [Double] = []
        for (index, word) in words.enumerated() {
            let t0 = CACurrentMediaTime()
            rig.delta("token_cost", seq: UInt64(index + 1), word)
            let t1 = CACurrentMediaTime()
            // What a wake costs each view (its observation runs this pass when the token wakes it).
            for view in views { view.projection.observedPass() }
            let t2 = CACurrentMediaTime()
            store.append((t1 - t0) * 1_000)
            passes.append((t2 - t1) * 1_000)
            total.append((t2 - t0) * 1_000)
            // The real path: each view's store observation, if the token woke it.
            for _ in 0..<3 { await Task.yield() }
        }
        let after = views.map(\.projection.refreshPasses)
        let ran = zip(after, before).map { $0 - $1 }.reduce(0, +)
        let woke = zip(views.map(\.projection.observedWakes), wakesBefore).map { $0 - $1 }.reduce(0, +)
        let reply = rig.store.liveRun(in: HomeChatRig.conversation)?.text.utf8.count ?? 0
        print(Self.line("views=\(count) store", store))
        print(Self.line("views=\(count) passes", passes))
        print(Self.line("views=\(count) total", total))
        print("HOMETOKEN views=\(count) tokens \(Self.tokens) refreshPasses \(ran) wakes \(woke) replyBytes \(reply) history \(rig.store.transcript(for: HomeChatRig.conversation).count)")
        #expect(woke == 0, "\(woke) store observation wakes for \(Self.tokens) talk tokens in \(count) whole-message view(s)")
        #expect(ran == 0, "\(ran) projection passes for \(Self.tokens) talk tokens in \(count) whole-message view(s): none shows a token")
    }

    /// A turn that starts with thinking (most Chief turns): before the run has reply text or an
    /// activity line nothing shows for it, so its thought tokens wake no view either
    /// (review of #33945: an empty shape was written over no shape on every thought token).
    @Test func thoughtTokensBeforeAnyReplyWakeNoWholeMessageView() async throws {
        let rig = try await HomeChatRig(history: 200, replies: .wholeMessages)
        defer { rig.stop() }
        rig.frame()
        for _ in 0..<4 { await Task.yield() }
        let wakesBefore = rig.view.projection.observedWakes
        for seq in 0..<200 {
            rig.store.handle(.live(.delta(HomeLiveDelta(
                conversation: HomeChatRig.conversation, author: rig.chief, run: "thinking_first", step: "thought",
                isTalk: false, seq: UInt64(seq), text: seq == 0 ? "Reading the branch" : " and more", isFinal: false))))
            for _ in 0..<3 { await Task.yield() }
        }
        let woke = rig.view.projection.observedWakes - wakesBefore
        print("HOMETOKEN thought tokens 200 wakes \(woke)")
        #expect(woke == 0, "\(woke) store observation wakes for 200 thought tokens before any reply text")
    }
}

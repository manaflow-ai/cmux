import CmuxHomeCore
import Foundation
import QuartzCore
import Testing
@testable import MessagesLabHome

/// The Dock showed "Application Not Responding" for cmux NIGHTLY while it still worked (Lawrence,
/// 2026-10-29 10:03 PM). A trace of that app (pid 4499, 240 s): its longest main-thread stalls,
/// 418 ms and 335 ms, were `HomeProjection.refresh` -> `HomeDiff.plan`, which mapped every shown
/// row again (`HomeMapping.projectedParts`: link detection with `NSDataDetector`, Markdown) on each
/// store change, though only one row changed. Main-thread stalls like these delay the Dock's
/// request for the app's menu past its deadline.
///
/// The rule: one store change costs about one row, not the whole transcript. A diff over 400
/// shown rows where one message arrives costs less than three times the same diff over 40 rows
/// (2 ms at least: comparing 400 unchanged rows is not free), and under 30 ms. The old diff cost about ten times as much at 400 rows (linear in the rows).
@MainActor @Suite(.serialized) struct HomeDiffCostTests {
    static let me = ParticipantID("user_me")
    static let chief = ParticipantID("agent_chief")
    static let base = Date(timeIntervalSince1970: 1_800_000_000)

    /// A Chief-shaped reply: Markdown with an inline link, a bare URL line and a list.
    static func text(_ i: Int) -> String {
        """
        ## Step \(i): land the fix

        The run is green on [run \(i)](https://github.com/manaflow-ai/cmux/actions/runs/\(40_000_000 + i)).
        https://github.com/manaflow-ai/cmux/commit/\(String(repeating: "a", count: 32))\(i)
        - checked `feat-cmux-next` at https://example.com/build/\(i) and the fleet log
        - before 418 ms, after 4 ms; see https://example.com/trace/\(i)
        """
    }

    /// `count` rows alternating me and the Chief; every fifth row is a thread reply to the row
    /// before it, so the diff's thread-root lookups run too.
    static func items(_ count: Int) -> [TranscriptItem] {
        (0..<count).map { i in
            let author = i % 2 == 0 ? chief : me
            let root = i % 5 == 4 ? MessageID("msg_\(i - 1)") : nil
            return TranscriptItem(key: IdempotencyKey("k\(i)"), seq: Seq(UInt64(i + 1)), author: author,
                                  parts: [.text(text(i))], createdAt: base.addingTimeInterval(Double(i)),
                                  delivery: .committed, replyTo: root.map { PartRef(message: $0) }, threadRoot: root,
                                  messageID: MessageID("msg_\(i)"))
        }
    }

    static func summary(lastSeq: Int) -> ConversationSummary {
        let people = [CmuxHomeCore.Participant(id: me, kind: .human, displayName: "Me"),
                      CmuxHomeCore.Participant(id: chief, kind: .agent, displayName: "Chief", agentClass: .chief)]
        return ConversationSummary(id: ConversationID("conv_cost"), title: "Chief", participants: people,
                                   lastSeq: Seq(UInt64(lastSeq)), createdAt: base, updatedAt: base,
                                   readCursors: [:], readCursorTimes: [:])
    }

    /// The best of five runs of the diff from `shown` rows to the same rows plus one new message, in ms.
    static func planMs(shown: Int) -> (ms: Double, diff: HomeDiff) {
        let all = items(shown + 1)
        let old = Array(all.prefix(shown)), new = all
        let s0 = summary(lastSeq: shown), s1 = summary(lastSeq: shown + 1)
        var best = Double.infinity
        var diff = HomeDiff()
        for _ in 0..<5 {
            let t0 = CACurrentMediaTime()
            diff = HomeDiff.plan(old: old, new: new, oldSummary: s0, newSummary: s1, aliases: [:], me: me)
            best = min(best, (CACurrentMediaTime() - t0) * 1000)
        }
        return (best, diff)
    }

    @Test func oneNewMessageCostsAboutOneRowNotTheTranscript() {
        _ = Self.planMs(shown: 10) // warm the detector and the Markdown renderer
        let small = Self.planMs(shown: 40)
        let large = Self.planMs(shown: 400)
        print(String(format: "HOMEDIFFCOST rows 40 %.3f ms, rows 400 %.3f ms, ratio %.2f", small.ms, large.ms, large.ms / max(small.ms, 0.001)))
        // The diff is the same either way: one receive, no rebuild.
        #expect(!large.diff.rebuild)
        #expect(large.diff.actions.map(HomeDiff.describe) == ["receive k400 \(Self.chief.rawValue)"])
        #expect(large.ms < 30, "one new message over 400 rows took \(large.ms) ms on the main thread")
        #expect(large.ms < max(small.ms, 2) * 3, "400 rows cost \(large.ms) ms, 40 rows \(small.ms) ms: linear in the transcript")
    }
}

import AppKit
@testable import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// Typing in Home stays smooth while the Chief's agents work in the background (Lawrence
/// 2026-10-30: "imessage typing thing gets laggy, it's laggy as i type rn ... maybe it's because of
/// stuff happening in bg processes", with ~9 agents running).
///
/// The real view (`MessagesLabHomeView`) over a real `HomeStore` on the mock owner, in an
/// offscreen window, with a Home-sized transcript: the generated history plus Chief replies and
/// agent work reports that carry Markdown and links, many of them thread replies. Each display
/// frame runs what the main thread runs while the Chief dispatches agents: its live run's
/// "working on" line and thought change, typing dots come and go, a work report posts into a
/// thread now and then, a tapback lands, other conversations move in the inbox; then the
/// person's keystroke, then one layout pass and a Core Animation flush. The store's changes reach
/// the transcript the way Observation delivers them (`HomeProjection.observedPass`).
///
/// The rules: under that load a frame's main-thread time stays under 4 ms at p95, a frame that only
/// moves the live line costs under 2 ms at p95, and a keystroke costs about what it costs with no load. `HOMELOAD` lines in the log carry the numbers.
@MainActor @Suite(.serialized) struct HomeBackgroundLoadPerfTests {
    private static func ms(_ t0: CFTimeInterval) -> Double { (CACurrentMediaTime() - t0) * 1000 }
    private static func p(_ xs: [Double], _ q: Double) -> Double { HomeStreamingPerfTests.p(xs, q) }
    private static func line(_ name: String, _ xs: [Double]) -> String {
        String(format: "%@ n %d p50 %.3f p95 %.3f p99 %.3f max %.2f ms", name, xs.count, p(xs, 0.5), p(xs, 0.95), p(xs, 0.99), xs.max() ?? 0)
    }

    /// A Chief reply or an agent's work report as Home shows them: Markdown, links, a list.
    static func report(_ n: Int) -> String {
        """
        **a\(800 + n) landed** the fix on feat-cmux-next: [diff](https://github.com/manaflow-ai/cmux/compare/aaa\(n)...bbb\(n)), \
        CI https://github.com/manaflow-ai/cmux/actions/runs/4100\(n)0000 is green.
        - before: p95 \(n % 40 + 20) ms, after: \(n % 7 + 2) ms
        - shots in ~/fun/cmux-shots/item-\(n)/ and https://cmux.com/next
        Next: `cmux-ci wait \(n)`, then the NIGHTLY check.
        """
    }

    @Test func typingStaysSmoothWhileAgentsWorkInTheBackground() async throws {
        let rig = try await HomeChatRig(history: 300, width: 760, height: 900)
        defer { rig.stop() }
        let conversation = HomeChatRig.conversation
        let store = rig.store, view = rig.view, window = rig.window
        // A Home-sized transcript: Chief replies with links, and work reports in their threads.
        var roots: [MessageID] = []
        for n in 0..<120 {
            let root = n % 3 == 0 ? nil : roots.last
            let key = IdempotencyKey("report_\(n)")
            _ = await rig.post([.text(Self.report(n))], key: key, threadRoot: root)
            if root == nil, let id = store.transcript(for: conversation).last(where: { $0.key == key })?.messageID { roots.append(id) }
        }
        let others = store.rows.map(\.summary.id).filter { $0 != conversation }
        let projection = view.projection
        var pending: [() -> Void] = []
        view.controller.nextFrame = { pending.append($0) }
        func frameStart() {
            while !pending.isEmpty { let w = pending; pending.removeAll(); w.forEach { $0() } }
        }
        func flush() { window.contentView?.layoutSubtreeIfNeeded(); CATransaction.flush() }
        projection.refresh()
        view.controller.demo?.pinToBottom()
        flush()
        let field = try #require(view.controller.demo?.compose.textView.view)
        window.makeFirstResponder(field)
        var typed = 0
        func key() -> Double {
            let k0 = CACurrentMediaTime()
            if typed % 40 == 39 {
                field.selectAll(nil)
                field.insertText("a", replacementRange: field.selectedRange())
            } else {
                field.insertText(typed % 6 == 5 ? " " : "e", replacementRange: field.selectedRange())
            }
            typed += 1
            return Self.ms(k0)
        }

        var tick = 0, posted = 0
        var phases: [String: [Double]] = [:]
        func timed<T>(_ name: String, _ body: () -> T) -> T {
            let t0 = CACurrentMediaTime(); let r = body(); phases[name, default: []].append(Self.ms(t0)); return r
        }
        /// The background traffic of one frame, as the store receives it (synchronous events), and
        /// its async ones (a posted report, a tapback, another conversation's message).
        func background() async {
            tick += 1
            let agent = "a\(870 + tick % 9)"
            timed("store activity") {
                store.handle(.live(.activity(HomeLiveActivityFrame(conversation: conversation, author: rig.chief, run: "chief-run",
                                                                   activity: HomeLiveActivity(line: "Checking on \(agent)", since: Date())))))
            }
            if tick % 3 == 0 {
                timed("store thought") { store.handle(.live(.delta(HomeLiveDelta(conversation: conversation, author: rig.chief, run: "chief-run",
                                                        step: "thought:\(tick / 30)", isTalk: false, seq: UInt64(tick),
                                                        text: "\n\n**Waiting for \(agent)**", isFinal: false)))) }
            }
            if tick % 20 == 0 { store.handle(.typing(conversation, rig.chief, on: tick % 40 == 0)) }
            if tick % 30 == 0 {
                posted += 1
                _ = await rig.source.post([.text(Self.report(1000 + posted))], from: rig.chief, in: conversation,
                                          key: IdempotencyKey("bg_\(posted)"), threadRoot: roots[checked: posted % max(1, roots.count)])
            }
            if tick % 45 == 0, let target = store.transcript(for: conversation).last?.messageID {
                _ = await rig.source.react(.tapback(.love), to: target, from: rig.chief, in: conversation)
            }
            if tick % 10 == 0, let other = others[checked: tick % max(1, others.count)] {
                await rig.source.receive("update \(tick)", from: rig.chief, in: other)
            }
            let y0 = CACurrentMediaTime()
            await Task.yield()
            let kind = tick % 30 == 0 ? "post" : tick % 45 == 0 ? "react" : tick % 10 == 0 ? "inbox" : tick % 3 == 0 ? "thought" : "activity"
            phases["yield (\(kind) frame)", default: []].append(Self.ms(y0))
            timed("observed pass (\(kind) frame)") { projection.observedPass() }
        }

        func frame(load: Bool) async -> (frame: Double, background: Double, key: Double) {
            let f0 = CACurrentMediaTime()
            frameStart()
            var bg = 0.0
            if load { let b0 = CACurrentMediaTime(); await background(); bg = Self.ms(b0) }
            let k = key()
            flush()
            return (Self.ms(f0), bg, k)
        }

        var idleFrames: [Double] = [], idleKeys: [Double] = []
        for _ in 0..<240 { let f = await frame(load: false); idleFrames.append(f.frame); idleKeys.append(f.key) }
        let refreshes0 = projection.refreshPasses
        var frames: [Double] = [], bgs: [Double] = [], keys: [Double] = []
        for _ in 0..<720 { let f = await frame(load: true); frames.append(f.frame); bgs.append(f.background); keys.append(f.key) }
        let label = "rows=\(projection.shown.count) posted=\(posted) refreshes=\(projection.refreshPasses - refreshes0)"
        print("HOMELOAD \(label) idle \(Self.line("frame", idleFrames))")
        print("HOMELOAD \(label) idle \(Self.line("keystroke", idleKeys))")
        print("HOMELOAD \(label) load \(Self.line("frame", frames))")
        print("HOMELOAD \(label) load \(Self.line("background", bgs))")
        print("HOMELOAD \(label) load \(Self.line("keystroke", keys))")
        for (k, v) in phases.sorted(by: { $0.value.reduce(0, +) > $1.value.reduce(0, +) }) {
            print(String(format: "HOMELOAD phase %@ total %.1f ms ", k, v.reduce(0, +)) + Self.line(k, v))
        }

        // A frame that only moves the Chief's "working on" line (most frames while agents work)
        // re-derives the trailing rows, not the transcript from my last read receipt down.
        let lineOnly = (phases["yield (activity frame)"] ?? []).enumerated().map { $0.element + (phases["observed pass (activity frame)"]?[checked: $0.offset] ?? 0) }
        #expect(Self.p(lineOnly, 0.95) < 2, "a live-line frame's store pass p95 \(Self.p(lineOnly, 0.95)) ms")
        #expect(Self.p(frames, 0.95) < 4, "frame under load p95 \(Self.p(frames, 0.95)) ms, idle \(Self.p(idleFrames, 0.95)) ms")
        #expect(Self.p(keys, 0.95) < Self.p(idleKeys, 0.95) + 1,
                "keystroke under load p95 \(Self.p(keys, 0.95)) ms, idle \(Self.p(idleKeys, 0.95)) ms")
    }
}

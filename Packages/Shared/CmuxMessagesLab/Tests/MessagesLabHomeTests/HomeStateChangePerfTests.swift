import AppKit
@testable import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// Home stays smooth while I talk to the Chief and the conversation's state changes (Lawrence
/// 2026-10-30: "imessage ui is laggy when im talking and state changes, like typing indicator, or
/// new message sent etc").
///
/// The real view (`MessagesLabHomeView`) over a real `HomeStore` on the mock owner, in an offscreen
/// window, with a Home-sized transcript (HomeBackgroundLoadPerfTests: the generated history plus
/// Chief replies and agent work reports with Markdown and links, many in threads). Each timed
/// display frame runs one state change the way the app receives it (the store's event, then the
/// projection's observed pass), then my keystroke, then one layout pass and a Core Animation flush:
///
/// - the Chief's typing dots come and go;
/// - I send: the bubble flies in (the optimistic insert, pinned to the bottom), the store logs
///   it, the owner commits it ("Delivered"), the Chief reads it ("Read");
/// - the Chief's reply posts, and an agent's work report posts into its thread;
/// - my own typing starts (the first character) and ends (the field emptied).
///
/// The rule: a change derives again only the rows of the messages it changes, never every row under my
/// last read message (a count, so it holds on a busy fleet host). The frame times are printed, not gated:
/// on a shared host the idle keystroke alone swung from 0.9 to 14 ms p95 between runs. `HOMESTATE` lines carry the numbers and each step's share (projection pass steps, the
/// transcript commit's phases, the layout and flush).
@MainActor @Suite(.serialized) struct HomeStateChangePerfTests {
    private static func ms(_ t0: CFTimeInterval) -> Double { (CACurrentMediaTime() - t0) * 1000 }
    private static func p(_ xs: [Double], _ q: Double) -> Double { HomeStreamingPerfTests.p(xs, q) }
    private static func line(_ name: String, _ xs: [Double]) -> String {
        String(format: "%@ n %d p50 %.3f p95 %.3f p99 %.3f max %.2f ms", name, xs.count, p(xs, 0.5), p(xs, 0.95), p(xs, 0.99), xs.max() ?? 0)
    }

    /// One kind of frame's samples: the whole frame, and each step's ms per frame.
    private struct Samples {
        var frame: [Double] = []
        var key: [Double] = []
        var steps: [String: [Double]] = [:]
        /// Rows the frame's transcript commits derived again.
        var derived: [Int] = []
    }

    /// The two halves of the traffic, each with its own rig (the fleet's watchdog wants a test done in 3 minutes).
    enum Phase: String, CaseIterable, Sendable {
        /// My last message far up, read: the Chief's typing dots, status line, replies and work reports, my typing.
        case chiefTalks
        /// My sends, each after a few of the Chief's messages: from the press to "Read".
        case iSend
    }

    @Test(arguments: Phase.allCases) func eachStateChangeDerivesOnlyTheRowsItChanges(_ phase: Phase) async throws {
        let rig = try await HomeChatRig(history: 300, width: 760, height: 900)
        defer { rig.stop() }
        let conversation = HomeChatRig.conversation
        let store = rig.store, view = rig.view, window = rig.window
        // My last message is far up, read: its "Read" receipt sits above ~120 Chief messages, as in
        // a Home where agents report while I watch.
        await rig.send("\(HomeChatRig.tag) start the agents")
        await rig.source.markRead(by: rig.chief, in: conversation)
        await HomeChatRig.until { (store.summary(conversation)?.readCursors[rig.chief] ?? 0) >= (store.summary(conversation)?.lastSeq ?? 0) }
        var roots: [MessageID] = []
        for n in 0..<120 {
            let root = n % 3 == 0 ? nil : roots.last
            let key = IdempotencyKey("report_\(n)")
            _ = await rig.post([.text(HomeBackgroundLoadPerfTests.report(n))], key: key, threadRoot: root)
            if root == nil, let id = store.transcript(for: conversation).last(where: { $0.key == key })?.messageID { roots.append(id) }
        }
        let projection = view.projection
        var pending: [() -> Void] = []
        view.controller.nextFrame = { pending.append($0) }
        func frameStart() {
            while !pending.isEmpty { let w = pending; pending.removeAll(); w.forEach { $0() } }
        }
        projection.refresh()
        view.controller.demo?.pinToBottom()
        window.contentView?.layoutSubtreeIfNeeded(); CATransaction.flush()
        let field = try #require(view.controller.demo?.compose.textView.view)
        window.makeFirstResponder(field)

        var typed = 0
        func key() {
            field.insertText(typed % 6 == 5 ? " " : "e", replacementRange: field.selectedRange())
            typed += 1
        }
        var samples: [String: Samples] = [:]
        // The rows each change left are the rows a derive of the whole window gives (a change re-derives
        // only the messages it changes): same keys in order, and the same spec for every exactly measured
        // row but the day labels (their text follows the clock).
        var mismatches: [String] = []
        func checkRows(_ name: String) {
            guard let demo = view.controller.demo, let state = view.controller.store?.state else { return }
            let full = RowBuilder.rows(state, messages: state.conversation.messages, now: Date(), width: demo.bounds.width, scale: demo.renderScale)
            let live = demo.model.rows.filter { !$0.ghost }.map(\.spec)
            guard full.map(\.key) == live.map(\.key) else {
                let diff = full.map(\.key).difference(from: live.map(\.key))
                mismatches.append("\(name): keys differ: \(diff.prefix(6).map { "\($0)" })")
                return
            }
            for (a, b) in zip(full, live) where !a.estimated && !b.estimated && !a.key.hasPrefix("sep:") && a != b {
                mismatches.append("\(name): \(a.key) gap \(b.gap)->\(a.gap) height \(b.height)->\(a.height) kind differs: \(a.kind != b.kind)")
                return
            }
        }
        defer { projection.passLog = nil }

        /// One display frame: last frame's held work, `change` (the store's event and the observed
        /// pass), my keystroke (`keystroke`, or the default one), layout and the CA flush. Timed under `name`.
        func frame(_ name: String?, keystroke: (() -> Void)? = nil, _ change: () async -> Void) async {
            projection.passLog = name == nil ? nil : [:]
            MessagesWindowView.timePhases = [:]
            MessagesWindowView.maxCommitMs = 0
            let derived0 = view.controller.demo?.derivedRows ?? 0
            let f0 = CACurrentMediaTime()
            frameStart()
            let held = Self.ms(f0)
            let c0 = CACurrentMediaTime()
            await change()
            let changed = Self.ms(c0)
            let k0 = CACurrentMediaTime()
            (keystroke ?? key)()
            let k = Self.ms(k0)
            let l0 = CACurrentMediaTime()
            window.contentView?.layoutSubtreeIfNeeded()
            let layout = Self.ms(l0)
            let x0 = CACurrentMediaTime()
            CATransaction.flush()
            let flush = Self.ms(x0)
            let total = Self.ms(f0)
            guard let name else { return }
            checkRows(name)
            var s = samples[name] ?? Samples()
            s.frame.append(total); s.key.append(k)
            s.derived.append((view.controller.demo?.derivedRows ?? 0) - derived0)
            var steps: [String: Double] = ["held": held, "change": changed, "keystroke": k, "layout": layout, "flush": flush,
                                           "commit (max)": MessagesWindowView.maxCommitMs]
            for (step, v) in projection.passLog ?? [:] { steps["pass " + step] = v }
            for (name, v) in MessagesWindowView.timePhases { steps["commit " + name] = v }
            for (step, v) in steps { s.steps[step, default: []].append(v) }
            samples[name] = s
        }
        /// Frames with no state change: the keystroke alone (the baseline), and the settle between kinds.
        func idle(_ n: Int, timed: Bool = false) async {
            for _ in 0..<n { await frame(timed ? "idle (keystroke only)" : nil) { projection.observedPass() } }
        }
        /// The view's wake after a change's springs (the rig's scheduler never fires one): the rows that
        /// faded out leave, as the app's wake does about a second after the change.
        func settle() async {
            await frame("wake after a change (faded rows leave)") {
                view.controller.demo?.settle(at: view.controller.clock + 2)
            }
        }
        /// Waits for `condition` (the store's echo of a change) for at most 2 s; a miss is an issue named `what`.
        var misses: [String] = []
        func until(_ what: String, _ condition: @escaping @MainActor () -> Bool) async {
            let t0 = CACurrentMediaTime()
            while !condition() {
                if CACurrentMediaTime() - t0 > 2 { misses.append(what); print("HOMESTATE miss \(what)"); return }
                await Task.yield()
            }
        }

        await idle(60, timed: true)
        // The receipt far up: the Chief's typing, its replies and work reports, my typing.
        for round in 0..<(phase == .chiefTalks ? 24 : 0) {
            // The Chief's typing dots.
            await frame("chief typing on") { store.handle(.typing(conversation, rig.chief, on: true)); projection.observedPass() }
            await idle(2)
            await settle()
            await frame("chief typing off") { store.handle(.typing(conversation, rig.chief, on: false)); projection.observedPass() }
            await idle(2)
            await settle()

            // The Chief's "working on" line changes, twice (its run's activity).
            for step in 0..<2 {
                await frame("chief status line changes") {
                    store.handle(.live(.activity(HomeLiveActivityFrame(conversation: conversation, author: rig.chief, run: "chief-run",
                                                                       activity: HomeLiveActivity(line: "Checking on a\(870 + round * 2 + step)", since: Date())))))
                    projection.observedPass()
                }
                await idle(1)
            }
            rig.run("chief-run", "done")
            await idle(3)

            // The Chief's reply, then an agent's work report in its thread.
            let replyKey = IdempotencyKey("reply_\(round)")
            await frame("chief reply posts") {
                _ = await rig.source.post([.text(HomeBackgroundLoadPerfTests.report(2000 + round))], from: rig.chief, in: conversation, key: replyKey)
                await until("chief reply posted") { store.transcript(for: conversation).contains { $0.key == replyKey && $0.seq != nil } }
                projection.observedPass()
            }
            await idle(2)
            await settle()
            let reportKey = IdempotencyKey("work_\(round)")
            await frame("work report posts in a thread") {
                _ = await rig.source.post([.text(HomeBackgroundLoadPerfTests.report(3000 + round))], from: rig.chief, in: conversation,
                                          key: reportKey, threadRoot: roots[checked: round % max(1, roots.count)])
                await until("work report posted") { store.transcript(for: conversation).contains { $0.key == reportKey && $0.seq != nil } }
                projection.observedPass()
            }
            await idle(2)
            await settle()

            // My own typing: the field emptied (typing ends), then the first character (typing starts).
            await frame("my typing ends (field emptied)", keystroke: {
                field.selectAll(nil); field.insertText("", replacementRange: field.selectedRange())
            }) { projection.observedPass() }
            await idle(1)
            await frame("my typing starts (first character)") { projection.observedPass() }
            await idle(2)
            await settle()
        }
        // My sends, each after a few of the Chief's messages: from the press to "Read".
        for round in 0..<(phase == .iSend ? 24 : 0) {
            for n in 0..<4 {
                _ = await rig.post([.text(HomeBackgroundLoadPerfTests.report(4000 + round * 4 + n))], key: IdempotencyKey("between_\(round)_\(n)"))
                await idle(1)
            }
            await rig.holdSends()
            let text = "\(HomeChatRig.tag) can you check the nightly feed again, round \(round)"
            field.selectAll(nil); field.insertText(text, replacementRange: field.selectedRange())
            await frame("send: bubble flies in", keystroke: {}) { _ = projection.send() }
            await frame("send: the store logs it") {
                await until("send logged") { store.transcript(for: conversation).contains { $0.plainText == text } }
                projection.observedPass()
            }
            await idle(2)
            await settle()
            await frame("send: delivered") {
                await rig.source.releaseSubmits()
                await until("send delivered") { store.transcript(for: conversation).contains { $0.plainText == text && $0.seq != nil } }
                projection.observedPass()
            }
            await idle(2)
            await settle()
            await frame("send: read") {
                await rig.source.markRead(by: rig.chief, in: conversation)
                await until("Chief read") { (store.summary(conversation)?.readCursors[rig.chief] ?? 0) >= (store.summary(conversation)?.lastSeq ?? 0) }
                projection.observedPass()
            }
            await idle(2)
            await settle()
        }

        let kinds = samples.keys.sorted()
        print("HOMESTATE phase=\(phase.rawValue) rows=\(projection.shown.count) rebuilds=\(projection.rebuilds)")
        for k in kinds {
            guard let s = samples[k] else { continue }
            print("HOMESTATE \(Self.line(k, s.frame)) rows derived max \(s.derived.max() ?? 0)")
            for (step, v) in s.steps.sorted(by: { Self.p($0.value, 0.5) > Self.p($1.value, 0.5) }) where Self.p(v, 0.95) >= 0.05 {
                print("HOMESTATE   step " + Self.line(step, v))
            }
        }
        #expect(misses.isEmpty, "store echoes that never came: \(misses.prefix(8))")
        #expect(mismatches.isEmpty, "rows after a change differ from a whole-window derive: \(mismatches.prefix(8))")
        for k in kinds {
            guard let s = samples[k] else { continue }
            // A change derives the rows of the messages it changes and their neighbours (a work report: its
            // thread's root and replies too), never every row under my last read message (~120 Chief messages here).
            #expect((s.derived.max() ?? 0) <= 40, "\(k): a commit derived \(s.derived.max() ?? 0) rows again")
        }
    }
}

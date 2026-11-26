import AppKit
@testable import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// Typing in the Home Chief composer while many agents stream (user, 2026-10-20:
/// "rn im typing in the chat area and i feel lag", ~75 subagents live). The real
/// view (`MessagesLabHomeView`) over a real `HomeStore` on the mock owner, in an
/// offscreen window; keys go in through the field's `insertText`, the same
/// delegate path (`textDidChange`, `.setDraft`, `HomeStore.setDraft`) a key
/// takes. Between keys, one display frame of Home traffic arrives the way the
/// owner's frames do, one main-actor turn each: 100 other conversations' replies
/// and typing, the Chief's own reply growing, and a long agent report now and
/// then. The rule: a key's frame (the traffic queued before it plus the key
/// itself, laid out and committed) stays under 8 ms at p95, and traffic for other
/// conversations costs the Chief's transcript nothing.
@MainActor @Suite(.serialized) struct HomeComposerTypingLatencyTests {
    final class NoWake: ChatWakeScheduler {
        func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) {}
        func cancel() {}
    }

    static let conversation = ConversationID("conv_chief")
    /// Agents streaming into Home at once (the target is 100; the user had ~75).
    static let agents = 100
    /// The key frame budget at p95 (half a 60 Hz frame).
    static let budgetMs = 8.0

    private func until(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<20_000 where !condition() { await Task.yield() }
    }

    /// Runs the main-actor work queued so far (observation hops), as the run loop would between events.
    private func drain(_ turns: Int = 8) async {
        for _ in 0..<turns { await Task.yield() }
    }

    private static func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    private static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
    }

    private static func line(_ name: String, _ v: [Double]) -> String {
        String(format: "%@ p50 %.2f ms, p95 %.2f ms, max %.2f ms (n=%d)", name,
               percentile(v, 0.5), percentile(v, 0.95), v.max() ?? 0, v.count)
    }

    /// A long agent report (the size of the [aN] reports the Chief gets), Markdown with a list and code.
    private static func report(_ n: Int) -> String {
        var s = "**a\(n) report.** The fix is on feat-cmux-next with no PR.\n\n"
        for i in 0..<24 {
            s += "- Item \(i): `Packages/macOS/CmuxNext/Sources/File\(i).swift` changed; tests pass on the minis, see [run \(i)](https://example.com/\(i)).\n"
        }
        s += "\n```swift\nlet value = compute(\(n))\nprint(value)\n```\n"
        return s
    }

    struct Harness {
        let store: HomeStore
        let window: NSWindow
        let view: MessagesLabHomeView
        let field: NSTextView
        let me: ParticipantID
        let chief: ParticipantID
    }

    private func makeHarness() async throws -> Harness {
        let options = MockHomeSource.Options(chiefHistory: 300, latency: .zero, replyDelay: .seconds(3600))
        let store = HomeStore(source: MockHomeSource(options: options))
        store.start()
        await until { store.me != nil && store.isOnline }
        await store.open(Self.conversation)
        await until { !store.transcript(for: Self.conversation).isEmpty }
        let me = try #require(store.me?.id)
        let chief = try #require(store.transcript(for: Self.conversation).first { $0.author != me }?.author)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 900), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let view = MessagesLabHomeView(store: store, conversation: Self.conversation, me: me, wake: NoWake())
        view.frame = NSRect(x: 0, y: 0, width: 700, height: 900)
        window.contentView = view
        view.projection.refresh()
        view.layoutSubtreeIfNeeded()
        let field = try #require(view.controller.demo?.compose.textView.view)
        return Harness(store: store, window: window, view: view, field: field, me: me, chief: chief)
    }

    /// One key, through the field's delegate path, laid out and committed: its frame's cost.
    private static func key(_ h: Harness, _ character: String) -> Double {
        let start = ContinuousClock.now
        h.field.insertText(character, replacementRange: h.field.selectedRange())
        h.window.contentView?.layoutSubtreeIfNeeded()
        h.window.displayIfNeeded()
        CATransaction.flush()
        return ms(ContinuousClock.now - start)
    }

    private static let sentence = "I'm checking the fleet run and the suite results now, then I land the fix. "

    /// The display frames the projection waits for (`PaneHost.nextFrame`, "tests capture it"): work
    /// held for the next frame runs when the bench starts one.
    final class Frames {
        var held: [() -> Void] = []
        func start() { let w = held; held = []; w.forEach { $0() } }
    }

    @Test func typingStaysUnderBudgetWhileAHundredAgentsStream() async throws {
        let h = try await makeHarness()
        defer { h.view.stop(); h.window.close(); h.store.stop() }
        let frames = Frames()
        h.view.controller.nextFrame = { [frames] f in frames.held.append(f) }
        let typed = "please also check the sidebar search and the tab bar buttons "

        // Idle: no traffic.
        var idle: [Double] = []
        for c in typed { frames.start(); idle.append(Self.key(h, String(c))) }
        frames.start()

        // Streaming. Each agent sends ~20 frames a second; at 60 Hz a display frame holds a third of
        // them. Keys come ~100 ms apart (6 frames): 5 frames of traffic between keys, then the key's
        // frame: the key and the traffic that lands in the same frame.
        let others = (0..<Self.agents).map { ConversationID("conv_agent_\($0)") }
        let peers = (0..<Self.agents).map { ParticipantID("agent_\($0)") }
        var otherDrafts = zip(others, peers).map { HomeTurnDraft(participant: $1, turn: IdempotencyKey("turn_\($0.rawValue)")) }
        var chiefDraft = HomeTurnDraft(participant: h.chief, turn: IdempotencyKey("turn_chief_live"))
        var chiefText = ""
        var frame = 0
        var chiefChanges = 0
        func trafficFrame() async {
            frame += 1
            for i in otherDrafts.indices where (i + frame) % 3 == 0 {
                otherDrafts[i].segments[0, default: ""] += "word\(frame) "
                otherDrafts[i].lastSeq += 1
                h.store.showDraft(otherDrafts[i], turn: otherDrafts[i].turn, author: otherDrafts[i].participant, in: others[i])
                if (i + frame) % 12 == 0 { h.store.typing[others[i]] = frame % 8 < 4 ? [peers[i]] : [] }
                await drain(2) // one owner frame, one main-actor turn (its observation hop)
            }
            if frame % 3 == 0 { // the Chief's own reply grows
                chiefText += Self.sentence
                chiefDraft.segments[0] = chiefText
                chiefDraft.lastSeq += 1
                h.store.showDraft(chiefDraft, turn: chiefDraft.turn, author: chiefDraft.participant, in: Self.conversation)
                chiefChanges += 1
                await drain()
            }
            if frame % 40 == 0, let summary = h.store.summary(Self.conversation) { // a long agent report lands
                // The Chief's reply so far ends with it; the next one starts (a reply is a few hundred words,
                // not the whole run: a 27K-character single stream is a197's long-stream render path).
                chiefText = ""
                chiefDraft = HomeTurnDraft(participant: h.chief, turn: IdempotencyKey("turn_chief_live_\(frame)"))
                let rev = h.store.mirror.revision(of: .conversation(Self.conversation)) + 1
                h.store.handle(.message(CmuxHomeCore.Message(
                    id: MessageID("msg_report_\(frame)"), conversation: Self.conversation, seq: summary.lastSeq + 1,
                    clientMessageID: IdempotencyKey("report_\(frame)"), author: h.chief,
                    parts: [.text(Self.report(frame))], createdAt: Date()), rev: rev))
                chiefChanges += 1
                await drain()
            }
        }
        var between: [Double] = [], keyFrames: [Double] = [], keysOnly: [Double] = []
        let passesBefore = h.view.projection.refreshPasses
        for round in 0..<3 {
            for c in typed {
                let gap = ContinuousClock.now
                for _ in 0..<5 { frames.start(); await trafficFrame() }
                let gapMs = Self.ms(ContinuousClock.now - gap) / 5
                frames.start()
                let start = ContinuousClock.now
                let k = Self.key(h, String(c))
                await trafficFrame()
                h.window.contentView?.layoutSubtreeIfNeeded()
                h.window.displayIfNeeded()
                CATransaction.flush()
                let whole = Self.ms(ContinuousClock.now - start)
                if round > 0 { between.append(gapMs); keysOnly.append(k); keyFrames.append(whole) } // round 0 warms up
            }
        }
        frames.start()
        await drain()
        let passes = h.view.projection.refreshPasses - passesBefore

        print("HOME-COMPOSER-LATENCY " + Self.line("idle key", idle))
        print("HOME-COMPOSER-LATENCY " + Self.line("traffic per frame between keys", between))
        print("HOME-COMPOSER-LATENCY " + Self.line("key alone", keysOnly))
        print("HOME-COMPOSER-LATENCY " + Self.line("key frame (key + same-frame traffic)", keyFrames))
        print("HOME-COMPOSER-LATENCY Chief transcript passes \(passes) for \(chiefChanges) Chief changes, \(frame) frames, \(Self.agents) agents")

        #expect(Self.percentile(idle, 0.95) < Self.budgetMs, "idle key p95 over budget: \(Self.line("idle", idle))")
        #expect(Self.percentile(keyFrames, 0.95) < Self.budgetMs,
                "key frame p95 over budget with \(Self.agents) agents streaming: \(Self.line("key frame", keyFrames)); \(Self.line("key alone", keysOnly)); \(Self.line("between", between))")
        // The frames between keys are printed, not gated: their p95 is the Chief's own reply re-rendering
        // as it grows (a197, Home streaming lag), which no longer lands in a key's frame.
    }

    /// Traffic for other conversations never re-reads the Chief's transcript: their replies,
    /// typing and rows are someone else's (whole-dictionary Observation woke the Chief's
    /// projection for every agent's frame).
    @Test func otherConversationsTrafficSkipsTheChiefTranscript() async throws {
        let h = try await makeHarness()
        defer { h.view.stop(); h.window.close(); h.store.stop() }
        await drain()
        let before = h.view.projection.refreshPasses
        for i in 0..<Self.agents {
            var draft = HomeTurnDraft(participant: ParticipantID("agent_\(i)"), turn: IdempotencyKey("turn_\(i)"))
            draft.segments[0] = "streaming text \(i)"
            draft.lastSeq = 1
            h.store.showDraft(draft, turn: draft.turn, author: draft.participant, in: ConversationID("conv_agent_\(i)"))
            h.store.typing[ConversationID("conv_agent_\(i)")] = [ParticipantID("agent_\(i)")]
            await drain()
        }
        #expect(h.view.projection.refreshPasses == before,
                "\(h.view.projection.refreshPasses - before) Chief transcript passes for \(Self.agents) other conversations' frames")
        // The Chief's own change still reaches it.
        var mine = HomeTurnDraft(participant: h.chief, turn: IdempotencyKey("turn_chief"))
        mine.segments[0] = "on it"
        mine.lastSeq = 1
        h.store.showDraft(mine, turn: mine.turn, author: mine.participant, in: Self.conversation)
        await drain()
        #expect(h.view.projection.refreshPasses > before, "the Chief's own reply did not reach its transcript")
    }
}

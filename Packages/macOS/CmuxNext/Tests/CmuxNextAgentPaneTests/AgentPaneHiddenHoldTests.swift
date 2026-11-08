import Foundation
import CmuxNextCompat
import Testing
@testable import CmuxNextAgentPane

/// A chat pane nobody can see gets no bridge call for a streaming turn: each call woke its page's
/// web process. Leo's running nightly (2026-10-21) had one hidden chat take 148 calls and 109
/// web-process sleep and wake cycles in two minutes, at the 0.25 s hidden interval. What its
/// page waits on still goes: a reply, `_acpmux/prompt_accepted`, a turn's end, the close and a backlog.
@Suite(.serialized)
@MainActor
struct AgentPaneHiddenHoldTests {
    typealias Rig = AgentPaneHiddenPacingTests.Rig

    @Test func aHiddenPaneStreamingATurnGetsNoCallUntilItShows() {
        let rig = Rig(hidden: true)
        // Two seconds of a streaming turn: frames every 62.5 ms, and any deadline the pacer sets.
        for _ in 0..<32 {
            rig.arrive()
            rig.clock += 0.0625
            rig.deadline.fire()
            rig.pacer.delivered()
        }
        #expect(rig.calls == 0, "a hidden pane's page was called \(rig.calls) times for a streaming turn")
        // Shown: the held frames go at once, in one call.
        rig.hidden = false
        rig.pacer.visibilityChanged()
        #expect(rig.calls == 1)
    }

    @Test func heldFramesGoWhenThePaneShows() {
        let rig = Rig(hidden: true)
        rig.arrive()
        rig.arrive()
        #expect(rig.calls == 0)
        // Still hidden: a probe report changes nothing.
        rig.pacer.visibilityChanged()
        #expect(rig.calls == 0)
        rig.hidden = false
        rig.pacer.visibilityChanged()
        #expect(rig.calls == 1)
        #expect(!rig.pacer.held)
    }

    @Test func framesThePageWaitsOnTakeTheHeldStreamAlong() {
        let rig = Rig(hidden: true)
        rig.arrive()
        #expect(rig.calls == 0)
        // A reply arrives behind the held updates: one call takes them all.
        rig.arrive(urgent: true)
        #expect(rig.calls == 1)
        // The page ran it; the stream goes on, held again.
        rig.clock += 1
        rig.pacer.delivered()
        rig.arrive()
        #expect(rig.calls == 1)
        #expect(rig.pacer.held)
    }

    @Test func aHiddenPaneDrainsABacklogAtTheHiddenInterval() {
        let rig = Rig(hidden: true)
        // A full flush's backlog (the socket says so) leaves more after its call.
        rig.arrive(urgent: true, capped: 1)
        #expect(rig.calls == 1)
        rig.clock += 0.0625
        rig.pacer.delivered()
        #expect(rig.calls == 1, "the rest of a backlog went inside the hidden interval")
        #expect(rig.pacer.waitingWhileHidden)
        rig.clock += 0.25
        rig.deadline.fire()
        #expect(rig.calls == 2)
    }

    @Test func whatThePageWaitsOn() {
        let waits = { (text: String) -> Bool in
            AcpmuxPaneSocket.pageWaits(on: (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:])
        }
        #expect(waits(#"{"jsonrpc":"2.0","id":3,"result":{}}"#), "a reply")
        #expect(waits(#"{"jsonrpc":"2.0","id":4,"method":"session/request_permission","params":{}}"#), "a daemon request")
        #expect(waits(#"{"jsonrpc":"2.0","method":"_acpmux/prompt_accepted","params":{"promptId":"p"}}"#))
        // Its absence 5 s after Stop says the stop was forced.
        #expect(waits(#"{"jsonrpc":"2.0","method":"_acpmux/event","params":{"sessionId":"s","seq":9,"kind":"turn_end","msg":{}}}"#))
        #expect(waits(#"{"jsonrpc":"2.0","method":"_acpmux/event","params":{"sessionId":"s","seq":9,"kind":"turn_result","msg":{}}}"#))
        // A prompt sent behind a running turn: acpmux takes it with a `queued` record and sends no
        // `prompt_accepted` (hub/turns.rs accepts only a prompt that starts at once), so a held pane
        // left it "Still sending" until the turn ended (session claude-7, 2026-10-30, the repro on
        // cmux-austin-mini-1, 2026-10-31). A refusal or a removal from the queue answers a send too.
        for kind in ["queued", "dequeued", "queue_removed", "prompt_refused"] {
            #expect(waits(#"{"jsonrpc":"2.0","method":"_acpmux/event","params":{"sessionId":"s","seq":9,"kind":"\#(kind)","msg":{}}}"#), "\(kind)")
        }
        #expect(!waits(#"{"jsonrpc":"2.0","method":"_acpmux/event","params":{"sessionId":"s","seq":8,"kind":"agent_message_chunk","msg":{}}}"#))
        #expect(!waits(AcpmuxStandInServer.benchFrame(1)), "a streamed session/update")
    }

    @Test func whatAnswersThePage() {
        let answers = { (text: String) -> Bool in
            AcpmuxPaneSocket.answersPage((try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:])
        }
        #expect(answers(#"{"jsonrpc":"2.0","id":3,"result":{}}"#), "a reply")
        #expect(answers(#"{"jsonrpc":"2.0","id":3,"error":{"code":-32601,"message":"no"}}"#), "an error reply")
        #expect(!answers(#"{"jsonrpc":"2.0","id":4,"method":"session/request_permission","params":{}}"#), "a daemon request")
        #expect(!answers(#"{"jsonrpc":"2.0","method":"_acpmux/event","params":{"sessionId":"s","seq":9,"kind":"turn_end","msg":{}}}"#))
    }

    /// The page's events, one entry per bridge call, awaited as they arrive.
    final class Calls: @unchecked Sendable { // crash-allow: test support; every access holds the lock
        private let state = Mutex<(calls: [[String]], waiters: [(String, CheckedContinuation<[String], Never>)])>(([], []))

        func deliver(_ frames: [String]) {
            let ready = state.withLock { state -> [(CheckedContinuation<[String], Never>, [String])] in
                state.calls.append(frames)
                var ready: [(CheckedContinuation<[String], Never>, [String])] = []
                state.waiters.removeAll { needle, waiter in
                    guard let call = state.calls.first(where: { $0.contains { $0.contains(needle) } }) else { return false }
                    ready.append((waiter, call))
                    return true
                }
                return ready
            }
            for (waiter, call) in ready { waiter.resume(returning: call) }
        }

        /// The first call with a frame that contains `needle`.
        func call(containing needle: String) async -> [String] {
            await withCheckedContinuation { waiter in
                let found = state.withLock { state -> [String]? in
                    if let call = state.calls.first(where: { $0.contains { $0.contains(needle) } }) { return call }
                    state.waiters.append((needle, waiter))
                    return nil
                }
                if let found { waiter.resume(returning: found) }
            }
        }

        var count: Int { state.withLock { $0.calls.count } }
    }

    /// The fallback deadline at once (next turn), so a hidden wait never needs a clock.
    final class SoonDeadline: AgentPaneFallbackDeadline {
        private var generation = 0
        func schedule(after delay: Duration, _ action: @escaping @MainActor @Sendable () -> Void) {
            generation += 1
            let mine = generation
            // task-owner: one test deadline; cancel() makes it a no-op
            Task { @MainActor [weak self] in if self?.generation == mine { action() } }
        }
        func cancel() { generation += 1 }
    }

    @Test func aHiddenChatGetsItsRepliesAndAcceptsButHoldsItsStream() async throws {
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        let calls = Calls()
        let pacer = AgentPaneFramePacer(frames: AgentPaneHiddenPacingTests.Ticks(), fallback: SoonDeadline(), isHidden: { true })
        let transport = AgentPaneTransport(pacer: pacer)
        transport.deliver = { event, done in
            calls.deliver(event.frames)
            // task-owner: the page's completion, a turn later as in the app
            Task { @MainActor in done() }
        }
        let id = try await transport.open(AcpmuxConnection(url: server.url, dashboardToken: "t", localAppToken: nil))
        // A reply reaches the hidden page.
        #expect(await transport.send(connection: id, frames: [#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#]) == nil)
        _ = await calls.call(containing: #""id":0"#)
        let before = calls.count
        // A streamed update waits; the accept behind it takes it along in one call.
        server.push(AcpmuxStandInServer.benchFrame(1), to: 0)
        server.push(#"{"jsonrpc":"2.0","method":"_acpmux/prompt_accepted","params":{"promptId":"p"}}"#, to: 0)
        let accepted = await calls.call(containing: "prompt_accepted")
        #expect(accepted.contains { $0.contains("session/update") }, "the update went in a call of its own")
        #expect(calls.count == before + 1)
        // A full flush's backlog reaches the hidden page too, in one call; the rest follows at the
        // hidden interval.
        let full = transport.limits.maximumFramesPerFlush
        for seq in 2...(full + 9) { server.push(AcpmuxStandInServer.benchFrame(seq), to: 0) }
        let backlog = await calls.call(containing: #""s":\#(full + 1),"#)
        #expect(backlog.count == full)
        #expect(backlog.first?.contains(#""s":2,"#) == true)
    }
}

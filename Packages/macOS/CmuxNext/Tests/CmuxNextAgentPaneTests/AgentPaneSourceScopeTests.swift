import Foundation
import Testing
@testable import CmuxNextAgentPane

/// A fork or a handoff copies a session's content into a new session the pane then controls. From
/// a session outside the pane's scope it uses the click's scope credit, the same as an attach that
/// brings a session in: no credit, refused transport.gesture_required, and a refusal never uses the
/// click. From a session in scope it keeps today's rules. The methods: `acp.session.fork` and
/// `_acpmux/handoff_prepare` name the source (`sessionId`); `handoff_draft`, `handoff_start` and
/// `handoff_discard` name the handoff (`handoffId`), whose source the relay learns from the
/// daemon's replies (a handoff it never saw counts as outside the scope).
@MainActor
@Suite(.serialized) struct AgentPaneSourceScopeTests {
    typealias Rig = AgentPaneProductRulesTests.Rig

    /// Every fork and handoff frame from `source` (a session) or `handoff` (its id).
    static func frames(source: String, handoff: String) -> [(String, [String: Any])] {
        [
            ("acp.session.fork", ["sessionId": source, "throughSeq": 3]),
            ("_acpmux/handoff_prepare", ["sessionId": source, "harness": "codex", "handoffKey": "k-\(source)"]),
            ("_acpmux/handoff_draft", ["handoffId": handoff, "revision": 1, "draftKey": "d-\(handoff)", "capsule": ["text": "x"]]),
            ("_acpmux/handoff_start", ["handoffId": handoff, "revision": 1, "promptId": "p-\(handoff)"]),
            ("_acpmux/handoff_discard", ["handoffId": handoff]),
        ]
    }

    func rig() async throws -> Rig {
        let rig = Rig()
        try await rig.start()
        let root = rig.root
        rig.transport.roots = { [root] }
        rig.transport.primaryRoot = { root }
        return rig
    }

    /// Waits until a daemon frame holding `needle` reached the page (the relay observed it first).
    func pageGot(_ rig: Rig, _ needle: String) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if rig.events.flatMap(\.frames).contains(where: { $0.contains(needle) }) { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    /// The daemon's frames of a fork or a handoff that name `marker`, once a later read reached it.
    func forksAndHandoffs(_ rig: Rig, naming marker: String) async -> [String] {
        let sentinel = await rig.send("_acpmux/events", ["sessionId": "s-sentinel-\(rig.nextID)"])
        _ = await rig.received(sentinel)
        return (rig.server.peers.first?.frames ?? []).filter {
            ($0.contains("acp.session.fork") || $0.contains("_acpmux/handoff_")) && $0.contains(marker)
        }
    }

    @Test func aForkOrHandoffFromOutsideTheScopeIsRefusedWithoutAClick() async throws {
        let rig = try await rig()
        defer { rig.server.stop() }
        // A read-only view of the foreign session, and its handoff (learned from a read).
        await rig.send("_acpmux/attach", ["sessionId": "s-foreign", "limit": 10])
        rig.server.answer("_acpmux/handoff_get", with: #"{"handoffId":"h-foreign","source":{"sessionId":"s-foreign"}}"#)
        await rig.send("_acpmux/handoff_get", ["sessionId": "s-foreign"])
        #expect(await pageGot(rig, "h-foreign"))
        for (method, params) in Self.frames(source: "s-foreign", handoff: "h-foreign") {
            await rig.send(method, params, expect: .gestureRequired)
        }
        // A handoff the relay never saw counts as outside the scope too.
        await rig.send("_acpmux/handoff_start", ["handoffId": "h-unknown", "revision": 1], expect: .gestureRequired)
        #expect(await forksAndHandoffs(rig, naming: "-foreign").filter { !$0.contains("handoff_get") }.isEmpty)
        #expect(await forksAndHandoffs(rig, naming: "h-unknown").isEmpty)
    }

    @Test func oneClickPassesOneForkOrHandoffFromOutsideTheScope() async throws {
        let rig = try await rig()
        defer { rig.server.stop() }
        rig.transport.gestures.record()
        await rig.send("acp.session.fork", ["sessionId": "s-foreign", "throughSeq": 3])
        // The fork used the scope credit: a second one on the same click is refused.
        await rig.send("_acpmux/handoff_prepare", ["sessionId": "s-foreign", "harness": "codex", "handoffKey": "k1"],
                       expect: .gestureRequired)
        await rig.send("acp.session.fork", ["sessionId": "s-foreign", "throughSeq": 4], expect: .gestureRequired)
        // The grant credit of the same click is still there.
        #expect(rig.transport.gestures.isAvailable)
        #expect(await forksAndHandoffs(rig, naming: "s-foreign").count == 1)
        // A new click: one handoff from the foreign session, its review and its start.
        rig.server.answer("_acpmux/handoff_prepare", with: #"{"handoffId":"h-picked","source":{"sessionId":"s-foreign"}}"#)
        rig.transport.gestures.record()
        await rig.send("_acpmux/handoff_prepare", ["sessionId": "s-foreign", "harness": "codex", "handoffKey": "k2"])
        #expect(await pageGot(rig, "h-picked"))
        await rig.send("_acpmux/handoff_draft", ["handoffId": "h-picked", "revision": 1, "draftKey": "d", "capsule": ["text": "x"]])
        await rig.send("_acpmux/handoff_start", ["handoffId": "h-picked", "revision": 1, "promptId": "p"])
        // The click is used: another handoff from outside the scope is refused.
        await rig.send("_acpmux/handoff_start", ["handoffId": "h-other", "revision": 1], expect: .gestureRequired)
        await rig.send("acp.session.fork", ["sessionId": "s-foreign", "throughSeq": 5], expect: .gestureRequired)
    }

    @Test func aRefusedForkOrHandoffNeverUsesTheClick() async throws {
        let rig = try await rig()
        defer { rig.server.stop() }
        // Refused for its params: the click's scope credit stays for the attach.
        rig.transport.gestures.record()
        await rig.send("acp.session.fork", ["sessionId": "s-foreign", "throughSeq": 3, "extra": true], expect: .intentInvalid)
        await rig.send("_acpmux/handoff_prepare", ["sessionId": "s-foreign", "harness": "codex", "handoffKey": "k", "extra": 1],
                       expect: .intentInvalid)
        await rig.send("_acpmux/attach", ["sessionId": "s-clicked", "limit": 10])
        #expect(rig.transport.sessions.contains("s-clicked"))
        // A new click whose attach used the scope credit: the fork is refused, and the grant
        // credit stays for the prompt.
        rig.transport.gestures.record()
        await rig.send("_acpmux/attach", ["sessionId": "s-second", "limit": 10])
        #expect(rig.transport.sessions.contains("s-second"))
        for (method, params) in Self.frames(source: "s-foreign", handoff: "h-foreign") {
            await rig.send(method, params, expect: .gestureRequired)
        }
        await rig.send("session/prompt", ["sessionId": "s-second", "prompt": [Any]()])
        #expect(await forksAndHandoffs(rig, naming: "-foreign").isEmpty)
    }

    @Test func aForkOrHandoffFromTheScopeKeepsTodaysRules() async throws {
        let rig = try await rig()
        defer { rig.server.stop() }
        rig.transport.sessions.add("s-mine")
        rig.server.answer("_acpmux/handoff_prepare", with: #"{"handoffId":"h-mine","source":{"sessionId":"s-mine"}}"#)
        // No click: every frame from a session in scope passes, as before.
        await rig.send("acp.session.fork", ["sessionId": "s-mine", "throughSeq": 3])
        await rig.send("_acpmux/handoff_prepare", ["sessionId": "s-mine", "harness": "codex", "handoffKey": "k"])
        #expect(await pageGot(rig, "h-mine"))
        for (method, params) in Self.frames(source: "s-mine", handoff: "h-mine").dropFirst(2) {
            await rig.send(method, params)
        }
        #expect(await forksAndHandoffs(rig, naming: "-mine").count == 5)
        // And none of them used a click.
        rig.transport.gestures.record()
        await rig.send("_acpmux/attach", ["sessionId": "s-clicked", "limit": 10])
        #expect(rig.transport.sessions.contains("s-clicked"))
    }
}

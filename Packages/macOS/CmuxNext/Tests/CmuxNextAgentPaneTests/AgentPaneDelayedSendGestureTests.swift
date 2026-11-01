import Foundation
import Testing
@testable import CmuxNextAgentPane

/// P0, 2026-10-29: on a Mac at load ~200, Leo's own typed messages came back "Not sent: it needs
/// your own key press or click." The person's Enter was recorded when AppKit dispatched it, but the
/// page's prompt reached the relay more than ``AgentPaneUserGestures/lifetime`` later (a starved main
/// thread and web process), so the expired gesture refused a send the person made. A send now spends
/// the person's unspent gesture however old it is; only a send with no gesture of theirs is refused.
@Suite(.serialized)
@MainActor
struct AgentPaneDelayedSendGestureTests {
    typealias Slow = AgentPaneSlowStartPromptTests

    /// A pane whose chat `s-new` already runs, started with no gesture, so no start credit is left.
    static func paneWithChat() async throws -> Slow.Pane {
        let pane = try await Slow.pane()
        #expect(await Slow.start(pane, id: 1) == nil)
        return pane
    }

    @Test func aRealEnterSendsWhenTheMainThreadDelaysThePromptPastTheGestureLifetime() async throws {
        let pane = try await Self.paneWithChat()
        defer { pane.server.stop(); try? FileManager.default.removeItem(atPath: pane.folder) }

        // The person's Enter; the loaded main thread hands the page's prompt over two minutes later.
        pane.transport.gestures.record()
        pane.clock.now += AgentPaneUserGestures.lifetime * 4
        #expect(!pane.transport.gestures.isAvailable, "the test needs the gesture past its lifetime")

        let sent = await pane.transport.send(connection: pane.id, frames: [Slow.prompt(id: 2, promptId: "p-1")])
        #expect(sent == nil, "the person's own Enter was refused for its age")
        guard sent == nil else { return }
        _ = await pane.inbox.frame(containing: #""id":2"#)
        #expect(pane.server.peers.first?.frames.contains { $0.contains("session/prompt") } == true)

        // One send per gesture: a prompt with no new key press or click is still refused.
        #expect(await pane.transport.send(connection: pane.id, frames: [Slow.prompt(id: 3, promptId: "p-2")]) == .gestureRequired)
    }

    @Test func aPromptWithNoGestureOfThePersonsIsStillRefused() async throws {
        let pane = try await Self.paneWithChat()
        defer { pane.server.stop(); try? FileManager.default.removeItem(atPath: pane.folder) }

        pane.clock.now += AgentPaneUserGestures.lifetime * 4
        #expect(await pane.transport.send(connection: pane.id, frames: [Slow.prompt(id: 2, promptId: "p-1")]) == .gestureRequired)
    }

    /// A send that takes a ticket first (a prompt with attachments, `nativePromptUpload.ts`) gets it
    /// from a delayed Enter too, once.
    @Test func aSendTicketComesFromADelayedEnter() async throws {
        let pane = try await Self.paneWithChat()
        defer { pane.server.stop(); try? FileManager.default.removeItem(atPath: pane.folder) }

        pane.transport.gestures.record()
        pane.clock.now += AgentPaneUserGestures.lifetime * 4
        let request: [String: Any] = ["method": "session/prompt", "params": ["promptId": "p-1"] as [String: Any]]
        let intent = try #require(AgentPaneGestureIntent(gestureParams: ["intent": request]))
        #expect(pane.transport.reserveGesture(intent) != nil, "the delayed Enter gave its send no ticket")
        #expect(pane.transport.reserveGesture(intent) == nil, "one gesture gave two send tickets")
    }

    /// Other grants keep their lifetime: only a send ignores the gesture's age.
    @Test func otherGrantsStillNeedAFreshGesture() {
        let clock = Slow.Clock()
        let gestures = AgentPaneUserGestures(now: { clock.now })
        #expect(!gestures.consumeForSend(), "no gesture was recorded")
        gestures.record()
        clock.now += AgentPaneUserGestures.lifetime * 4
        #expect(!gestures.consume())
    }

    /// Each rapid Enter reserves a prompt-specific ticket before the relay drains. Sending the
    /// first prompt must not clear the ticket for the second one.
    @Test func rapidPromptsKeepEachSendsGesture() throws {
        let clock = Slow.Clock()
        let gestures = AgentPaneUserGestures(now: { clock.now })
        func intent(_ promptId: String) throws -> AgentPaneGestureIntent {
            try #require(AgentPaneGestureIntent(gestureParams: [
                "intent": ["method": "session/prompt", "params": ["promptId": promptId]],
            ]))
        }

        gestures.record()
        let first = try #require(gestures.reserve(connection: 1, intent: intent("p-first")))
        gestures.record()
        let second = try #require(gestures.reserve(connection: 1, intent: intent("p-second")))

        func pick(_ promptId: String) -> AgentPaneGesturePick {
            AgentPaneGesturePick(method: "session/prompt", params: [
                "_meta": ["acpmux": ["promptId": promptId]],
            ])
        }

        #expect(gestures.redeem(first, connection: 1, pick: pick("p-first")))
        gestures.clearTicketsKeepingPrompts()
        #expect(gestures.redeem(second, connection: 1, pick: pick("p-second")))
    }

    @Test func anEffortTicketRedeemsWhenTheOpenedHarnessUsesItsReasoningEffortAlias() throws {
        let gestures = AgentPaneUserGestures()
        gestures.record()
        let intent = try #require(AgentPaneGestureIntent(gestureParams: [
            "intent": [
                "method": "session/set_config_option",
                "params": ["configId": "effort", "value": "high"],
            ],
        ]))
        let ticket = try #require(gestures.reserve(connection: 1, intent: intent))
        let pick = AgentPaneGesturePick(method: "session/set_config_option", params: [
            "configId": "reasoning_effort",
            "value": "high",
        ])
        #expect(gestures.redeem(ticket, connection: 1, pick: pick))
    }

    @Test func aFastTicketRedeemsWhenTheOpenedHarnessUsesItsFastModeValueAlias() throws {
        let gestures = AgentPaneUserGestures()
        gestures.record()
        let intent = try #require(AgentPaneGestureIntent(gestureParams: [
            "intent": [
                "method": "session/set_config_option",
                "params": ["configId": "fast-mode", "value": "on"],
            ],
        ]))
        let ticket = try #require(gestures.reserve(connection: 1, intent: intent))
        let pick = AgentPaneGesturePick(method: "session/set_config_option", params: [
            "configId": "fast_mode",
            "value": "true",
        ])
        #expect(gestures.redeem(ticket, connection: 1, pick: pick))
    }
}

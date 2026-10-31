import AppKit
@testable import CmuxNextPages
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// A mode picked in the composer's menu applies on one click (Leo, 2026-10-31: "this is what
/// happened with teh cmux NEXT app i got...": "Couldn't switch to auto: Click the choice again to
/// apply it.", the relay's `transport.gesture_required` for `session/set_mode`).
@Suite(.serialized)
@MainActor
struct AgentPaneModePickGestureTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    final class Clock { var now: TimeInterval = 1000 }

    private func modeIntent(_ mode: String = "auto") throws -> AgentPaneGestureIntent {
        try #require(AgentPaneGestureIntent(gestureParams: ["intent": ["method": "session/set_mode", "params": ["modeId": mode]]]))
    }

    private func modeFrame(_ mode: String = "auto") -> [String: Any] {
        ["sessionId": "s-1", "modeId": mode]
    }

    /// A mouse up from the HID system (source pid 0), or posted by another process.
    private func click(person: Bool) throws -> NSEvent {
        let event = try #require(CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: .zero, mouseButton: .left))
        event.setIntegerValueField(.eventSourceUnixProcessID, value: person ? 0 : Int64(getpid()) + 1)
        return try #require(NSEvent(cgEvent: event))
    }

    /// A mode picked while a harness starts waits with its ticket for the session; a start slower
    /// than a minute (a loaded Mac, a gateway that answers slowly) refused the pick while the prompt
    /// held behind the same switch still went.
    @Test func aHeldModePickOutlivesASlowHarnessStart() throws {
        let clock = Clock()
        let gestures = AgentPaneUserGestures(now: { clock.now })
        gestures.record(click: true)
        let ticket = try #require(gestures.reserve(connection: 1, intent: modeIntent()))
        clock.now += AgentPaneUserGestures.ticketLifetime + 30
        #expect(gestures.redeem(ticket, connection: 1, method: "session/set_mode", params: modeFrame()),
                "the held mode pick was refused after a slow start")
        // Still single use, and still for its exact pick and connection only.
        #expect(!gestures.redeem(ticket, connection: 1, method: "session/set_mode", params: modeFrame()))
        gestures.record(click: true)
        let other = try #require(gestures.reserve(connection: 1, intent: modeIntent()))
        #expect(!gestures.redeem(other, connection: 1, method: "session/set_mode", params: modeFrame("bypassPermissions")))
        gestures.record(click: true)
        let elsewhere = try #require(gestures.reserve(connection: 1, intent: modeIntent()))
        #expect(!gestures.redeem(elsewhere, connection: 2, method: "session/set_mode", params: modeFrame()))
        // It still ends: past the held prompt's lifetime.
        gestures.record(click: true)
        let stale = try #require(gestures.reserve(connection: 1, intent: modeIntent()))
        clock.now += AgentPaneUserGestures.heldPromptLifetime + 1
        #expect(!gestures.redeem(stale, connection: 1, method: "session/set_mode", params: modeFrame()))
    }

    /// A permission answer's ticket stays short: only the person's fresh click answers.
    @Test func aPermissionAnswerTicketKeepsItsShortLifetime() throws {
        let answer = try #require(AgentPaneGestureIntent(gestureParams: ["intent": [
            "method": "_acpmux/permission_respond", "params": ["sessionId": "s-1", "permissionId": "p", "optionId": "allow"],
        ]]))
        #expect(answer.lifetime == AgentPaneUserGestures.ticketLifetime)
        #expect(try modeIntent().lifetime == AgentPaneUserGestures.heldPromptLifetime)
    }

    /// The composer's menu shown past the pane's edge is the native popup panel, a window of its
    /// own the pane's gesture monitor never judges: the person's pick there is the gesture, so the
    /// set_mode it sends is granted. A posted click, or no event, grants nothing.
    @Test(.timeLimit(.minutes(1))) func aPickInTheNativePopupIsThePersonsGesture() throws {
        let clock = Clock()
        let gestures = AgentPaneUserGestures(now: { clock.now })
        let model = AgentPaneModel(host: NoHost(), transport: AgentPaneTransport(gestures: gestures))
        let file = try #require(AgentPageTestRoot.page)
        let view = try #require(AgentPaneView(model: model, source: .bundled(file), pageHost: true, chromium: nil))
        defer { view.close() }
        let page = try #require(view.page)
        #expect(!gestures.isAvailable)

        // The page host's popup (the agent chat on cmux-page://cmux.agent/).
        page.popupEvent(["type": "pick", "id": "0"], current: try click(person: true))
        #expect(gestures.consume(), "a pick in the page host's popup recorded no gesture")
        #expect(!gestures.consume())
        page.popupEvent(["type": "highlight", "id": "0"], current: try click(person: true))
        #expect(!gestures.isAvailable, "a hover is no gesture")
        page.popupEvent(["type": "pick", "id": "0"], current: try click(person: false))
        #expect(!gestures.isAvailable, "another process's posted click granted a gesture")
        page.popupEvent(["type": "pick", "id": "0"], current: nil)
        #expect(!gestures.isAvailable, "a pick outside event dispatch granted a gesture")

        // The pane's own host (agent.pageHost off).
        view.popupEvent(["type": "pick", "id": "0"], current: try click(person: true))
        #expect(gestures.consume(), "a pick in the pane's own popup recorded no gesture")
        view.popupEvent(["type": "dismiss"], current: try click(person: true))
        #expect(!gestures.isAvailable)

        // The pick's gesture is what the relay's rule for session/set_mode spends.
        #expect(AcpmuxPaneMethods.needsGesture(#"{"jsonrpc":"2.0","id":1,"method":"session/set_mode","params":{"sessionId":"s-1","modeId":"auto"}}"#,
                                               options: AcpmuxPermissionOptions()))
        page.popupEvent(["type": "pick", "id": "0"], current: try click(person: true))
        let ticket = try #require(gestures.reserve(connection: 1, intent: modeIntent()), "the pick's gesture took no ticket")
        #expect(gestures.redeem(ticket, connection: 1, method: "session/set_mode", params: modeFrame()))
    }
}

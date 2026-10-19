import CmuxAgentCursor
@testable import CmuxNextAgentCursor
import Foundation
import QuartzCore
import Testing

/// What an agent types reaches its cursor's caption: the bridge takes the
/// `typing` field out before the vendored decoder (which does not know it)
/// and hands it to the window that draws the event; the layer host draws it
/// beside a placed cursor.
@MainActor
struct AgentCursorTypingTests {
    final class Visible: AgentCursorTargetResolving {
        func placement(forTarget targetID: String) -> AgentCursorPlacement {
            .visible(content: CGRect(x: 0, y: 0, width: 800, height: 600), clip: CGRect(x: 0, y: 0, width: 800, height: 600),
                     zoom: 1, magnification: 1)
        }
    }

    final class Recording: AgentCursorLayerHosting {
        var commands: [AgentCursorCommand] = []
        func apply(_ command: AgentCursorCommand) { commands.append(command) }
    }

    private func json(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    private func event(seq: Int, kind: String, extra: [String: Any] = [:]) -> [String: Any] {
        var event: [String: Any] = ["v": 1, "session_id": "s", "target_id": "T", "seq": seq, "kind": kind,
                                    "space": "viewport", "t_ms": Double(seq) * 10]
        event.merge(extra) { $1 }
        return event
    }

    /// A window slot behind a bridge that holds the lease of target T.
    private func wired() -> (AgentCursorInputBridge, AgentCursorWindowSlot, CALayer) {
        let layer = CALayer()
        let slot = AgentCursorWindowSlot(resolver: Visible(), color: { _ in CGColor(gray: 1, alpha: 1) }) { layer }
        let bridge = AgentCursorInputBridge(publisher: { _ in slot.publisher }, publishers: { [slot.publisher] })
        bridge.onTyping = { event, typing in slot.noteTyping(typing, for: event) }
        bridge.leaseChanged(target: "T", session: "s", wireState: "driving")
        return (bridge, slot, layer)
    }

    @Test func typedTextReachesTheCaptionBesideTheCursor() throws {
        let (bridge, slot, _) = wired()
        bridge.receive(json(event(seq: 0, kind: "click", extra: ["point": ["x": 40, "y": 50]])))
        bridge.receive(json(event(seq: 1, kind: "type", extra: [
            "rect": ["x": 100, "y": 200, "w": 300, "h": 30], "typing": ["text": "hello"],
        ])))
        #expect(bridge.counts.published == 2)
        #expect(bridge.counts.rejected == 0)
        let cursor = try #require(slot.stack?.host.cursorLayer(for: "s"))
        #expect(cursor.captionText.string as? String == "hello")
        #expect(cursor.caption.opacity == 1)
        #expect(cursor.root.position == CGPoint(x: 250, y: 215), "the cursor went to the field")
    }

    @Test func typingOnAPointerEventOrAnInvalidTypingRejectsTheEvent() {
        let (bridge, _, _) = wired()
        bridge.receive(json(event(seq: 0, kind: "click", extra: ["point": ["x": 1, "y": 1], "typing": ["text": "x"]])))
        bridge.receive(json(event(seq: 1, kind: "type", extra: ["typing": ["text": "x", "secretValue": "y"]])))
        bridge.receive(json(event(seq: 2, kind: "type", extra: ["typing": ["text": String(repeating: "a", count: 65)]])))
        #expect(bridge.counts.rejected == 3)
        #expect(bridge.counts.published == 0)
    }

    @Test func withTheSettingOffNothingIsDrawn() {
        let (bridge, slot, _) = wired()
        bridge.isEnabled = false
        bridge.receive(json(event(seq: 0, kind: "click", extra: ["point": ["x": 1, "y": 1]])))
        #expect(slot.stack == nil, "no cursor layers are made")
        bridge.isEnabled = true
        bridge.receive(json(event(seq: 1, kind: "click", extra: ["point": ["x": 1, "y": 1]])))
        #expect(slot.stack?.host.sessions == ["s"])
        slot.removeAll()
        #expect(slot.stack?.host.sessions == [], "turning it off removes the cursors")
    }

    @Test func typingBeforeAnyPlacedInputShowsNoCaption() {
        let host = Recording()
        let model = AgentCursorOverlayModel(resolver: Visible(), host: host)
        let typed = AutomationInputEvent(sessionID: "s", targetID: "T", seq: 0, kind: .type, space: .viewport, tMs: 0)
        model.render(typed, typing: AgentTyping(text: "hi"))
        #expect(host.commands.isEmpty, "no field was measured and no cursor is placed")
        let field = AutomationInputEvent(sessionID: "s", targetID: "T", seq: 1, kind: .type, space: .viewport,
                                         rect: .init(x: 0, y: 0, w: 10, h: 10), tMs: 10)
        model.render(field, typing: AgentTyping(text: "!"))
        #expect(host.commands.contains(.caption(session: "s", text: "hi!")))
    }
}

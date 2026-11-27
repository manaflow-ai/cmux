import CmuxAgentCursor
@testable import CmuxNextAgentCursor
import Foundation
import QuartzCore
import Testing

/// Browser use thread (user, 2026-10-19: "We need to show the mouse cursor"):
/// each agent's cursor carries its name in a tag beside the arrow, the
/// keystroke caption sits under the tag, and a drag ends where it dropped.
@MainActor
struct AgentCursorNameTagTests {
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

    @Test(arguments: [
        ("cmux-browser-cli:Claude", "Claude"),
        ("cmux-browser-cli:  Codex  ", "Codex"),
        ("cmux-browser-cli", "Agent"),
        ("cmux-browser-cli:", "Agent"),
        ("chief-a139", "chief-a139"),
        ("a-very-long-repl-session-name-for-a-test", "a-very-long-repl-sessio…"),
    ])
    func theTagNamesTheSession(session: String, label: String) {
        #expect(AgentCursorSessionLabel(sessionID: session).text == label)
    }

    @Test func aPlacedCursorShowsItsAgentsName() throws {
        let layer = CALayer()
        let host = AgentCursorLayerHost(hostLayer: layer, color: { _ in CGColor(gray: 1, alpha: 1) })
        host.apply(.place(session: "cmux-browser-cli:Claude", point: CGPoint(x: 100, y: 100)))
        let cursor = try #require(host.cursorLayer(for: "cmux-browser-cli:Claude"))
        #expect(cursor.nameText.string as? String == "Claude")
        #expect(!cursor.nameTag.isHidden)
        #expect(cursor.nameTag.frame.width > 20, "the tag fits the name")
        #expect(cursor.nameTag.frame.minX > 0 && cursor.nameTag.frame.minY > 0, "the tag sits below-right of the tip, off the point acted on")
    }

    @Test func theCaptionSitsUnderTheNameTag() throws {
        let layer = CALayer()
        let host = AgentCursorLayerHost(hostLayer: layer, color: { _ in CGColor(gray: 1, alpha: 1) })
        host.apply(.place(session: "s", point: CGPoint(x: 100, y: 100)))
        host.apply(.caption(session: "s", text: "hello"))
        let cursor = try #require(host.cursorLayer(for: "s"))
        #expect(cursor.caption.frame.minY >= cursor.nameTag.frame.maxY, "caption below the tag, never over it")
    }

    @Test func theTagHidesWithTheArrowForAHiddenTarget() throws {
        let layer = CALayer()
        let host = AgentCursorLayerHost(hostLayer: layer, color: { _ in CGColor(gray: 1, alpha: 1) })
        host.apply(.indicate(session: "s", anchor: CGPoint(x: 5, y: 5)))
        let cursor = try #require(host.cursorLayer(for: "s"))
        #expect(cursor.nameTag.isHidden)
    }

    /// Seen in the browser use proof (2026-10-19): mid-drag the tag read upside down.
    @Test func aGlideTurnsTheArrowButNeverItsNameTagOrCaption() throws {
        let layer = CALayer()
        let host = AgentCursorLayerHost(hostLayer: layer, color: { _ in CGColor(gray: 1, alpha: 1) })
        host.apply(.place(session: "s", point: CGPoint(x: 400, y: 100)))
        let plan = GlideMotion().plan(fromX: 400, fromY: 100, toX: 100, toY: 300, endHeading: 2.5)
        host.apply(.glide(session: "s", plan: plan))
        let cursor = try #require(host.cursorLayer(for: "s"))
        let rootTurn = (cursor.root.value(forKeyPath: "transform.rotation.z") as? Double) ?? 0
        #expect(abs(rootTurn) < 1e-9, "the tag and caption stay level")
        #expect(cursor.root.animation(forKey: "agentCursor.heading") == nil)
        let arrowTurn = (cursor.heading.value(forKeyPath: "transform.rotation.z") as? Double) ?? 0
        let last = try #require(plan.samples.last)
        #expect(abs(arrowTurn - (last.heading - AgentCursorOverlayModel.restingHeading)) < 1e-6, "the arrow points along travel")
    }

    /// Movement pinned on: under the system's Reduce Motion (on in Blacksmith's macOS VMs) the
    /// cursor rightly appears at the drop with no glide.
    @Test func aDragGlidesToTheGrabThenEndsAtTheDrop() throws {
        let host = Recording()
        let model = AgentCursorOverlayModel(resolver: Visible(), host: host, animatesMovement: { true })
        model.render(AutomationInputEvent(sessionID: "s", targetID: "T", seq: 0, kind: .click, space: .viewport,
                                          point: .init(x: 10, y: 10), tMs: 0))
        model.render(AutomationInputEvent(sessionID: "s", targetID: "T", seq: 1, kind: .drag, space: .viewport,
                                          point: .init(x: 100, y: 100), to: .init(x: 300, y: 200), tMs: 10))
        guard case let .glide(_, plan) = try #require(host.commands.last) else {
            Issue.record("a drag glides: \(host.commands)")
            return
        }
        let first = try #require(plan.samples.first), last = try #require(plan.samples.last)
        #expect(abs(first.x - 10) < 30 && abs(first.y - 10) < 30, "starts where the cursor was")
        #expect(plan.samples.contains { abs($0.x - 100) < 2 && abs($0.y - 100) < 2 }, "passes the grab point")
        #expect(abs(last.x - 300) < 0.5 && abs(last.y - 200) < 0.5, "ends at the drop, not the grab")
        // The next input starts from the drop.
        model.render(AutomationInputEvent(sessionID: "s", targetID: "T", seq: 2, kind: .click, space: .viewport,
                                          point: .init(x: 300, y: 200), tMs: 20))
        #expect(host.commands.filter { if case .glide = $0 { true } else { false } }.count == 1,
                "one glide for the drag; a click at the drop does not move the cursor again")
    }
}

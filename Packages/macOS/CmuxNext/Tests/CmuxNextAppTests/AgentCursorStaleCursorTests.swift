import CmuxAgentCursor
@testable import CmuxNextAgentCursor
import CoreGraphics
import QuartzCore
import Testing

/// An agent cursor shows only while its agent acts on that tab (user report, 2026-11-09: a
/// "lin-shell2" cursor drew on a browser tab, "New chat" on linear.app, where no agent was acting).
/// Two leaks: a tab switch or a scroll re-placed the cursor and restarted its 10 s idle hide, so a
/// cursor that had faded came back each time the person looked at the tab; and a session that lost
/// the tab's lease but still held another tab kept its cursor on the tab it no longer drives.
@MainActor
struct AgentCursorStaleCursorTests {
    /// A tab the test shows, hides and scrolls.
    final class Tab: AgentCursorTargetResolving {
        var placement = AgentCursorPlacement.visible(
            content: CGRect(x: 0, y: 0, width: 800, height: 600), clip: CGRect(x: 0, y: 0, width: 800, height: 600),
            zoom: 1, magnification: 1
        )
        func placement(forTarget _: String) -> AgentCursorPlacement {
            placement
        }
    }

    final class Recording: AgentCursorLayerHosting {
        var commands: [AgentCursorCommand] = []
        func apply(_ command: AgentCursorCommand) {
            commands.append(command)
        }
    }

    static func click(_ target: String, seq: UInt64 = 0) -> AutomationInputEvent {
        AutomationInputEvent(sessionID: "lin-shell2", targetID: target, seq: seq, kind: .click, space: .viewport,
                             point: .init(x: 100, y: 100), tMs: Double(seq) * 1000)
    }

    /// The person switching away from the tab and back, and scrolling it, is no agent action: the cursor
    /// keeps the idle hide its agent's last action armed, so a faded cursor stays hidden.
    @Test func aTabSwitchOrScrollDoesNotBringBackAnIdleCursor() throws {
        let tab = Tab()
        let host = AgentCursorLayerHost(hostLayer: CALayer(), color: { _ in CGColor(gray: 1, alpha: 1) })
        let model = AgentCursorOverlayModel(resolver: tab, host: host, animatesMovement: { true })
        model.render(Self.click("T"))
        let root = try #require(host.cursorLayer(for: "lin-shell2")).root
        let armed = try #require(root.animation(forKey: "agentCursor.idleHide") as? CABasicAnimation).beginTime

        tab.placement = .hidden(anchor: CGRect(x: 40, y: 8, width: 20, height: 20))
        model.placementsDidChange(target: "T")
        tab.placement = .visible(content: CGRect(x: 0, y: -200, width: 800, height: 600),
                                 clip: CGRect(x: 0, y: 0, width: 800, height: 600), zoom: 1, magnification: 1)
        model.placementsDidChange(target: "T")

        let after = try #require(root.animation(forKey: "agentCursor.idleHide") as? CABasicAnimation).beginTime
        #expect(after == armed, "the idle hide still starts 10 s after the agent's last action")
    }

    /// A session that no longer holds the tab's lease (released, or another session took it) has no
    /// cursor there, also while it still holds a lease on another tab.
    @Test func aCursorLeavesTheTabItsSessionNoLongerLeases() {
        let host = Recording()
        let model = AgentCursorOverlayModel(resolver: Tab(), host: host, animatesMovement: { false })
        let leases = AgentCursorLeaseFanOut(models: { [model] })
        leases.leaseChanged(target: "linear", session: "lin-shell2", wireState: "driving")
        leases.leaseChanged(target: "other", session: "lin-shell2", wireState: "driving")
        model.render(Self.click("linear"))
        host.commands = []

        leases.leaseChanged(target: "linear", session: nil, wireState: nil)

        #expect(host.commands.contains(.remove(session: "lin-shell2")), "no cursor stays on the released tab")
        host.commands = []
        model.placementsDidChange(target: "linear")
        #expect(host.commands.isEmpty, "switching back to the tab does not draw it again")
    }
}

import CmuxAgentCursor
import CoreGraphics
import Testing
@testable import CmuxNextAgentCursor

@MainActor
private final class Layout: AgentCursorTargetResolving {
    var placements: [String: AgentCursorPlacement] = [:]
    func placement(forTarget targetID: String) -> AgentCursorPlacement { placements[targetID] ?? .elsewhere }
}

@MainActor
private final class Host: AgentCursorLayerHosting {
    var commands: [AgentCursorCommand] = []
    func apply(_ command: AgentCursorCommand) { commands.append(command) }
}

private func event(
    _ session: String = "s1", target: String = "tab_1", seq: UInt64 = 0, kind: AutomationInputEvent.Kind = .move,
    point: AutomationInputEvent.Point = .init(x: 40, y: 20), zoom: Double? = nil
) -> AutomationInputEvent {
    AutomationInputEvent(sessionID: session, targetID: target, seq: seq, kind: kind, space: .viewport,
                         point: point, zoom: zoom, tMs: Double(seq))
}

@MainActor
@Suite struct AgentCursorVisibilityChangeTests {
    private let viewport = CGRect(x: 100, y: 50, width: 800, height: 600)

    @Test func thePageZoomNowAppliesWhenTheEventCarriesNone() {
        let point = AgentCursorGeometry.overlayPoint(of: event(), content: viewport, clip: viewport, zoom: 2, magnification: 1)
        #expect(point == CGPoint(x: 180, y: 90))
        let own = AgentCursorGeometry.overlayPoint(of: event(zoom: 1.25), content: viewport, clip: viewport, zoom: 2, magnification: 1)
        #expect(own == CGPoint(x: 150, y: 75), "the event's own zoom wins")
    }

    @Test func aPointInTheHiddenPartOfAColumnStaysInsideTheClip() {
        // The right 300 pt of the viewport are under a docked column.
        let clip = CGRect(x: 100, y: 50, width: 500, height: 600)
        let far = event(point: .init(x: 700, y: 20))
        #expect(AgentCursorGeometry.overlayPoint(of: far, content: viewport, clip: clip, zoom: 1, magnification: 1) == CGPoint(x: 600, y: 70))
    }

    @Test func aVisibilityChangeMovesTheCursorWithoutANewEvent() {
        let layout = Layout()
        layout.placements["tab_1"] = .visible(content: viewport, clip: viewport, zoom: 1, magnification: 1)
        let host = Host()
        let model = AgentCursorOverlayModel(resolver: layout, host: host)
        model.render(event(kind: .click))
        host.commands.removeAll()

        layout.placements["tab_1"] = .hidden(anchor: CGRect(x: 10, y: 0, width: 120, height: 28))
        model.placementsDidChange(target: "tab_1")
        layout.placements["tab_1"] = .visible(content: viewport.offsetBy(dx: -50, dy: 0), clip: viewport, zoom: 1, magnification: 1)
        model.placementsDidChange(target: "tab_1")
        model.placementsDidChange(target: "tab_9")
        layout.placements["tab_1"] = .elsewhere
        model.placementsDidChange(target: "tab_1")

        #expect(host.commands == [
            .indicate(session: "s1", anchor: CGPoint(x: 70, y: 14)),
            .place(session: "s1", point: CGPoint(x: 100, y: 70)),
            .hide(session: "s1"),
        ], "no pulse on re-placement, other targets ignored")
    }

    @Test func aPausedSessionDoesNotMoveOnAVisibilityChange() {
        let layout = Layout()
        layout.placements["tab_1"] = .visible(content: viewport, clip: viewport, zoom: 1, magnification: 1)
        let host = Host()
        let model = AgentCursorOverlayModel(resolver: layout, host: host)
        model.render(event())
        model.leaseDidChange(session: "s1", state: .paused)
        host.commands.removeAll()
        layout.placements["tab_1"] = .elsewhere
        model.placementsDidChange(target: "tab_1")
        #expect(host.commands.isEmpty)
    }

    @Test func aLeaseEndUntracksTheSessionsTarget() {
        let layout = Layout()
        layout.placements["tab_1"] = .visible(content: viewport, clip: viewport, zoom: 1, magnification: 1)
        let model = AgentCursorOverlayModel(resolver: layout, host: Host())
        var untracked: [String] = []
        model.onUntrack = { untracked.append($0) }
        model.render(event())
        model.leaseDidChange(session: "s1", state: nil)
        model.leaseDidChange(session: "s1", state: nil)
        #expect(untracked == ["tab_1"])
    }
}

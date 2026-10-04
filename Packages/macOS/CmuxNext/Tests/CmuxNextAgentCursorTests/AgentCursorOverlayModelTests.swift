import CmuxAgentCursor
import CoreGraphics
import Testing
@testable import CmuxNextAgentCursor

@MainActor
private final class FakeLayout: AgentCursorTargetResolving {
    var placements: [String: AgentCursorPlacement] = [:]
    func placement(forTarget targetID: String) -> AgentCursorPlacement {
        placements[targetID] ?? .elsewhere
    }
}

@MainActor
private final class RecordingHost: AgentCursorLayerHosting {
    var commands: [AgentCursorCommand] = []
    func apply(_ command: AgentCursorCommand) { commands.append(command) }
}

private func input(
    _ session: String = "s1", target: String = "tab_1", seq: UInt64 = 0, kind: AutomationInputEvent.Kind = .click,
    point: AutomationInputEvent.Point? = .init(x: 40, y: 12), rect: AutomationInputEvent.Rect? = nil, zoom: Double? = nil
) -> AutomationInputEvent {
    AutomationInputEvent(sessionID: session, targetID: target, seq: seq, kind: kind, space: .viewport,
                         point: point, rect: rect, zoom: zoom, tMs: Double(seq))
}

@MainActor
@Suite struct AgentCursorOverlayModelTests {
    private let content = CGRect(x: 100, y: 50, width: 800, height: 600)

    @Test func viewportPointsScaleByZoomTimesMagnificationFromTheContentOrigin() {
        let point = AgentCursorGeometry.overlayPoint(of: input(zoom: 1.25), content: content, magnification: 2)
        #expect(point == CGPoint(x: 100 + 40 * 2.5, y: 50 + 12 * 2.5))
    }

    @Test func pointsOutsideTheContentAreClampedToIt() {
        let far = input(point: .init(x: 5000, y: -30))
        #expect(AgentCursorGeometry.overlayPoint(of: far, content: content, magnification: 1) == CGPoint(x: 900, y: 50))
    }

    @Test func typeWithoutAPointUsesTheFocusedRectAndKeyWithNeitherDrawsNothing() {
        let typed = input(kind: .type, point: nil, rect: .init(x: 10, y: 20, w: 100, h: 30))
        #expect(AgentCursorGeometry.pagePoint(of: typed) == CGPoint(x: 60, y: 35))
        let layout = FakeLayout()
        layout.placements["tab_1"] = .visible(content: content, magnification: 1)
        let host = RecordingHost()
        let model = AgentCursorOverlayModel(resolver: layout, host: host)
        model.render(input(kind: .key, point: nil))
        #expect(host.commands.isEmpty)
    }

    @Test func theFirstInputPlacesTheCursorAndTheNextGlidesFromThere() throws {
        let layout = FakeLayout()
        layout.placements["tab_1"] = .visible(content: content, magnification: 1)
        let host = RecordingHost()
        let model = AgentCursorOverlayModel(resolver: layout, host: host)
        model.render(input(seq: 0, kind: .move, point: .init(x: 0, y: 0)))
        model.render(input(seq: 1, kind: .click, point: .init(x: 300, y: 0)))
        #expect(host.commands.first == .place(session: "s1", point: CGPoint(x: 100, y: 50)))
        guard host.commands.count == 3, case let .glide(session, plan) = host.commands[1] else {
            Issue.record("expected place, glide, pulse: \(host.commands)")
            return
        }
        #expect(session == "s1")
        #expect(plan.origin == CGPoint(x: 100, y: 50))
        let last = try #require(plan.samples.last)
        #expect(last.x == 400 && last.y == 50)
        #expect(host.commands[2] == .pulse(session: "s1"))
    }

    @Test func aHiddenTargetPointsAtItsTabAndAnotherWindowHidesTheCursor() {
        let layout = FakeLayout()
        layout.placements["tab_2"] = .hidden(anchor: CGRect(x: 10, y: 0, width: 120, height: 28))
        let host = RecordingHost()
        let model = AgentCursorOverlayModel(resolver: layout, host: host)
        model.render(input(target: "tab_2"))
        model.render(input(target: "tab_9", seq: 1))
        #expect(host.commands == [.indicate(session: "s1", anchor: CGPoint(x: 70, y: 14)), .hide(session: "s1")])
    }

    @Test func aPausedLeaseFreezesTheCursorUntilHandBack() {
        let layout = FakeLayout()
        layout.placements["tab_1"] = .visible(content: content, magnification: 1)
        let host = RecordingHost()
        let model = AgentCursorOverlayModel(resolver: layout, host: host)
        model.render(input(seq: 0, kind: .move))
        model.leaseDidChange(session: "s1", state: .paused)
        model.render(input(seq: 1, kind: .click, point: .init(x: 200, y: 200)))
        model.leaseDidChange(session: "s1", state: .driving)
        model.leaseDidChange(session: "s1", state: nil)
        #expect(host.commands == [
            .place(session: "s1", point: CGPoint(x: 140, y: 62)),
            .setPaused(session: "s1", paused: true),
            .setPaused(session: "s1", paused: false),
            .remove(session: "s1"),
        ])
    }

    @Test func twoSessionsKeepSeparateCursors() {
        let layout = FakeLayout()
        layout.placements["tab_1"] = .visible(content: content, magnification: 1)
        let host = RecordingHost()
        let model = AgentCursorOverlayModel(resolver: layout, host: host)
        model.render(input("a", kind: .move, point: .init(x: 0, y: 0)))
        model.render(input("b", kind: .move, point: .init(x: 10, y: 10)))
        #expect(host.commands == [
            .place(session: "a", point: CGPoint(x: 100, y: 50)),
            .place(session: "b", point: CGPoint(x: 110, y: 60)),
        ])
    }
}

import CmuxAgentCursor
@testable import CmuxNextAgentCursor
import CoreGraphics
import Testing

/// A hidden overlay draws nothing (plans/cmux-next/chrome-parity/p06-scheduler.md, task 205): an
/// agent that drives a tab of a workspace no window shows makes no cursor command per input.
/// Before, every input to such a target applied `.hide` again, and each `.hide` rebuilt the
/// window's clickable tags.
@MainActor
struct AgentCursorHiddenOverlayTests {
    final class Switchable: AgentCursorTargetResolving {
        var placement: AgentCursorPlacement = .elsewhere
        func placement(forTarget targetID: String) -> AgentCursorPlacement { placement }
    }

    final class Recording: AgentCursorLayerHosting {
        var commands: [AgentCursorCommand] = []
        func apply(_ command: AgentCursorCommand) { commands.append(command) }
    }

    private static let shown = AgentCursorPlacement.visible(content: CGRect(x: 0, y: 0, width: 800, height: 600),
                                                            clip: CGRect(x: 0, y: 0, width: 800, height: 600), zoom: 1, magnification: 1)

    private func click(_ seq: UInt64) -> AutomationInputEvent {
        AutomationInputEvent(sessionID: "s", targetID: "T", seq: seq, kind: .click, space: .viewport,
                             point: .init(x: 100, y: 100), tMs: Double(seq) * 500)
    }

    private func hides(_ commands: [AgentCursorCommand]) -> Int {
        commands.filter { if case .hide = $0 { true } else { false } }.count
    }

    @Test func aHundredInputsToATargetNeverShownApplyNothing() {
        let host = Recording()
        let model = AgentCursorOverlayModel(resolver: Switchable(), host: host, animatesMovement: { false })
        for seq in 0..<100 { model.render(click(UInt64(seq))) }
        #expect(host.commands.isEmpty, "\(host.commands.count) commands for a cursor this window never draws")
    }

    @Test func aCursorThatLeavesHidesOnceThenAppliesNothing() {
        let resolver = Switchable()
        resolver.placement = Self.shown
        let host = Recording()
        let model = AgentCursorOverlayModel(resolver: resolver, host: host, animatesMovement: { false })
        model.render(click(0))
        #expect(!host.commands.isEmpty, "the shown target draws")
        // The person switches to another workspace: the next input hides the cursor, once.
        resolver.placement = .elsewhere
        host.commands = []
        for seq in 1...100 { model.render(click(UInt64(seq))) }
        #expect(hides(host.commands) == 1)
        #expect(host.commands.count == 1, "only the one hide: \(host.commands)")
        // Shown again, the next input draws it again.
        resolver.placement = Self.shown
        host.commands = []
        model.render(click(101))
        #expect(host.commands.contains { if case .place = $0 { true } else { false } })
    }

    @Test func aVisibilityChangeToElsewhereHidesOnce() {
        let resolver = Switchable()
        resolver.placement = Self.shown
        let host = Recording()
        let model = AgentCursorOverlayModel(resolver: resolver, host: host, animatesMovement: { false })
        model.render(click(0))
        resolver.placement = .elsewhere
        host.commands = []
        model.placementsDidChange(target: "T")
        model.placementsDidChange(target: "T")
        #expect(hides(host.commands) == 1)
    }
}

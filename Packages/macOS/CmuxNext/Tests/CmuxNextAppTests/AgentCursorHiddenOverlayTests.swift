import CmuxAgentCursor
@testable import CmuxNextAgentCursor
import CoreGraphics
import Testing

/// A hidden overlay draws nothing (plans/cmux-next/chrome-parity/p06-scheduler.md, task 205): an
/// agent that drives a tab this window does not show makes no cursor command per input. A target
/// the window does not list (`elsewhere`) hides the cursor once; one it lists but does not show
/// (`hidden(anchor:)`, a background workspace or tab) puts the indicator on its anchor once and
/// refreshes it at most once per half idle fade. Before, every input applied `.hide` or
/// `.indicate` again, and each rebuilt the window's clickable tags.
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

    /// The usual hidden workspace: listed in this window's sidebar but not shown
    /// (`AgentCursorPlacement.hidden(anchor:)`). Its first input puts the indicator on the anchor;
    /// the next 99 inputs, all within half the indicator's idle fade, apply nothing (no glide
    /// removal, no idle re-arm, no tag rebuild).
    @Test func aHundredInputsToAListedButHiddenWorkspaceIndicateOnce() {
        let resolver = Switchable()
        resolver.placement = .hidden(anchor: CGRect(x: 10, y: 200, width: 220, height: 28))
        let host = Recording()
        let model = AgentCursorOverlayModel(resolver: resolver, host: host, animatesMovement: { false })
        for seq in 0..<100 {
            model.render(AutomationInputEvent(sessionID: "s", targetID: "T", seq: UInt64(seq), kind: .click, space: .viewport,
                                              point: .init(x: 100, y: 100), tMs: Double(seq) * 10))
        }
        #expect(host.commands.count <= 1, "\(host.commands.count) commands for 100 inputs to a hidden workspace")
        #expect(host.commands.contains { if case .indicate = $0 { true } else { false } }, "the sidebar row shows where the agent works")
    }

    /// The indicator stays up while the agent keeps working: an input half an idle fade after the
    /// last `.indicate` refreshes it; a moved anchor (the row moved) indicates at once.
    @Test func theIndicatorRefreshesAtHalfItsIdleFadeAndFollowsItsAnchor() {
        let resolver = Switchable()
        resolver.placement = .hidden(anchor: CGRect(x: 10, y: 200, width: 220, height: 28))
        let host = Recording()
        let model = AgentCursorOverlayModel(resolver: resolver, host: host, animatesMovement: { false })
        let half = AgentCursorLayerHost.idleHideDelay * 1000 / 2
        func input(_ seq: UInt64, at tMs: Double) -> AutomationInputEvent {
            AutomationInputEvent(sessionID: "s", targetID: "T", seq: seq, kind: .click, space: .viewport, point: .init(x: 100, y: 100), tMs: tMs)
        }
        model.render(input(0, at: 0))
        model.render(input(1, at: half - 1))
        #expect(host.commands.count == 1)
        model.render(input(2, at: half))
        #expect(host.commands.count == 2, "the indicator was not refreshed half an idle fade later")
        resolver.placement = .hidden(anchor: CGRect(x: 10, y: 240, width: 220, height: 28))
        model.render(input(3, at: half + 1))
        #expect(host.commands.count == 3, "a moved anchor did not move the indicator")
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

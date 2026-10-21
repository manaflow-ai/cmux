import CmuxAgentCursor
@testable import CmuxNextAgentCursor
import CoreGraphics
import Testing

/// The agent cursor traces the human path the page got
/// (plans/cmux-next/human-mouse-DESIGN.md): streamed moves are followed
/// with short linear segments and no spring, a lone move still glides, and
/// Reduce Motion snaps every placement.
@MainActor
struct AgentCursorHumanFollowTests {
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

    private func move(_ seq: UInt64, x: Double, y: Double, tMs: Double) -> AutomationInputEvent {
        AutomationInputEvent(sessionID: "s", targetID: "T", seq: seq, kind: .move, space: .viewport,
                             point: .init(x: x, y: y), tMs: tMs)
    }

    private func plans(_ commands: [AgentCursorCommand]) -> [GlidePlan] {
        commands.compactMap { if case let .glide(_, plan) = $0 { plan } else { nil } }
    }

    @Test func streamedMovesAreFollowedLinearlyWithoutASpring() throws {
        let host = Recording()
        let model = AgentCursorOverlayModel(resolver: Visible(), host: host, animatesMovement: { true })
        model.render(move(0, x: 100, y: 100, tMs: 0))
        model.render(move(1, x: 110, y: 104, tMs: 16.7))
        model.render(move(2, x: 124, y: 110, tMs: 33.4))
        let glides = plans(host.commands)
        #expect(glides.count == 2, "each streamed sample after the first is one follow segment")
        let segment = try #require(glides.last)
        #expect(abs(segment.duration - 0.0167) < 0.006, "the segment lasts the measured gap, got \(segment.duration)")
        let last = try #require(segment.samples.last)
        #expect(abs(last.x - 124) < 0.001 && abs(last.y - 110) < 0.001)
        // Linear: every sample lies on the segment from (110,104) to (124,110), none past its end.
        for sample in segment.samples {
            let u = (sample.x - 110) / 14
            #expect(u >= -0.001 && u <= 1.001, "no overshoot past the sample")
            #expect(abs(sample.y - (104 + 6 * u)) < 0.01, "on the straight segment")
        }
    }

    @Test func aLoneMoveAfterIdleStillGlides() throws {
        let host = Recording()
        let model = AgentCursorOverlayModel(resolver: Visible(), host: host, animatesMovement: { true })
        model.render(move(0, x: 100, y: 100, tMs: 0))
        model.render(move(1, x: 500, y: 300, tMs: 2_000))
        let glide = try #require(plans(host.commands).last)
        #expect(glide.arrivedTick > 0 && glide.samples.count > glide.arrivedTick, "the glide keeps its settle")
    }

    @Test func reduceMotionSnapsEveryPlacement() {
        let host = Recording()
        let model = AgentCursorOverlayModel(resolver: Visible(), host: host, animatesMovement: { false })
        model.render(move(0, x: 100, y: 100, tMs: 0))
        model.render(move(1, x: 110, y: 104, tMs: 16.7))
        model.render(move(2, x: 500, y: 300, tMs: 2_000))
        #expect(plans(host.commands).isEmpty, "no glide or follow under Reduce Motion")
        let placed = host.commands.compactMap { if case let .place(_, point) = $0 { point } else { nil } }
        #expect(placed.count == 3)
        #expect(placed.last == CGPoint(x: 500, y: 300))
    }
}

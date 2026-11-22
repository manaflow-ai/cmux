import AppKit
import CmuxNextBridge
import CmuxNextDesignTokens
@testable import CmuxNextLayout
import Testing

/// No bounce in any motion (Lawrence 2026-11-10; plans/cmux-next/motion-first-principles-DESIGN.md,
/// principle 5 and removal 6): a velocity a release carries (a dropped tab's ghost, a released
/// divider) never takes an edge past its place, and never away from it. Each release is stepped
/// frame by frame on the springs the app gives it, at every speed.
@MainActor
@Suite struct NoBounceCarryTests {
    /// 1e-6 of a 200 pt travel: frames that do not rest by themselves (`advanceUnsettled`).
    static let allowed: CGFloat = 200 * 1e-6
    /// The ghost rests each of its four springs by itself, once it is within a quarter point and
    /// slow (`TabDragGhostMotion.step`): an edge is two of them, so it may be a rest snap off.
    static let restSnap: CGFloat = 0.25

    nonisolated static let speeds: [MotionSpeed] = MotionSpeed.allCases

    static func edges(_ rect: CGRect) -> [CGFloat] { [rect.minX, rect.maxX, rect.minY, rect.maxY] }

    /// How far any edge went past its place, and away from it, over `frames` rects.
    static func worst(from start: CGRect, to target: CGRect, _ rects: [CGRect]) -> (past: CGFloat, away: CGFloat) {
        let from = edges(start), to = edges(target)
        var past: CGFloat = 0, away: CGFloat = 0
        for rect in rects {
            let now = edges(rect)
            for edge in 0..<4 {
                let direction: CGFloat = to[edge] >= from[edge] ? 1 : -1
                past = max(past, (now[edge] - to[edge]) * direction)
                away = max(away, (from[edge] - now[edge]) * direction)
            }
        }
        return (past, away)
    }

    /// A dropped tab: the ghost goes to its landing on `settle` with the pointer's velocity
    /// (`TabDragSession.land`). Toward the landing, away from it and across it, no edge of the
    /// ghost passes the landing rect.
    @Test(arguments: speeds)
    func aDroppedGhostNeverPassesItsLanding(_ speed: MotionSpeed) {
        let policy = MotionPolicy(speed: speed, reduceMotion: false)
        let held = CGRect(x: 400, y: 300, width: 220, height: 140)
        let landing = CGRect(x: 120, y: 40, width: 160, height: 28)
        for velocity in [CGVector(dx: -4000, dy: -4000), CGVector(dx: 4000, dy: 4000), CGVector(dx: -40000, dy: 3000),
                         CGVector(dx: 0, dy: -900), CGVector.zero] {
            var ghost = TabDragGhostMotion(rect: held, cardness: 1, rectSpring: policy.spring(.track), morphSpring: policy.spring(.appear))
            ghost.rectSpring = policy.spring(.settle)
            ghost.setTarget(landing, cardness: 0, jump: true, velocity: velocity)
            let start = ghost.presentedRect
            var rects: [CGRect] = []
            for _ in 0..<360 {
                _ = ghost.step(1.0 / 120)
                rects.append(ghost.presentedRect)
            }
            let worst = Self.worst(from: start, to: landing, rects)
            #expect(worst.past <= Self.restSnap,
                    "speed \(speed.rawValue), release at \(velocity): an edge of the ghost passes its landing by \(worst.past) pt")
            #expect(worst.away <= Self.restSnap,
                    "speed \(speed.rawValue), release at \(velocity): an edge of the ghost moves \(worst.away) pt away from its landing")
            #expect(abs((rects.last?.minX ?? 0) - landing.minX) < 0.5, "the ghost did not land")
        }
    }

    /// The ghost jumping between targets on `track` while it still moves (a new slot under a
    /// moving ghost): the second jump is never passed either.
    @Test(arguments: speeds)
    func aGhostRetargetedInFlightNeverPassesItsSlot(_ speed: MotionSpeed) {
        let policy = MotionPolicy(speed: speed, reduceMotion: false)
        let first = CGRect(x: 0, y: 0, width: 200, height: 30)
        let second = CGRect(x: 300, y: 0, width: 160, height: 30)
        for frames in [1, 2, 4, 8] {
            for third in [CGRect(x: 40, y: 0, width: 180, height: 30), CGRect(x: 310, y: 0, width: 120, height: 30)] {
                var ghost = TabDragGhostMotion(rect: first, cardness: 0, rectSpring: policy.spring(.track), morphSpring: policy.spring(.appear))
                ghost.setTarget(second, cardness: 0, jump: true)
                for _ in 0..<frames { _ = ghost.step(1.0 / 120) }
                ghost.setTarget(third, cardness: 0, jump: true)
                let start = ghost.presentedRect
                var rects: [CGRect] = []
                for _ in 0..<360 {
                    _ = ghost.step(1.0 / 120)
                    rects.append(ghost.presentedRect)
                }
                let worst = Self.worst(from: start, to: third, rects)
                #expect(worst.past <= Self.restSnap,
                        "speed \(speed.rawValue), a new slot after \(frames) frames: an edge of the ghost passes it by \(worst.past) pt")
                #expect(worst.away <= Self.restSnap,
                        "speed \(speed.rawValue), a new slot after \(frames) frames: an edge of the ghost moves \(worst.away) pt away from it")
            }
        }
    }

    /// A divider released while it moves (`SplitMotion.seed`): the pane beside it and the divider
    /// start with the release's velocity and stop on the snapped layout, on the split's spring and
    /// on `move`.
    @Test(arguments: speeds)
    func aReleasedDividerNeverPassesItsRest(_ speed: MotionSpeed) {
        let policy = MotionPolicy(speed: speed, reduceMotion: false)
        for token in [MotionSpring.split, .move] {
            for velocity in [600, 6000, 60000] as [CGFloat] {
                let paneStart = CGRect(x: 0, y: 0, width: 200, height: 100), paneRest = CGRect(x: 0, y: 0, width: 260, height: 100)
                let dividerStart = CGRect(x: 200, y: 0, width: 4, height: 100), dividerRest = CGRect(x: 260, y: 0, width: 4, height: 100)
                var pane = AnimatedFrame(paneStart)
                pane.setTarget(paneRest)
                var divider = AnimatedFrame(dividerStart)
                divider.setTarget(dividerRest)
                var frames: [PaneID: AnimatedFrame] = [PaneID("beside"): pane]
                var dividers: [DividerHandleView.Kind: AnimatedFrame] = [.split(SplitID("d")): divider]
                SplitMotion.seed(velocity: velocity, along: .horizontal, divider: divider, panes: &frames, dividers: &dividers)
                var paneRects: [CGRect] = [], dividerRects: [CGRect] = []
                var movingPane = frames[PaneID("beside")] ?? pane, movingDivider = dividers[.split(SplitID("d"))] ?? divider
                #expect(movingPane.width.velocity > 0, "the release gave the pane no velocity")
                for _ in 0..<360 {
                    _ = movingPane.advanceUnsettled(1.0 / 120, parameters: policy.spring(token))
                    _ = movingDivider.advanceUnsettled(1.0 / 120, parameters: policy.spring(token))
                    paneRects.append(movingPane.rect)
                    dividerRects.append(movingDivider.rect)
                }
                let paneWorst = Self.worst(from: paneStart, to: paneRest, paneRects)
                let dividerWorst = Self.worst(from: dividerStart, to: dividerRest, dividerRects)
                #expect(max(paneWorst.past, dividerWorst.past) <= Self.allowed,
                        "speed \(speed.rawValue), \(token.rawValue), release at \(velocity) pt/s: an edge passes its rest by \(max(paneWorst.past, dividerWorst.past)) pt")
                #expect(max(paneWorst.away, dividerWorst.away) <= Self.allowed,
                        "speed \(speed.rawValue), \(token.rawValue), release at \(velocity) pt/s: an edge moves away from its rest")
            }
        }
    }
}

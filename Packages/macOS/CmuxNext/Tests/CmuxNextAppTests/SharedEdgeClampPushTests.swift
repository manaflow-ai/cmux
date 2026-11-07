import AppKit
import CmuxNextDesignTokens
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// FRAME OWNER REFACTOR S2B, rule D's clamp push (`SharedEdgeClamp.push`), with the springs set up by hand: a bouncy
/// anchor (`ui.animations.bounce` subtle) can overshoot its target, and the push must never carry the line past its own
/// target (the clamp), nor give it a speed there (#35775 follow-up, Codex review of the push).
@MainActor
@Suite(.closesItsWindows)
struct SharedEdgeClampPushTests {
    typealias Rig = SharedEdgeDuringSpringTests.Rig

    /// The clamp a press on split x makes when b1's anchor (A's edge, b1's left edge) rests further right than b1's
    /// minimum allows: the line springs right to its clamp (free +1), and b1 is its anchor pane.
    func clamp() -> SharedEdgeClamp {
        SharedEdgeClamp(kind: .split("x"), axis: .horizontal, free: 1, panes: ["b1": (0, 1), "b2": (1, 0)],
                        dividers: [.split("x"): (1, 1)], anchor: ("b1", false), floor: 0)
    }

    /// Sets b1's left edge (the anchor) `anchorLeft` from its target at `anchorSpeed`, and the line (b1's right edge, the
    /// divider, b2's left edge) `lineLeft` from its target at `lineSpeed`.
    func set(_ rig: Rig, anchorLeft: CGFloat, anchorSpeed: CGFloat, lineLeft: CGFloat, lineSpeed: CGFloat) throws {
        let screen = try rig.screen
        var b1 = try #require(screen.paneFrames["b1"]), b2 = try #require(screen.paneFrames["b2"])
        var divider = try #require(screen.dividerFrames[.split("x")])
        (b1.x.value, b1.x.velocity) = (b1.x.target + anchorLeft, anchorSpeed)
        (b1.width.value, b1.width.velocity) = (b1.width.target + lineLeft - anchorLeft, lineSpeed - anchorSpeed)
        (divider.x.value, divider.x.velocity) = (divider.x.target + lineLeft, lineSpeed)
        (b2.x.value, b2.x.velocity) = (b2.x.target + lineLeft, lineSpeed)
        (b2.width.value, b2.width.velocity) = (b2.width.target - lineLeft, -lineSpeed)
        screen.paneFrames["b1"] = b1
        screen.paneFrames["b2"] = b2
        screen.dividerFrames[.split("x")] = divider
    }

    func lineLeft(_ rig: Rig) throws -> (left: CGFloat, speed: CGFloat) {
        let divider = try #require(try rig.screen.dividerFrames[.split("x")])
        return (divider.x.value - divider.x.target, divider.x.velocity)
    }

    @Test func anAnchorPastItsTargetDoesNotCarryTheLinePastTheClamp() throws {
        let rig = Rig()
        defer { rig.window.closeAfterTest() }
        let clamp = clamp()
        // The anchor overshot its target by 2 pt, moving on at 30 pt/s; the line is 1 pt short of the clamp.
        try set(rig, anchorLeft: 2, anchorSpeed: 30, lineLeft: -1, lineSpeed: 10)
        clamp.push(on: try rig.screen)
        let line = try lineLeft(rig)
        #expect(abs(line.left) < 0.001, "the push left the line \(Rig.pt(line.left)) pt from its clamp (it may go to it, never past it)")
        #expect(line.speed == 10, "the push gave the line \(Rig.pt(line.speed)) pt/s at its clamp: it keeps its own speed there")
    }

    @Test func anAnchorShortOfItsTargetPushesTheLineToTheFloorAndGivesItItsSpeed() throws {
        let rig = Rig()
        defer { rig.window.closeAfterTest() }
        let clamp = clamp()
        // The anchor is 10 pt short of its target at 400 pt/s; the line 30 pt short at 50 pt/s: b1 shows 20 pt under the
        // width the floor allows (the line's leftover less the anchor's must stay at 0 or more).
        try set(rig, anchorLeft: -10, anchorSpeed: 400, lineLeft: -30, lineSpeed: 50)
        clamp.push(on: try rig.screen)
        let line = try lineLeft(rig)
        #expect(abs(line.left + 10) < 0.001, "the line shows \(Rig.pt(line.left)) pt from its clamp, the anchor's place is -10 pt")
        #expect(abs(line.speed - 400) < 0.001, "the line moves at \(Rig.pt(line.speed)) pt/s, the anchor at 400 pt/s")
        // b1's width now has no leftover and no speed of its own: it stays at its minimum while the anchor pushes.
        let b1 = try #require(try rig.screen.paneFrames["b1"])
        #expect(abs(b1.width.value - b1.width.target) < 0.001 && abs(b1.width.velocity) < 0.001,
                "b1 shows \(Rig.pt(b1.width.value - b1.width.target)) pt off its target width at \(Rig.pt(b1.width.velocity)) pt/s")
    }

    @Test func aLineAheadOfItsAnchorIsNotPushed() throws {
        let rig = Rig()
        defer { rig.window.closeAfterTest() }
        let clamp = clamp()
        try set(rig, anchorLeft: -20, anchorSpeed: 100, lineLeft: -5, lineSpeed: 80)
        clamp.push(on: try rig.screen)
        let line = try lineLeft(rig)
        #expect(abs(line.left + 5) < 0.001 && abs(line.speed - 80) < 0.001, "the push moved a line that was ahead of its anchor")
    }
}

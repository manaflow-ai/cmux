import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// PANE KEYS, the last strip column beside a full-width one (Chief 2026-11-12, from the 2026-11-11 captures of
/// Lawrence's "ctrl shift hl behavior is unintuitive when i'm in a column"): a new column opened beside a screen that
/// fills the strip (width 1) shows at the window's right edge, the full-width column partly scrolled off to the left.
/// Ctrl-Shift-H on the new column was refused: a trade gives its width to the column before it, which is already at
/// its widest share, and a trade never moves the camera. Now the column narrows on its own: the strip keeps it at the
/// window's right edge, so its left edge (the divider a person sees) moves right, and Ctrl-Shift-L takes it back the
/// same way.
@MainActor
@Suite(.closesItsWindows)
struct KeyboardResizeLastColumnScrollTests {
    typealias Rig = KeyboardResizeArrowDirectionTests.Rig

    /// The strip after a new column beside a full-width screen: the new column (p1) ends at the window's right edge.
    static func rig() throws -> Rig {
        let rig = Rig(KeyboardResizeArrowDirectionTests.columns([1, 2.0 / 3]), focus: "p1")
        let shown = try rig.shown(), edge = try rig.screen.bounds.maxX
        let p0 = try #require(shown["p0"]), p1 = try #require(shown["p1"])
        try #require(abs(p1.maxX - edge) <= 0.5 && p0.minX < -1, "SETUP: p1 is not at the window's edge past a scrolled p0: \(shown)")
        return rig
    }

    /// Ctrl-Shift-H narrows the last column: its left edge moves right by a step, its right edge stays at the window's.
    @Test func leftNarrowsTheLastColumnBesideAFullWidthOne() throws {
        let rig = try Self.rig()
        defer { rig.window.closeAfterTest() }
        let before = try #require(try rig.shown()["p1"])
        #expect(rig.press("p1", .left), "Ctrl-Shift-H on the last column was refused")
        let after = try #require(try rig.shown()["p1"])
        #expect(abs(after.minX - before.minX - rig.step) <= 1, "the last column's left edge moved \(after.minX - before.minX), want \(rig.step)")
        #expect(abs(after.maxX - before.maxX) <= 0.5, "the last column left the window's edge: \(before.maxX) -> \(after.maxX)")
    }

    /// Ctrl-Shift-L after it puts the last column back where it was.
    @Test func rightAfterLeftPutsTheLastColumnBack() throws {
        let rig = try Self.rig()
        defer { rig.window.closeAfterTest() }
        let start = try #require(try rig.shown()["p1"])
        try #require(rig.press("p1", .left), "Ctrl-Shift-H on the last column was refused")
        #expect(rig.press("p1", .right), "Ctrl-Shift-L after it was refused")
        let back = try #require(try rig.shown()["p1"])
        #expect(abs(back.minX - start.minX) <= 1 && abs(back.maxX - start.maxX) <= 0.5, "\(start) -> \(back)")
    }
}

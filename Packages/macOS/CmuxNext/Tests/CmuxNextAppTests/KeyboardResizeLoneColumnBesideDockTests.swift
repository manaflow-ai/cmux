import CmuxNextBridge
import CoreGraphics
@testable import CmuxNextLayout
import Testing

/// PANE KEYS, a lone strip column beside a docked side dock (Lawrence 2026-11-23, video "CleanShot 2026-11-23 at
/// 2.46.47 PM": "u see issue with this? gotta fix columns stuff"). The screen was Chief's chat docked on the left and one
/// browser column beside it. With the chat focused, Ctrl-Shift-H moved the divider between them left. With the browser
/// focused, the same key moved the browser's far right edge left instead: the column narrowed on its own and left an
/// empty strip between it and the window's right edge, while the divider a person sees stayed still.
///
/// Rule now: the lone column's only divider is the dock's inner edge, and it follows the arrow, whichever of the two
/// panes has the focus. The column keeps its far edge at the window's edge, so no press leaves an empty area.
///
/// Before (#34123, 2026-11-03, kept by 0193eeb02b7 on 2026-11-11): a lone column always got wider or narrower on its own
/// across its far edge.
nonisolated struct KeyboardResizeLoneColumnBesideDockTests {
    typealias Grid = KeyboardResizeGrowShrinkTests

    /// Lawrence's screen: the chat docked on the left at half the window, one full-width browser column beside it.
    static let leftDock = Grid.strip([
        Grid.column("chat", 0.5, .leaf("chat"), dock: DockColumn(edge: .left, mode: .docked)),
        Grid.column("web", 1, .leaf("web")),
    ])

    /// The mirror: one column beside a dock docked on the right.
    static let rightDock = Grid.strip([
        Grid.column("web", 1, .leaf("web")),
        Grid.column("chat", 0.3, .leaf("chat"), dock: DockColumn(edge: .right, mode: .docked)),
    ])

    /// Every pane's frame in the window, as the screen shows it with the strip's camera at rest at its start (a lone
    /// column that fits the strip never scrolls). ``KeyboardResizeGrowShrinkTests/frames(_:)`` gives strip panes in the
    /// strip's own space, which a dock's width moves as a whole.
    static func shown(_ layout: ScreenLayout) -> [PaneID: CGRect] {
        let geometry = ScreenGeometry.compute(layout, viewport: Grid.viewport, style: Grid.style)
        let shift = geometry.viewShift(offset: 0)
        return geometry.panes.reduce(into: [:]) { frames, entry in
            frames[entry.key] = geometry.scrolls(pane: entry.key) ? entry.value.offsetBy(dx: shift, dy: 0) : entry.value
        }
    }

    /// The divider between the column and the dock: the column's left edge beside a left dock, its right edge beside a
    /// right dock.
    static func divider(_ layout: ScreenLayout, dockOnLeft: Bool) throws -> CGFloat {
        let web = try #require(shown(layout)["web"])
        return dockOnLeft ? web.minX : web.maxX
    }

    /// Ctrl-Shift-H / L on the column move the divider between it and the dock left / right by a step, as the same keys
    /// do with the dock focused; the column's far edge stays at the window's edge.
    @Test(arguments: [true, false])
    func theDividerBesideTheDockFollowsTheArrow(_ dockOnLeft: Bool) throws {
        let layout = dockOnLeft ? Self.leftDock : Self.rightDock
        let start = try #require(Self.shown(layout)["web"])
        let divider = try Self.divider(layout, dockOnLeft: dockOnLeft)
        for direction in [LayoutDirection.left, .right] {
            let pressed = try #require(Grid.press("web", direction, layout), "\(direction) on the column moved nothing")
            let moved = try Self.divider(pressed, dockOnLeft: dockOnLeft) - divider
            #expect(direction == .left ? moved < -1 : moved > 1, "\(direction): the divider beside the dock moved \(moved)")
            let web = try #require(Self.shown(pressed)["web"])
            let farEdge = dockOnLeft ? web.maxX - start.maxX : web.minX - start.minX
            #expect(abs(farEdge) < 0.5, "\(direction): the column's far edge left the window's edge by \(farEdge)")
        }
    }

    /// Beside a left dock (Lawrence's screen) the column and the dock focused move the same divider the same way: one
    /// key, one edge. (A right dock focused keeps its grow/shrink rule, so there H moves its edge right: not this case.)
    @Test func theColumnAndALeftDockMoveTheSameDivider() throws {
        let layout = Self.leftDock
        for direction in [LayoutDirection.left, .right] {
            let fromColumn = try #require(Grid.press("web", direction, layout), "\(direction) on the column moved nothing")
            let fromDock = try #require(Grid.press("chat", direction, layout), "\(direction) on the dock moved nothing")
            let (a, b) = (try Self.divider(fromColumn, dockOnLeft: true), try Self.divider(fromDock, dockOnLeft: true))
            #expect(abs(a - b) < 0.5, "\(direction): the column moved the divider to \(a), the dock to \(b)")
        }
    }

    /// No press leaves an empty area beside the column: after any run of presses it still reaches the window's edge.
    @Test(arguments: [LayoutDirection.left, .right])
    func noPressLeavesAnEmptyAreaBesideTheColumn(_ direction: LayoutDirection) throws {
        var layout = Self.leftDock
        let edge = try #require(Self.shown(layout)["web"]).maxX
        for _ in 0..<12 {
            guard let next = Grid.press("web", direction, layout) else { break }
            layout = next
            let web = try #require(Self.shown(layout)["web"])
            #expect(abs(web.maxX - edge) < 0.5, "\(direction): the column ends at \(web.maxX), the window's edge is at \(edge)")
        }
    }

    /// The press back puts both panes where they were.
    @Test(arguments: [true, false])
    func thePressBackPutsBothPanesBack(_ dockOnLeft: Bool) throws {
        let layout = dockOnLeft ? Self.leftDock : Self.rightDock
        let start = Self.shown(layout)
        for (there, back) in [(LayoutDirection.left, LayoutDirection.right), (.right, .left)] {
            let moved = try #require(Grid.press("web", there, layout), "\(there) moved nothing")
            let returned = try #require(Grid.press("web", back, moved), "\(back) after \(there) moved nothing")
            for (pane, frame) in start {
                let now = try #require(Self.shown(returned)[pane])
                #expect(abs(now.minX - frame.minX) < 0.5 && abs(now.maxX - frame.maxX) < 0.5, "\(there) then \(back): \(pane) \(frame) -> \(now)")
            }
        }
    }

    /// A lone column with no dock still gets wider or narrower on its own (the "strip, one column" row of the table).
    @Test func aLoneColumnWithNoDockStillSizesOnItsOwn() throws {
        let layout = Grid.strip([Grid.column("c0", 0.5, .leaf("web"))])
        let before = try #require(Self.shown(layout)["web"])
        let after = try #require(Grid.press("web", .right, layout).flatMap { Self.shown($0)["web"] })
        #expect(after.width > before.width + 1 && abs(after.minX - before.minX) < 0.5)
    }
}

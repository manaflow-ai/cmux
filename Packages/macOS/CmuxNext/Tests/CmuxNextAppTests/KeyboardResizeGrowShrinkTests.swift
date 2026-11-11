import CmuxNextBridge
import CoreGraphics
@testable import CmuxNextLayout
import Testing

/// PANE KEYS (plans/cmux-next/pane-keys.md; Lawrence 2026-11-07: "behavior of ctrl shift hjkl is still unintuitive to
/// me, with regards to splits and columns"): Ctrl-Shift-L / J make the focused pane one step wider / taller and
/// Ctrl-Shift-H / K one step narrower / shorter, wherever it sits. The pane's right (bottom) edge moves; when that edge
/// is the screen's own, its left (top) edge does. The press back puts every pane where it was.
///
/// Before (#34123): a press moved the divider in the arrow's direction, so Right shrank the right pane of a split, the
/// last strip column, a right dock and the last row, and a pane inside a column's split could never widen its column.
/// One row per case of the spec's table.
nonisolated struct KeyboardResizeGrowShrinkTests {
    static let viewport = CGSize(width: 1200, height: 800)

    static var style: LayoutStyle {
        var style = LayoutStyle()
        style.minimumPaneContentSize = CGSize(width: 120, height: 64)
        style.rowsEnabled = true
        return style
    }

    /// Which edge of the focused pane a grow press moves.
    nonisolated enum Edge: String, Sendable { case right, left, bottom, top }

    nonisolated struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let layout: ScreenLayout
        let pane: PaneID
        /// The edge Right (or Down, for top and bottom) moves out; nil: no press along that axis moves anything.
        let edge: Edge?
        /// The pane's other edge stays. False where the pane grows with its column: the split inside keeps its ratio, so
        /// the inner divider moves too, by the pane's share.
        var keepsOtherEdge = true
        var testDescription: String { name }
    }

    static func split(_ axis: SplitAxis, _ a: SplitNode, _ b: SplitNode, id: String = "s") -> SplitNode {
        .split(SplitID(id), axis: axis, ratio: 0.5, a: a, b: b)
    }

    static func strip(_ columns: [LayoutColumn]) -> ScreenLayout { .columns(columns) }

    static func column(_ id: String, _ width: Double, _ root: SplitNode, dock: DockColumn? = nil, rows: [LayoutRow] = []) -> LayoutColumn {
        LayoutColumn(id: ColumnID(id), width: width, root: root, dock: dock, rows: rows)
    }

    static let twoRows = column("c0", 1, split(.vertical, .leaf("r1p"), .leaf("r2p"), id: "compat"),
                                rows: [LayoutRow(id: "r1", height: 500, root: .leaf("r1p")), LayoutRow(id: "r2", height: 500, root: .leaf("r2p"))])

    static let cases: [Case] = [
        Case(name: "split screen, left pane", layout: .splits(split(.horizontal, .leaf("a"), .leaf("b"))), pane: "a", edge: .right),
        Case(name: "split screen, right pane", layout: .splits(split(.horizontal, .leaf("a"), .leaf("b"))), pane: "b", edge: .left),
        Case(name: "split screen, top pane", layout: .splits(split(.vertical, .leaf("a"), .leaf("b"))), pane: "a", edge: .bottom),
        Case(name: "split screen, bottom pane", layout: .splits(split(.vertical, .leaf("a"), .leaf("b"))), pane: "b", edge: .top),
        Case(name: "split screen, middle of three", layout: .splits(split(.horizontal, .leaf("a"), split(.horizontal, .leaf("b"), .leaf("c"), id: "t"))),
             pane: "b", edge: .right),
        Case(name: "strip, first column", layout: strip([column("c0", 0.3, .leaf("p0")), column("c1", 0.3, .leaf("p1")), column("c2", 0.3, .leaf("p2"))]),
             pane: "p0", edge: .right),
        Case(name: "strip, middle column", layout: strip([column("c0", 0.3, .leaf("p0")), column("c1", 0.3, .leaf("p1")), column("c2", 0.3, .leaf("p2"))]),
             pane: "p1", edge: .right),
        Case(name: "strip, last column", layout: strip([column("c0", 0.5, .leaf("p0")), column("c1", 0.5, .leaf("p1"))]), pane: "p1", edge: .left),
        Case(name: "strip, one column", layout: strip([column("c0", 0.5, .leaf("p0"))]), pane: "p0", edge: .right),
        Case(name: "column split, right pane of a middle column (widens the column)",
             layout: strip([column("c0", 0.4, split(.horizontal, .leaf("a"), .leaf("b"))), column("c1", 0.4, .leaf("p1"))]), pane: "b", edge: .right,
             keepsOtherEdge: false),
        Case(name: "one full-width column split, right pane (the split moves)", layout: strip([column("c0", 1, split(.horizontal, .leaf("a"), .leaf("b")))]),
             pane: "b", edge: .left),
        Case(name: "one full-width column split, left pane", layout: strip([column("c0", 1, split(.horizontal, .leaf("a"), .leaf("b")))]),
             pane: "a", edge: .right),
        Case(name: "column split, left pane of a column", layout: strip([column("c0", 0.4, split(.horizontal, .leaf("a"), .leaf("b"))), column("c1", 0.4, .leaf("p1"))]),
             pane: "a", edge: .right),
        Case(name: "column split, right pane of the last column",
             layout: strip([column("c0", 0.4, .leaf("p0")), column("c1", 0.6, split(.horizontal, .leaf("a"), .leaf("b")))]), pane: "b", edge: .left),
        Case(name: "stacked column, top pane", layout: strip([column("c0", 0.5, split(.vertical, .leaf("a"), .leaf("b"))), column("c1", 0.5, .leaf("p1"))]),
             pane: "a", edge: .bottom),
        Case(name: "stacked column, bottom pane", layout: strip([column("c0", 0.5, split(.vertical, .leaf("a"), .leaf("b"))), column("c1", 0.5, .leaf("p1"))]),
             pane: "b", edge: .top),
        Case(name: "rows, upper row", layout: strip([twoRows]), pane: "r1p", edge: .bottom),
        Case(name: "rows, last row", layout: strip([twoRows]), pane: "r2p", edge: .top),
        Case(name: "left dock", layout: strip([column("d", 0.3, .leaf("pd"), dock: DockColumn(edge: .left, mode: .docked)), column("c0", 1, .leaf("p0"))]),
             pane: "pd", edge: .right),
        Case(name: "right dock", layout: strip([column("c0", 1, .leaf("p0")), column("d", 0.3, .leaf("pd"), dock: DockColumn(edge: .right, mode: .docked))]),
             pane: "pd", edge: .left),
        Case(name: "top dock", layout: strip([column("d", 0.3, .leaf("pd"), dock: DockColumn(edge: .top, mode: .docked)), column("c0", 1, .leaf("p0"))]),
             pane: "pd", edge: .bottom),
        Case(name: "bottom dock", layout: strip([column("c0", 1, .leaf("p0")), column("d", 0.3, .leaf("pd"), dock: DockColumn(edge: .bottom, mode: .docked))]),
             pane: "pd", edge: .top),
    ]

    static func frames(_ layout: ScreenLayout) -> [PaneID: CGRect] {
        ScreenGeometry.compute(layout, viewport: viewport, style: style).panes
    }

    /// `layout` after one press of `direction` on `pane`; nil when the press changes nothing.
    static func press(_ pane: PaneID, _ direction: LayoutDirection, _ layout: ScreenLayout) -> ScreenLayout? {
        let geometry = ScreenGeometry.compute(layout, viewport: viewport, style: style)
        guard let change = PaneResize.change(for: pane, direction: direction, in: layout, shown: ShownResizeRange(geometry: geometry, style: style)) else {
            return nil
        }
        return switch change {
        case .splitRatio(let split, let ratio): layout.settingRatio(ratio, for: split)
        case .columnWidth(let column, let width): layout.settingWidth(width, for: column)
        case .columnTrade(let left, let leftWidth, let right, let rightWidth): layout.settingWidth(leftWidth, for: left).settingWidth(rightWidth, for: right)
        case .rowHeights(let column, let heights): layout.settingRowHeights(heights, for: column)
        }
    }

    static func extent(_ frame: CGRect, _ axis: SplitAxis) -> CGFloat { axis == .horizontal ? frame.width : frame.height }

    /// The grow key grows the pane across `edge` and keeps its other edge; the shrink key shrinks it across the same edge.
    @Test(arguments: cases)
    func theGrowKeyGrowsThePaneAcrossItsEdgeAndTheShrinkKeyShrinksIt(_ row: Case) throws {
        let edge = try #require(row.edge)
        let horizontal = edge == .right || edge == .left
        let axis: SplitAxis = horizontal ? .horizontal : .vertical
        let before = try #require(Self.frames(row.layout)[row.pane])
        for (direction, grows) in horizontal ? [(LayoutDirection.right, true), (.left, false)] : [(.down, true), (.up, false)] {
            let after = try #require(Self.press(row.pane, direction, row.layout).flatMap { Self.frames($0)[row.pane] },
                                     "\(direction) moved nothing")
            let change = Self.extent(after, axis) - Self.extent(before, axis)
            #expect(grows ? change > 1 : change < -1, "\(direction) changed the pane's extent by \(change)")
            let (moving, kept): (CGFloat, CGFloat) = switch edge {
            case .right: (after.maxX - before.maxX, after.minX - before.minX)
            case .left: (after.minX - before.minX, after.maxX - before.maxX)
            case .bottom: (after.maxY - before.maxY, after.minY - before.minY)
            case .top: (after.minY - before.minY, after.maxY - before.maxY)
            }
            #expect(abs(moving) > 1, "\(direction) did not move the pane's \(edge) edge")
            if row.keepsOtherEdge {
                #expect(abs(kept) < 0.5, "\(direction) moved the pane's other edge by \(kept)")
            } else {
                #expect(abs(kept) < abs(moving), "\(direction) moved the pane's other edge (\(kept)) as far as its \(edge) edge (\(moving))")
            }
        }
    }

    /// Every move is reversible: the grow key then the shrink key (and the shrink key then the grow key) put every pane
    /// back where it was.
    @Test(arguments: cases)
    func thePressBackPutsEveryPaneWhereItWas(_ row: Case) throws {
        let edge = try #require(row.edge)
        let keys: [(LayoutDirection, LayoutDirection)] = edge == .right || edge == .left ? [(.right, .left), (.left, .right)] : [(.down, .up), (.up, .down)]
        let start = Self.frames(row.layout)
        for (there, back) in keys {
            let moved = try #require(Self.press(row.pane, there, row.layout), "\(there) moved nothing")
            let returned = try #require(Self.press(row.pane, back, moved), "\(back) after \(there) moved nothing")
            for (pane, frame) in start {
                let now = try #require(Self.frames(returned)[pane])
                #expect(abs(now.minX - frame.minX) < 0.5 && abs(now.maxX - frame.maxX) < 0.5 && abs(now.minY - frame.minY) < 0.5
                        && abs(now.maxY - frame.maxY) < 0.5, "\(there) then \(back): \(pane) \(frame) -> \(now)")
            }
        }
    }

    /// A pane alone on a split screen has no edge to move: every key is refused.
    @Test(arguments: [LayoutDirection.left, .right, .up, .down])
    func aLonePaneRefusesEveryKey(_ direction: LayoutDirection) {
        #expect(Self.press("a", direction, .splits(.leaf("a"))) == nil)
    }

    /// A strip column with no rows fills the window's height: Up and Down are refused.
    @Test(arguments: [LayoutDirection.up, .down])
    func aFullHeightColumnRefusesUpAndDown(_ direction: LayoutDirection) {
        let layout = Self.strip([Self.column("c0", 0.5, .leaf("p0")), Self.column("c1", 0.5, .leaf("p1"))])
        #expect(Self.press("p1", direction, layout) == nil)
    }
}

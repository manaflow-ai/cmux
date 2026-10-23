import AppKit
@testable import CmuxNextDesign
import Testing

/// No O(all) work per event (perf-lead.md cause 6, row 8): the pointer is at one point, so a
/// hover refresh may read only the targets whose views lie under that point and the targets
/// that hover now. Before, every refresh (each enter and exit, each sidebar layout pass, each
/// key-window change of a Cmd-Tab) recomputed every target in the window, and a key change
/// also filed every target of the app again: ~20 ms per Cmd-Tab in a large session.
///
/// Two counts, neither a hook in the owner:
/// - recomputed: `isHoverable` calls. The owner asks it once per target it recomputes (after
///   the window and hidden checks, before the geometry).
/// - touched: the cells whose geometry, window or visibility the event read (`TouchedView`).
///   This sees the other half of the O(all) cause, index upkeep that reads every target's view
///   (a refile by window, a scan for moved views) without recomputing any hover. A refresh
///   reads only the children of the views on the pointer's path, so at most one row's cells
///   (and the cell that hovered before).
///
/// The synthesized pointer is pinned (`followsRealMouse: false`): another job that moves the
/// real mouse on a shared GUI host must not end it mid-test.
@MainActor
struct PointerHoverWorkPerEventTests {
    /// Targets one refresh may recompute: the one under the pointer and the one that hovered
    /// before (a move from one cell to the next), whatever the number of targets in the window.
    private static let budget = 2

    @MainActor
    private final class Counter {
        var asked = 0
        var changes: [(cell: Int, hovering: Bool)] = []
        /// Cells whose geometry, window or visibility was read while `recording`.
        var touched: Set<ObjectIdentifier> = []
        var recording = false

        func note(_ view: NSView) {
            if recording { touched.insert(ObjectIdentifier(view)) }
        }
    }

    /// A cell that notes every read of what a hover owner could ask a view: its geometry, its
    /// window, its superview and whether it is shown.
    private final class TouchedView: NSView {
        var counter: Counter?

        override var frame: NSRect {
            get { counter?.note(self); return super.frame }
            set { super.frame = newValue }
        }
        override var bounds: NSRect {
            get { counter?.note(self); return super.bounds }
            set { super.bounds = newValue }
        }
        override var isHidden: Bool {
            get { counter?.note(self); return super.isHidden }
            set { super.isHidden = newValue }
        }
        override var visibleRect: NSRect { counter?.note(self); return super.visibleRect }
        override var isHiddenOrHasHiddenAncestor: Bool { counter?.note(self); return super.isHiddenOrHasHiddenAncestor }
        override var window: NSWindow? { counter?.note(self); return super.window }
        override var superview: NSView? { counter?.note(self); return super.superview }
    }

    /// What one event cost: targets recomputed and cells read.
    private struct Work {
        let recomputed: Int
        let touched: Int
    }

    /// `rows` x `columns` cells, each row its own container (a sidebar section, a tab strip),
    /// each cell one hover target that counts how often it was asked.
    @MainActor
    private struct Grid {
        let window: NSWindow
        let rows: [NSView]
        let cells: [NSView]
        let hovers: [PointerHover]
        let counter: Counter
        let columns: Int

        init(rows rowCount: Int, columns: Int, side: CGFloat = 8) {
            let size = NSSize(width: CGFloat(columns) * side, height: CGFloat(rowCount) * side)
            window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            let counter = Counter()
            var rows: [NSView] = [], cells: [NSView] = [], hovers: [PointerHover] = []
            for row in 0..<rowCount {
                let rowView = NSView(frame: NSRect(x: 0, y: CGFloat(row) * side, width: size.width, height: side))
                window.contentView?.addSubview(rowView)
                rows.append(rowView)
                for column in 0..<columns {
                    let cell = TouchedView(frame: NSRect(x: CGFloat(column) * side, y: 0, width: side, height: side))
                    cell.counter = counter
                    rowView.addSubview(cell)
                    let index = cells.count
                    let hover = PointerHover(cell) { hovering in counter.changes.append((index, hovering)) }
                    hover.isHoverable = {
                        counter.asked += 1
                        return true
                    }
                    cells.append(cell)
                    hovers.append(hover)
                }
            }
            self.rows = rows
            self.cells = cells
            self.hovers = hovers
            self.counter = counter
            self.columns = columns
        }

        func center(of cell: Int) -> NSPoint {
            let view = cells[cell]
            return view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        }

        /// Runs `body` and returns how many targets it recomputed and how many cells it read.
        func work(_ body: () -> Void) -> Work {
            counter.asked = 0
            counter.touched = []
            counter.recording = true
            body()
            counter.recording = false
            return Work(recomputed: counter.asked, touched: counter.touched.count)
        }

        /// Points the pinned synthesized pointer at `point` (nil: outside the window).
        func point(at point: NSPoint?) {
            PointerHover.setDebugPointer(point, in: window, followsRealMouse: false)
        }

        func hovering() -> [Int] { hovers.indices.filter { hovers[$0].isHovering } }

        func tearDown() {
            point(at: nil)
            PointerHover.debugPointers[ObjectIdentifier(window)] = nil
            window.close()
        }
    }

    /// 2,000 targets in one window (a session's sidebar rows, tab strips and chrome buttons): a
    /// pointer move, a geometry refresh and a key-window change each recompute at most
    /// `budget` of them and read at most one row's cells plus the one that hovered before.
    @Test func aRefreshRecomputesOnlyTheTargetsUnderThePointer() {
        let grid = Grid(rows: 40, columns: 50)
        defer { grid.tearDown() }
        let first = 50 * 3 + 7, second = 50 * 21 + 33
        let all = grid.cells.count, readBudget = grid.columns + Self.budget

        func check(_ work: Work, _ event: String, recomputeBudget: Int = Self.budget) {
            #expect(work.recomputed <= recomputeBudget, "\(event) recomputed \(work.recomputed) of \(all) targets")
            #expect(work.touched <= readBudget, "\(event) read \(work.touched) of \(all) cells (one row is \(grid.columns))")
        }

        let enter = grid.work { grid.point(at: grid.center(of: first)) }
        #expect(grid.hovering() == [first])
        check(enter, "the pointer entering one cell")

        let move = grid.work { grid.point(at: grid.center(of: second)) }
        #expect(grid.hovering() == [second])
        check(move, "a move to the next cell")

        let layout = grid.work { PointerHover.refresh(in: grid.window) }
        #expect(grid.hovering() == [second])
        check(layout, "a geometry refresh")

        // A Cmd-Tab posts the window's resign and become key, and `KeyWindowObserver` refreshes
        // the window once per notice. The test runs those two refreshes itself: a post to the
        // process-wide center would reach every other suite's and AppKit's observers.
        let key = grid.work {
            PointerHover.refresh(in: grid.window)
            PointerHover.refresh(in: grid.window)
        }
        #expect(grid.hovering() == [second])
        check(key, "a key-window change (resign + become)", recomputeBudget: 2 * Self.budget)
    }

    /// The narrow refresh keeps the hover rules: a view that moves, hides or reflows under a
    /// still pointer clears and the one now under it lights, the end before the start; nested
    /// targets both hover; a view that moves to another window lights on that window's next
    /// refresh; a pointer outside the window clears everything.
    @Test func aNarrowRefreshKeepsTheHoverRules() {
        let grid = Grid(rows: 4, columns: 4, side: 20)
        defer { grid.tearDown() }
        grid.point(at: grid.center(of: 5))
        #expect(grid.hovering() == [5])

        // Cell 5 moves away and cell 6 slides under the still pointer.
        let five = grid.cells[5].frame, six = grid.cells[6].frame
        grid.counter.changes = []
        grid.cells[5].frame = six
        grid.cells[6].frame = five
        PointerHover.refresh(in: grid.window)
        #expect(grid.hovering() == [6])
        #expect(grid.counter.changes.map { $0.cell } == [5, 6] && grid.counter.changes.map { $0.hovering } == [false, true],
                "the hover that ends runs before the one that starts: \(grid.counter.changes)")

        // Its row hides under the still pointer.
        grid.rows[1].isHidden = true
        PointerHover.refresh(in: grid.window)
        #expect(grid.hovering().isEmpty)
        grid.rows[1].isHidden = false
        PointerHover.refresh(in: grid.window)
        #expect(grid.hovering() == [6])

        // A target on the row itself hovers with the cell inside it.
        let rowHover = PointerHover(grid.rows[1])
        PointerHover.refresh(in: grid.window)
        #expect(rowHover.isHovering)
        #expect(grid.hovering() == [6])

        // The view leaves for another window: the hover clears with no event in that window.
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 80, height: 80), styleMask: [.borderless],
                             backing: .buffered, defer: true)
        other.isReleasedWhenClosed = false
        defer { other.close() }
        let cell = grid.cells[6]
        other.contentView?.addSubview(cell)
        cell.frame.origin = NSPoint(x: 60, y: 60)
        PointerHover.refresh(in: grid.window)
        #expect(grid.hovering().isEmpty)
        #expect(rowHover.isHovering)

        // The moved view lights on its new window's next refresh (no window index notices the
        // move at once: an owner that re-parents under the pointer refreshes the new window).
        let inOther = cell.convert(NSPoint(x: cell.bounds.midX, y: cell.bounds.midY), to: nil)
        PointerHover.setDebugPointer(inOther, in: other, followsRealMouse: false)
        #expect(grid.hovering() == [6])
        PointerHover.setDebugPointer(nil, in: other, followsRealMouse: false)
        PointerHover.debugPointers[ObjectIdentifier(other)] = nil
        #expect(grid.hovering().isEmpty)

        // The pointer leaves the window.
        grid.point(at: nil)
        #expect(!rowHover.isHovering)
        #expect(grid.hovering().isEmpty)
    }
}

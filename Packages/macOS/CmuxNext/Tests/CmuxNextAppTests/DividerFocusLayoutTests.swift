import AppKit
@testable import CmuxNextLayout
import Testing

/// A focus move changes no divider (cx-3j8y.2): the bench saw every split handle lay out on each
/// one, about 150 / 420 / 610 layout calls per move at 16 / 64 / 128 panes. Moving focus across a
/// 4 x 4 grid lays out no divider handle.
@MainActor
struct DividerFocusLayoutTests {
    /// A balanced grid of `panes` (p1...pN), splits alternating across and down.
    private static func grid(_ panes: ArraySlice<Int>, horizontal: Bool = true, next: inout Int) -> SplitNode {
        guard panes.count > 1 else { return .leaf(PaneID("p\(panes.first!)")) }
        let middle = panes.startIndex + panes.count / 2
        next += 1
        let id = SplitID("s\(next)")
        let a = grid(panes[panes.startIndex..<middle], horizontal: !horizontal, next: &next)
        let b = grid(panes[middle...], horizontal: !horizontal, next: &next)
        return .split(id, axis: horizontal ? .horizontal : .vertical, ratio: 0.5, a: a, b: b)
    }

    @Test func aFocusMoveLaysOutNoDividerHandle() throws {
        var next = 0
        let screen = DividerSnapTests.Screen(Self.grid(Array(1...16)[...], next: &next))
        let view = try #require(screen.screen)
        let handles = Array(view.dividerViews.values)
        #expect(handles.count == 15)
        // Layout reaches the handles at all: otherwise no layout per move proves nothing.
        #expect(handles.allSatisfy { $0.layoutCount > 0 })

        for pane in 2...16 {
            let before = handles.map(\.layoutCount).reduce(0, +)
            screen.model.focus(PaneID("p\(pane)"))
            screen.root.syncWithModel()
            screen.root.layoutSubtreeIfNeeded()
            let passes = handles.map(\.layoutCount).reduce(0, +) - before
            #expect(passes == 0, "focus p\(pane) laid out \(passes) divider handle(s)")
        }
    }
}

import AppKit
import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// R3b (Lawrence's rule, scope by cmux-ad 2026-10-31): a create keeps every other column's width in points.
/// New Column keeps every old column; Cmd-D (Split Right) and Split Down split inside a column, whose own
/// panes share it, and no other column changes. The check counts one violation for a create that changed
/// another column, and none for a create that kept them or a width change that is no create. Debug builds
/// record the widths (the test target builds Debug).
@MainActor @Suite(.serialized, .closesItsWindows) struct ColumnWidthInvariantTests {
    final class Panes: LayoutPaneContentProvider {
        func makeContentView(for pane: PaneID) -> NSView { NSView() }
    }

    final class Screen {
        let provider = Panes()
        let model: LayoutModel
        let root: LayoutRootView
        let window: NSWindow

        init(_ layout: ScreenLayout) {
            _ = NSApplication.shared
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: layout)], activeScreenID: "s", focusedPane: "p1")
            model.followsDesignMetrics = false
            model.baseStyle.columnGap = 0
            root = LayoutRootView(model: model, contentProvider: provider)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            root.driver.isManual = true
        }

        func close() { window.close() }

        func show(_ layout: ScreenLayout) {
            model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: layout)])
            root.syncWithModel()
            root.layoutSubtreeIfNeeded()
        }
    }

    nonisolated static func columns(_ widths: [(String, Double)]) -> ScreenLayout {
        .columns(widths.enumerated().map { index, column in
            LayoutColumn(id: ColumnID(column.0), width: column.1, root: .leaf(PaneID("p\(index + 1)")))
        })
    }

    /// Column a (p1) split by `axis` with a new pane p3 at width `a`, beside column b (p2) at width `b`.
    nonisolated static func split(_ axis: SplitAxis, a: Double, b: Double) -> ScreenLayout {
        .columns([LayoutColumn(id: "a", width: a, root: .split("s", axis: axis, ratio: 0.5, a: .leaf("p1"), b: .leaf("p3"))),
                  LayoutColumn(id: "b", width: b, root: .leaf("p2"))])
    }

    nonisolated static let twoColumns = columns([("a", 0.5), ("b", 0.5)])

    /// New Column narrows an old column; Cmd-D and Split Down in column a narrow column b; a lone split
    /// tree's first New Column takes the rest of the screen (the old `1 - width` rule).
    nonisolated static let resizingCreates: [(from: ScreenLayout, to: ScreenLayout)] = [
        (twoColumns, columns([("a", 0.4), ("b", 0.5), ("c", 0.3)])),
        (twoColumns, split(.horizontal, a: 0.6, b: 0.4)),
        (twoColumns, split(.vertical, a: 0.6, b: 0.4)),
        (.splits(.leaf("p1")), columns([("a", 0.5), ("c", 0.5)])),
    ]

    @Test(arguments: 0..<4)
    func aCreateThatResizesAnotherColumnCountsOneViolation(_ index: Int) {
        let (from, to) = Self.resizingCreates[index]
        let screen = Screen(from)
        defer { screen.close() }
        let invariant = ColumnWidthInvariant()
        screen.show(to)
        #expect(invariant.check([screen.root], action: "layout.newColumn") == 1, "a create that resized another column counted no violation")
        #expect(invariant.check([screen.root], action: "layout.newColumn") == 0, "the same create counted again")
        #expect(invariant.violations == 1)
    }

    /// New Columns keeping every old width (the new column takes new space, the strip scrolls); Cmd-D and
    /// Split Down in column a, which halve its panes and keep column b; Cmd-D on a lone split tree (no other
    /// column); and a width change that is no create (a preset, another client's drag).
    nonisolated static let keepingChanges: [(from: ScreenLayout, to: ScreenLayout)] = [
        (twoColumns, columns([("a", 0.5), ("b", 0.5), ("c", 0.3)])),
        (.splits(.leaf("p1")), columns([("a", 1), ("c", 0.5)])),
        (twoColumns, split(.horizontal, a: 0.5, b: 0.5)),
        (twoColumns, split(.vertical, a: 0.5, b: 0.5)),
        (.splits(.leaf("p1")), .splits(.split("h", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2")))),
        (twoColumns, columns([("a", 0.4), ("b", 0.6)])),
    ]

    @Test(arguments: 0..<6)
    func aChangeThatKeepsEveryOtherColumnsWidthCountsNone(_ index: Int) {
        let (from, to) = Self.keepingChanges[index]
        let screen = Screen(from)
        defer { screen.close() }
        let invariant = ColumnWidthInvariant()
        screen.show(to)
        #expect(invariant.check([screen.root], action: "layout.newColumn") == 0, "a change that kept every other column's width counted a violation")
    }
}

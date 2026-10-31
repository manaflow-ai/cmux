import AppKit
import CmuxNextDesign
@testable import CmuxNextLayout
import Testing

/// R3b (Lawrence 2026-10-31, binding: "creating new columns must never resize existing columns"): a create
/// that adds a column, New Column or Split Right, leaves every pane that existed before at its width in
/// points; the check counts one violation for a create that changed one, and none for a create that kept
/// every width, a Split Down or a width change that adds no column. Debug builds record the widths (the
/// test target builds Debug). No column gap, so a lone split tree is as wide as a full-width column.
@MainActor @Suite(.serialized) struct ColumnWidthInvariantTests {
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

    nonisolated static let splitRight: SplitNode = .split("h", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2"))
    nonisolated static let splitDown: SplitNode = .split("v", axis: .vertical, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2"))

    /// New Column narrows an existing column; Split Right (today's Cmd-D) halves the pane it splits; a lone
    /// split tree's first New Column takes the rest of the screen (the old `1 - width` rule).
    nonisolated static let resizingCreates: [(from: ScreenLayout, to: ScreenLayout)] = [
        (columns([("a", 0.5), ("b", 0.5)]), columns([("a", 0.4), ("b", 0.5), ("c", 0.3)])),
        (.splits(.leaf("p1")), .splits(splitRight)),
        (.splits(.leaf("p1")), columns([("a", 0.5), ("c", 0.5)])),
    ]

    @Test(arguments: 0..<3)
    func aCreateThatResizesAnExistingColumnCountsOneViolation(_ index: Int) {
        let (from, to) = Self.resizingCreates[index]
        let screen = Screen(from)
        defer { screen.close() }
        let invariant = ColumnWidthInvariant()
        screen.show(to)
        #expect(invariant.check([screen.root], action: "layout.newColumn") == 1, "a create that resized a column counted no violation")
        #expect(invariant.check([screen.root], action: "layout.newColumn") == 0, "the same create counted again")
        #expect(invariant.violations == 1)
    }

    /// New Columns keeping every width (the new column takes new space, the strip scrolls), a Split Down (it
    /// adds no column), and a width change that adds no column (a preset, another client's drag).
    nonisolated static let keepingChanges: [(from: ScreenLayout, to: ScreenLayout)] = [
        (columns([("a", 0.5), ("b", 0.5)]), columns([("a", 0.5), ("b", 0.5), ("c", 0.3)])),
        (.splits(.leaf("p1")), columns([("a", 1), ("c", 0.5)])),
        (.splits(.leaf("p1")), .splits(splitDown)),
        (columns([("a", 0.5), ("b", 0.5)]), columns([("a", 0.4), ("b", 0.6)])),
    ]

    @Test(arguments: 0..<4)
    func aChangeThatKeepsEveryExistingColumnsWidthCountsNone(_ index: Int) {
        let (from, to) = Self.keepingChanges[index]
        let screen = Screen(from)
        defer { screen.close() }
        let invariant = ColumnWidthInvariant()
        screen.show(to)
        #expect(invariant.check([screen.root], action: "layout.newColumn") == 0, "a change that kept every width counted a violation")
    }
}

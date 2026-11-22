import AppKit
import Testing
@testable import CmuxNextLayout

/// Center column: the model records a one-shot request and the root
/// view scrolls that column to the viewport center.
@MainActor
struct ColumnCenterTests {
    private let screen = LayoutScreen(id: "s", name: "", layout: .columns([
        LayoutColumn(id: "c1", width: 0.5, root: .leaf("a")),
        LayoutColumn(id: "c2", width: 0.5, root: .leaf("b")),
        LayoutColumn(id: "c3", width: 0.5, root: .leaf("c")),
        LayoutColumn(id: "c4", width: 0.5, root: .leaf("d")),
    ]))

    @Test func centerRequestFocusesAndCountsRepeats() {
        let model = LayoutModel(screens: [screen])
        #expect(model.centerColumn(containing: "c"))
        #expect(model.focusedPane == "c")
        #expect(model.centerRequest == ColumnCenterRequest(pane: "c", sequence: 1))
        #expect(model.centerColumn())
        #expect(model.centerRequest == ColumnCenterRequest(pane: "c", sequence: 2))
    }

    @Test func splitsScreensAndUnknownPanesRefuse() {
        let model = LayoutModel(screens: [LayoutScreen(id: "t", name: "", layout: .splits(.leaf("a")))])
        #expect(!model.centerColumn())
        #expect(!model.centerColumn(containing: "zzz"))
        #expect(model.centerRequest == nil)
    }

    @Test func rootViewScrollsTheColumnToTheViewportCenter() async {
        let model = LayoutModel(screens: [screen], activeScreenID: "s", focusedPane: "a")
        let provider = StubCenterProvider()
        let view = LayoutRootView(model: model, contentProvider: provider)
        view.frame = CGRect(x: 0, y: 0, width: 1000, height: 400)
        view.layoutSubtreeIfNeeded()

        // Focus alone reveals minimally: the column lands at the right edge.
        model.focus("c")
        await waitUntil { (view.frame(of: "c")?.maxX ?? 0) <= 1000 && (view.frame(of: "c")?.minX ?? 0) > 0 }
        #expect(abs((view.frame(of: "c")?.midX ?? 0) - 500) > 50)

        model.centerColumn()
        await waitUntil { abs((view.frame(of: "c")?.midX ?? 0) - 500) < 1 }
        #expect(abs((view.frame(of: "c")?.midX ?? 0) - 500) < 1)
        withExtendedLifetime(provider) {}
    }

    /// Waits up to 1000 turns; a timeout records an Issue at the caller with the time waited.
    private func waitUntil(sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool) async {
        let start = ContinuousClock.now
        for _ in 0..<1000 where !condition() { await Task.yield() }
        if !condition() {
            Issue.record("waitUntil gave up after 1000 turns (\(ContinuousClock.now - start)): the condition at \(sourceLocation.fileName):\(sourceLocation.line) never held",
                         sourceLocation: sourceLocation)
        }
    }
}

private final class StubCenterProvider: LayoutPaneContentProvider {
    func makeContentView(for pane: PaneID) -> NSView { NSView() }
}

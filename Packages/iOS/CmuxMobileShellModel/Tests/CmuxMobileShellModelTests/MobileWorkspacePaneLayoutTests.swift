import Testing
@testable import CmuxMobileShellModel

struct MobileWorkspacePaneLayoutTests {
    private typealias Layout = MobileWorkspacePaneLayout

    private func tab(_ id: String, kind: Layout.Tab.Kind = .terminal) -> Layout.Tab {
        Layout.Tab(id: .init(rawValue: id), kind: kind, title: "Tab \(id)")
    }

    /// A three-pane tree:
    /// horizontal(left pane [t1, t2], vertical(top pane [t3], bottom pane [b1 browser])).
    private var nestedLayout: Layout {
        Layout(
            root: .split(
                orientation: .horizontal,
                ratio: 0.6,
                first: .pane(Layout.Pane(
                    id: "pane-left",
                    tabs: [tab("t1"), tab("t2")],
                    selectedTabID: "t2"
                )),
                second: .split(
                    orientation: .vertical,
                    ratio: 0.5,
                    first: .pane(Layout.Pane(id: "pane-top", tabs: [tab("t3")], selectedTabID: "t3")),
                    second: .pane(Layout.Pane(
                        id: "pane-bottom",
                        tabs: [tab("b1", kind: .browser)],
                        selectedTabID: "b1"
                    ))
                )
            )
        )
    }

    @Test func panesAreDepthFirst() {
        let panes = nestedLayout.panes
        #expect(panes.map(\.id) == ["pane-left", "pane-top", "pane-bottom"])
    }

    @Test func orderedTabsFlattenPaneDFSThenTabOrder() {
        #expect(nestedLayout.orderedTabs.map(\.id.rawValue) == ["t1", "t2", "t3", "b1"])
    }

    @Test func paneContainingTabFindsOwningPane() {
        #expect(nestedLayout.pane(containing: "t2")?.id == "pane-left")
        #expect(nestedLayout.pane(containing: "b1")?.id == "pane-bottom")
        #expect(nestedLayout.pane(containing: "missing") == nil)
    }

    @Test func selectedTabFallsBackToFirst() {
        let pane = Layout.Pane(id: "p", tabs: [tab("a"), tab("b")], selectedTabID: nil)
        #expect(pane.selectedTab?.id == "a")
        let dangling = Layout.Pane(id: "p", tabs: [tab("a"), tab("b")], selectedTabID: "gone")
        #expect(dangling.selectedTab?.id == "a")
    }

    @Test func singlePaneFallbackPrefersFocusedTerminal() {
        let terminals = [
            MobileTerminalPreview(id: "t1", name: "one"),
            MobileTerminalPreview(id: "t2", name: "two", isFocused: true),
        ]
        let layout = Layout.singlePane(terminals: terminals)
        #expect(layout.paneCount == 1)
        #expect(layout.orderedTabs.map(\.id) == ["t1", "t2"])
        #expect(layout.panes[0].selectedTabID == "t2")
        #expect(layout.orderedTabs.allSatisfy { $0.kind == .terminal })
    }

    @Test func singlePaneFallbackWithNoFocusSelectsFirst() {
        let terminals = [
            MobileTerminalPreview(id: "t1", name: "one"),
            MobileTerminalPreview(id: "t2", name: "two"),
        ]
        #expect(Layout.singlePane(terminals: terminals).panes[0].selectedTabID == "t1")
    }

    @Test func removingTabKeepsPaneAndRepairsSelection() {
        let removed = nestedLayout.removingTab("t2")
        let leftPane = removed?.panes.first { $0.id == "pane-left" }
        #expect(leftPane?.tabs.map(\.id) == ["t1"])
        // t2 was pane-left's selection; the survivor becomes selected.
        #expect(leftPane?.selectedTabID == "t1")
    }

    @Test func removingLastTabOfPaneCollapsesSplitToSurvivor() {
        // Removing t3 empties pane-top, so the vertical split collapses to
        // pane-bottom and the root keeps only two panes.
        let removed = nestedLayout.removingTab("t3")
        #expect(removed?.panes.map(\.id) == ["pane-left", "pane-bottom"])
        guard case .split(let orientation, _, _, _)? = removed?.root else {
            Issue.record("expected the horizontal root split to survive")
            return
        }
        #expect(orientation == .horizontal)
    }

    @Test func removingEveryTabReturnsNil() {
        let single = Layout(root: .pane(Layout.Pane(id: "p", tabs: [tab("only")], selectedTabID: "only")))
        #expect(single.removingTab("only") == nil)
    }
}

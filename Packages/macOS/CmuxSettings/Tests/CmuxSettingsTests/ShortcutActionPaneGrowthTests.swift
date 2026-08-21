import Testing
@testable import CmuxSettings

@Suite("Pane growth shortcut actions")
struct ShortcutActionPaneGrowthTests {
    @Test func actionsHaveStableIdentifiersAndPaneGrouping() {
        #expect(ShortcutAction.growPaneWidth.rawValue == "growPaneWidth")
        #expect(ShortcutAction.growPaneHeight.rawValue == "growPaneHeight")
        #expect(ShortcutAction.growPaneWidth.group == .panes)
        #expect(ShortcutAction.growPaneHeight.group == .panes)
    }

    @Test func actionsHaveDistinctDefaultShortcuts() {
        #expect(
            ShortcutAction.growPaneWidth.defaultStroke ==
                ShortcutStroke(key: "0", command: true, option: true)
        )
        #expect(
            ShortcutAction.growPaneHeight.defaultStroke ==
                ShortcutStroke(key: "0", command: true, shift: true, option: true)
        )
    }
}

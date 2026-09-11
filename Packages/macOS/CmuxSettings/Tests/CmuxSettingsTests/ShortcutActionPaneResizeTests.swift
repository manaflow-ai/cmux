import Testing
@testable import CmuxSettings

@Suite("Pane resize shortcut actions")
struct ShortcutActionPaneResizeTests {
    @Test func actionsHaveStableIdentifiersAndPaneGrouping() {
        #expect(ShortcutAction.shrinkPaneWidth.rawValue == "shrinkPaneWidth")
        #expect(ShortcutAction.growPaneWidth.rawValue == "growPaneWidth")
        #expect(ShortcutAction.shrinkPaneHeight.rawValue == "shrinkPaneHeight")
        #expect(ShortcutAction.growPaneHeight.rawValue == "growPaneHeight")
        #expect(ShortcutAction.shrinkPaneWidth.group == .panes)
        #expect(ShortcutAction.growPaneWidth.group == .panes)
        #expect(ShortcutAction.shrinkPaneHeight.group == .panes)
        #expect(ShortcutAction.growPaneHeight.group == .panes)
    }

    @Test func actionsHaveDistinctDefaultShortcuts() {
        #expect(
            ShortcutAction.shrinkPaneWidth.defaultStroke ==
                ShortcutStroke(key: "←", command: true, control: true)
        )
        #expect(
            ShortcutAction.growPaneWidth.defaultStroke ==
                ShortcutStroke(key: "→", command: true, control: true)
        )
        #expect(
            ShortcutAction.shrinkPaneHeight.defaultStroke ==
                ShortcutStroke(key: "↑", command: true, control: true)
        )
        #expect(
            ShortcutAction.growPaneHeight.defaultStroke ==
                ShortcutStroke(key: "↓", command: true, control: true)
        )
    }
}

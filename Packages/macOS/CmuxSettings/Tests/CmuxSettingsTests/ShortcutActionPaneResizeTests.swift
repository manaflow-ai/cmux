import Testing
@testable import CmuxSettings

@Suite("Pane resize shortcut actions")
struct ShortcutActionPaneResizeTests {
    @Test(arguments: [
        ShortcutAction.growPaneLeft,
        ShortcutAction.growPaneRight,
        ShortcutAction.growPaneUp,
        ShortcutAction.growPaneDown,
    ])
    func directionalActionsAreVisibleButInitiallyUnbound(
        action: ShortcutAction
    ) {
        #expect(action.defaultStroke == nil)
        #expect(action.group == .panes)
        #expect(action.displayName.hasPrefix("Grow Pane "))
    }
}

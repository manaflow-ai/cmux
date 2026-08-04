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

    @Test func exactShareActionsUseQuarterShortcutsAndPaneGroup() {
        let cases: [(ShortcutAction, String, Bool)] = [
            (.setPaneWidth25Percent, "1", false),
            (.setPaneWidth50Percent, "2", false),
            (.setPaneWidth75Percent, "3", false),
            (.setPaneHeight25Percent, "1", true),
            (.setPaneHeight50Percent, "2", true),
            (.setPaneHeight75Percent, "3", true),
        ]

        for (action, key, shift) in cases {
            #expect(action.defaultStroke == ShortcutStroke(
                key: key,
                command: true,
                shift: shift,
                option: true
            ))
            #expect(action.group == .panes)
            #expect(action.displayName.contains("Pane"))
        }
    }
}

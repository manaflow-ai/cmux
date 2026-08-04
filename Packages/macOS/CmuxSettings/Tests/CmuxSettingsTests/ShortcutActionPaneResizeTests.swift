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

    @Test func ratioFamiliesUseNumberedShortcutsAndPaneGroup() {
        let cases: [(ShortcutAction, Bool)] = [
            (.setPaneWidthRatioByNumber, false),
            (.setPaneHeightRatioByNumber, true),
        ]

        for (action, shift) in cases {
            #expect(action.defaultStroke == ShortcutStroke(
                key: "1",
                command: true,
                shift: shift,
                option: true
            ))
            #expect(action.numberedDigitRange == 1...6)
            #expect(action.usesNumberedDigitMatching)
            #expect(action.group == .panes)
            #expect(action.displayName.contains("1:1–6:1"))
        }
    }
}

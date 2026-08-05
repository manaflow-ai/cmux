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
    func directionalActionsUseDefaultViResizeBindings(
        action: ShortcutAction
    ) throws {
        let expectedKey: String
        switch action {
        case .growPaneLeft: expectedKey = "h"
        case .growPaneDown: expectedKey = "j"
        case .growPaneUp: expectedKey = "k"
        case .growPaneRight: expectedKey = "l"
        default: throw TestError.unexpectedAction
        }
        #expect(action.defaultStroke == ShortcutStroke(
            key: expectedKey,
            shift: true,
            control: true
        ))
        #expect(action.group == .panes)
        #expect(action.displayName.hasPrefix("Resize Pane "))
    }

    private enum TestError: Error {
        case unexpectedAction
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
            #expect(action.numberedDigitRange == 1...3)
            #expect(action.usesNumberedDigitMatching)
            #expect(action.group == .panes)
            #expect(action.displayName.contains("1/3, 1/2, 2/3"))
        }
    }

    @Test func heightMaximizeUsesShiftOptionCommandZero() {
        let action = ShortcutAction.maximizePaneHeight
        #expect(action.defaultStroke == ShortcutStroke(
            key: "0",
            command: true,
            shift: true,
            option: true
        ))
        #expect(action.numberedDigitRange == nil)
        #expect(!action.usesNumberedDigitMatching)
        #expect(action.group == .panes)
        #expect(action.displayName == "Toggle Pane Height Maximize")
    }
}

import Foundation
import Testing
@testable import CmuxSettings

@Suite("ShortcutAction")
struct ShortcutActionTests {
    @Test func growPaneActionsArePaneShortcutsWithCommandOptionShiftArrowDefaults() {
        let cases: [(ShortcutAction, String)] = [
            (.growPaneLeft, "←"),
            (.growPaneRight, "→"),
            (.growPaneUp, "↑"),
            (.growPaneDown, "↓"),
        ]

        for (action, key) in cases {
            #expect(action.group == .panes)
            #expect(action.defaultStroke == ShortcutStroke(
                key: key,
                command: true,
                shift: true,
                option: true
            ))
        }
    }
}

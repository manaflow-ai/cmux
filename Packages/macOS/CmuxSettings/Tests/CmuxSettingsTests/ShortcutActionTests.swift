import Foundation
import Testing
@testable import CmuxSettings

@Suite("ShortcutAction")
struct ShortcutActionTests {
    @Test func resizeSplitActionsExposePaneGroupNamesAndNoDefaults() {
        let expected: [(ShortcutAction, String)] = [
            (.resizeSplitLeft, "Resize Split Left"),
            (.resizeSplitRight, "Resize Split Right"),
            (.resizeSplitUp, "Resize Split Up"),
            (.resizeSplitDown, "Resize Split Down"),
        ]

        for (action, displayName) in expected {
            #expect(ShortcutAction.allCases.contains(action))
            #expect(action.group == .panes)
            #expect(action.displayName == displayName)
            #expect(action.defaultStroke == nil)
            #expect(action.defaultShortcut == nil)
        }
    }
}

import Testing
@testable import CmuxSettings

@Suite("ShortcutAction numbered digit matching")
struct ShortcutActionNumberedDigitTests {
    @Test func onlyNumberedSelectionActionsUseDigitMatching() {
        for action in ShortcutAction.allCases {
            let expected = action == .selectSurfaceByNumber || action == .selectWorkspaceByNumber
            #expect(
                action.usesNumberedDigitMatching == expected,
                "\(action) usesNumberedDigitMatching should be \(expected)"
            )
        }
    }

    @Test func diffViewerScrollToTopDefaultIsChord() {
        #expect(
            ShortcutAction.diffViewerScrollToTop.defaultShortcut == StoredShortcut(
                first: ShortcutStroke(key: "g"),
                second: ShortcutStroke(key: "g")
            )
        )
    }

    @Test func surfaceSelectionActionsHaveConcreteDefaults() {
        let surfaceActions: [(ShortcutAction, String)] = [
            (.selectSurface1, "1"),
            (.selectSurface2, "2"),
            (.selectSurface3, "3"),
            (.selectSurface4, "4"),
            (.selectSurface5, "5"),
            (.selectSurface6, "6"),
            (.selectSurface7, "7"),
            (.selectSurface8, "8"),
            (.selectSurface9, "9"),
        ]

        #expect(ShortcutAction.selectSurfaceByNumber.defaultShortcut == nil)

        for (action, digit) in surfaceActions {
            #expect(action.defaultShortcut == StoredShortcut(first: ShortcutStroke(key: digit, control: true)))
            #expect(action.defaultFocusWhenClause == .not(.atom(.sidebarFocus)))
            #expect(!action.usesNumberedDigitMatching)
        }
    }

    @Test func onlyDiffViewerContentActionsAllowBareFirstStrokes() {
        let bareFirstStrokeActions: Set<ShortcutAction> = [
            .diffViewerScrollDown,
            .diffViewerScrollUp,
            .diffViewerScrollToBottom,
            .diffViewerScrollToTop,
            .diffViewerOpenFileSearch,
        ]

        for action in ShortcutAction.allCases {
            #expect(
                action.allowsBareFirstStroke == bareFirstStrokeActions.contains(action),
                "\(action) allowsBareFirstStroke should match diff-viewer content shortcut policy"
            )
        }
    }
}

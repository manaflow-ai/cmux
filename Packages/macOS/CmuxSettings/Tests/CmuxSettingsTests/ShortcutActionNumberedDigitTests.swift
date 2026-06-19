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

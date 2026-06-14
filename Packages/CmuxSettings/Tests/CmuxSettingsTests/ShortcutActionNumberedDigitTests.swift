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

    @Test func diffViewerVimNavigationDefaultsUseControlChords() {
        #expect(ShortcutAction.diffViewerScrollHalfPageDown.defaultShortcut == StoredShortcut(first: ShortcutStroke(key: "d", control: true)))
        #expect(ShortcutAction.diffViewerScrollHalfPageUp.defaultShortcut == StoredShortcut(first: ShortcutStroke(key: "u", control: true)))
        #expect(ShortcutAction.diffViewerSelectNextFile.defaultShortcut == StoredShortcut(first: ShortcutStroke(key: "n", control: true)))
        #expect(ShortcutAction.diffViewerSelectPreviousFile.defaultShortcut == StoredShortcut(first: ShortcutStroke(key: "p", control: true)))
    }

    @Test func onlyDiffViewerContentActionsAllowBareFirstStrokes() {
        let bareFirstStrokeActions: Set<ShortcutAction> = [
            .diffViewerScrollDown,
            .diffViewerScrollUp,
            .diffViewerScrollHalfPageDown,
            .diffViewerScrollHalfPageUp,
            .diffViewerScrollToBottom,
            .diffViewerScrollToTop,
            .diffViewerSelectNextFile,
            .diffViewerSelectPreviousFile,
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

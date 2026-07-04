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

    @Test func workspaceAndSurfaceNumberedDefaultsUseSeparateModifierLanes() {
        #expect(
            ShortcutAction.selectWorkspaceByNumber.defaultShortcut == StoredShortcut(
                first: ShortcutStroke(key: "1", control: true)
            )
        )
        #expect(
            ShortcutAction.selectSurfaceByNumber.defaultShortcut == StoredShortcut(
                first: ShortcutStroke(key: "1", command: true)
            )
        )
    }

    @Test func diffViewerScrollToTopDefaultIsChord() {
        #expect(
            ShortcutAction.diffViewerScrollToTop.defaultShortcut == StoredShortcut(
                first: ShortcutStroke(key: "g"),
                second: ShortcutStroke(key: "g")
            )
        )
    }

    @Test func fileExplorerOpenSelectionDefaultsMatchKeyboardOpenPolicy() {
        #expect(
            ShortcutAction.fileExplorerOpenSelection.defaultShortcut == StoredShortcut(
                first: ShortcutStroke(key: "\r")
            )
        )
        #expect(
            ShortcutAction.fileExplorerOpenSelectionFinderAlias.defaultShortcut == StoredShortcut(
                first: ShortcutStroke(key: "↓", command: true)
            )
        )
    }

    @Test func onlyFocusedContentActionsAllowBareFirstStrokes() {
        let bareFirstStrokeActions: Set<ShortcutAction> = [
            .diffViewerScrollDown,
            .diffViewerScrollUp,
            .diffViewerScrollToBottom,
            .diffViewerScrollToTop,
            .diffViewerOpenFileSearch,
            .fileExplorerOpenSelection,
            .fileExplorerOpenSelectionFinderAlias,
        ]

        for action in ShortcutAction.allCases {
            #expect(
                action.allowsBareFirstStroke == bareFirstStrokeActions.contains(action),
                "\(action) allowsBareFirstStroke should match focused content shortcut policy"
            )
        }
    }

    @Test func fileExplorerOpenSelectionShortcutsAreSingleStrokeOnly() {
        #expect(!ShortcutAction.fileExplorerOpenSelection.allowsChordShortcut)
        #expect(!ShortcutAction.fileExplorerOpenSelectionFinderAlias.allowsChordShortcut)
    }
}

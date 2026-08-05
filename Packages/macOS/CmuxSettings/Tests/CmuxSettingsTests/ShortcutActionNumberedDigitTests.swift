import Testing
@testable import CmuxSettings

@Suite("ShortcutAction numbered digit matching")
struct ShortcutActionNumberedDigitTests {
    @Test func numberedActionsExposeTheirSupportedDigitRanges() {
        for action in ShortcutAction.allCases {
            let expectedRange: ClosedRange<Int>? = switch action {
            case .selectSurfaceByNumber, .selectWorkspaceByNumber:
                1...9
            case .setPaneWidthRatioByNumber, .setPaneHeightRatioByNumber:
                1...6
            default:
                nil
            }
            #expect(
                action.numberedDigitRange == expectedRange,
                "\(action) numberedDigitRange should be \(String(describing: expectedRange))"
            )
            #expect(action.usesNumberedDigitMatching == (expectedRange != nil))
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

    @Test func diffViewerFileNavigationDefaultsAreMnemonicChords() {
        #expect(
            ShortcutAction.diffViewerNextFile.defaultShortcut == StoredShortcut(
                first: ShortcutStroke(key: "]"),
                second: ShortcutStroke(key: "f")
            )
        )
        #expect(
            ShortcutAction.diffViewerPreviousFile.defaultShortcut == StoredShortcut(
                first: ShortcutStroke(key: "["),
                second: ShortcutStroke(key: "f")
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
            .diffViewerScrollHalfPageDown,
            .diffViewerScrollHalfPageUp,
            .diffViewerScrollDownEmacs,
            .diffViewerScrollUpEmacs,
            .diffViewerScrollToBottom,
            .diffViewerScrollToTop,
            .diffViewerOpenFileSearch,
            .diffViewerNextFile,
            .diffViewerPreviousFile,
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

import CmuxTerminalCore
import Testing

@Suite
struct TerminalSoftWrapCopyTests {
    @Test func joinsRowsGhosttyMarksWrapped() {
        let rows = [
            TerminalCopyRow(text: "hello worl", wrapped: true),
            TerminalCopyRow(text: "d test", wrapped: false),
        ]

        #expect(TerminalSoftWrapCopy().joinedText(rows) == "hello world test")
    }

    @Test func preservesTheSpaceAtASoftWrapBoundary() {
        let rows = [
            TerminalCopyRow(text: "hello ", wrapped: true),
            TerminalCopyRow(text: "world", wrapped: false),
        ]

        #expect(TerminalSoftWrapCopy().joinedText(rows) == "hello world")
    }

    @Test func joinsThreeWrappedRowsIntoOneLine() {
        let rows = [
            TerminalCopyRow(text: "hello worl", wrapped: true),
            TerminalCopyRow(text: "d this is", wrapped: true),
            TerminalCopyRow(text: " a test", wrapped: false),
        ]

        #expect(TerminalSoftWrapCopy().joinedText(rows) == "hello world this is a test")
    }

    @Test func keepsHardNewlinesWhenTheWrapFlagIsOff() {
        let rows = [
            TerminalCopyRow(text: "hello", wrapped: false),
            TerminalCopyRow(text: "world", wrapped: false),
        ]

        #expect(TerminalSoftWrapCopy().joinedText(rows) == "hello\nworld")
    }

    @Test func keepsBlankLines() {
        let rows = [
            TerminalCopyRow(text: "hello", wrapped: false),
            TerminalCopyRow(text: "", wrapped: false),
            TerminalCopyRow(text: "world", wrapped: false),
        ]

        #expect(TerminalSoftWrapCopy().joinedText(rows) == "hello\n\nworld")
    }

    @Test func doesNotSoftJoinABlankRowEvenWhenMarkedWrapped() {
        let rows = [
            TerminalCopyRow(text: "hello", wrapped: true),
            TerminalCopyRow(text: "", wrapped: true),
            TerminalCopyRow(text: "world", wrapped: false),
        ]

        #expect(TerminalSoftWrapCopy().joinedText(rows) == "hello\n\nworld")
    }

    @Test func trimsTrailingSpacesOnEachLogicalLine() {
        let rows = [
            TerminalCopyRow(text: "hello  ", wrapped: false),
            TerminalCopyRow(text: "world   ", wrapped: false),
        ]

        #expect(TerminalSoftWrapCopy().joinedText(rows) == "hello\nworld")
    }

    @Test func hardWrapReflowStaysOffUnlessRequested() {
        let rows = [
            TerminalCopyRow(text: "abcdefghij", wrapped: false),
            TerminalCopyRow(text: "more", wrapped: false),
        ]

        #expect(
            TerminalSoftWrapCopy(terminalColumns: 10).joinedText(rows)
                == "abcdefghij\nmore"
        )
    }

    @Test func hardWrapReflowJoinsAFullWidthRowWhenEnabled() {
        let rows = [
            TerminalCopyRow(text: "abcdefghij", wrapped: false),
            TerminalCopyRow(text: "  more", wrapped: false),
            TerminalCopyRow(text: "next", wrapped: false),
        ]

        #expect(
            TerminalSoftWrapCopy(hardWrapReflow: true, terminalColumns: 10).joinedText(rows) == "abcdefghij more\nnext"
        )
    }

    @Test func hardWrapReflowLeavesShortLinesAndStructureAlone() {
        let rows = [
            TerminalCopyRow(text: "short", wrapped: false),
            TerminalCopyRow(text: "line", wrapped: false),
            TerminalCopyRow(text: "abcdefghij", wrapped: false),
            TerminalCopyRow(text: "- item", wrapped: false),
        ]

        #expect(
            TerminalSoftWrapCopy(hardWrapReflow: true, terminalColumns: 10).joinedText(rows) == "short\nline\nabcdefghij\n- item"
        )
    }

    @Test func joiningUsesWrapFlagsWhenEachPhysicalRowIsStillItsOwnLine() {
        let text = "curl -X POST https://ex\nample.com/api"

        #expect(
            TerminalSoftWrapCopy().joiningSoftWraps(
                in: text,
                wrapFlags: [true, false]
            ) == "curl -X POST https://example.com/api"
        )
    }

    @Test func joiningLeavesTextAlreadyUnwrappedByGhostty() {
        let text = "curl -X POST https://example.com/api\nnext command"

        #expect(
            TerminalSoftWrapCopy().joiningSoftWraps(
                in: text,
                wrapFlags: [true, true, false]
            ) == text
        )
    }

    @Test func joiningLeavesUnwrappedLinesUntouched() {
        let text = "hello  \nworld  "

        #expect(
            TerminalSoftWrapCopy().joiningSoftWraps(
                in: text,
                wrapFlags: [false, false]
            ) == text
        )
    }

    @Test func physicalLineCountDropsOnlyATrailingEmptyLine() {
        #expect(TerminalSoftWrapCopy().physicalLineCount(in: "a\nb") == 2)
        #expect(TerminalSoftWrapCopy().physicalLineCount(in: "a\nb\n") == 2)
        #expect(TerminalSoftWrapCopy().physicalLineCount(in: "a\n\nb") == 3)
    }

    @Test func joiningHardWrapsOnlyWhenTheSettingIsOn() {
        let text = "abcdefghij\nmore text"

        #expect(
            TerminalSoftWrapCopy(hardWrapReflow: false, terminalColumns: 10).joiningSoftWraps(
                in: text,
                wrapFlags: nil
            ) == text
        )
        #expect(
            TerminalSoftWrapCopy(hardWrapReflow: false, terminalColumns: 10).joiningSoftWraps(
                in: text,
                wrapFlags: [false, false]
            ) == text
        )
        #expect(
            TerminalSoftWrapCopy(hardWrapReflow: true, terminalColumns: 10).joiningSoftWraps(
                in: text,
                wrapFlags: nil
            ) == "abcdefghij more text"
        )
        #expect(
            TerminalSoftWrapCopy(hardWrapReflow: true, terminalColumns: 10).joiningSoftWraps(
                in: text,
                wrapFlags: [false, false]
            ) == "abcdefghij more text"
        )
    }

    @Test func hardWrapReflowLeavesLinesWiderThanTheGridAlone() {
        let text = "abcdefghijklmno\ndone"

        #expect(
            TerminalSoftWrapCopy(hardWrapReflow: true, terminalColumns: 10).joiningSoftWraps(
                in: text,
                wrapFlags: nil
            ) == text
        )
    }

    @Test func hardWrapReflowCountsNarrowPunctuationAsOneCell() {
        let text = "a \u{2014} \u{201C}b\u{201D}\nnext"

        #expect(
            TerminalSoftWrapCopy(hardWrapReflow: true, terminalColumns: 10).joiningSoftWraps(
                in: text,
                wrapFlags: nil
            ) == text
        )
    }

    @Test func hardWrapReflowCountsWideCharactersAsTwoCells() {
        let text = "\u{65E5}\u{672C}\u{8A9E}\u{65E5}\u{672C}\nnext"

        #expect(
            TerminalSoftWrapCopy(hardWrapReflow: true, terminalColumns: 10).joiningSoftWraps(
                in: text,
                wrapFlags: nil
            ) == "\u{65E5}\u{672C}\u{8A9E}\u{65E5}\u{672C} next"
        )
    }
}

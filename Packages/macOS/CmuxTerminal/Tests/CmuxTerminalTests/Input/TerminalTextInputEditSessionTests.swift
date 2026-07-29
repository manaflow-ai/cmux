import Foundation
import Testing
@testable import CmuxTerminal

@Suite struct TerminalTextInputEditSessionTests {
    @Test(arguments: [
        "你",
        "한",
        "日本",
        "ф",
        "ع",
        "ש",
        "क",
        "ก",
        "a\u{301}",
        "👨🏽‍💻",
    ])
    func committedKeyboardTextRemainsOpaque(_ text: String) {
        var session = TerminalTextInputEditSession()
        session.beginEvent()
        #expect(session.insertText(text).isEmpty)

        #expect(session.finishEvent() == [text])
        #expect(!session.hasMarkedText)
    }

    @Test func canonicalEquivalentTextRemainsUnchanged() {
        var session = TerminalTextInputEditSession()
        session.beginEvent()
        #expect(session.insertText("e\u{301}").isEmpty)

        #expect(session.finishEvent() == ["e\u{301}"])
        #expect(!session.hasMarkedText)
    }

    @Test func transformedInsertionsDoNotAccumulateOutsideMarkedText() {
        var session = TerminalTextInputEditSession()
        var committedCount = 0
        var retainedMarkedText = false

        for index in 0..<4_096 {
            let transformedText = "\(index % 10)"
            session.beginEvent()
            #expect(session.insertText(transformedText).isEmpty)
            committedCount += session.finishEvent().count
            retainedMarkedText = retainedMarkedText ||
                session.hasMarkedText
        }

        #expect(committedCount == 4_096)
        #expect(!retainedMarkedText)
    }

    @Test(arguments: ["\u{001B}", "\u{0008}", "\u{007F}"])
    func committedControlCallbacksNeverBecomeMarkedText(
        _ controlText: String
    ) {
        var session = TerminalTextInputEditSession()
        session.beginEvent()
        #expect(session.insertText(controlText).isEmpty)

        #expect(session.finishEvent() == [controlText])
        #expect(!session.hasMarkedText)
    }

    @Test func callbackOrderIsPreservedWithinOneEvent() {
        var session = TerminalTextInputEditSession()
        session.beginEvent()
        #expect(session.insertText("first").isEmpty)
        #expect(session.insertText("second").isEmpty)
        #expect(session.insertText("").isEmpty)
        #expect(session.insertText("third").isEmpty)

        #expect(session.finishEvent() == ["first", "second", "third"])
    }

    @Test func insertionOutsideNativeEventCommitsImmediately() {
        var session = TerminalTextInputEditSession()

        #expect(session.insertText("opaque") == ["opaque"])
        #expect(!session.hasMarkedText)
    }

    @Test func oneLargeInsertionDoesNotBecomeMarkedText() {
        var session = TerminalTextInputEditSession()
        let transformedText = String(repeating: "Ω", count: 65_537)
        session.beginEvent()
        #expect(session.insertText(transformedText).isEmpty)

        #expect(session.finishEvent() == [transformedText])
        #expect(!session.hasMarkedText)
    }

    @Test func explicitMarkedTextUsesAppKitCommitContract() {
        var session = TerminalTextInputEditSession()
        session.beginEvent()
        session.setMarkedText(
            "opaque preedit",
            selectedRange: NSRange(location: 14, length: 0)
        )

        #expect(session.insertText("opaque commit").isEmpty)
        #expect(session.finishEvent() == ["opaque commit"])
        #expect(!session.hasMarkedText)
    }

    @Test func emptyCommitEndsExplicitMarkedText() {
        var session = TerminalTextInputEditSession()
        session.setMarkedText(
            "opaque",
            selectedRange: NSRange(location: 6, length: 0)
        )

        #expect(session.insertText("").isEmpty)
        #expect(!session.hasMarkedText)
    }

    @Test func markedSelectionUsesUtf16Coordinates() {
        var session = TerminalTextInputEditSession()
        let markedText = "👨🏽‍💻x"
        let markedLength = (markedText as NSString).length
        session.setMarkedText(
            markedText,
            selectedRange: NSRange(
                location: markedLength - 1,
                length: 1
            )
        )

        #expect(session.markedText == markedText)
        #expect(
            session.markedSelection
                == NSRange(location: markedLength - 1, length: 1)
        )
    }

    @Test func markedSelectionIsClampedToMarkedText() {
        var session = TerminalTextInputEditSession()
        session.setMarkedText(
            "abc",
            selectedRange: NSRange(location: 10, length: 10)
        )

        #expect(
            session.markedSelection
                == NSRange(location: 3, length: 0)
        )
    }

    @Test func missingMarkedSelectionDefaultsToEnd() {
        var session = TerminalTextInputEditSession()
        session.setMarkedText(
            "abc",
            selectedRange: NSRange(location: NSNotFound, length: 0)
        )

        #expect(
            session.markedSelection
                == NSRange(location: 3, length: 0)
        )
    }

    @Test func emptyMarkedTextClearsComposition() {
        var session = TerminalTextInputEditSession()
        session.setMarkedText(
            "opaque",
            selectedRange: NSRange(location: 6, length: 0)
        )

        session.setMarkedText(
            "",
            selectedRange: NSRange(location: 0, length: 0)
        )

        #expect(!session.hasMarkedText)
        #expect(
            session.markedSelection
                == NSRange(location: NSNotFound, length: 0)
        )
    }

    @Test func unmarkCommitsExplicitMarkedText() {
        var session = TerminalTextInputEditSession()
        session.setMarkedText(
            "opaque",
            selectedRange: NSRange(location: 6, length: 0)
        )

        #expect(session.unmarkText() == ["opaque"])
        #expect(!session.hasMarkedText)
    }

    @Test func discardRemovesMarkedTextWithoutCommitting() {
        var session = TerminalTextInputEditSession()
        session.setMarkedText(
            "opaque",
            selectedRange: NSRange(location: 6, length: 0)
        )

        session.discardMarkedText()
        #expect(!session.hasMarkedText)
        #expect(session.unmarkText().isEmpty)
    }

    @Test func externalBoundaryCommitsMarkedText() {
        var session = TerminalTextInputEditSession()
        session.setMarkedText(
            "opaque",
            selectedRange: NSRange(location: 6, length: 0)
        )

        #expect(session.commitPendingText() == ["opaque"])
        #expect(!session.hasMarkedText)
    }
}

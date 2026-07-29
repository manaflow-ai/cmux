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
    func translatedKeyboardTextCommitsAsOpaqueText(_ text: String) {
        var session = TerminalTextInputEditSession()
        session.beginEvent(translatedText: text)
        #expect(session.insertText(
            text,
            replacementRange: NSRange(location: NSNotFound, length: 0)
        ).isEmpty)

        #expect(session.finishEvent(consumedByTextInput: true) == [text])
        #expect(!session.hasMarkedText)
    }

    @Test func canonicalEquivalentKeyboardTextCommitsImmediately() {
        var session = TerminalTextInputEditSession()
        session.beginEvent(translatedText: "\u{00E9}")
        #expect(session.insertText(
            "e\u{301}",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        ).isEmpty)

        #expect(
            session.finishEvent(consumedByTextInput: true) == ["e\u{301}"]
        )
        #expect(!session.hasMarkedText)
    }

    @Test(arguments: ["\u{001B}", "\u{0008}", "\u{007F}"])
    func controlCallbacksNeverBecomeProvisionalText(_ controlText: String) {
        var session = TerminalTextInputEditSession()
        session.beginEvent(translatedText: "~")
        #expect(session.insertText(
            controlText,
            replacementRange: NSRange(location: NSNotFound, length: 0)
        ).isEmpty)

        #expect(
            session.finishEvent(consumedByTextInput: true) == [controlText]
        )
        #expect(!session.hasMarkedText)
    }

    @Test func rawNativePayloadCommitsWithoutStartingAnEdit() {
        var session = TerminalTextInputEditSession()
        session.beginEvent(
            translatedText: "translated",
            rawText: "raw"
        )
        #expect(session.insertText(
            "raw",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        ).isEmpty)

        #expect(session.finishEvent(consumedByTextInput: true) == ["raw"])
        #expect(!session.hasMarkedText)
    }

    @Test func oneShotTransformationFlushesBeforeNextUnownedKey() {
        var session = TerminalTextInputEditSession()
        session.beginEvent(translatedText: "x", rawText: "x")
        #expect(session.insertText(
            "opaque",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        ).isEmpty)
        #expect(session.finishEvent(consumedByTextInput: true).isEmpty)
        #expect(session.markedText == "opaque")

        session.beginEvent(translatedText: "\r", rawText: "\r")
        #expect(
            session.finishEvent(consumedByTextInput: false) == ["opaque"]
        )
        #expect(!session.hasMarkedText)
    }

    @Test func oneShotTransformationFlushesBeforeDelegatedCommand() {
        var session = TerminalTextInputEditSession()
        session.beginEvent(translatedText: "x", rawText: "x")
        #expect(session.insertText(
            "opaque",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        ).isEmpty)
        #expect(session.finishEvent(consumedByTextInput: true).isEmpty)

        session.beginEvent(translatedText: "\r", rawText: "\r")
        #expect(session.finishEvent(
            consumedByTextInput: true,
            commandPerformed: true
        ) == ["opaque"])
        #expect(!session.hasMarkedText)
    }

    @Test func oneShotTransformationFlushesBeforeDirectText() {
        var session = TerminalTextInputEditSession()
        session.beginEvent(translatedText: "x", rawText: "x")
        #expect(session.insertText(
            "opaque",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        ).isEmpty)
        #expect(session.finishEvent(consumedByTextInput: true).isEmpty)

        session.beginEvent(translatedText: "z", rawText: "z")
        #expect(session.insertText(
            "z",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        ) == ["opaque", "z"])
        #expect(session.finishEvent(consumedByTextInput: true).isEmpty)
        #expect(!session.hasMarkedText)
    }

    @Test func pendingTransformationPreservesRecoveredNativeText() {
        var session = TerminalTextInputEditSession()
        session.beginEvent(translatedText: "x", rawText: "x")
        #expect(session.insertText(
            "opaque",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        ).isEmpty)
        #expect(session.finishEvent(consumedByTextInput: true).isEmpty)

        session.beginEvent(translatedText: "~", rawText: "\u{001B}")
        #expect(session.insertText(
            "\u{001B}",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        ) == ["opaque", "~"])
        #expect(session.finishEvent(consumedByTextInput: true).isEmpty)
        #expect(!session.hasMarkedText)
    }

    @Test func continuousTransformationsRemainReversibleUntilSemanticCommit() {
        var session = TerminalTextInputEditSession()
        var expectedText = ""

        for index in 0..<128 {
            let nativeText = "native-\(index)"
            let transformedText = "\(index % 10)"
            session.beginEvent(
                translatedText: nativeText,
                rawText: nativeText
            )
            #expect(session.insertText(
                transformedText,
                replacementRange: NSRange(
                    location: NSNotFound,
                    length: 0
                )
            ).isEmpty)
            expectedText.append(transformedText)
            #expect(
                session.finishEvent(consumedByTextInput: true).isEmpty
            )
        }

        #expect(session.markedText == expectedText)

        session.beginEvent(translatedText: "\r", rawText: "\r")
        #expect(session.insertText(
            "final",
            replacementRange: NSRange(
                location: 0,
                length: (expectedText as NSString).length
            )
        ) == ["final"])
        #expect(session.finishEvent(consumedByTextInput: true).isEmpty)
        #expect(!session.hasMarkedText)
    }

    @Test func oneLargeTransformationRemainsReversibleUntilExternalBoundary() {
        var session = TerminalTextInputEditSession()
        let transformedText = String(repeating: "Ω", count: 65_537)
        session.beginEvent(translatedText: "x", rawText: "x")
        #expect(session.insertText(
            transformedText,
            replacementRange: NSRange(location: NSNotFound, length: 0)
        ).isEmpty)

        #expect(session.finishEvent(consumedByTextInput: true).isEmpty)
        #expect(session.markedText == transformedText)
        #expect(session.commitPendingText() == [transformedText])
        #expect(!session.hasMarkedText)
    }

    @Test func consumedReplacementEditsRemainProvisionalUntilCommit() {
        var session = TerminalTextInputEditSession()

        session.beginEvent(translatedText: "1")
        #expect(session.insertText(
            "α",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        ).isEmpty)
        #expect(session.finishEvent(consumedByTextInput: true).isEmpty)
        #expect(session.markedText == "α")

        session.beginEvent(translatedText: "2")
        #expect(session.insertText(
            "β",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        ).isEmpty)
        #expect(session.finishEvent(consumedByTextInput: true).isEmpty)
        #expect(session.markedText == "αβ")

        session.beginEvent(translatedText: "3")
        #expect(session.insertText(
            "γ",
            replacementRange: NSRange(location: 1, length: 1)
        ).isEmpty)
        #expect(session.finishEvent(consumedByTextInput: true).isEmpty)
        #expect(session.markedText == "αγ")

        session.beginEvent(translatedText: "\r")
        #expect(session.insertText(
            "Ω",
            replacementRange: NSRange(location: 0, length: 2)
        ) == ["Ω"])
        #expect(session.finishEvent(consumedByTextInput: true).isEmpty)
        #expect(!session.hasMarkedText)
    }

    @Test func replacementRangesUseUtf16DocumentCoordinates() {
        var session = TerminalTextInputEditSession()

        session.beginEvent(translatedText: "1")
        #expect(session.insertText(
            "👨🏽‍💻x",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        ).isEmpty)
        #expect(session.finishEvent(consumedByTextInput: true).isEmpty)

        let emojiLength = ("👨🏽‍💻" as NSString).length
        session.beginEvent(translatedText: "2")
        #expect(session.insertText(
            "y",
            replacementRange: NSRange(location: emojiLength, length: 1)
        ).isEmpty)
        #expect(session.markedText == "👨🏽‍💻y")
        #expect(
            session.markedSelection
                == NSRange(location: emojiLength + 1, length: 0)
        )
    }

    @Test func unconsumedInsertionCommitsInsteadOfStartingPreedit() {
        var session = TerminalTextInputEditSession()
        session.beginEvent(translatedText: "x")
        #expect(session.insertText(
            "opaque",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        ).isEmpty)

        #expect(
            session.finishEvent(consumedByTextInput: false) == ["opaque"]
        )
        #expect(!session.hasMarkedText)
    }

    @Test func explicitMarkedTextUsesAppKitCommitContract() {
        var session = TerminalTextInputEditSession()
        session.beginEvent(translatedText: nil)
        session.setMarkedText(
            "opaque preedit",
            selectedRange: NSRange(location: 14, length: 0)
        )

        #expect(session.insertText(
            "opaque commit",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        ) == ["opaque commit"])
        #expect(session.finishEvent(consumedByTextInput: true).isEmpty)
        #expect(!session.hasMarkedText)
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

    @Test func unmarkCommitsReplacementDrivenMarkedText() {
        var session = TerminalTextInputEditSession()
        session.beginEvent(translatedText: "x")
        #expect(session.insertText(
            "opaque",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        ).isEmpty)
        #expect(session.finishEvent(consumedByTextInput: true).isEmpty)

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

    @Test func externalBoundaryCommitsPendingReplacementText() {
        var session = TerminalTextInputEditSession()
        session.beginEvent(translatedText: "x")
        #expect(session.insertText(
            "opaque",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        ).isEmpty)
        #expect(session.finishEvent(consumedByTextInput: true).isEmpty)

        #expect(session.commitPendingText() == ["opaque"])
        #expect(!session.hasMarkedText)
    }
}

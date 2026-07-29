import Foundation
import Testing
@testable import CmuxTerminal

@Suite struct TerminalTextInputEditSessionTests {
    @Test func consumedReplacementEditsRemainProvisionalUntilCommit() {
        var session = TerminalTextInputEditSession()

        session.beginEvent(sourceKind: .inputMethod)
        #expect(session.insertText(
            "α",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        ).isEmpty)
        #expect(session.finishEvent(consumedByTextInput: true).isEmpty)
        #expect(session.markedText == "α")

        session.beginEvent(sourceKind: .inputMethod)
        #expect(session.insertText(
            "β",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        ).isEmpty)
        #expect(session.finishEvent(consumedByTextInput: true).isEmpty)
        #expect(session.markedText == "αβ")

        session.beginEvent(sourceKind: .inputMethod)
        #expect(session.insertText(
            "γ",
            replacementRange: NSRange(location: 1, length: 1)
        ).isEmpty)
        #expect(session.finishEvent(consumedByTextInput: true).isEmpty)
        #expect(session.markedText == "αγ")

        session.beginEvent(sourceKind: .inputMethod)
        #expect(session.insertText(
            "Ω",
            replacementRange: NSRange(location: 0, length: 2)
        ) == ["Ω"])
        #expect(session.finishEvent(consumedByTextInput: true).isEmpty)
        #expect(!session.hasMarkedText)
    }

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
    func directLayoutTextIsAlwaysCommittedOpaqueText(_ text: String) {
        var session = TerminalTextInputEditSession()
        session.beginEvent(sourceKind: .keyboardLayout)
        #expect(session.insertText(
            text,
            replacementRange: NSRange(location: NSNotFound, length: 0)
        ).isEmpty)
        #expect(session.finishEvent(consumedByTextInput: true) == [text])
        #expect(!session.hasMarkedText)
    }

    @Test func explicitMarkedTextKeepsTheStandardAppKitCommitContract() {
        var session = TerminalTextInputEditSession()
        session.beginEvent(sourceKind: .inputMethod)
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

    @Test func unconsumedInputMethodInsertionIsCommitted() {
        var session = TerminalTextInputEditSession()
        session.beginEvent(sourceKind: .inputMethod)
        #expect(session.insertText(
            "opaque",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        ).isEmpty)

        #expect(
            session.finishEvent(consumedByTextInput: false) == ["opaque"]
        )
        #expect(!session.hasMarkedText)
    }

    @Test func explicitInitialReplacementIsCommitted() {
        var session = TerminalTextInputEditSession()
        session.beginEvent(sourceKind: .inputMethod)
        #expect(session.insertText(
            "opaque",
            replacementRange: NSRange(location: 0, length: 0)
        ).isEmpty)

        #expect(
            session.finishEvent(consumedByTextInput: true) == ["opaque"]
        )
        #expect(!session.hasMarkedText)
    }

    @Test func unmarkCommitsAReplacementDrivenBuffer() {
        var session = TerminalTextInputEditSession()
        session.beginEvent(sourceKind: .inputMethod)
        #expect(session.insertText(
            "opaque",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        ).isEmpty)
        #expect(session.finishEvent(consumedByTextInput: true).isEmpty)

        #expect(session.unmarkText() == ["opaque"])
        #expect(!session.hasMarkedText)
    }
}

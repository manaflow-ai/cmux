import Foundation
import Testing
import CmuxTerminalCore

@Suite struct TerminalCommandSubmissionTests {
    @Test func singleLineUsesPlainInputAndOneSubmit() {
        let submission = TerminalCommandSubmission(command: "pnpm install")

        #expect(Array(submission.data) == Array("pnpm install\r".utf8))
    }

    @Test func multilineUsesBracketedPasteAndOneSubmit() {
        let submission = TerminalCommandSubmission(command: "pnpm install\npnpm test")

        #expect(Array(submission.data) == Array("\u{001B}[200~pnpm install\npnpm test\u{001B}[201~\r".utf8))
    }

    @Test func stripsOneTrailingTerminatorBeforeDetectingMultiline() {
        let submission = TerminalCommandSubmission(command: "one\ntwo\r\n")

        #expect(submission.text == "\u{001B}[200~one\ntwo\u{001B}[201~\r")
    }

    @Test func preservesExistingSingleLineTerminator() {
        #expect(TerminalCommandSubmission(command: "echo ok\n").text == "echo ok\n")
        #expect(TerminalCommandSubmission(command: "echo ok\r\n").text == "echo ok\r\n")
    }

    @Test func bracketedPasteCanBeDisabledForUnsupportedShells() {
        let submission = TerminalCommandSubmission(
            command: "one\ntwo",
            submit: "\n",
            bracketedPasteSafe: false
        )

        #expect(submission.text == "one\ntwo\n")
    }
}

import CmuxTerminalCore
import Testing

@Suite
struct TerminalUnsafePasteConfirmationPolicyTests {
    @Test func approvesUnsafePastesWhenTheSettingIsOff() {
        let policy = TerminalUnsafePasteConfirmationPolicy(confirmationEnabled: false)
        for hasWindow in [true, false] {
            #expect(policy.decision(isPasteRequest: true, hasWindow: hasWindow) == .approve)
        }
    }

    @Test func asksInAWindowSheetWhenTheSettingIsOn() {
        let policy = TerminalUnsafePasteConfirmationPolicy(confirmationEnabled: true)
        #expect(policy.decision(isPasteRequest: true, hasWindow: true) == .askInWindowSheet)
    }

    @Test func rejectsAPasteItCannotAskAboutWhenTheSettingIsOn() {
        let policy = TerminalUnsafePasteConfirmationPolicy(confirmationEnabled: true)
        #expect(policy.decision(isPasteRequest: true, hasWindow: false) == .reject)
    }

    // Ghostty asks about a terminal clipboard read only under
    // `clipboard-read = ask`; `allow` and `deny` never reach this policy.
    @Test func deniesTerminalClipboardReadsWhateverTheSetting() {
        for enabled in [true, false] {
            let policy = TerminalUnsafePasteConfirmationPolicy(confirmationEnabled: enabled)
            #expect(policy.decision(isPasteRequest: false, hasWindow: true) == .reject)
        }
    }

    @Test func rejectsATerminalClipboardReadItCannotAskAboutWhateverTheSetting() {
        for enabled in [true, false] {
            let policy = TerminalUnsafePasteConfirmationPolicy(confirmationEnabled: enabled)
            #expect(policy.decision(isPasteRequest: false, hasWindow: false) == .reject)
        }
    }

    @Test func previewKeepsShortTextUnchanged() {
        let policy = TerminalUnsafePasteConfirmationPolicy(confirmationEnabled: true)
        #expect(policy.preview(of: "echo one\necho two") == "echo one\necho two")
    }

    @Test func previewCutsExtraLinesAndLongLines() {
        let text = (1...5).map { "line \($0)" }.joined(separator: "\n")
        let fewLines = TerminalUnsafePasteConfirmationPolicy(
            confirmationEnabled: true,
            maximumPreviewLines: 3
        )
        #expect(fewLines.preview(of: text) == "line 1\nline 2\nline 3\n…")
        let shortLines = TerminalUnsafePasteConfirmationPolicy(
            confirmationEnabled: true,
            maximumPreviewLineLength: 4
        )
        #expect(shortLines.preview(of: "abcdefghij") == "abcd…")
    }

    @Test func previewNormalizesCarriageReturnLineBreaks() {
        let policy = TerminalUnsafePasteConfirmationPolicy(confirmationEnabled: true)
        #expect(policy.preview(of: "a\r\nb\rc") == "a\nb\nc")
    }
}

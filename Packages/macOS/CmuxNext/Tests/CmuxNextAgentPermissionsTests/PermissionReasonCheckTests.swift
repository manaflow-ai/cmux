@testable import CmuxNextAgentPermissions
import Testing

/// The card's reason check (agent-permissions-DESIGN.md section 4): a reason
/// that fits the person's request reads `matches`; one that does not is
/// flagged `unclear`; a missing prompt or reason says so.
@Suite struct PermissionReasonCheckTests {
    @Test func aReasonThatSharesWordsWithThePromptMatches() {
        let check = PermissionReasonCheck(kind: .fullDiskAccess, reason: "Read your Mail database to find the invoice emails",
                                          prompt: "find the March invoices in my email")
        #expect(check.verdict == .matches)
        #expect(check.sharedWords.contains("invoic"))
    }

    @Test func aPromptAboutWorkThatNeedsTheGrantMatches() {
        let check = PermissionReasonCheck(kind: .fullDiskAccess, reason: "Open chat.db to count them",
                                          prompt: "how many iMessages did I get last week?")
        #expect(check.verdict == .matches)
    }

    @Test func aReasonUnrelatedToThePromptIsUnclear() {
        let check = PermissionReasonCheck(kind: .fullDiskAccess, reason: "Need to scan the whole system for keys",
                                          prompt: "rename the sidebar groups to shorter titles")
        #expect(check.verdict == .unclear)
        #expect(check.sharedWords.isEmpty)
    }

    @Test func computerUseForAnExportTheUserAskedForMatches() {
        let check = PermissionReasonCheck(kind: .computerUse, reason: "Click Export in Numbers and pick CSV",
                                          prompt: "export my budget spreadsheet from Numbers as CSV")
        #expect(check.verdict == .matches)
    }

    @Test func computerUseForUnrelatedWorkIsUnclear() {
        let check = PermissionReasonCheck(kind: .computerUse, reason: "Check your bank balance in Safari",
                                          prompt: "fix the failing unit test in the parser")
        #expect(check.verdict == .unclear)
    }

    @Test func noPromptIsSaid() {
        #expect(PermissionReasonCheck(kind: .camera, reason: "Scan the QR code on your desk", prompt: nil).verdict == .noPrompt)
        #expect(PermissionReasonCheck(kind: .camera, reason: "Scan the QR code on your desk", prompt: "  ").verdict == .noPrompt)
    }

    @Test func anEmptyOrTinyReasonIsRefused() {
        #expect(PermissionReasonCheck(kind: .microphone, reason: "", prompt: "dictate a note").verdict == .noReason)
        #expect(PermissionReasonCheck(kind: .microphone, reason: "  need ", prompt: "dictate a note").verdict == .noReason)
    }
}

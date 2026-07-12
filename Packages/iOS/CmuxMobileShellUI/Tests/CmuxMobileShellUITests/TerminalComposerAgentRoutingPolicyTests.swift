@testable import CmuxMobileShellUI
import Testing

@Suite
struct TerminalComposerAgentRoutingPolicyTests {
    @Test(arguments: [
        (false, true, 0, false, true),
        (false, true, 1, true, true),
        (true, false, 0, true, false),
        (true, true, 1, false, false),
        (true, false, 1, false, false),
    ])
    func submissionAndAttachmentPolicy(
        isAgentRouting: Bool,
        textIsEmpty: Bool,
        attachmentCount: Int,
        canSend: Bool,
        canAttach: Bool
    ) {
        let policy = TerminalComposerAgentRoutingPolicy(
            isAgentGUIRouting: isAgentRouting,
            trimmedTextIsEmpty: textIsEmpty,
            attachmentCount: attachmentCount
        )
        #expect(policy.canSend == canSend)
        #expect(policy.canAttach == canAttach)
        #expect(policy.showsAttachmentGuidance == (isAgentRouting && attachmentCount > 0))
    }
}

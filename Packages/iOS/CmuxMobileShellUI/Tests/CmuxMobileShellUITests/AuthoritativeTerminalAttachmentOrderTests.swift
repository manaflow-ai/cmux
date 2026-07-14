import Testing
@testable import CmuxMobileShellUI

@Test func authoritativeAttachSuppressesRendererBeforeRegisteringStreams() {
    var steps: [String] = []

    let result = AuthoritativeTerminalAttachmentOrder.start(
        suppressPresentation: { steps.append("suppress") },
        registerStreams: {
            steps.append("register")
            return 42
        }
    )

    #expect(result == 42)
    #expect(steps == ["suppress", "register"])
}

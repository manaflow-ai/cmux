import Testing
@testable import CmuxMobileShellUI

@Test func authoritativeAttachSuppressesRendererBeforeRegisteringStreams() {
    var steps: [String] = []

    let result = AuthoritativeTerminalAttachmentOrder.start(
        authoritativeGridEnabled: true,
        suppressPresentation: { steps.append("suppress") },
        registerStreams: {
            steps.append("register")
            return 42
        }
    )

    #expect(result == 42)
    #expect(steps == ["suppress", "register"])
}

@Test func ordinaryAttachRegistersWithoutSuppressingRenderer() {
    var steps: [String] = []

    let result = AuthoritativeTerminalAttachmentOrder.start(
        authoritativeGridEnabled: false,
        suppressPresentation: { steps.append("suppress") },
        registerStreams: {
            steps.append("register")
            return 7
        }
    )

    #expect(result == 7)
    #expect(steps == ["register"])
}

@Test func ordinaryNewStreamTokenDoesNotBeginAuthoritativeReplay() {
    #expect(!AuthoritativeTerminalAttachmentOrder.shouldBeginReplayForNewStream(
        authoritativeGridEnabled: false
    ))
    #expect(AuthoritativeTerminalAttachmentOrder.shouldBeginReplayForNewStream(
        authoritativeGridEnabled: true
    ))
}

@Test func viewportOnlyOrdinaryChunkStillRestoresRawRenderer() {
    #expect(AuthoritativeTerminalAttachmentOrder.shouldUseRawRenderer(
        hasAuthoritativeGrid: false
    ))
    #expect(!AuthoritativeTerminalAttachmentOrder.shouldUseRawRenderer(
        hasAuthoritativeGrid: true
    ))
}

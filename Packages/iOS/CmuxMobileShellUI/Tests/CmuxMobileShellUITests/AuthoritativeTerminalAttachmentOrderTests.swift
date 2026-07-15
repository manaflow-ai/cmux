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
        authoritativeGridEnabled: false,
        hasAuthoritativeGrid: false
    ))
    #expect(!AuthoritativeTerminalAttachmentOrder.shouldUseRawRenderer(
        authoritativeGridEnabled: false,
        hasAuthoritativeGrid: true
    ))
}

@Test func directGridStreamNeverRestoresRawRendererForFallbackOrViewportOnlyChunks() {
    #expect(!AuthoritativeTerminalAttachmentOrder.shouldUseRawRenderer(
        authoritativeGridEnabled: true,
        hasAuthoritativeGrid: false
    ))
    #expect(!AuthoritativeTerminalAttachmentOrder.shouldUseRawRenderer(
        authoritativeGridEnabled: true,
        hasAuthoritativeGrid: true
    ))
}

@Test func directGridStreamRejectsNonemptyRawFallbackButAllowsViewportPolicyOnlyChunk() {
    #expect(AuthoritativeTerminalAttachmentOrder.acceptsRawChunk(
        authoritativeGridEnabled: true,
        dataIsEmpty: true
    ))
    #expect(!AuthoritativeTerminalAttachmentOrder.acceptsRawChunk(
        authoritativeGridEnabled: true,
        dataIsEmpty: false
    ))
    #expect(AuthoritativeTerminalAttachmentOrder.acceptsRawChunk(
        authoritativeGridEnabled: false,
        dataIsEmpty: false
    ))
}

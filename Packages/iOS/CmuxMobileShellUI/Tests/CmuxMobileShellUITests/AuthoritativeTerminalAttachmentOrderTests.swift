import Testing
@testable import CmuxMobileShellUI

@Test func authoritativeAttachSuppressesRendererBeforeRegisteringStreams() {
    var steps: [String] = []

    let result = GhosttySurfaceRepresentable.Coordinator.start(
        authoritativeGridEnabled: true,
        releaseViewportOwnership: { steps.append("release-viewport") },
        suppressPresentation: { steps.append("suppress") },
        registerStreams: {
            steps.append("register")
            return 42
        }
    )

    #expect(result == 42)
    #expect(steps == ["release-viewport", "suppress", "register"])
}

@Test func ordinaryAttachRegistersWithoutSuppressingRenderer() {
    var steps: [String] = []

    let result = GhosttySurfaceRepresentable.Coordinator.start(
        authoritativeGridEnabled: false,
        releaseViewportOwnership: { steps.append("release-viewport") },
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
    #expect(!GhosttySurfaceRepresentable.Coordinator.shouldBeginReplayForNewStream(
        authoritativeGridEnabled: false
    ))
    #expect(GhosttySurfaceRepresentable.Coordinator.shouldBeginReplayForNewStream(
        authoritativeGridEnabled: true
    ))
}

@Test func viewportOnlyOrdinaryChunkStillRestoresRawRenderer() {
    #expect(GhosttySurfaceRepresentable.Coordinator.shouldUseRawRenderer(
        authoritativeGridEnabled: false,
        hasAuthoritativeGrid: false
    ))
    #expect(!GhosttySurfaceRepresentable.Coordinator.shouldUseRawRenderer(
        authoritativeGridEnabled: false,
        hasAuthoritativeGrid: true
    ))
}

@Test func directGridStreamNeverRestoresRawRendererForFallbackOrViewportOnlyChunks() {
    #expect(!GhosttySurfaceRepresentable.Coordinator.shouldUseRawRenderer(
        authoritativeGridEnabled: true,
        hasAuthoritativeGrid: false
    ))
    #expect(!GhosttySurfaceRepresentable.Coordinator.shouldUseRawRenderer(
        authoritativeGridEnabled: true,
        hasAuthoritativeGrid: true
    ))
}

@Test func directGridStreamRejectsNonemptyRawFallbackButAllowsViewportPolicyOnlyChunk() {
    #expect(GhosttySurfaceRepresentable.Coordinator.acceptsRawChunk(
        authoritativeGridEnabled: true,
        dataIsEmpty: true
    ))
    #expect(!GhosttySurfaceRepresentable.Coordinator.acceptsRawChunk(
        authoritativeGridEnabled: true,
        dataIsEmpty: false
    ))
    #expect(GhosttySurfaceRepresentable.Coordinator.acceptsRawChunk(
        authoritativeGridEnabled: false,
        dataIsEmpty: false
    ))
}

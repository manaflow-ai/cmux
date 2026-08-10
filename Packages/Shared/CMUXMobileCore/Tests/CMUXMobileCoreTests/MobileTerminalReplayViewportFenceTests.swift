import Testing
@testable import CMUXMobileCore

@Suite struct MobileTerminalReplayViewportFenceTests {
    @Test func rejectsGridCapturedBeforeAcceptedViewportResize() {
        #expect(!MobileTerminalReplayViewportFence.accepts(
            capturedColumns: 94,
            capturedRows: 37,
            expectedColumns: 72,
            expectedRows: 61
        ))
    }

    @Test func acceptsGridCapturedAtAcceptedViewport() {
        #expect(MobileTerminalReplayViewportFence.accepts(
            capturedColumns: 72,
            capturedRows: 61,
            expectedColumns: 72,
            expectedRows: 61
        ))
    }

    @Test func preservesLegacyRequestWithoutViewport() {
        #expect(MobileTerminalReplayViewportFence.accepts(
            capturedColumns: 94,
            capturedRows: 37,
            expectedColumns: nil,
            expectedRows: nil
        ))
    }
}

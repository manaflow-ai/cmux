import Testing

@testable import CmuxSettingsUI

/// Lifecycle regression tests for ``MobilePairingStatusModel``.
@MainActor
@Suite struct MobilePairingStatusModelLifecycleTests {
    @Test func initializationDoesNotReadHostStatusOrStartObservationStream() {
        let (stream, _) = AsyncStream<MobilePairingStatusSnapshot>.makeStream()
        let hostActions = CountingMobilePairingHostActions(stream: stream)

        _ = MobilePairingStatusModel(hostActions: hostActions)

        #expect(hostActions.statusReads == 0)
        #expect(hostActions.streamCreations == 0)
    }
}

import Testing

@testable import CmuxSettingsUI

/// Lifecycle regression tests for ``DesktopNotificationAuthorizationModel``.
@MainActor
@Suite struct DesktopNotificationAuthorizationModelLifecycleTests {
    @Test func startObservingSeedsCurrentStatusAndRefreshesHostAuthorization() {
        let (mobileStream, _) = AsyncStream<MobilePairingStatusSnapshot>.makeStream()
        let (desktopStream, _) = AsyncStream<DesktopNotificationAuthorizationState>.makeStream()
        let hostActions = CountingMobilePairingHostActions(
            stream: mobileStream,
            desktopStream: desktopStream
        )
        hostActions.desktopStatus = .authorized
        let model = DesktopNotificationAuthorizationModel(hostActions: hostActions)

        model.startObserving()

        #expect(model.current == .authorized)
        #expect(hostActions.desktopStatusReads == 1)
        #expect(hostActions.desktopStreamCreations == 1)
        #expect(hostActions.desktopRefreshes == 1)
    }
}

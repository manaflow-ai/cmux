import Observation
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

    @Test func repeatedStartObservingRefreshesHostAuthorizationWithoutResubscribing() {
        let (mobileStream, _) = AsyncStream<MobilePairingStatusSnapshot>.makeStream()
        let (desktopStream, _) = AsyncStream<DesktopNotificationAuthorizationState>.makeStream()
        let hostActions = CountingMobilePairingHostActions(
            stream: mobileStream,
            desktopStream: desktopStream
        )
        hostActions.desktopStatus = .notDetermined
        let model = DesktopNotificationAuthorizationModel(hostActions: hostActions)

        model.startObserving()
        hostActions.desktopStatus = .authorized
        model.startObserving()

        #expect(model.current == .authorized)
        #expect(hostActions.desktopStatusReads == 2)
        #expect(hostActions.desktopStreamCreations == 1)
        #expect(hostActions.desktopRefreshes == 2)
    }

    @Test func freshAuthorizedStatusReplacesUnknownStateAfterObservationStarts() async {
        let (desktopStream, desktopContinuation) =
            AsyncStream<DesktopNotificationAuthorizationState>.makeStream()
        var streamCreations = 0
        let model = DesktopNotificationAuthorizationModel(
            currentStatus: { .unknown },
            makeStream: {
                streamCreations += 1
                return desktopStream
            },
            refreshStatus: {
                #expect(streamCreations == 1)
                desktopContinuation.yield(.authorized)
            }
        )

        model.startObserving()

        let (changes, changeContinuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        withObservationTracking {
            _ = model.current
        } onChange: {
            changeContinuation.yield(())
        }

        for await _ in changes.prefix(1) {}

        #expect(model.current == .authorized)
        #expect(streamCreations == 1)
        desktopContinuation.finish()
        changeContinuation.finish()
    }
}

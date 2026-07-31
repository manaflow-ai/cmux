import CmuxAuthRuntime
import Foundation
import Testing

@testable import CmuxMobileShellUI

private actor LifecyclePushRegistration: PushRegistering {
    private var value = PushRegistrationSnapshot(
        isEnabled: true,
        hasDeviceToken: false,
        backendState: .awaitingDeviceToken
    )

    var isEnabled: Bool { true }
    var snapshot: PushRegistrationSnapshot { value }

    func snapshots() -> AsyncStream<PushRegistrationSnapshot> {
        AsyncStream { continuation in
            continuation.yield(value)
            continuation.finish()
        }
    }

    func setEnabled(_ enabled: Bool) {}

    func register(deviceToken: Data) {
        value = PushRegistrationSnapshot(
            isEnabled: true,
            hasDeviceToken: true,
            backendState: .registered
        )
    }

    func deviceTokenRegistrationFailed() {
        value = PushRegistrationSnapshot(
            isEnabled: true,
            hasDeviceToken: false,
            backendState: .deviceTokenRegistrationFailed
        )
    }

    func syncTokenIfPossible() {}
    func unregisterFromServer() {}
    func unregisterFromServer(accessToken: String?, refreshToken: String?) {}
}

@Suite struct MobilePushCoordinatorLifecycleTests {
    @MainActor
    @Test func callbackFailureOffersRetryAndSuccessfulTokenRecoversReadiness() async {
        let registration = LifecyclePushRegistration()
        var registrationRequests = 0
        let coordinator = MobilePushCoordinator(
            registration: registration,
            authorizationStatus: { .authorized },
            requestAuthorization: { true },
            registerForRemoteNotifications: { registrationRequests += 1 }
        )
        await coordinator.refreshReadiness()

        await coordinator.handleDeviceTokenFailure()

        #expect(
            coordinator.registrationSnapshot.backendState
                == .deviceTokenRegistrationFailed
        )
        #expect(
            coordinator.readiness(macStatus: nil)
                == .blocked(.deviceTokenRegistrationFailed)
        )

        coordinator.retryDeviceTokenRegistration()
        #expect(registrationRequests == 1)

        await coordinator.handleDeviceToken(Data(repeating: 0xCD, count: 32))
        #expect(coordinator.registrationSnapshot.backendState == .registered)
    }
}

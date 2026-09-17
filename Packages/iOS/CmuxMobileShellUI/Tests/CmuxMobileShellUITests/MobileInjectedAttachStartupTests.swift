import CmuxMobileShellModel
import Testing
@testable import CmuxMobileShellUI

@Suite
struct MobileInjectedAttachStartupTests {
    @Test
    @MainActor
    func beginsRouteAdmissionWithoutAnExternalTransportReadinessBarrier() async throws {
        let coordinator = MobileStartupConnectionCoordinator()
        let attempt = try #require(coordinator.claimInjectedAttach())
        let recorder = MobileInjectedAttachURLRecorder()
        let attachURL = "cmux-ios://attach?v=2&payload=iroh-route"

        let completion = await coordinator.connectInjectedAttach(
            attempt,
            attachURL: attachURL
        ) { rawURL in
            await recorder.record(rawURL)
            return MobilePairingURLConnectionResult.connected
        }

        let completedAttempt = try #require(completion)
        #expect(await recorder.values() == [attachURL])
        #expect(completedAttempt.result == .connected)
        #expect(!completedAttempt.shouldReconnectStoredMac)
        #expect(coordinator.claimStoredReconnect() == nil)
    }

    @Test
    @MainActor
    func teardownCancellationLetsLaunchRouteRetryAndIgnoresLateCompletion() async throws {
        let coordinator = MobileStartupConnectionCoordinator()
        let cancelledAttempt = try #require(coordinator.claimInjectedAttach())
        let recorder = MobileInjectedAttachURLRecorder()
        let attachURL = "cmux-ios://attach?v=2&payload=iroh-route"

        #expect(!coordinator.cancelInjectedAttach(
            cancelledAttempt,
            retryLaunchRoute: true
        ))
        #expect(coordinator.claimStoredReconnect() == nil)

        let retryAttempt = try #require(coordinator.claimInjectedAttach())

        let staleCompletion = await coordinator.connectInjectedAttach(
            cancelledAttempt,
            attachURL: attachURL
        ) { rawURL in
            await recorder.record(rawURL)
            return MobilePairingURLConnectionResult.connected
        }
        #expect(staleCompletion == nil)

        let completion = await coordinator.connectInjectedAttach(
            retryAttempt,
            attachURL: attachURL
        ) { rawURL in
            await recorder.record(rawURL)
            return MobilePairingURLConnectionResult.connected
        }

        let completedAttempt = try #require(completion)
        #expect(await recorder.values() == [attachURL])
        #expect(completedAttempt.attempt == retryAttempt)
        #expect(completedAttempt.result == .connected)
        #expect(!completedAttempt.shouldReconnectStoredMac)
    }
}

private actor MobileInjectedAttachURLRecorder {
    private var urls: [String] = []

    func record(_ url: String) {
        urls.append(url)
    }

    func values() -> [String] {
        urls
    }
}

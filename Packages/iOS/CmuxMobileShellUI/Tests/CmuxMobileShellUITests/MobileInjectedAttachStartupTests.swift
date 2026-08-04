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

        let result = await DogfoodAttachPreparation().run {
            let rawURL = attachURL
            await recorder.record(rawURL)
            return MobilePairingURLConnectionResult.connected
        }

        #expect(await recorder.values() == [attachURL])
        #expect(result == .connected)
        #expect(!coordinator.finishInjectedAttach(attempt, outcome: .connected))
        #expect(coordinator.claimStoredReconnect() == nil)
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

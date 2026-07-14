import Testing

@testable import CmuxBrowser

@MainActor
@Suite("Browser automation watchdog")
struct BrowserAutomationWatchdogTests {
    @Test("A completed liveness probe preserves the current browser process")
    func responsiveProbeDoesNotRecover() async {
        var recoveryCount = 0
        let watchdog = BrowserAutomationWatchdog(
            sleep: { duration in
                try await ContinuousClock().sleep(for: duration)
            }
        )

        let outcome = await watchdog.recoverIfUnresponsive(
            probe: { finish in finish() },
            recover: {
                recoveryCount += 1
                return true
            }
        )

        #expect(outcome == .responsive)
        #expect(recoveryCount == 0)
    }

    @Test("A missing liveness callback replaces the unresponsive browser process")
    func timedOutProbeRecovers() async {
        var recoveryCount = 0
        let watchdog = BrowserAutomationWatchdog(sleep: { _ in })

        let outcome = await watchdog.recoverIfUnresponsive(
            probe: { _ in },
            recover: {
                recoveryCount += 1
                return true
            }
        )

        #expect(outcome == .recovered)
        #expect(recoveryCount == 1)
    }

    @Test("A WebView replaced during the probe is not replaced a second time")
    func supersededProbeDoesNotRecoverAgain() async {
        var recoveryCount = 0
        let watchdog = BrowserAutomationWatchdog(sleep: { _ in })

        let outcome = await watchdog.recoverIfUnresponsive(
            probe: { _ in },
            recover: {
                recoveryCount += 1
                return false
            }
        )

        #expect(outcome == .superseded)
        #expect(recoveryCount == 1)
    }
}

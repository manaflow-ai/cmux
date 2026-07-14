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
            probes: [{ finish in finish() }],
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
            probes: [{ _ in }],
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
            probes: [{ _ in }],
            recover: {
                recoveryCount += 1
                return false
            }
        )

        #expect(outcome == .superseded)
        #expect(recoveryCount == 1)
    }

    @Test("A responsive snapshot cannot mask a missing JavaScript callback")
    func oneResponsiveChannelStillRecovers() async {
        var recoveryCount = 0
        let watchdog = BrowserAutomationWatchdog(sleep: { _ in })

        let outcome = await watchdog.recoverIfUnresponsive(
            probes: [
                { _ in },
                { finish in finish() },
            ],
            recover: {
                recoveryCount += 1
                return true
            }
        )

        #expect(outcome == .recovered)
        #expect(recoveryCount == 1)
    }

    @Test("All browser callback channels must respond before the pipeline is healthy")
    func allResponsiveChannelsPreserveBrowserProcess() async {
        var recoveryCount = 0
        let watchdog = BrowserAutomationWatchdog()

        let outcome = await watchdog.recoverIfUnresponsive(
            probes: [
                { finish in finish() },
                { finish in finish() },
            ],
            recover: {
                recoveryCount += 1
                return true
            }
        )

        #expect(outcome == .responsive)
        #expect(recoveryCount == 0)
    }
}

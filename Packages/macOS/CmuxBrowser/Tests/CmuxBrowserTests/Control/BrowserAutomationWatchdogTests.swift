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

    @Test("Concurrent checks for one browser instance share one liveness operation")
    func concurrentChecksShareOneRecovery() async {
        var probeCount = 0
        var recoveryCount = 0
        var pendingProbeCompletions: [@MainActor @Sendable () -> Void] = []
        let (probeStarts, probeStartsContinuation) = AsyncStream.makeStream(
            of: Void.self,
            bufferingPolicy: .bufferingOldest(2)
        )
        var probeStartsIterator = probeStarts.makeAsyncIterator()
        let watchdog = BrowserAutomationWatchdog()
        let probe: BrowserAutomationWatchdog.Probe = { finish in
            probeCount += 1
            pendingProbeCompletions.append(finish)
            probeStartsContinuation.yield()
        }
        let recover: BrowserAutomationWatchdog.Recovery = {
            recoveryCount += 1
            return true
        }

        let firstCheck = Task { @MainActor in
            await watchdog.recoverIfUnresponsive(probes: [probe], recover: recover)
        }
        let firstProbeStarted: Void? = await probeStartsIterator.next()
        #expect(firstProbeStarted != nil)

        let secondCheck = Task { @MainActor in
            await watchdog.recoverIfUnresponsive(probes: [probe], recover: recover)
        }
        await Task.yield()

        #expect(probeCount == 1)
        let completions = pendingProbeCompletions
        for completion in completions {
            completion()
        }
        let firstOutcome = await firstCheck.value
        let secondOutcome = await secondCheck.value

        #expect(firstOutcome == .responsive)
        #expect(secondOutcome == .responsive)
        #expect(probeCount == 1)
        #expect(recoveryCount == 0)
        probeStartsContinuation.finish()
    }

    @Test("Cancelling the leading check cancels callers sharing its recovery")
    func leadingCancellationCancelsSharedRecovery() async {
        var probeCount = 0
        let (probeStarts, probeStartsContinuation) = AsyncStream.makeStream(
            of: Void.self,
            bufferingPolicy: .bufferingOldest(2)
        )
        var probeStartsIterator = probeStarts.makeAsyncIterator()
        let watchdog = BrowserAutomationWatchdog()
        let probe: BrowserAutomationWatchdog.Probe = { _ in
            probeCount += 1
            probeStartsContinuation.yield()
        }
        let recover: BrowserAutomationWatchdog.Recovery = { true }

        let firstCheck = Task { @MainActor in
            await watchdog.recoverIfUnresponsive(probes: [probe], recover: recover)
        }
        let firstProbeStarted: Void? = await probeStartsIterator.next()
        #expect(firstProbeStarted != nil)

        let secondCheck = Task { @MainActor in
            await watchdog.recoverIfUnresponsive(probes: [probe], recover: recover)
        }
        await Task.yield()
        firstCheck.cancel()

        let firstOutcome = await firstCheck.value
        let secondOutcome = await secondCheck.value
        #expect(firstOutcome == .cancelled)
        #expect(secondOutcome == .cancelled)
        #expect(probeCount == 1)
        probeStartsContinuation.finish()
    }
}

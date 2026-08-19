import Testing

@testable import CmuxPeerTransport

@Suite("PeerEndpointHealthWatchdog")
struct PeerEndpointHealthWatchdogTests {
    /// Scripted probe: returns queued verdicts in order, then `.inactive`.
    actor ProbeScript {
        private var verdicts: [PeerEndpointHealthVerdict]
        private(set) var probeCount = 0

        init(_ verdicts: [PeerEndpointHealthVerdict]) {
            self.verdicts = verdicts
        }

        func next() -> PeerEndpointHealthVerdict {
            probeCount += 1
            return verdicts.isEmpty ? .inactive : verdicts.removeFirst()
        }
    }

    actor RecreateRecorder {
        private(set) var reasons: [String] = []

        func record(_ reason: String) {
            reasons.append(reason)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func firesRecreateOnTerminalFailure() async throws {
        let script = ProbeScript([.healthy, .dead("driver died"), .inactive])
        let recorder = RecreateRecorder()
        let watchdog = PeerEndpointHealthWatchdog(
            interval: .milliseconds(5),
            probe: { await script.next() },
            recreate: { reason in await recorder.record(reason) }
        )
        await watchdog.start()
        #expect(await watchdog.isRunning)

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while await recorder.reasons.isEmpty, clock.now < deadline {
            try await clock.sleep(for: .milliseconds(10))
        }
        await watchdog.stop()

        // Exactly the injected terminal failure fired recreate; healthy and
        // inactive verdicts never did.
        #expect(await recorder.reasons == ["driver died"])
    }

    @Test(.timeLimit(.minutes(1)))
    func stopCancelsProbing() async throws {
        let script = ProbeScript([]) // Always .inactive: never recreates.
        let recorder = RecreateRecorder()
        let watchdog = PeerEndpointHealthWatchdog(
            interval: .milliseconds(5),
            probe: { await script.next() },
            recreate: { reason in await recorder.record(reason) }
        )
        await watchdog.start()

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while await script.probeCount == 0, clock.now < deadline {
            try await clock.sleep(for: .milliseconds(10))
        }
        #expect(await script.probeCount > 0)

        await watchdog.stop()
        #expect(await watchdog.isRunning == false)
        // Give any tick already past its cancellation check time to land,
        // then require the count to hold still.
        try await clock.sleep(for: .milliseconds(30))
        let settledCount = await script.probeCount
        try await clock.sleep(for: .milliseconds(60))
        #expect(await script.probeCount == settledCount)
        #expect(await recorder.reasons.isEmpty)
    }

    @Test func startIsIdempotent() async {
        let script = ProbeScript([])
        let watchdog = PeerEndpointHealthWatchdog(
            interval: .seconds(60),
            probe: { await script.next() },
            recreate: { _ in }
        )
        await watchdog.start()
        await watchdog.start()
        #expect(await watchdog.isRunning)
        await watchdog.stop()
        #expect(await watchdog.isRunning == false)
    }
}

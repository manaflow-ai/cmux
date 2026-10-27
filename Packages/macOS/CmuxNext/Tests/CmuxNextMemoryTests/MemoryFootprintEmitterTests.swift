import CmuxNextCompat
import CmuxNextMemory
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// p07-memory-016: the footprints go into the histograms once per interval on the emitter's own
/// deadline (Chrome's periodic `ProcessMemoryMetricsEmitter` run), never per read or pressure change.
@MainActor @Suite struct MemoryFootprintEmitterTests {
    /// The live PID reads the emitter made.
    final class Reads {
        var count = 0
    }

    /// One sample per interval with the live WebContent PIDs, none before the interval ends, a
    /// second `start` arms nothing more, and `stop` ends the sampling. The next deadline is armed
    /// only after the sample is recorded, so waiting for it is waiting for the record.
    @Test func theEmitterSamplesOncePerInterval() async throws {
        let clock = CmuxNextWakeupsTestSupport.ManualClock()
        let histograms = MemoryHistograms(pressure: MemoryPressureEvents(source: ManualMemoryPressureSource()), discardKinds: [])
        let reads = Reads()
        let emitter = MemoryFootprintEmitter(
            histograms: histograms,
            webContentPIDs: {
                reads.count += 1
                return [900]
            },
            sample: { webContent in
                let app = MemoryDiagnosticsProcesses.Row(kind: .app, pid: 1, physFootprintBytes: 300 << 20)
                let pages = webContent.map { MemoryDiagnosticsProcesses.Row(kind: .webkitWebContent, pid: $0, physFootprintBytes: 40 << 20) }
                return MemoryDiagnosticsProcesses(rows: [app] + pages)
            },
            interval: .seconds(3_600),
            timer: DemandTimer(owner: "test.memory-footprints", clock: clock, ledger: WakeupLedger()))
        emitter.start()
        emitter.start()
        try await clock.waitForSleeper()
        #expect(clock.sleeperCount == 1, "a second start armed a second deadline")

        clock.advance(by: .seconds(1_800))
        #expect(histograms.snapshot().appFootprintMiB.count == 0, "sampled before the interval ended")
        clock.advance(by: .seconds(1_800))
        try await clock.waitForSleeper()
        var snapshot = histograms.snapshot()
        #expect(reads.count == 1)
        #expect(snapshot.appFootprintMiB.count == 1)
        #expect(snapshot.appFootprintMiB.sum == 300)
        #expect(snapshot.rendererFootprintMiB.sum == 40)

        clock.advance(by: .seconds(3_600))
        try await clock.waitForSleeper()
        snapshot = histograms.snapshot()
        #expect(reads.count == 2)
        #expect(snapshot.appFootprintMiB.count == 2)

        emitter.stop()
        #expect(clock.sleeperCount == 0, "stop left the deadline armed")
        clock.advance(by: .seconds(3_600))
        #expect(histograms.snapshot().appFootprintMiB.count == 2)
    }
}

import CmuxNextCompat
@testable import CmuxNextMemory
import CmuxNextWakeups
import Testing

/// The footprints go into the histograms once per interval on the emitter's own
/// deadline (Chrome's periodic `ProcessMemoryMetricsEmitter` run), never per read or pressure change.
/// The deadline is a `background` ``MainDeadline`` and the record a posted `background` task.
@MainActor @Suite struct MemoryFootprintEmitterTests {
    /// The live PID reads the emitter made.
    final class Reads {
        var count = 0
    }

    /// One sample per interval with the live WebContent PIDs, none before the interval ends, a
    /// second `start` arms nothing more, and `stop` ends the sampling. The next deadline is armed
    /// only after the sample is recorded.
    @Test func theEmitterSamplesOncePerInterval() async throws {
        let rig = MemoryDeadlineRig()
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
            deadlines: rig.deadlines)
        emitter.start()
        emitter.start()
        #expect(rig.hasArmedWake)

        rig.advance(by: .seconds(1_800))
        rig.fireAtNow()
        #expect(reads.count == 0 && histograms.snapshot().appFootprintMiB.count == 0, "sampled before the interval ended")
        rig.fireAndRun()
        #expect(reads.count == 1)
        emitter.start()
        try await Self.recorded(1, histograms, rig)
        let snapshot = histograms.snapshot()
        #expect(snapshot.appFootprintMiB.sum == 300)
        #expect(snapshot.rendererFootprintMiB.sum == 40)
        #expect(rig.hasArmedWake, "the record armed the next sample")

        rig.fireAndRun()
        try await Self.recorded(2, histograms, rig)
        #expect(reads.count == 2, "a start while the first sample was read armed a second deadline")

        emitter.stop()
        #expect(!rig.hasArmedWake, "stop left the deadline armed")
        rig.advance(by: .seconds(3_600))
        rig.fireAtNow()
        #expect(histograms.snapshot().appFootprintMiB.count == 2)
    }

    /// A sample read when `stop` comes is not recorded and arms nothing.
    @Test func aSampleReadAcrossStopIsDropped() async throws {
        let rig = MemoryDeadlineRig()
        let histograms = MemoryHistograms(pressure: MemoryPressureEvents(source: ManualMemoryPressureSource()), discardKinds: [])
        let gate = SampleGate()
        let emitter = MemoryFootprintEmitter(histograms: histograms, webContentPIDs: { [] },
                                             sample: { _ in await gate.wait() }, interval: .seconds(60), deadlines: rig.deadlines)
        emitter.start()
        rig.fireAndRun()
        await gate.reached()
        emitter.stop()
        #expect(emitter.isSampling)
        await gate.open()
        for _ in 0..<10_000 where emitter.isSampling {
            await Task.yield()
            rig.frame()
        }
        try #require(!emitter.isSampling, "the sample's record never ran")
        #expect(histograms.snapshot().appFootprintMiB.count == 0, "a sample read across stop was recorded")
        #expect(!rig.hasArmedWake, "a stopped emitter armed its next sample")
    }

    /// Runs the rig's frames until `count` samples are recorded (the read runs off main, its record is a posted task).
    static func recorded(_ count: Int, _ histograms: MemoryHistograms, _ rig: MemoryDeadlineRig) async throws {
        for _ in 0..<10_000 where histograms.snapshot().appFootprintMiB.count < count {
            await Task.yield()
            rig.frame()
        }
        try #require(histograms.snapshot().appFootprintMiB.count == count)
    }
}

/// Holds a sample's read until the test opens it.
actor SampleGate {
    private var waiting: CheckedContinuation<MemoryDiagnosticsProcesses, Never>?
    private var arrived: CheckedContinuation<Void, Never>?
    private var hasArrived = false

    /// The read: returns an app row once ``open()`` runs.
    func wait() async -> MemoryDiagnosticsProcesses {
        await withCheckedContinuation { continuation in
            waiting = continuation
            hasArrived = true
            arrived?.resume()
            arrived = nil
        }
    }

    /// Returns once a read waits.
    func reached() async {
        guard !hasArrived else { return }
        await withCheckedContinuation { arrived = $0 }
    }

    func open() {
        waiting?.resume(returning: MemoryDiagnosticsProcesses(rows: [.init(kind: .app, pid: 1, physFootprintBytes: 1 << 20)]))
        waiting = nil
    }
}

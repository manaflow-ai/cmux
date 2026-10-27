import CmuxNextCompat
import CmuxNextMetrics
import CmuxNextTrace
import Darwin
import Testing

/// `memory.<kind>_kib`, `memory.total_kib`, `cpu.<kind>_pct` and `disk.idle_write_kib_per_min` (p09-observability task
/// 121) over a fake provider of the clock and each process's counters.
@Suite("Memory, CPU and idle disk per process kind")
struct ProcessResourceSamplerTests {
    private typealias Process = ProcessResourceSampler.KnownProcess
    private typealias Usage = ProcessResourceSampler.Usage

    private static let mebibyte: UInt64 = 1_024 * 1_024
    private static let second: UInt64 = 1_000_000_000

    /// The counters the fake provider hands out: the uptime clock and each pid's usage (a pid not listed is unreadable).
    final class FakeProcesses: Sendable {
        private struct State {
            var uptimeNanos: UInt64 = 1_000 * ProcessResourceSamplerTests.second
            var usage: [Int32: Usage] = [:]
            var sequence: UInt64 = 0
        }

        private let state = Mutex(State())

        var sources: ProcessResourceSampler.Sources {
            ProcessResourceSampler.Sources(uptimeNanos: { self.state.withLock { $0.uptimeNanos } },
                                           usage: { pid in self.state.withLock { $0.usage[pid] } })
        }

        func set(_ pid: Int32, footprintMiB: UInt64, cpuSeconds: UInt64 = 0, writtenKiB: UInt64 = 0, start: UInt64 = 1) {
            state.withLock {
                $0.usage[pid] = Usage(footprintBytes: footprintMiB * ProcessResourceSamplerTests.mebibyte,
                                      cpuNanos: cpuSeconds * ProcessResourceSamplerTests.second, diskWriteBytes: writtenKiB * 1_024,
                                      startTime: start)
            }
        }

        /// The next transition's number.
        func nextSequence() -> UInt64 {
            state.withLock { state in
                state.sequence += 1
                return state.sequence
            }
        }

        func end(_ pid: Int32) {
            state.withLock { $0.usage[pid] = nil }
        }

        /// `seconds` of uptime pass; each pid in `cpu` uses that many more CPU seconds and each in `written` writes that
        /// many more KiB.
        func advance(seconds: UInt64, cpu: [Int32: UInt64] = [:], written: [Int32: UInt64] = [:]) {
            state.withLock { state in
                state.uptimeNanos += seconds * ProcessResourceSamplerTests.second
                for (pid, used) in cpu { state.usage[pid]?.cpuNanos += used * ProcessResourceSamplerTests.second }
                for (pid, kib) in written { state.usage[pid]?.diskWriteBytes += kib * 1_024 }
            }
        }
    }

    private let fake = FakeProcesses()
    private let store: MetricsStore
    private let sampler: ProcessResourceSampler

    init() {
        let runtime = TraceRuntime(role: .app)
        let profile = MetricsProfile(appVersion: "1.2.3", buildNumber: "45", channel: "nightly", osVersion: "26.1.0",
                                     hardwareClass: "Mac16,10", bootSessionUUID: Array(0 ..< 16), buildUUID: Array(16 ..< 32),
                                     buildDay: MetricsProfile.Day(year: 2026, month: 10, day: 26))
        store = MetricsStore(role: .app, profile: profile, pid: 4242)
        #expect(store.attach(to: runtime))
        sampler = ProcessResourceSampler(sources: fake.sources, metrics: Metrics(runtime: runtime))
    }

    private static let processes = [
        Process(kind: .app, pid: 10), Process(kind: .daemon, pid: 20), Process(kind: .host, pid: 30), Process(kind: .host, pid: 31),
        Process(kind: .renderer, pid: 40),
    ]

    /// The count and sum of `id`'s histogram so far.
    private func samples(_ id: HistogramID) -> [UInt64] {
        guard let histogram = store.delta().histograms.first(where: { $0.name == id.name }) else { return [0, 0] }
        return [histogram.count, histogram.sum]
    }

    @discardableResult
    private func sample(_ trigger: ProcessResourceSampler.Trigger,
                                 _ processes: [Process] = ProcessResourceSamplerTests.processes) -> ProcessResourceSampler.Sample? {
        sampler.sample(processes, at: .init(trigger: trigger, sequence: fake.nextSequence()))
    }

    private func seedFootprints() {
        fake.set(10, footprintMiB: 300)
        fake.set(20, footprintMiB: 40)
        fake.set(30, footprintMiB: 8)
        fake.set(31, footprintMiB: 12)
        fake.set(40, footprintMiB: 100)
    }

    @Test("A sample records each process's footprint under its kind and the total once")
    func memoryPerProcessAndTotal() throws {
        seedFootprints()
        let sample = try #require(sample(.report))

        #expect(samples(.memory(.app)) == [1, 300 * 1_024])
        #expect(samples(.memory(.daemon)) == [1, 40 * 1_024])
        #expect(samples(.memory(.host)) == [2, 20 * 1_024], "one sample per host, as Chrome records one per renderer")
        #expect(samples(.memory(.renderer)) == [1, 100 * 1_024])
        #expect(samples(.memoryTotal) == [1, 460 * 1_024])
        #expect(sample.kinds == [.app, .daemon, .host, .renderer])
        #expect(sample.memoryKiB[.host] == 20 * 1_024)
        #expect(sample.totalKiB == 460 * 1_024)
    }

    @Test("A pid listed twice is read once, an unreadable one is counted, and nothing known records nothing")
    func duplicatesAndUnreadable() throws {
        fake.set(10, footprintMiB: 1)
        let sample = try #require(sample(.report, [Process(kind: .app, pid: 10), Process(kind: .renderer, pid: 10), Process(kind: .gpu, pid: 99)]))
        #expect(samples(.memory(.app)) == [1, 1_024])
        #expect(samples(.memory(.renderer)) == [0, 0])
        #expect(sample.unreadable == 1)

        _ = self.sample(.report, [Process(kind: .gpu, pid: 99)])
        #expect(samples(.memoryTotal) == [1, 1_024], "a sample that read no process records no total")
    }

    @Test("CPU records percent of one core since the previous reading of the same process")
    func cpuSincePreviousReading() throws {
        seedFootprints()
        sample(.becomeActive)
        fake.advance(seconds: 20, cpu: [10: 5, 20: 1, 30: 20])
        let sample = try #require(sample(.resignActive))

        #expect(samples(.cpu(.app)) == [1, 25])
        #expect(samples(.cpu(.daemon)) == [1, 5])
        #expect(samples(.cpu(.host)) == [2, 100], "the busy host uses one whole core, the other none")
        #expect(sample.cpuPercent[Process(kind: .host, pid: 30)] == 100)
        #expect(sample.cpuPercent[Process(kind: .host, pid: 31)] == 0)
    }

    @Test("A reading under 10 s after the baseline records no CPU and keeps the baseline")
    func shortCPUPeriodKeepsTheBaseline() {
        seedFootprints()
        sample(.becomeActive)
        fake.advance(seconds: 4, cpu: [10: 2])
        sample(.resignActive)
        #expect(samples(.cpu(.app)) == [0, 0])
        fake.advance(seconds: 6, cpu: [10: 3])
        sample(.becomeActive)
        #expect(samples(.cpu(.app)) == [1, 50], "5 s of CPU over the 10 s since the kept baseline")
    }

    @Test("A pid reused by another process starts a new baseline")
    func reusedPIDStartsOver() {
        fake.set(10, footprintMiB: 1, cpuSeconds: 100, start: 1)
        sample(.becomeActive, [Process(kind: .app, pid: 10)])
        fake.advance(seconds: 30)
        fake.set(10, footprintMiB: 1, cpuSeconds: 2, start: 2)
        sample(.resignActive, [Process(kind: .app, pid: 10)])
        #expect(samples(.cpu(.app)) == [0, 0])
    }

    @Test("Disk writes per idle minute from resign to become-active, over the processes known at both ends")
    func idleDiskWrites() throws {
        seedFootprints()
        sample(.resignActive)
        #expect(sampler.isMeasuringIdle)
        fake.advance(seconds: 120, written: [10: 600, 20: 300, 40: 100])
        fake.end(31)
        fake.set(50, footprintMiB: 1, writtenKiB: 10_000)
        let sample = try #require(sample(.becomeActive, Self.processes + [Process(kind: .gpu, pid: 50)]))

        #expect(sample.idle == ProcessResourceSampler.IdlePeriod(nanos: 120 * Self.second, writtenBytes: 1_000 * 1_024))
        #expect(samples(.diskIdleWrite) == [1, 500], "1,000 KiB in 2 minutes; the gpu process unknown at the start is left out")
        #expect(!sampler.isMeasuringIdle)
    }

    @Test("An idle period under a minute records nothing; a report records the period so far and opens the next")
    func shortIdleAndReports() {
        seedFootprints()
        sample(.resignActive)
        fake.advance(seconds: 30, written: [10: 100])
        sample(.report)
        #expect(samples(.diskIdleWrite) == [0, 0])
        #expect(sampler.isMeasuringIdle, "a short period stays open at a report")
        fake.advance(seconds: 30, written: [10: 200])
        sample(.report)
        #expect(samples(.diskIdleWrite) == [1, 300])
        fake.advance(seconds: 60, written: [10: 60])
        sample(.becomeActive)
        #expect(samples(.diskIdleWrite) == [2, 360])
    }

    @Test("A sample that ran after a later transition records nothing and opens no idle period while active")
    func outOfOrderSampleIsDropped() {
        seedFootprints()
        _ = sampler.sample(Self.processes, at: .init(trigger: .becomeActive, sequence: 2))
        let late = sampler.sample(Self.processes, at: .init(trigger: .resignActive, sequence: 1))
        #expect(late == nil)
        #expect(!sampler.isMeasuringIdle)
        #expect(samples(.memoryTotal) == [1, 460 * 1_024])
        #expect(sampler.tally() == ProcessResourceSampler.Tally(recorded: [.becomeActive: 1], outOfOrder: 1))
    }

    @Test("The live reader reads this process's own counters")
    func liveReaderReadsThisProcess() throws {
        let usage = try #require(ProcessResourceSampler.usage(of: getpid()))
        #expect(usage.footprintBytes > 0)
        #expect(usage.startTime > 0)
        #expect(ProcessResourceSampler.usage(of: -1) == nil)
    }
}

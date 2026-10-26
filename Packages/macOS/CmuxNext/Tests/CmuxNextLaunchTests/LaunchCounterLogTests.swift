import CmuxNextCompat
import CmuxNextLaunch
import Testing

/// The launch counter log behind `DebugTimings.markLaunch`: the counters are read before
/// anything is kept or sent, a repeated milestone keeps its first sample and sends nothing,
/// and the values go to the value sink (never a time mark), the temperature first.
struct LaunchCounterLogTests {
    /// What happened, in order, across the counters and the sink.
    nonisolated final class Journal: Sendable {
        private let entries = Mutex<[String]>([])

        func note(_ entry: String) { entries.withLock { $0.append(entry) } }

        var all: [String] { entries.withLock { $0 } }
    }

    /// Counters that change after each read, so a second read is visible.
    nonisolated final class CountingCounters: LaunchCounterSource {
        private let journal: Journal
        private let reads = Mutex(0)

        init(journal: Journal) { self.journal = journal }

        func pageIns() -> UInt64? {
            journal.note("read pageins")
            return reads.withLock { count in
                count += 1
                return count == 1 ? 4_200 : 9
            }
        }

        func mainThreadCPUNanos() -> UInt64? {
            journal.note("read cpu")
            return 187_500_000
        }
    }

    nonisolated struct RecordingSink: LaunchValueSink {
        let journal: Journal

        func writeValue(name: String, number: Double) { journal.note("value \(name) \(number)") }
        func writeValue(name: String, label: String) { journal.note("value \(name) \(label)") }
    }

    private func log(_ journal: Journal) -> LaunchCounterLog {
        LaunchCounterLog(reader: StartupCounterReader(source: CountingCounters(journal: journal)), sink: RecordingSink(journal: journal))
    }

    @Test func theRunLoopStartReadsFirstThenSendsTheTemperatureAndPageIns() {
        let journal = Journal()
        let counters = log(journal)
        let sample = counters.read(atMilestone: "run_loop_start")
        #expect(sample?.temperature == .cold)
        #expect(journal.all == [
            "read pageins",
            "value launch.temperature cold",
            "value launch.pageins_run_loop_start 4200.0",
        ])
        #expect(counters.snapshot == LaunchCounterLog.Snapshot(
            temperature: .cold, values: [.init(name: "launch.pageins_run_loop_start", value: 4_200)]))
    }

    @Test func aRepeatedMilestoneKeepsTheFirstSampleAndSendsNothing() {
        let journal = Journal()
        let counters = log(journal)
        counters.read(atMilestone: "run_loop_start")
        let repeated = counters.read(atMilestone: "run_loop_start")
        #expect(repeated == nil)
        // The second read saw 9 page-ins (warm); the temperature stays the first one's.
        #expect(counters.snapshot.temperature == .cold)
        #expect(counters.snapshot.values == [.init(name: "launch.pageins_run_loop_start", value: 4_200)])
        #expect(journal.all.filter { $0.hasPrefix("value") }.count == 2)
    }

    @Test func theFirstFrameAddsItsValuesWithoutChangingTheTemperature() {
        let journal = Journal()
        let counters = log(journal)
        counters.read(atMilestone: "run_loop_start")
        counters.read(atMilestone: "first_window_frame_committed")
        #expect(counters.snapshot == LaunchCounterLog.Snapshot(temperature: .cold, values: [
            .init(name: "launch.pageins_run_loop_start", value: 4_200),
            .init(name: "launch.pageins_first_frame", value: 9),
            .init(name: "launch.main_cpu_ms", value: 187.5),
        ]))
        #expect(Array(journal.all.suffix(4)) == [
            "read pageins",
            "read cpu",
            "value launch.pageins_first_frame 9.0",
            "value launch.main_cpu_ms 187.5",
        ])
    }

    @Test func otherMilestonesReadAndSendNothing() {
        let journal = Journal()
        let counters = log(journal)
        #expect(counters.read(atMilestone: "main_start") == nil)
        #expect(journal.all.isEmpty)
        #expect(counters.snapshot == LaunchCounterLog.Snapshot())
    }

    @Test func everySentNameIsOneOfTheReadersValueNames() {
        let journal = Journal()
        let counters = log(journal)
        counters.read(atMilestone: "run_loop_start")
        counters.read(atMilestone: "first_window_frame_committed")
        let names = Set(journal.all.filter { $0.hasPrefix("value ") }.map { String($0.split(separator: " ")[1]) })
        #expect(names == [
            StartupCounterReader.temperatureName, StartupCounterReader.pageInsRunLoopStartName,
            StartupCounterReader.pageInsFirstFrameName, StartupCounterReader.mainCPUName,
        ])
    }
}

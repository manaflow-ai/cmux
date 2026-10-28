import CmuxNextMetrics
import CmuxNextTrace
import Foundation
import Testing

/// The stability counts and their denominators (p09-observability task 109): each source is one sample of its
/// own catalog histogram, and the counts live in the launch's metrics file, so the next launch folds a crashed
/// launch's counts as that launch's own section.
@Suite("Stability counters", .serialized)
struct StabilityCountersTests {
    private static let profile = MetricsProfile(appVersion: "1.2.3", buildNumber: "45", channel: "nightly", osVersion: "26.1.0",
                                                hardwareClass: "Mac16,10", bootSessionUUID: Array(0 ..< 16),
                                                buildUUID: Array(16 ..< 32), buildDay: MetricsProfile.Day(year: 2026, month: 10, day: 28))

    /// A fresh runtime with a fresh store attached, the counters over it, and the store.
    private static func attached(pid: UInt32 = 4242) -> (StabilityCounters, MetricsStore) {
        let runtime = TraceRuntime(role: .app)
        let store = MetricsStore(role: .app, profile: profile, pid: pid)
        #expect(store.attach(to: runtime))
        return (StabilityCounters(metrics: Metrics(runtime: runtime)), store)
    }

    /// Each histogram with samples: its name, sample count and buckets as `[index: count]`.
    private static func counts(_ delta: MetricsDelta) -> [String: (count: UInt64, sum: UInt64, buckets: [Int: UInt64])] {
        var out: [String: (count: UInt64, sum: UInt64, buckets: [Int: UInt64])] = [:]
        for histogram in delta.histograms where histogram.count > 0 {
            out[histogram.name] = (histogram.count, histogram.sum,
                                   Dictionary(uniqueKeysWithValues: histogram.buckets.map { ($0.index, $0.count) }))
        }
        return out
    }

    @Test("Each source records one sample of its own histogram")
    func eachSourceIsOneSampleOfItsHistogram() {
        let sources: [(name: String, value: Int, record: (StabilityCounters) -> Void)] = [
            ("stability.launch", 1, { $0.launched(.init(previousExit: nil)) }),
            ("stability.active_seconds", 42, { $0.active(seconds: 42) }),
            ("stability.child_exit.daemon", Int(HistogramID.ChildExit.signal.rawValue), { $0.childExited(.daemon, .signal) }),
            ("stability.child_exit.acpmux", Int(HistogramID.ChildExit.panic.rawValue), { $0.childExited(.acpmux, .panic) }),
            ("daemon.unresponsive", 1, { $0.daemonUnresponsive(lastRequest: .terminalIO) }),
        ]
        for source in sources {
            let (stability, store) = Self.attached()
            source.record(stability)
            let counts = Self.counts(store.delta())
            #expect(counts.count == 1, "\(source.name): \(counts.keys.sorted())")
            #expect(counts[source.name]?.count == 1, "\(source.name) counted more or less than once")
            if source.name == "stability.active_seconds" {
                #expect(counts[source.name]?.sum == 42)
            } else if source.name != "stability.launch" {
                #expect(counts[source.name]?.buckets == [source.value: 1])
            }
        }
    }

    @Test("A launch after an unclean end counts the launch and the end's kind, once each")
    func aLaunchCountsItsPreviousEnd() {
        for exit in HistogramID.UncleanExit.allCases {
            let (stability, store) = Self.attached()
            stability.launched(.init(previousExit: exit))
            let counts = Self.counts(store.delta())
            #expect(counts["stability.launch"]?.count == 1)
            #expect(counts["stability.unclean_exit"]?.buckets == [Int(exit.rawValue): 1])
            #expect(counts.count == 2)
        }
    }

    @Test("No active second and an unknown last request count as nothing and as other")
    func edges() {
        let (stability, store) = Self.attached()
        stability.active(seconds: 0)
        stability.active(seconds: -3)
        #expect(Self.counts(store.delta()).isEmpty, "a zero active time counted a sample")
        stability.daemonUnresponsive(lastRequest: nil)
        let other = HistogramID.MethodClass.allCases.firstIndex(of: .other) ?? -1
        #expect(Self.counts(store.delta())["daemon.unresponsive"]?.buckets == [other: 1])
    }

    @Test("A wait status names how a child ended")
    func waitStatus() {
        #expect(HistogramID.ChildExit(waitStatus: 0) == .clean)
        #expect(HistogramID.ChildExit(waitStatus: 101 << 8) == .panic, "Rust's panic exit")
        #expect(HistogramID.ChildExit(waitStatus: 1 << 8) == .panic)
        #expect(HistogramID.ChildExit(waitStatus: SIGKILL) == .signal)
        #expect(HistogramID.ChildExit(waitStatus: SIGSEGV | 0o200) == .signal, "a core dump is still a signal")
        #expect(HistogramID.ChildExit(waitStatus: SIGKILL, outOfMemory: true) == .oom)
    }

    /// The acceptance's fold test: counts recorded before and after the store moves into its file are in the file a
    /// crash leaves (nothing ran at the end of the launch), and the next launch folds them under that launch's id.
    @Test("The counts survive an app crash into the next launch's fold")
    func countsSurviveACrash() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "stability-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (stability, store) = Self.attached(pid: 100)
        stability.launched(.init(previousExit: .systemShutdown))
        _ = try #require(store.adoptFile(directory: directory.path(percentEncoded: false)))
        stability.active(seconds: 61)
        stability.childExited(.daemon, .signal)
        stability.daemonUnresponsive(lastRequest: .topology)
        // The launch crashes here: no delta is marked logged, nothing is flushed or closed.

        let current = directory.appending(path: MetricsStore.fileName(role: .app, pid: 200))
        let fold = MetricsLaunchFold(directory: directory, current: current, reader: MetricsLaunchFileReader(role: .app))
        let scan = try fold.sections()
        #expect(scan.unreadable.isEmpty)
        let section = try #require(scan.sections.first)
        #expect(scan.sections.count == 1)
        #expect(section.contents.profile == Self.profile)
        let counts = Self.counts(section.contents.delta)
        #expect(counts["stability.launch"]?.count == 1)
        #expect(counts["stability.unclean_exit"]?.buckets == [Int(HistogramID.UncleanExit.systemShutdown.rawValue): 1])
        #expect(counts["stability.active_seconds"]?.sum == 61)
        #expect(counts["stability.child_exit.daemon"]?.buckets == [Int(HistogramID.ChildExit.signal.rawValue): 1])
        #expect(counts["daemon.unresponsive"]?.buckets == [0: 1], "topology is the first class")
        #expect(try fold.sections().sections.map(\.id) == [section.id], "a read changes nothing")
    }
}

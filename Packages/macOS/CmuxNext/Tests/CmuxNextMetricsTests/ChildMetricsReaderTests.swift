import CmuxNextCompat
import CmuxNextMetrics
import CmuxNextTrace
import Foundation
import Testing

/// The daemon request latency fold (task 062): the app maps the daemon's metrics file read-only at a report and adds
/// what the daemon recorded since the last fold to its own `daemon.request.<class>`; a missing file is counted, and
/// nothing is folded twice, neither by a second report nor by the dead-file fold after the daemon ends.
struct ChildMetricsReaderTests {
    /// Runs file work inline on the test's thread.
    struct InlineFiles: MayBlockRunner {
        func runFiles<T: Sendable>(_ priority: MayBlockPriority, shutdown: MayBlockShutdown, site: MayBlockCallSite,
                                   _ body: @escaping @Sendable () throws -> T) async throws -> T { try body() }
        func runSystem<T: Sendable>(_ priority: MayBlockPriority, shutdown: MayBlockShutdown, site: MayBlockCallSite,
                                    _ body: @escaping @Sendable () throws -> T) async throws -> T { try body() }
        func runHostResolution<T: Sendable>(_ priority: MayBlockPriority, shutdown: MayBlockShutdown, site: MayBlockCallSite,
                                            _ body: @escaping @Sendable () throws -> T) async throws -> T { try body() }
        func postFiles(_ priority: MayBlockPriority, shutdown: MayBlockShutdown, site: MayBlockCallSite,
                       _ body: @escaping @Sendable () -> Void) { body() }
    }

    struct UploadFailed: Error {}

    private static let day = MetricsProfile.Day(year: 2026, month: 10, day: 26)
    private static let daemonPID: UInt32 = 4_711
    private static let catalog: [HistogramID] = [.daemonRequest(.query), .daemonRequest(.topology), .daemonDispatchQueue, .mainTurn]

    private let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "child-metrics-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    private static func profile(version: String) -> MetricsProfile {
        MetricsProfile(appVersion: version, buildNumber: "45", channel: "nightly", osVersion: "26.1.0",
                       hardwareClass: "Mac16,10", bootSessionUUID: Array(repeating: 7, count: 16), buildDay: day)
    }

    /// A daemon's store in its `metrics-daemon-<pid>.bin` in `folder`, and the recorder that writes it.
    private func daemonFile() throws -> (MetricsStore, Metrics) {
        let runtime = TraceRuntime(role: .daemon)
        let store = MetricsStore(role: .daemon, profile: Self.profile(version: "daemon-1"), pid: Self.daemonPID, catalog: Self.catalog)
        #expect(store.attach(to: runtime))
        _ = try #require(store.adoptFile(directory: folder.path(percentEncoded: false)))
        return (store, Metrics(runtime: runtime))
    }

    /// The app's store (on the heap) and its recorder.
    private static func appStore() -> (MetricsStore, Metrics) {
        let runtime = TraceRuntime(role: .app)
        let store = MetricsStore(role: .app, profile: profile(version: "app-1"), pid: 100, catalog: catalog)
        #expect(store.attach(to: runtime))
        return (store, Metrics(runtime: runtime))
    }

    private func reader(running: Bool) -> ChildMetricsReader {
        ChildMetricsReader(role: .daemon, directory: folder, isRunning: { _ in running })
    }

    private static func histogram(_ id: HistogramID, in delta: MetricsDelta) -> MetricsDelta.Histogram? {
        delta.histograms.first { $0.name == id.name }
    }

    @Test func aMissingDaemonFileIsCounted() async {
        defer { try? FileManager.default.removeItem(at: folder) }
        let (app, metrics) = Self.appStore()
        let fold = DaemonMetricsFold(reader: reader(running: true), metrics: metrics, work: InlineFiles())

        #expect(await fold.fold(pid: Int32(Self.daemonPID)) == .missing)
        #expect(await fold.fold(pid: nil) == .noDaemon)
        #expect(await fold.fold(pid: 0) == .noDaemon)
        let tally = await fold.tally
        #expect(tally.missing == 1 && tally.noDaemon == 2 && tally.folded == 0)
        #expect(tally.byName["missing"] == 1 && tally.byName["no_daemon"] == 2 && tally.byName["folded"] == 0,
                "debug.shipping_mode does not show the missing file")
        #expect(app.delta().isEmpty)
    }

    @Test func daemonRequestsFoldIntoTheAppOnceAcrossReports() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let (daemon, daemonMetrics) = try daemonFile()
        let (app, metrics) = Self.appStore()
        daemonMetrics.record(.daemonRequest(.query), 300)
        daemonMetrics.record(.daemonRequest(.query), 9_000)
        daemonMetrics.record(.daemonRequest(.topology), 50)
        daemonMetrics.record(.daemonDispatchQueue, 12)
        daemonMetrics.record(.mainTurn, 1_000)
        let fold = DaemonMetricsFold(reader: reader(running: true), metrics: metrics, work: InlineFiles())

        #expect(await fold.fold(pid: Int32(Self.daemonPID)) == .folded(histograms: 3, samples: 4))
        let first = app.delta()
        let query = try #require(Self.histogram(.daemonRequest(.query), in: first))
        let daemonQuery = try #require(Self.histogram(.daemonRequest(.query), in: daemon.delta()))
        #expect(query.count == 2 && query.sum == 9_300)
        #expect(query.buckets == daemonQuery.buckets, "the fold moved samples to other buckets")
        #expect(Self.histogram(.daemonRequest(.topology), in: first)?.count == 1)
        #expect(Self.histogram(.daemonDispatchQueue, in: first)?.count == 1)
        #expect(Self.histogram(.mainTurn, in: first) == nil, "the daemon's main.turn is not the app's")

        #expect(await fold.fold(pid: Int32(Self.daemonPID)) == .folded(histograms: 0, samples: 0), "a second report folded again")
        #expect(app.delta() == first)

        daemonMetrics.record(.daemonRequest(.query), 40)
        #expect(await fold.fold(pid: Int32(Self.daemonPID)) == .folded(histograms: 1, samples: 1))
        #expect(Self.histogram(.daemonRequest(.query), in: app.delta())?.count == 3)

        // A new controller (an app relaunch) over the same daemon reads the cursor beside the file.
        let relaunched = DaemonMetricsFold(reader: reader(running: true), metrics: metrics, work: InlineFiles())
        #expect(await relaunched.fold(pid: Int32(Self.daemonPID)) == .folded(histograms: 0, samples: 0))
        #expect(await fold.tally.samples == 5)
        withExtendedLifetime(daemon) {}
    }

    @Test func aDeadDaemonsSectionHasOnlyWhatTheAppDidNotFold() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let (daemon, daemonMetrics) = try daemonFile()
        let (_, metrics) = Self.appStore()
        daemonMetrics.record(.daemonRequest(.query), 300)
        daemonMetrics.record(.mainTurn, 1_000)
        #expect(DaemonMetricsFold.foldNow(pid: Self.daemonPID, reader: reader(running: true), metrics: metrics)
            == .folded(histograms: 1, samples: 1))
        daemonMetrics.record(.daemonRequest(.query), 500)

        let file = reader(running: true).file(pid: Self.daemonPID)
        #expect(!reader(running: true).isLaunchFile(file), "a running daemon's file went to the dead-file fold")
        let dead = reader(running: false)
        #expect(dead.isLaunchFile(file))
        let fold = MetricsLaunchFold(directory: folder, current: folder.appending(path: MetricsStore.fileName(role: .daemon, pid: 1)),
                                     reader: dead)
        var sent: [MetricsLaunchContents] = []
        let outcome = await fold.run { (section: MetricsLaunchSection<MetricsLaunchContents>) throws(UploadFailed) in
            sent.append(section.contents)
        }
        #expect(outcome.errors.isEmpty)
        let section = try #require(sent.first)
        #expect(sent.count == 1)
        #expect(section.profile.appVersion == "daemon-1")
        #expect(Self.histogram(.daemonRequest(.query), in: section.delta)?.count == 1, "the app's folded sample was sent again")
        #expect(Self.histogram(.daemonRequest(.query), in: section.delta)?.sum == 500)
        #expect(Self.histogram(.mainTurn, in: section.delta)?.count == 1)

        dead.removeOrphanCursors()
        #expect(!FileManager.default.fileExists(atPath: file.deletingPathExtension().appendingPathExtension("folded").path))
        withExtendedLifetime(daemon) {}
    }

    @Test func aCursorOfAnEarlierDaemonWithTheSamePidIsIgnored() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let (daemon, daemonMetrics) = try daemonFile()
        daemonMetrics.record(.daemonRequest(.query), 300)
        let reader = reader(running: true)
        let file = reader.file(pid: Self.daemonPID)
        let contents = try reader.read(file)
        try reader.advance(file, launch: "daemon-\(Self.daemonPID)-1", by: contents.delta.histograms)
        #expect(Self.histogram(.daemonRequest(.query), in: try reader.read(file).delta)?.count == 1)
        withExtendedLifetime(daemon) {}
    }

    @Test func aDaemonIdTheAppRefusesStaysInTheFile() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let (daemon, daemonMetrics) = try daemonFile()
        // An app whose catalog has no daemon.request.topology (an app update expired it while the daemon ran).
        let runtime = TraceRuntime(role: .app)
        let app = MetricsStore(role: .app, profile: Self.profile(version: "app-2"), pid: 100,
                               catalog: Self.catalog.filter { $0 != .daemonRequest(.topology) })
        #expect(app.attach(to: runtime))
        let metrics = Metrics(runtime: runtime)
        daemonMetrics.record(.daemonRequest(.query), 300)
        daemonMetrics.record(.daemonRequest(.topology), 50)
        let fold = DaemonMetricsFold(reader: reader(running: true), metrics: metrics, work: InlineFiles())

        #expect(await fold.fold(pid: Int32(Self.daemonPID)) == .folded(histograms: 1, samples: 1))
        #expect(Self.histogram(.daemonRequest(.query), in: app.delta())?.count == 1)
        #expect(Self.histogram(.daemonRequest(.topology), in: app.delta()) == nil)
        let left = try reader(running: true).read(reader(running: true).file(pid: Self.daemonPID)).delta
        #expect(Self.histogram(.daemonRequest(.query), in: left) == nil, "a folded sample would be sent again in the daemon's section")
        let topology = try #require(Self.histogram(.daemonRequest(.topology), in: left), "a refused sample was marked folded")
        #expect(topology.count == 1 && topology.sum == 50)
        withExtendedLifetime(daemon) {}
    }

    @Test func withNoAppStoreNothingIsFoldedOrMarked() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let (daemon, daemonMetrics) = try daemonFile()
        daemonMetrics.record(.daemonRequest(.query), 300)
        let metrics = Metrics(runtime: TraceRuntime(role: .app))
        #expect(DaemonMetricsFold.foldNow(pid: Self.daemonPID, reader: reader(running: true), metrics: metrics) == .noStore)
        let left = try reader(running: true).read(reader(running: true).file(pid: Self.daemonPID))
        #expect(Self.histogram(.daemonRequest(.query), in: left.delta)?.count == 1, "samples the app never took were marked folded")
        withExtendedLifetime(daemon) {}
    }
}

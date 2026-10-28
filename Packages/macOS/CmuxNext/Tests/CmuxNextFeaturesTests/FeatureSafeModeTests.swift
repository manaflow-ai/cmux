import Atomics
import CmuxNextCompat
import CmuxNextFeatures
import CmuxNextWakeups
import Darwin
import Foundation
import Testing

/// Chrome's variations safe mode for the remote flags document
/// (p12-perf-process.md section 3.9;
/// components/variations/service/safe_seed_manager.cc).
struct FeatureSafeModeTests {
    private static let killX = feature(0, "killX", .killSwitch, sticky: true)
    private static let perfY = feature(1, "perfY", .perfPath, sticky: false)
    private static let labsZ = feature(2, "labsZ", .labs, sticky: false)
    private static let registry = FeatureRegistry([killX, perfY, labsZ])

    private static func feature(_ index: Int, _ name: String, _ kind: Feature.Kind, sticky: Bool) -> Feature {
        Feature(
            index: index,
            name: name,
            owner: "PL-test",
            description: "A test feature.",
            kind: kind,
            process: .app,
            chromiumFeature: nil,
            defaults: FeatureDefaults(all: true),
            expires: nil,
            params: [],
            stories: [],
            sticky: sticky,
            runtimeMutable: false
        )
    }

    /// The document that kills X (sticky) and Y (not sticky), and turns Z on.
    private static let latest: [String: Bool] = ["killX": false, "perfY": false, "labsZ": true]
    /// An older document that only turns Y on.
    private static let lastKnownGood: [String: Bool] = ["perfY": true]

    /// A fresh features folder and the app's lanes; each launch reads the streaks the previous one left.
    private final class Harness: Sendable {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "feature-safe-mode-\(UUID().uuidString)", directoryHint: .isDirectory)
        let work: BackgroundWork
        /// The lane items' runs, yielded on their lane threads after each item's work returned.
        let runs: AsyncStream<Run>

        init() {
            let (runs, ran) = AsyncStream.makeStream(of: Run.self)
            self.runs = runs
            work = BackgroundWork(label: "test.feature-safe-mode", onRan: { lane, _, _, _ in
                ran.yield(Run(lane: lane, onMain: pthread_main_np() != 0))
            })
        }

        func launch(uncleanly: Bool, environment: [String: String] = [:]) async -> FeatureSafeMode {
            await FeatureSafeMode.launch(directory: directory, previousRunEndedUncleanly: uncleanly,
                                         environment: environment, work: work)
        }

        /// `crashes` launches in a row, each after a run that ended without a clean exit.
        func launchAfterCrashes(_ crashes: Int) async -> FeatureSafeMode {
            var safeMode = await launch(uncleanly: false)
            for _ in 0 ..< crashes { safeMode = await launch(uncleanly: true) }
            return safeMode
        }

        /// The first `count` runs. An awaited item resumes its caller before its lane reports the run,
        /// so a test waits for the reports instead of reading a snapshot after its last await.
        func first(_ count: Int) async -> [Run] {
            var seen: [Run] = []
            for await run in runs {
                seen.append(run)
                if seen.count == count { break }
            }
            return seen
        }

        deinit { try? FileManager.default.removeItem(at: directory) }
    }

    /// One lane item's run: its lane and whether its thread was the main thread.
    private struct Run: Sendable {
        let lane: BlockingLane
        let onMain: Bool
    }

    private static func resolved(_ remote: [String: Bool]) -> FeatureList {
        FeatureList(registry: registry, channel: .release, overrides: FeatureOverrides(remote: remote))
    }

    // MARK: Levels

    @Test func chromesThresholdsPickTheLevel() {
        typealias Streaks = FeatureSafeMode.Streaks
        #expect(FeatureSafeMode.Level(Streaks(crashes: 2, fetchFailures: 24)) == .regular)
        #expect(FeatureSafeMode.Level(Streaks(crashes: 3, fetchFailures: 0)) == .lastKnownGood)
        #expect(FeatureSafeMode.Level(Streaks(crashes: 0, fetchFailures: 25)) == .lastKnownGood)
        #expect(FeatureSafeMode.Level(Streaks(crashes: 4, fetchFailures: 0)) == .noRemote)
        #expect(FeatureSafeMode.Level(Streaks(crashes: 3, fetchFailures: 50)) == .noRemote)
    }

    // MARK: Crash streak

    @Test func aRegularLaunchAppliesTheLastDocument() async {
        let harness = Harness()
        let safeMode = await harness.launchAfterCrashes(2)
        #expect(safeMode.state.level == .regular)
        let list = Self.resolved(safeMode.remoteValues(latest: Self.latest, lastKnownGood: Self.lastKnownGood, registry: Self.registry))
        #expect(!list.isEnabled(Self.killX))
        #expect(!list.isEnabled(Self.perfY))
        #expect(list.resolution(of: Self.labsZ) == Feature.Resolution(isEnabled: true, source: .remote))
    }

    @Test func threeCrashesApplyTheLastKnownGoodDocumentAndKeepTheStickyKill() async {
        let harness = Harness()
        let safeMode = await harness.launchAfterCrashes(3)
        #expect(safeMode.state.level == .lastKnownGood)
        #expect(safeMode.state.streaks == FeatureSafeMode.Streaks(crashes: 3, fetchFailures: 0))
        let remote = safeMode.remoteValues(latest: Self.latest, lastKnownGood: Self.lastKnownGood, registry: Self.registry)
        #expect(remote == ["killX": false, "perfY": true])
        let list = Self.resolved(remote)
        #expect(list.resolution(of: Self.killX) == Feature.Resolution(isEnabled: false, source: .remote), "the seed's kill of X was lost")
        #expect(list.isEnabled(Self.perfY))
        #expect(list.resolution(of: Self.labsZ).source == .channelDefault)
    }

    @Test func fourCrashesDropEveryRemoteValueButTheStickyKills() async {
        let harness = Harness()
        let safeMode = await harness.launchAfterCrashes(4)
        #expect(safeMode.state.level == .noRemote)
        let remote = safeMode.remoteValues(latest: Self.latest, lastKnownGood: ["perfY": true, "killX": true], registry: Self.registry)
        #expect(remote == ["killX": false])
        let list = Self.resolved(remote)
        #expect(!list.isEnabled(Self.killX))
        #expect(list.resolution(of: Self.perfY).source == .channelDefault)
        #expect(list.resolution(of: Self.labsZ).source == .channelDefault)
        // A sticky kill only the last known good document holds stays off too.
        #expect(safeMode.remoteValues(latest: [:], lastKnownGood: ["killX": false], registry: Self.registry) == ["killX": false])
    }

    /// Params follow the document safe mode picks; no param survives `noRemote` (none is a kill switch).
    @Test(arguments: [
        (2, ["perfY": ["n": "3"]]),
        (3, ["perfY": ["n": "1"]]),
        (4, [String: [String: String]]()),
    ] as [(Int, [String: [String: String]])])
    func remoteParamsFollowTheLevel(crashes: Int, expected: [String: [String: String]]) async {
        let harness = Harness()
        let safeMode = await harness.launchAfterCrashes(crashes)
        #expect(safeMode.remoteParams(latest: ["perfY": ["n": "3"]], lastKnownGood: ["perfY": ["n": "1"]]) == expected)
    }

    @Test func aCleanLaunchKeepsTheStreak() async {
        let harness = Harness()
        _ = await harness.launchAfterCrashes(3)
        let safeMode = await harness.launch(uncleanly: false)
        #expect(safeMode.state.level == .lastKnownGood, "a clean run cleared the crash streak; only a successful fetch may")
    }

    // MARK: Fetch streak

    @Test func aSuccessfulFetchClearsBothStreaks() async throws {
        let harness = Harness()
        let crashed = await harness.launchAfterCrashes(4)
        await crashed.recordFetchStarted()
        #expect(try await crashed.currentStreaks() == FeatureSafeMode.Streaks(crashes: 4, fetchFailures: 1))
        await crashed.recordFetchSucceeded(promotingActiveDocument: {})
        #expect(try await crashed.currentStreaks() == .zero)
        let next = await harness.launch(uncleanly: false)
        #expect(next.state.level == .regular)
        #expect(next.remoteValues(latest: Self.latest, lastKnownGood: Self.lastKnownGood, registry: Self.registry) == Self.latest)
    }

    @Test func fetchFailureStreaksOf25And50ActLikeCrashes() async {
        let harness = Harness()
        let first = await harness.launch(uncleanly: false)
        for _ in 0 ..< 25 { await first.recordFetchStarted() }
        #expect(await harness.launch(uncleanly: false).state.level == .lastKnownGood)
        for _ in 0 ..< 25 { await first.recordFetchStarted() }
        let safeMode = await harness.launch(uncleanly: false)
        #expect(safeMode.state.level == .noRemote)
        #expect(safeMode.state.streaks == FeatureSafeMode.Streaks(crashes: 0, fetchFailures: 50))
    }

    // MARK: Last known good

    @Test func theFirstSuccessfulFetchOfARegularLaunchPromotesItsDocumentOnce() async {
        let harness = Harness()
        let regular = await harness.launch(uncleanly: false)
        let promotions = ManagedAtomic(0)
        await regular.recordFetchSucceeded { promotions.wrappingIncrement(ordering: .relaxed) }
        await regular.recordFetchSucceeded { promotions.wrappingIncrement(ordering: .relaxed) }
        #expect(promotions.load(ordering: .relaxed) == 1)
    }

    @Test func aSafeModeLaunchNeverPromotesTheDocumentItDidNotApply() async {
        let harness = Harness()
        let safeMode = await harness.launchAfterCrashes(3)
        let promotions = ManagedAtomic(0)
        await safeMode.recordFetchSucceeded { promotions.wrappingIncrement(ordering: .relaxed) }
        #expect(promotions.load(ordering: .relaxed) == 0)
    }

    // MARK: Files

    @MainActor @Test(.timeLimit(.minutes(1))) func theStreakFileIsReadAndWrittenOffTheMainThread() async throws {
        let harness = Harness()
        let safeMode = await harness.launch(uncleanly: true)
        await safeMode.recordFetchStarted()
        await safeMode.recordFetchSucceeded(promotingActiveDocument: {})
        _ = try await safeMode.currentStreaks()
        let ran = await harness.first(4)
        #expect(ran.count == 4)
        #expect(ran.allSatisfy { $0.lane == .files && !$0.onMain }, "a safe-mode file item ran on the main thread or off the files lane")
        #expect(FileManager.default.fileExists(atPath: safeMode.file.path))
    }

    @Test func anUnreadableStreakFileReadsAsNoStreak() async throws {
        let harness = Harness()
        try FileManager.default.createDirectory(at: harness.directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: harness.directory.appending(path: "safe-mode.json"))
        let lines = LockedLines()
        let safeMode = await FeatureSafeMode.launch(directory: harness.directory, previousRunEndedUncleanly: true,
                                                    environment: [:], work: harness.work, report: { lines.append($0) })
        #expect(safeMode.state.streaks == FeatureSafeMode.Streaks(crashes: 1, fetchFailures: 0))
        #expect(lines.all.contains { $0.hasPrefix("safe-mode streaks unreadable") })
        #expect(try await safeMode.currentStreaks() == FeatureSafeMode.Streaks(crashes: 1, fetchFailures: 0))
    }

    private final class LockedLines: Sendable {
        // concurrency-allow: test sink, appended by the safe mode's caller and read after its awaits (lock carve-out: an array, no I/O under it).
        private let lines = Mutex<[String]>([])
        func append(_ line: String) { lines.withLock { $0.append(line) } }
        var all: [String] { lines.withLock { $0 } }
    }

    // MARK: Bench override

    @Test func theOverrideTurnsSafeModeOffOnlyInBenchBuilds() async {
        let harness = Harness()
        _ = await harness.launchAfterCrashes(3)
        let safeMode = await harness.launch(uncleanly: true, environment: [FeatureSafeMode.overrideVariable: "off"])
        #expect(safeMode.state.streaks.crashes == 4, "the override stopped the streak count")
        #if CMUX_BENCH_HOOKS
        #expect(FeatureSafeMode.honorsOverride)
        #expect(safeMode.state.overridden)
        #expect(safeMode.state.level == .regular)
        #expect(safeMode.state.description == "safe-mode=overridden crash-streak=4 fetch-failure-streak=0")
        #else
        // A Release (and every non-bench) build never reads the variable.
        #expect(!FeatureSafeMode.honorsOverride)
        #expect(!safeMode.state.overridden)
        #expect(safeMode.state.level == .noRemote)
        #expect(safeMode.state.description == "safe-mode=no-remote crash-streak=4 fetch-failure-streak=0")
        #endif
    }
}

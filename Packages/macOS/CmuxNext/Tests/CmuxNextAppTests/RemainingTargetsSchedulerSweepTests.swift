import AppKit
import CmuxNextActions
import CmuxNextBrowserImport
import CmuxNextCompat
@testable import CmuxNextComputerUse
@testable import CmuxNextCookieImport
import CmuxNextDesign
@testable import CmuxNextImportCards
import CmuxNextResources
import CmuxNextSettings
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// p06-scheduler-346 (rule 9): one case per migrated owner class of the remaining targets' sweep.
///
/// - The cookie consent panel's answer is one outcome the import awaits off main: a panel that goes away without an
///   answer denies, and the first answer is the only one.
/// - The Computer Use helper v2's ready line races its limit through the `Deadline` helper: a helper that never says
///   ready is given up at the limit, and a ready line answers with no wait for the limit.
/// - The Computer Use helper follows `computerUse` from the settings file's first load, one apply at a time, the
///   newest value only.
/// - The Task Manager's next sample waits on its visible `MainDeadline`, and stop() ends the sampling.
/// - The import cards follow cmux coming forward through the app's one AppEvents fan-out, not an observer of their own,
///   and a stale scan runs again when cmux comes forward.
@MainActor @Suite(.timeLimit(.minutes(1))) struct RemainingTargetsSchedulerSweepTests {
    private static func request() -> CookieImportRequest {
        CookieImportRequest(requester: CookieImportRequester(kind: .agentChat, name: "Claude"), reason: "sign in to GitHub",
                            source: "Chrome", sourceIsSafari: false, domains: ["github.com"], target: "Default")
    }

    private static func deadlines() -> MainDeadlineScheduler {
        MainDeadlineScheduler(work: MainWorkScheduler(budget: MainFrameBudget()))
    }

    @Test func aConsentPanelThatGoesAwayWithoutAnAnswerDenies() async {
        let answer = FirstOutcome<CookieImportAnswer>()
        var panel: CookieImportConsentPanel? = CookieImportConsentPanel(request: Self.request(), deadlines: Self.deadlines(),
                                                                       answer: answer, onShowRequester: nil)
        #expect(panel != nil)
        panel = nil
        #expect(await answer.value() == .deny)
    }

    @Test func theConsentPanelsFirstAnswerIsTheOnlyOne() async {
        let answer = FirstOutcome<CookieImportAnswer>()
        let panel = CookieImportConsentPanel(request: Self.request(), deadlines: Self.deadlines(), answer: answer, onShowRequester: nil)
        panel.answer(.allow)
        panel.answer(.deny)
        panel.answer(.timedOut)
        #expect(await answer.value() == .allow)
        withExtendedLifetime(panel) {}
    }

    @Test func aHelperThatNeverSaysReadyIsGivenUpAtItsLimit() async throws {
        let clock = ManualClock()
        let (lines, feed) = AsyncStream<Data>.makeStream()
        let child = ComputerUseHelperV2Child(pid: 0, input: -1, lines: lines)
        let ready = Task { await ComputerUseHelperV2.readySocket(of: child, within: .seconds(5), clock: clock) }
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(4))
        // A line that is not `ready` does not answer.
        feed.yield(Data(#"{"type":"log"}"#.utf8))
        clock.advance(by: .seconds(1))
        #expect(await ready.value == nil)
        feed.finish()
    }

    @Test func aReadyLineAnswersWithItsSocketWithoutWaitingForTheLimit() async {
        let (lines, feed) = AsyncStream<Data>.makeStream()
        let child = ComputerUseHelperV2Child(pid: 0, input: -1, lines: lines)
        feed.yield(Data(#"{"type":"ready","socket":"/tmp/h.sock"}"#.utf8))
        // The limit is an hour on a clock nobody advances: only the line can answer.
        let socket = await ComputerUseHelperV2.readySocket(of: child, within: .seconds(3600), clock: ManualClock())
        #expect(socket == "/tmp/h.sock")
        feed.finish()
    }

    @Test func theCardsFollowCmuxComingForwardThroughTheAppsOneFanOut() throws {
        let suite = "import-cards-events-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let ledger = FileManager.default.temporaryDirectory.appending(path: "import-jobs-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: ledger) }
        let events = AppEvents(center: NotificationCenter())
        let center = ImportSuggestionsCenter(defaults: defaults, ledgerURL: ledger)
        center.scanThisMac = { _ in [] }
        let host = ImportCardsHost(runImport: { _, _, _ in throw CancellationError() }, importedProfiles: { [] }, openSettings: { _ in },
                                   importClassic: { _ in nil }, appEvents: events)
        let registry = ActionRegistry(catalog: ActionCatalog.all, aliases: ActionCatalog.legacyAliases)
        center.start(host: host, registry: registry)
        center.start(host: host, registry: registry)
        #expect(events.subscriberCount(NSApplication.didBecomeActiveNotification) == 1)
        #expect(events.isObserving(NSApplication.didBecomeActiveNotification))
    }

    @Test func aStaleScanRunsAgainWhenCmuxComesForward() async throws {
        let suite = "import-cards-rescan-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let ledger = FileManager.default.temporaryDirectory.appending(path: "import-jobs-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: ledger) }
        let center = NotificationCenter()
        let clock = SweepClock()
        let scans = SweepCounter()
        let cards = ImportSuggestionsCenter(defaults: defaults, ledgerURL: ledger, now: { clock.now })
        cards.scanThisMac = { _ in
            scans.count += 1
            return []
        }
        let host = ImportCardsHost(runImport: { _, _, _ in throw CancellationError() }, importedProfiles: { [] }, openSettings: { _ in },
                                   importClassic: { _ in nil }, appEvents: AppEvents(center: center))
        cards.start(host: host, registry: ActionRegistry(catalog: ActionCatalog.all, aliases: ActionCatalog.legacyAliases))
        #expect(runMainLoop { scans.count == 1 && !cards.isScanning }, "the first scan at start")

        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        runMainLoopPass(for: 0.05)
        #expect(scans.count == 1, "a fresh scan does not run again")

        clock.now += ImportSuggestionsCenter.rescanInterval
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(runMainLoop { scans.count == 2 }, "a stale scan runs again when cmux comes forward")
    }

    @Test func theComputerUseHelperFollowsFromTheFirstLoadOneApplyAtATimeNewestOnly() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "cnc-computer-use-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "cmux-next.json")
        func write(_ driver: String) throws { try Data(#"{"computerUse":{"enabled":true,"driver":"\#(driver)"}}"#.utf8).write(to: file) }
        try write("upstream")
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: file,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        let directory = "/tmp/cmux-cua-follow-\(UUID().uuidString.prefix(8))/scope"
        defer { try? FileManager.default.removeItem(atPath: (directory as NSString).deletingLastPathComponent) }
        let spawner = SweepGatedSpawner()
        // The legacy helper's start resolves its candidates first: each legacy apply is one ask.
        let legacyStarts = SweepLockedCount()
        let daemon = ComputerUseHelperDaemon(candidates: { legacyStarts.bump(); return [] },
                                             upstream: ComputerUseHelperV2(directory: directory,
                                                                           helperApp: { URL(fileURLWithPath: "/nonexistent/cmux-cua-test.app") },
                                                                           spawner: spawner))
        defer { daemon.applicationWillTerminate() }
        // Real lanes: a legacy apply resolves its candidates on them, so `legacyStarts` counts each one.
        daemon.follow(settings, mainWork: linklessMainWork(), lanes: BackgroundWork(label: "test.cua-follow"), disabledByPolicy: { false })
        runMainLoopPass(for: 0.05)
        #expect(spawner.spawns == 0, "nothing applies before the settings file's first load")

        await settings.reload()
        #expect(runMainLoop { spawner.spawns == 1 }, "the first load applies the file's value")

        // Two values while that apply waits in its spawn: legacy, then upstream again.
        try write("legacy")
        await settings.reload()
        runMainLoopPass(for: 0.05)
        try write("upstream")
        await settings.reload()
        runMainLoopPass(for: 0.05)
        #expect(spawner.spawns == 1, "one apply at a time")

        spawner.release.yield()
        #expect(runMainLoop { spawner.spawns == 2 }, "the newest value applies after the running apply")
        runMainLoopPass(for: 0.05)
        #expect(legacyStarts.count == 0, "a value a newer one replaced while it waited never applies")
        spawner.release.yield()
    }

    @Test func theTaskManagersNextSampleWaitsOnItsVisibleDeadlineAndStopEndsIt() async {
        let rig = MainDeadlineRig()
        let source = SweepTaskManagerSource()
        let model = TaskManagerModel(source: source, deadlines: rig.deadlines, interval: .seconds(1), kill: { _ in })
        model.start()
        #expect(runMainLoop { model.sampleCount == 1 }, "start takes the first sample")
        #expect(rig.hasArmedWake, "the next sample waits on its deadline")
        runMainLoopPass(for: 0.05)
        #expect(model.sampleCount == 1, "no second sample before its deadline")

        rig.fireAndRun()
        #expect(runMainLoop { model.sampleCount == 2 }, "the deadline takes the next sample")

        model.stop()
        rig.fireAndRun()
        runMainLoopPass(for: 0.05)
        #expect(model.sampleCount == 2, "no sample after stop()")
        #expect(source.samples == 2)
    }
}

/// A count the test's main-actor closures raise.
@MainActor final class SweepCounter {
    var count = 0
}

/// The import cards' clock, moved by the test.
@MainActor final class SweepClock {
    var now = Date(timeIntervalSince1970: 1_000_000)
}

/// A count any thread raises (the helper's candidates are read off main).
nonisolated final class SweepLockedCount: Sendable {
    private let value = Mutex(0)

    func bump() { value.withLock { $0 += 1 } }

    var count: Int { value.withLock { $0 } }
}

/// A Task Manager source that counts its samples.
final class SweepTaskManagerSource: TaskManagerSampleSource {
    private(set) var samples = 0

    func sample() async -> TaskManagerSampleSet {
        samples += 1
        return TaskManagerSampleSet()
    }
}

/// A helper v2 spawner whose every spawn waits for the test's release, then fails; it counts the spawns.
nonisolated final class SweepGatedSpawner: ComputerUseHelperV2Spawning {
    struct Refused: Error {}

    /// Ends one waiting spawn.
    let release: AsyncStream<Void>.Continuation
    private let releases: AsyncStream<Void>
    private let started = Mutex(0)

    init() {
        (releases, release) = AsyncStream.makeStream()
    }

    /// Spawns started so far.
    var spawns: Int { started.withLock { $0 } }

    func spawn(executable: URL, environment: [String: String], logPath: String) async throws -> ComputerUseHelperV2Child {
        started.withLock { $0 += 1 }
        for await _ in releases { break }
        throw Refused()
    }

    func terminate(_ pid: pid_t) {}
}

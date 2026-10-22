import AppKit
import CmuxNextCompat
import CmuxNextErrorJournal
import CmuxNextHomeEngine
import Foundation

/// Owns this build's ``ErrorJournal`` and the places it harvests: the app's own unified log
/// (page console errors included), the Chief's acpmux `daemon.log`, `host.log` and
/// `client.log`, the app's own acpmux log, and cmux crash reports.
///
/// It harvests only when something asks: before every `errors.list` (``ErrorJournalControl``),
/// and when the person leaves the app (resign active), at most once per ``harvestSpacing``.
/// Never on a timer and never at launch: an app left alone reads no log (reading the unified log
/// wakes OSLogService, which cost 2.6 % CPU in a 60 s idle window on cmux20,
/// plans/cmux-next/speed-of-sound-DESIGN.md).
///
/// The journal lives in `~/Library/Application Support/<bundle id>/errors`, one per build.
@MainActor
final class ErrorJournalService {
    let journal: ErrorJournal
    let sources: [any ErrorHarvestSource]
    private let clock: any Clock<Duration>
    private var harvesting: Task<Void, Never>?
    private var sinceLastHarvest: (() -> Duration)?
    private var resignObserver: (any NSObjectProtocol)?

    /// A harvest that leaving the app started is still running.
    var isHarvesting: Bool { harvesting != nil }

    /// The least time between two harvests that leaving the app starts.
    static let harvestSpacing: Duration = .seconds(300)

    init(journal: ErrorJournal, sources: [any ErrorHarvestSource], clock: any Clock<Duration> = ContinuousClock()) {
        self.journal = journal
        self.sources = sources
        self.clock = clock
    }

    /// The journal folder of a build.
    static func directory(bundleID: String) -> URL {
        let support = FileManager().urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager().homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent(bundleID, isDirectory: true).appendingPathComponent("errors", isDirectory: true)
    }

    /// The service for this launch: its own journal folder and every log it can see.
    static func make(environment: AppEnvironment) -> ErrorJournalService {
        let chief = ChiefHome.resolve(tag: environment.tag)
        // A Chief on the app's own acpmux has no daemon log of its own: the app's below is its.
        let chiefAcpmuxLog = chief.usesAppAcpmux ? nil : chief.acpmuxHome.appendingPathComponent("daemon.log")
        var sources: [any ErrorHarvestSource] = [
            OSLogErrorSource(),
            LogFileErrorSource(url: chief.root.appendingPathComponent("host.log"), source: "chief"),
            LogFileErrorSource(url: chief.root.appendingPathComponent("client.log"), source: "chief"),
            CrashReportErrorSource(),
        ]
        if let chiefAcpmuxLog { sources.insert(LogFileErrorSource(url: chiefAcpmuxLog, source: "acpmux"), at: 1) }
        // The app's own acpmux, in this build's home (BuildIdentity: NIGHTLY's ~/.acpmux, any other build's
        // ~/.acpmux/builds/<key>, as AcpmuxEnvironment starts it), when it is not the Chief's.
        let appAcpmux = environment.build.acpmuxHome(userHome: FileManager().homeDirectoryForCurrentUser).appendingPathComponent("daemon.log")
        if appAcpmux.standardizedFileURL != chiefAcpmuxLog?.standardizedFileURL {
            sources.append(LogFileErrorSource(url: appAcpmux, source: "acpmux-app"))
        }
        return ErrorJournalService(journal: ErrorJournal(directory: directory(bundleID: environment.launch.bundleID ?? Bundle.main.bundleIdentifier ?? "com.cmuxterm.app")),
                                   sources: sources)
    }

    /// Harvests each time the person leaves the app (at most once per ``harvestSpacing``).
    func start() {
        guard resignObserver == nil else { return }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // main-proof: observer registered with queue: .main
            MainActor.assumeIsolated { _ = self?.appDidResignActive() }
        }
    }

    /// The person left the app: harvest now unless one ran within ``harvestSpacing`` or is running.
    /// Returns the harvest it started; it ends after the harvest is written and cleared (tests await it).
    @discardableResult
    func appDidResignActive() -> Task<Void, Never>? {
        guard harvesting == nil else { return nil }
        if let since = sinceLastHarvest, since() < Self.harvestSpacing { return nil }
        sinceLastHarvest = Self.stopwatch(clock)
        let journal = journal
        let sources = sources
        // A detached utility task: reading the logs never runs on the main thread.
        // concurrency-allow: one harvest per leave of the app, off the main thread
        let task = Task.detached(priority: .utility) { _ = await journal.harvest(sources) }
        let running = Task { [weak self] in
            await task.value
            self?.harvesting = nil
        }
        harvesting = running
        return running
    }

    private static func stopwatch<C: Clock>(_ clock: C) -> () -> Duration where C.Duration == Duration {
        let start = clock.now
        return { start.duration(to: clock.now) }
    }

    /// Stops harvesting and writes what is pending.
    func stop() async {
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        await harvesting?.value
        await journal.flush()
    }
}

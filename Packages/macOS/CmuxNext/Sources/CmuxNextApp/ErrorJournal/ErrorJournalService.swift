import CmuxNextCompat
import CmuxNextErrorJournal
import CmuxNextFiles
import CmuxNextHomeEngine
import CmuxNextWakeups
import Foundation

/// Owns this build's ``ErrorJournal`` and the places it harvests: the app's own unified log
/// (page console errors included), the Chief's acpmux `daemon.log`, `host.log` and
/// `client.log`, the app's own acpmux log, and cmux crash reports. Harvests once at ``start()``,
/// then on the system's background activity scheduler when a watched log changed, and before
/// every `errors.list`.
///
/// The journal lives in `~/Library/Application Support/<bundle id>/errors`, one per build.
@MainActor
final class ErrorJournalService {
    /// One watched folder and the names of the items in it that matter; nil names: any item.
    nonisolated struct Watch: Sendable, Equatable {
        let folder: URL
        let names: Set<String>?

        /// Whether `change` touches an item that matters.
        func matters(_ change: FolderChange) -> Bool {
            guard case .items(let items) = change, let names else { return true }
            return !names.isDisjoint(with: items)
        }
    }

    let journal: ErrorJournal
    let sources: [any ErrorHarvestSource]
    /// The folders whose changes make the next scheduled run harvest.
    let watched: [Watch]
    /// The app's Energy Saver policy: its poll stretch multiplies the cadence, and its pause holds it.
    private let energy: EnergyPolicySource
    private let activities: any BackgroundActivityScheduling
    private let folders: any FolderWatching
    private let activityID: String
    private var harvester: Harvester?
    private var activity: (any BackgroundActivityRun)?
    /// The poll stretch ``activity`` was scheduled with; nil while no activity is scheduled.
    private var scheduledStretch: Int?
    private var energyObservation: MainActorEnergyObservation?
    /// The harvest that ``start()`` runs at once.
    private(set) var launchHarvest: Task<Void, Never>?
    /// One task for each of ``watched``, iterating that folder's changes off the main thread.
    private(set) var watches: [Task<Void, Never>] = []

    /// The time between two scheduled runs (times the saver's ``EnergyPolicy/pollStretch``).
    nonisolated static let harvestInterval: Duration = .seconds(300)
    /// How far the system can move a run from its due time (times the saver's stretch).
    nonisolated static let harvestTolerance: Duration = .seconds(120)
    /// The FSEvents latency of the folder watches, ``harvestInterval``: however often a folder's logs are
    /// written, its watch wakes at most once in each interval, and the first change after a quiet interval
    /// comes at once (`kFSEventStreamCreateFlagNoDefer`).
    nonisolated static let watchLatency: CFTimeInterval = 300
    /// The ``WakeupLedger`` owner of each run (idle-budget.json `allowed_periodic`).
    nonisolated static let owner = "ErrorJournalService.harvest"

    init(journal: ErrorJournal, sources: [any ErrorHarvestSource], watched: [Watch], energy: EnergyPolicySource,
         activities: any BackgroundActivityScheduling = SystemBackgroundActivityScheduler(),
         folders: any FolderWatching = FolderWatcher(latency: ErrorJournalService.watchLatency),
         activityID: String = "com.cmuxterm.app.error-journal.harvest") {
        self.journal = journal
        self.sources = sources
        self.watched = watched
        self.energy = energy
        self.activities = activities
        self.folders = folders
        self.activityID = activityID
    }

    /// The journal folder of a build.
    static func directory(bundleID: String) -> URL {
        let support = FileManager().urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager().homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent(bundleID, isDirectory: true).appendingPathComponent("errors", isDirectory: true)
    }

    /// The service for this launch: its own journal folder and every log it can see.
    static func make(environment: AppEnvironment, energy: EnergyPolicySource) -> ErrorJournalService {
        let chief = ChiefHome.resolve(tag: environment.tag)
        // A Chief on the app's own acpmux has no daemon log of its own: the app's below is its.
        let chiefAcpmuxLog = chief.usesAppAcpmux ? nil : chief.acpmuxHome.appendingPathComponent("daemon.log")
        let crashReports = CrashReportErrorSource()
        var logs = [
            LogFileErrorSource(url: chief.root.appendingPathComponent("host.log"), source: "chief"),
            LogFileErrorSource(url: chief.root.appendingPathComponent("client.log"), source: "chief"),
        ]
        if let chiefAcpmuxLog { logs.insert(LogFileErrorSource(url: chiefAcpmuxLog, source: "acpmux"), at: 0) }
        // The app's own acpmux, in this build's home (BuildIdentity: NIGHTLY's ~/.acpmux, any other build's
        // ~/.acpmux/builds/<key>, as AcpmuxEnvironment starts it), when it is not the Chief's.
        let appAcpmux = environment.build.acpmuxHome(userHome: FileManager().homeDirectoryForCurrentUser).appendingPathComponent("daemon.log")
        if appAcpmux.standardizedFileURL != chiefAcpmuxLog?.standardizedFileURL {
            logs.append(LogFileErrorSource(url: appAcpmux, source: "acpmux-app"))
        }
        var sources: [any ErrorHarvestSource] = [OSLogErrorSource()]
        sources.append(contentsOf: logs.map { $0 as any ErrorHarvestSource })
        sources.append(crashReports)
        let bundleID = environment.launch.bundleID ?? Bundle.main.bundleIdentifier ?? "com.cmuxterm.app"
        return ErrorJournalService(journal: ErrorJournal(directory: directory(bundleID: bundleID)), sources: sources,
                                   watched: folderWatches(logs: logs.map(\.url), reports: crashReports.directory), energy: energy,
                                   activityID: "\(bundleID).error-journal.harvest")
    }

    /// One watch for each folder of `logs` (their names in it), and one for the crash `reports` folder (any item).
    nonisolated static func folderWatches(logs: [URL], reports: URL) -> [Watch] {
        var names: [URL: Set<String>] = [:]
        for log in logs { names[log.deletingLastPathComponent().standardizedFileURL, default: []].insert(log.lastPathComponent) }
        let folders = names.sorted { $0.key.path < $1.key.path }.map { Watch(folder: $0.key, names: $0.value) }
        return folders + [Watch(folder: reports.standardizedFileURL, names: nil)]
    }

    /// Harvests at once, then lets the system's background activity scheduler harvest about every
    /// ``harvestInterval`` (within ``harvestTolerance``, both times the saver's stretch) while Energy
    /// Saver does not pause keepalives and polls.
    ///
    /// Nothing of it runs on the main thread: the scheduler runs each harvest on its own background
    /// queue (``BackgroundActivity``), and a run reads the sources only when a watched folder changed
    /// since the last harvest began (FSEvents, ``watchLatency``); otherwise it ends at once. One
    /// harvest runs at a time. The main actor only follows the energy policy: a change of stretch or
    /// pause invalidates the activity and schedules a new one. The unified log has no change signal:
    /// its entries come in with the next harvest a log change starts, or with `errors.list`.
    func start() {
        guard harvester == nil else { return }
        let harvester = Harvester()
        self.harvester = harvester
        watches = watched.map { Self.watch($0, on: folders, marking: harvester) }
        energyObservation = MainActorEnergyObservation(energy) { [weak self] policy in self?.follow(policy) }
        follow(energy.policy)
        launchHarvest = Self.harvestNow(journal, sources, on: harvester)
    }

    /// Stops harvesting and writes what is pending. A harvest that has started finishes.
    func stop() async {
        activity?.invalidate()
        activity = nil
        scheduledStretch = nil
        energyObservation?.cancel()
        energyObservation = nil
        for watch in watches { watch.cancel() }
        watches = []
        harvester = nil
        await journal.flush()
    }

    /// Schedules the activity for `policy`'s stretch, or none while it pauses keepalives and polls.
    private func follow(_ policy: EnergyPolicy) {
        let stretch = policy.pausesKeepalives ? nil : policy.pollStretch
        guard let harvester, stretch != scheduledStretch else { return }
        activity?.invalidate()
        activity = nil
        scheduledStretch = stretch
        guard let stretch else { return }
        let journal = journal, sources = sources
        let spec = BackgroundActivity(identifier: activityID, owner: Self.owner, interval: Self.harvestInterval * stretch,
                                      tolerance: Self.harvestTolerance * stretch)
        activity = activities.schedule(spec) { await harvester.harvest(journal, sources) }
    }

    /// A task off the main thread that marks `harvester` changed after each change of an item of `watch`
    /// that matters, until it is cancelled or the changes end.
    private nonisolated static func watch(_ watch: Watch, on folders: any FolderWatching,
                                          marking harvester: Harvester) -> Task<Void, Never> {
        // task-owner: the watch of one folder; stop() cancels it
        Task(priority: .utility) {
            for await change in folders.changes(in: watch.folder) where watch.matters(change) {
                harvester.changed.store(true, ordering: .releasing)
            }
        }
    }

    /// The harvest of ``start()``, in a task off the main thread.
    private nonisolated static func harvestNow(_ journal: ErrorJournal, _ sources: [any ErrorHarvestSource],
                                               on harvester: Harvester) -> Task<Void, Never> {
        // task-owner: one harvest; ErrorJournalServiceTests await it, nothing cancels it
        Task(priority: .utility) { await harvester.harvest(journal, sources) }
    }
}

/// Whether a watched folder changed since the last harvest began (true at first), and whether one runs.
private nonisolated final class Harvester: Sendable {
    let changed = Atomic<Bool>(true)
    private let running = Atomic<Bool>(false)

    /// Reads `sources` into `journal` off the main thread when a watched folder changed and no harvest runs.
    @concurrent func harvest(_ journal: ErrorJournal, _ sources: [any ErrorHarvestSource]) async {
        guard changed.load(ordering: .acquiring), !running.exchange(true, ordering: .acquiring) else { return }
        changed.store(false, ordering: .relaxed)
        await journal.harvest(sources)
        running.store(false, ordering: .releasing)
    }
}

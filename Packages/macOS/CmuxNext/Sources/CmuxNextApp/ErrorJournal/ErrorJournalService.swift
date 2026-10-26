import CmuxNextCompat
import CmuxNextErrorJournal
import CmuxNextHomeEngine
import CmuxNextWakeups
import Foundation

/// Owns this build's ``ErrorJournal`` and the places it harvests: the app's own unified log
/// (page console errors included), the Chief's acpmux `daemon.log`, `host.log` and
/// `client.log`, the app's own acpmux log, and cmux crash reports. Harvests every
/// ``harvestInterval`` and before every `errors.list`.
///
/// The journal lives in `~/Library/Application Support/<bundle id>/errors`, one per build.
@MainActor
final class ErrorJournalService {
    let journal: ErrorJournal
    let sources: [any ErrorHarvestSource]
    /// The harvest in flight, off the main thread, and its number.
    private var harvesting: Task<Void, Never>?
    private var harvests = 0
    /// The repeating harvest: one flexible entry of the main thread's wake-up queue every ``harvestInterval``
    /// (Chromium's `RepeatingTimer` on a background task runner), owner `ErrorJournalService.harvest` of
    /// idle-budget.json `allowed_periodic`.
    private let cadence: MainDeadline

    /// How often the journal reads its sources while the app runs.
    static let harvestInterval: Duration = .seconds(300)

    init(journal: ErrorJournal, sources: [any ErrorHarvestSource], deadlines: MainDeadlineScheduler) {
        self.journal = journal
        self.sources = sources
        cadence = MainDeadline(owner: "ErrorJournalService.harvest", workClass: .background, scheduler: deadlines)
    }

    /// The journal folder of a build.
    static func directory(bundleID: String) -> URL {
        let support = FileManager().urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager().homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent(bundleID, isDirectory: true).appendingPathComponent("errors", isDirectory: true)
    }

    /// The service for this launch: its own journal folder and every log it can see.
    static func make(environment: AppEnvironment, deadlines: MainDeadlineScheduler) -> ErrorJournalService {
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
                                   sources: sources, deadlines: deadlines)
    }

    /// Starts the periodic harvest; the first one runs at once.
    func start() {
        guard !cadence.isScheduled else { return }
        harvest()
        cadence.start(every: Self.harvestInterval) { [weak self] in self?.harvest() }
    }

    /// The next periodic harvest's wake (nil while stopped).
    var nextHarvest: TimerAlignment.Wake? { cadence.plannedWake }

    /// Stops harvesting and writes what is pending.
    func stop() async {
        cadence.cancel()
        harvesting?.cancel()
        harvesting = nil
        await journal.flush()
    }

    /// One harvest off the main thread, unless the last one still runs (the journal is an actor: a second
    /// would only queue behind it).
    private func harvest() {
        guard harvesting == nil else { return }
        harvests += 1
        let journal = journal, sources = sources, number = harvests
        // task-owner: one harvest of the journal's sources; stop() cancels it
        harvesting = Task.detached(priority: .utility) { [weak self] in
            _ = await journal.harvest(sources)
            await self?.harvestEnded(number)
        }
    }

    private func harvestEnded(_ number: Int) {
        if number == harvests { harvesting = nil }
    }
}

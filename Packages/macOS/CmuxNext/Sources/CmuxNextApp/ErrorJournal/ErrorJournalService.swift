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
    /// The harvest that runs now, if any.
    private var harvesting: Task<Void, Never>?
    /// The next harvest, ``harvestInterval`` after the last one ended.
    private let nextHarvest = DemandTimer(owner: "error-journal.harvest")
    private var running = false
    /// Bumped by start() and stop(): a harvest or deadline of an earlier run does nothing.
    private var generation: UInt64 = 0

    /// How often the journal reads its sources while the app runs.
    static let harvestInterval: Duration = .seconds(300)

    init(journal: ErrorJournal, sources: [any ErrorHarvestSource]) {
        self.journal = journal
        self.sources = sources
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
        let home = FileManager().homeDirectoryForCurrentUser
        var sources: [any ErrorHarvestSource] = [
            OSLogErrorSource(),
            LogFileErrorSource(url: chief.acpmuxHome.appendingPathComponent("daemon.log"), source: "acpmux"),
            LogFileErrorSource(url: chief.root.appendingPathComponent("host.log"), source: "chief"),
            LogFileErrorSource(url: chief.root.appendingPathComponent("client.log"), source: "chief"),
            CrashReportErrorSource(),
        ]
        // The app's own acpmux (Release and NIGHTLY share ~/.acpmux) when it is not the Chief's.
        let appAcpmux = home.appendingPathComponent(".acpmux/daemon.log")
        if appAcpmux.standardizedFileURL != chief.acpmuxHome.appendingPathComponent("daemon.log").standardizedFileURL {
            sources.append(LogFileErrorSource(url: appAcpmux, source: "acpmux-app"))
        }
        return ErrorJournalService(journal: ErrorJournal(directory: directory(bundleID: environment.launch.bundleID ?? Bundle.main.bundleIdentifier ?? "com.cmuxterm.app")),
                                   sources: sources)
    }

    /// Starts the periodic harvest; the first one runs at once.
    func start() {
        guard !running else { return }
        running = true
        generation &+= 1
        harvest(generation)
    }

    /// Stops harvesting and writes what is pending.
    func stop() async {
        running = false
        generation &+= 1
        nextHarvest.cancel()
        harvesting?.cancel()
        harvesting = nil
        await journal.flush()
    }

    /// Runs one harvest off the main actor; when it ends, the next one is due after ``harvestInterval``.
    private func harvest(_ run: UInt64) {
        guard running, run == generation else { return }
        let journal = journal
        let sources = sources
        harvesting = Task.detached(priority: .utility) { [weak self] in
            await journal.harvest(sources)
            guard !Task.isCancelled else { return }
            await self?.harvestEnded(run)
        }
    }

    private func harvestEnded(_ run: UInt64) {
        guard running, run == generation else { return }
        harvesting = nil
        nextHarvest.schedule(after: Self.harvestInterval) { [weak self] in
            await self?.harvest(run)
        }
    }
}

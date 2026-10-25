import CmuxNextCompat
import CmuxNextErrorJournal
import CmuxNextHomeEngine
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
    private var harvesting: Task<Void, Never>?

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

    /// Starts the periodic harvest; the first one runs at once.
    func start() {
        guard harvesting == nil else { return }
        let journal = journal
        let sources = sources
        let interval = Self.harvestInterval
        // A fixed-interval background harvest, cancelled by stop() (CLAUDE.md Clock.sleep carve-out:
        // the delay is the intended cadence; nothing waits on it).
        harvesting = Task.detached(priority: .utility) {
            // concurrency-allow: a detached utility task, never the main thread; each pass awaits a harvest, then the cancellable cadence sleep
            // wakeup-allow: one harvest every 300 s (harvestInterval) while the app runs, ended by stop()
            while !Task.isCancelled {
                await journal.harvest(sources)
                // concurrency-allow: async cadence sleep on the detached harvest task; cancelled by stop(), blocks no thread
                // wakeup-allow: the 300 s harvest cadence; nothing waits on it
                guard (try? await ContinuousClock().sleep(for: interval)) != nil else { return }
            }
        }
    }

    /// Stops harvesting and writes what is pending.
    func stop() async {
        harvesting?.cancel()
        harvesting = nil
        await journal.flush()
    }
}

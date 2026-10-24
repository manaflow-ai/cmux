import CmuxNextCompat
import CmuxNextErrorJournal
import CmuxNextHomeEngine
import Foundation

/// Owns this build's ``ErrorJournal`` and the places it harvests: the app's own unified log, the
/// Chief's acpmux `daemon.log`, `host.log` and `client.log`, the app's own acpmux log, and cmux
/// crash reports. Errors reported through an ``ErrorReporter`` (cmux's own) and page console
/// errors (``ConsoleErrorCapture``) are not harvested: they are recorded when they happen, so a
/// crash keeps them (a fault at once, an error after the journal's batch delay).
///
/// It harvests at launch (crash reports and log lines written while the app was not running),
/// at quit (``stop()``: what frameworks and the cmux sites still on `Logger` logged in this run,
/// which no later launch can read) and before every `errors.list`. Never on a timer: an idle app
/// wakes for nothing (plans/cmux-next/idle-wakeups.md). The quit's harvest is best effort: the
/// quit cancels it once the engines stopped, and it keeps and writes what it read by then.
///
/// The journal lives in `~/Library/Application Support/<bundle id>/errors`, one per build.
@MainActor
final class ErrorJournalService {
    let journal: ErrorJournal
    let sources: [any ErrorHarvestSource]
    /// The launch harvest, while it runs; the quit's harvest waits for it.
    private var launchHarvest: Task<Void, Never>?
    private var started = false

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

    /// The launch harvest, once, off the main actor (the journal's actor reads the sources).
    func start() {
        guard !started else { return }
        started = true
        let journal = journal
        let sources = sources
        // task-owner: the one launch harvest; stop() waits for it before the quit's harvest
        launchHarvest = Task.detached(priority: .utility) {
            _ = await journal.harvest(sources)
        }
    }

    /// The quit's harvest: waits for the launch harvest if it still runs, reads every source once
    /// more and writes what is pending (`QuitSteps.harvestErrors`). Cancelling it (the quit does,
    /// once the engines stopped) cancels the launch harvest too; each keeps and writes what it
    /// read, and the journal's pending records are written either way.
    func stop() async {
        if let launch = launchHarvest {
            await withTaskCancellationHandler {
                await launch.value
            } onCancel: {
                launch.cancel()
            }
        }
        launchHarvest = nil
        _ = await journal.harvest(sources)
    }
}

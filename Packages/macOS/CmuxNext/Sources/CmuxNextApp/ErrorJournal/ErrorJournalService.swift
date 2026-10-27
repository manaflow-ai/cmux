import CmuxNextCompat
import CmuxNextErrorJournal
import CmuxNextHomeEngine
import CmuxNextWakeups
import Foundation

/// Owns this build's ``ErrorJournal`` and the places it harvests: the app's own unified log
/// (page console errors included), the Chief's acpmux `daemon.log`, `host.log` and
/// `client.log`, the app's own acpmux log, and cmux crash reports. Harvests every
/// ``harvestInterval`` (times the Energy Saver's ``EnergyPolicy/pollStretch``) and before every
/// `errors.list`.
///
/// The journal lives in `~/Library/Application Support/<bundle id>/errors`, one per build.
@MainActor
final class ErrorJournalService {
    let journal: ErrorJournal
    let sources: [any ErrorHarvestSource]
    /// The clock the periodic harvest sleeps on; tests pass a `ManualClock`.
    private let clock: any Clock<Duration>
    private let ledger: WakeupLedger
    /// The app's Energy Saver policy, read at each booking.
    private let energy: EnergyPolicySource
    /// The cadence between ``start()`` and ``stop()``.
    private var cadence: HarvestCadence?

    /// How often the journal reads its sources while the app runs.
    nonisolated static let harvestInterval: Duration = .seconds(300)

    init(journal: ErrorJournal, sources: [any ErrorHarvestSource], energy: EnergyPolicySource,
         clock: any Clock<Duration> = ContinuousClock(), ledger: WakeupLedger = .shared) {
        self.journal = journal
        self.sources = sources
        self.energy = energy
        self.clock = clock
        self.ledger = ledger
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
                                   sources: sources, energy: energy)
    }

    /// Starts the periodic harvest; the first one runs at once.
    ///
    /// The cadence never wakes the main thread, as Chromium's `RepeatingTimer` on a ThreadPool sequenced task runner
    /// (base/timer/timer.h): each harvest runs off main, then a ``DemandTimer`` with no main wake-up queue sleeps
    /// ``harvestInterval`` (times the saver's stretch) on its clock, with ``WakeLeeway``'s tolerance, and starts the
    /// next. The next one is planned only when one ends, so two never overlap. Owner `ErrorJournalService.harvest` of
    /// idle-budget.json `allowed_periodic`.
    func start() {
        guard cadence == nil else { return }
        // timer-class-allow: off-main: each fire starts the next harvest on the cooperative pool and never wakes the main thread
        let cadence = HarvestCadence(timer: DemandTimer(owner: "ErrorJournalService.harvest", clock: clock, ledger: ledger), energy: energy)
        self.cadence = cadence
        let journal = journal, sources = sources
        // task-owner: the first harvest of this start; the next ones start from the cadence's timer, stop() ends them
        Task.detached(priority: .utility) { await Self.harvest(journal, sources, cadence: cadence) }
    }

    /// Stops harvesting and writes what is pending. A harvest in flight ends and plans no next one.
    func stop() async {
        cadence?.stopped.store(true, ordering: .relaxed)
        cadence?.timer.cancel()
        cadence = nil
        await journal.flush()
    }

    /// One harvest off the main thread, then the next one ``harvestInterval`` times the saver's stretch
    /// later unless ``stop()`` came.
    @concurrent private nonisolated static func harvest(_ journal: ErrorJournal, _ sources: [any ErrorHarvestSource],
                                                        cadence: HarvestCadence) async {
        guard !cadence.stopped.load(ordering: .relaxed) else { return }
        _ = await journal.harvest(sources)
        guard !cadence.stopped.load(ordering: .relaxed) else { return }
        cadence.timer.schedule(after: harvestInterval * cadence.energy.policy.pollStretch) { await harvest(journal, sources, cadence: cadence) }
    }
}

/// One start's cadence: its timer, the policy that stretches it, and whether ``ErrorJournalService/stop()``
/// ended it.
private nonisolated final class HarvestCadence: Sendable {
    let timer: DemandTimer
    let energy: EnergyPolicySource
    let stopped = Atomic<Bool>(false)

    init(timer: DemandTimer, energy: EnergyPolicySource) {
        self.timer = timer
        self.energy = energy
    }
}

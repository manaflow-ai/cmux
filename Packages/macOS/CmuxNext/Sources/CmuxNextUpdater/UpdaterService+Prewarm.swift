import CmuxNextWakeups
import Foundation

/// The staged build's pre-warm (``StagedUpdatePrewarm``): started once per build, when the update is
/// staged, and waited for by the install click for at most ``UpdaterService/prewarmInstallWait``.
struct StagedPrewarmRun {
    let build: String
    let started: ContinuousClock.Instant
    let urgency: StagedUpdatePrewarm.Urgency
    /// The pre-warm's log line once it ended; nil while it runs.
    var line: String?
}

/// An install click that waits for the pre-warm (``UpdaterService/installAfterPrewarm(_:)``).
struct PrewarmWaitingInstall {
    let build: String
    let clicked: ContinuousClock.Instant
    let install: @MainActor () -> Void
}

extension UpdaterService {
    /// How long an install click waits for a pre-warm still running before the install goes on
    /// without it: the pre-warm saves the update's first launch about 2.7 s (#43890), and a person
    /// who clicks Restart to Update seconds after the update staged (Leo's NIGHTLY: 3 s) finds most
    /// of it done already.
    static let prewarmInstallBound: Duration = .seconds(3)

    /// The staged build whose first launch was pre-warmed or is being pre-warmed.
    var prewarmedBuild: String? { prewarmRun?.build }

    /// Pre-warms the staged build's first launch once per build (``StagedUpdatePrewarm``), as soon as
    /// it is staged (`trigger` says what started it, for the log). Only a build newer than the running
    /// one: it knows ``StagedUpdatePrewarm/argument`` because the running build does, so an older
    /// staged build (a switch back) never gets an argument it would not stop on. Returns why nothing
    /// was started, or nil when a pre-warm of the staged build runs or ran.
    ///
    /// Every outcome goes to the update log at once: `launch pre-warm of <build>: started (<trigger>)`, then a
    /// line after the scan and after each run, or `launch pre-warm: skipped (<why>)` once per build
    /// and reason. A pre-warm that never ran can no longer be silent (Leo's NIGHTLY had no line at all).
    @discardableResult
    func prewarmStagedUpdate(trigger: String = "staged") -> String? {
        guard let build = stagedBuild(), !build.isEmpty else { return skipPrewarm(of: nil, "no staged build") }
        if prewarmRun?.build == build { return nil }
        guard let bundleIdentifier = identity.bundleIdentifier else { return skipPrewarm(of: build, "no bundle id") }
        guard AppcastSelector.isOlder(identity.build, than: build) else {
            return skipPrewarm(of: build, "staged build \(build) is not newer than running build \(identity.build)")
        }
        let urgency = StagedUpdatePrewarm.Urgency()
        prewarmRun = StagedPrewarmRun(build: build, started: ContinuousClock.now, urgency: urgency)
        log.append("launch pre-warm of \(build): started (\(trigger))")
        let prewarm = StagedUpdatePrewarm(installations: UpdateInstallPreflight.stagedInstallations(bundleIdentifier: bundleIdentifier),
                                          bundleIdentifier: bundleIdentifier, build: build)
        let runner = prewarmRunner, log = log, work = work
        let marker = prewarmMarker(bundleIdentifier: bundleIdentifier)
        // task-owner: one pre-warm per staged build; ends after its last process (each stopped at its timeout).
        // Best effort until an install click waits for it (``installAfterPrewarm(_:)`` raises `urgency`); its folder
        // scan runs on a files lane slot of its own
        // (``StagedUpdatePrewarm/perform(work:processes:timeout:total:clock:marker:urgency:progress:)``), its processes through AsyncProcess.
        Task.detached(priority: WorkPriority.bestEffort.taskPriority) { [weak self] in
            let line: String
            if let runner { line = await runner(prewarm) } else { line = await prewarm.perform(work: work, marker: marker, urgency: urgency, progress: { log.append($0) }) }
            log.append(line)
            await self?.prewarmEnded(urgency, line: line)
        }
        return nil
    }

    /// Restart to Update, after the click's feed read: waits for the staged build's pre-warm, at most
    /// ``prewarmInstallWait``, then runs `install`. A pre-warm that never started (the update staged in
    /// the same turn as the click, say) starts now. Logs one `launch pre-warm before install:` line:
    /// done, partial (still running at the bound) or skipped (and why). A second click while it waits
    /// adds nothing.
    func installAfterPrewarm(_ install: @escaping @MainActor () -> Void) {
        guard prewarmWaitingInstall == nil else { return }
        if let skipped = prewarmStagedUpdate(trigger: "install") {
            log.append("launch pre-warm before install: skipped (\(skipped))")
            return install()
        }
        guard let run = prewarmRun else { return install() }
        if run.line != nil {
            log.append("launch pre-warm before install: done \(StagedUpdatePrewarm.milliseconds(ContinuousClock.now - run.started)) ms after it started: before the click, no wait")
            return install()
        }
        run.urgency.raise()
        // The bound counts from the click, not from the end of the click's feed read: the two waits
        // never add up (they took up to 6 s in all, ask-ad4a68e740).
        let clicked = installClickedAt ?? ContinuousClock.now
        let left = prewarmInstallWait - (ContinuousClock.now - clicked)
        guard left > .zero else {
            log.append("launch pre-warm before install: partial, still running \(StagedUpdatePrewarm.milliseconds(ContinuousClock.now - clicked)) ms after the click; installing")
            return install()
        }
        prewarmWaitingInstall = PrewarmWaitingInstall(build: run.build, clicked: clicked, install: install)
        #if DEBUG || CMUX_BENCH_HOOKS
        UpdateHarness.mark("prewarm_wait_start")
        #endif
        prewarmWaitTimer.schedule(after: left) { @MainActor [weak self] in self?.settlePrewarmWait(done: false) }
    }

    /// The pre-warm `run` (its ``StagedPrewarmRun/urgency``) ended with `line`; an install waiting for it goes on.
    /// A pre-warm replaced since (another staged build) changes nothing.
    func prewarmEnded(_ run: StagedUpdatePrewarm.Urgency, line: String) {
        guard let current = prewarmRun, current.urgency === run else { return }
        prewarmRun?.line = line
        if prewarmWaitingInstall?.build == current.build { settlePrewarmWait(done: true) }
    }

    /// Ends the install click's wait: the pre-warm ended (`done`) or the bound passed.
    private func settlePrewarmWait(done: Bool) {
        guard let waiting = prewarmWaitingInstall else { return }
        prewarmWaitingInstall = nil
        prewarmWaitTimer.cancel()
        let waited = StagedUpdatePrewarm.milliseconds(ContinuousClock.now - waiting.clicked)
        log.append(done
            ? "launch pre-warm before install: done, the install waited \(waited) ms"
            : "launch pre-warm before install: partial, still running after \(waited) ms; installing")
        #if DEBUG || CMUX_BENCH_HOOKS
        UpdateHarness.mark(done ? "prewarm_wait_end.done" : "prewarm_wait_end.partial")
        #endif
        waiting.install()
    }

    /// Logs why the staged build's pre-warm did not start, once per build and reason, and leaves it in the build's
    /// marker, so its first launch records why it was not pre-warmed (`skipped:<why>` in `cmux app launch-times`).
    private func skipPrewarm(of build: String?, _ reason: String) -> String {
        let key = "\(build ?? "")|\(reason)"
        guard prewarmSkipLogged != key else { return reason }
        prewarmSkipLogged = key
        log.append("launch pre-warm: skipped (\(reason))")
        // Never the running build: its next launch is a relaunch, which reads `no_record`.
        guard let build, !build.isEmpty, build != identity.build, let bundleIdentifier = identity.bundleIdentifier,
              let marker = prewarmMarker(bundleIdentifier: bundleIdentifier) else { return reason }
        work.post(.userVisible, mayBlock: .files) { StagedUpdatePrewarm.writeLaunchMarker(build: build, step: .skipped(reason), at: marker) }
        return reason
    }

    /// The app's pre-warm marker; nil in a test process, so no test writes the person's marker. The build's first
    /// launch records what it says (`cmux app launch-times`' `prewarmed` and `prewarm_reason`).
    private func prewarmMarker(bundleIdentifier: String) -> URL? {
        let process = ProcessInfo.processInfo
        return UpdateLogFile.isTestProcess(name: process.processName, environment: process.environment)
            ? nil : StagedUpdatePrewarm.launchMarkerURL(bundleIdentifier: bundleIdentifier)
    }
}

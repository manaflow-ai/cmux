import CmuxNextWakeups
import CmuxUpdater
import Foundation
@preconcurrency import Sparkle

/// Keeps the staged update the right one: a staged build that is not newer than the running one
/// has its installer cancelled (``dropStale(updater:)``), and a staged build gives way to a newer
/// build of the followed ring (Leo 2026-10-22: "how are the dev build hot swaps? like the update
/// ready i want the latest dev builds to be able to show up").
///
/// Sparkle never reads the feed while an update waits: its scheduled check is skipped while the
/// held ready reply keeps the session open, and a check answers with the waiting update. So a Dev
/// build published after the staged one would wait for a restart. While an update waits, this
/// probes the feed (the read-only probe, filtered by the ring as Sparkle filters) once per
/// `updates.checkIntervalSeconds` (the tip app: every ``TipUpdateCheck/interval``), and
/// at once when the person checks or picks a ring. When the ring has a strictly newer build, it
/// cancels the staged installer (Skip on Sparkle's held reply,
/// which records no skipped version and touches no file of the person's) and starts a check
/// through this app's driver (``UpdateController/checkForUpdates()``, never Sparkle's silent
/// driver), which downloads the newer build and stages it, replaceable again, for the card. If
/// that download fails, nothing is staged until Sparkle's next scheduled check (its timer
/// restarts when the session ends), which stages the newest build again.
///
/// Never during an install: only the Update Ready phase arms or runs it, and a click to install
/// ends it (``installStarted()``) until the phase leaves Update Ready. Stop condition and cleanup:
/// the one-shot ``timer`` is armed only in Update Ready with
/// `updates.checkAutomatically` on, and is cancelled when the phase leaves it (install, relaunch,
/// swap, cancel) or the schedule changes; one probe runs at a time, and the next waits a whole
/// interval. The timer cancels its sleep when this object goes; a probe in flight ends with its
/// 15-second fetch deadline.
@MainActor
final class StagedUpdateRefresh {
    /// Whether this app's driver holds the staged installer and found updates download by
    /// themselves; nil reads the driver (``UpdateController/canCancelStagedUpdate``).
    var replaceable: (() -> Bool)?
    /// Starts the check that stages the newer build; nil runs the driver's ``UpdateController/checkForUpdates()``.
    var startCheck: (() -> Void)?
    /// `updates.checkAutomatically` and `updates.checkIntervalSeconds` (``reschedule(automatic:interval:updater:)``).
    private(set) var schedule: (automatic: Bool, interval: TimeInterval) = (true, 3600)
    /// The probe in flight, if any, the ring pick it reads (``ringMoved()``) and whether the person asked for it.
    private(set) var task: Task<Void, Never>?
    private var probing: (pick: Int, asked: Bool)?
    /// Counts the person's ring picks, so a probe that began before one (even away and back) is read again.
    private var ringPicks = 0
    /// A click on Install took the staged update: nothing probes or cancels until Update Ready ends.
    private var installing = false
    let timer: DemandTimer
    /// The install click waiting for the feed (``beforeInstall(updater:install:)``): the staged
    /// build it read against and the install to run if that build stays.
    private var pendingClick: (staged: String, install: @MainActor () -> Void)?
    /// The install click's deadline: the feed has ``clickProbeDeadline`` to answer.
    let clickTimer: DemandTimer
    /// How long the install click waits for the feed before it installs the staged build.
    static let clickProbeDeadline: Duration = .seconds(3)

    init(clock: any Clock<Duration>) {
        timer = DemandTimer(owner: "UpdaterService.stagedRefresh", clock: clock)
        clickTimer = DemandTimer(owner: "UpdaterService.installClick", clock: clock)
    }

    /// Whether an install click waits for the feed.
    var clickWaits: Bool { pendingClick != nil }

    /// The person clicked to install the staged build: read the ring's feed first, for at most
    /// ``clickProbeDeadline``. A strictly newer build replaces the staged one (its installer is
    /// cancelled, Sparkle's check downloads the newer build, and the click carries over to it,
    /// ``UpdaterService/installAfterSwap``), so one click ends on the newest build (a583: the click
    /// at 03:39 installed a build staged at 02:10, and the relaunched app staged the 03:37 nightly
    /// for a second click). Otherwise, or when the feed fails or is slow, `install` runs. A second
    /// click while the feed is read joins the first.
    func beforeInstall(updater: UpdaterService, install: @escaping @MainActor () -> Void) {
        guard pendingClick == nil else { return }
        guard updater.disabledReason == nil, isReplaceable(updater), let staged = updater.stagedBuild(), !staged.isEmpty else {
            return install()
        }
        updater.log.append("install click: looking for a build newer than staged build \(staged)")
        pendingClick = (staged, install)
        let probe = updater.probe()
        clickTimer.schedule(after: Self.clickProbeDeadline) { @MainActor [weak self, weak updater] in
            guard let self, let updater else { return }
            self.settleClick(answered: false, updater: updater)
        }
        Task { @MainActor [weak self, weak updater] in
            let failure = await probe.value
            guard let self, let updater else { return }
            self.settleClick(answered: failure == nil, updater: updater)
        }
    }

    /// The feed answered (or its deadline passed): the first of the two decides the click.
    private func settleClick(answered: Bool, updater: UpdaterService) {
        guard let (staged, install) = pendingClick else { return }
        pendingClick = nil
        clickTimer.cancel()
        guard answered, updater.stagedBuild() == staged,
              case .updateAvailable(let item)? = updater.lastProbe?.outcome,
              AppcastSelector.isOlder(staged, than: item.version) else {
            updater.log.append(answered ? "install click: staged build \(staged) is the newest"
                                        : "install click: the feed did not answer in time; installing staged build \(staged)")
            return install()
        }
        guard updater.cancelStaged() else {
            updater.log.append("install click: build \(item.version) is newer, but no installer was held to cancel; installing staged build \(staged)")
            return install()
        }
        updater.log.append("install click: build \(item.version) is newer than staged build \(staged): installing it instead")
        updater.installAfterSwap = true
        if let startCheck { startCheck() } else { updater.controller?.checkForUpdates() }
    }

    /// Follows the flow's phase: an update waiting arms the next probe; anything else ends it.
    func follow(_ phase: UpdateIndicatorPhase, updater: UpdaterService) {
        guard case .ready = phase else {
            installing = false
            return timer.cancel()
        }
        arm(updater)
    }

    /// The followed ring moved: a probe in flight read the ring before it.
    func ringMoved() {
        ringPicks += 1
    }

    /// The person clicked Install on the staged update: the pending probe ends, none is armed, and
    /// a probe in flight cancels nothing.
    func installStarted() {
        installing = true
        timer.cancel()
    }

    /// A changed schedule replaces the pending deadline: off ends it, a new interval counts from now.
    func reschedule(automatic: Bool, interval: TimeInterval, updater: UpdaterService) {
        guard schedule.automatic != automatic || schedule.interval != interval else { return }
        schedule = (automatic, interval)
        timer.cancel()
        arm(updater)
    }

    /// Whether the pending probe is the tip app's (``probesFast(_:)``).
    private(set) var armedFast = false

    /// The tip app probes every ``TipUpdateCheck/interval`` while a probe could replace the staged
    /// build, so a newer tip replaces it; otherwise (and in every other app) once per the person's
    /// interval, so a staged build nothing can replace never wakes every few minutes.
    private func probesFast(_ updater: UpdaterService) -> Bool {
        updater.identity.isTipBuild && TipUpdateCheck.interval < schedule.interval && updater.disabledReason == nil && isReplaceable(updater)
    }

    /// Downloads became automatic or stopped, or the managed policy moved: the pending probe takes
    /// the interval that now applies.
    func policyChanged(updater: UpdaterService) {
        guard timer.isScheduled, armedFast != probesFast(updater) else { return }
        timer.cancel()
        arm(updater)
    }

    /// Schedules the next probe one interval from now, unless one is pending or running.
    private func arm(_ updater: UpdaterService) {
        guard schedule.automatic, schedule.interval > 0, task == nil, !timer.isScheduled, !installing,
              case .ready = updater.flow.phase else { return }
        armedFast = probesFast(updater)
        timer.schedule(after: .seconds(armedFast ? TipUpdateCheck.interval : schedule.interval)) { @MainActor [weak self, weak updater] in
            guard let self, let updater, self.run(reason: "scheduled check", updater: updater) == nil else { return }
            self.arm(updater)
        }
    }

    /// Probes the ring for a build newer than the staged one, and swaps it in. Joins a probe in
    /// flight (one of another ring is read again when it ends); nil when nothing waits that this
    /// app can replace (then nothing is read). `asked` overrides whether the person asked (the reason
    /// is not "scheduled check"); the release push passes false, so nothing answers on screen.
    @discardableResult
    func run(reason: String, asked: Bool? = nil, updater: UpdaterService) -> Task<Void, Never>? {
        let asked = asked ?? (reason != "scheduled check")
        if let task {
            if asked { probing?.asked = true }
            return task
        }
        guard case .ready = updater.flow.phase, !installing, !updater.flow.installRequested, updater.disabledReason == nil,
              isReplaceable(updater), let staged = updater.stagedBuild(), !staged.isEmpty else { return nil }
        timer.cancel()
        updater.log.append("\(reason) while build \(staged) waits: looking for a newer \(updater.ring.rawValue) build")
        probing = (ringPicks, asked)
        let probe = updater.probe()
        let task = Task { [weak self, weak updater] in
            let failure = await probe.value
            guard let self, let updater else { return }
            self.finish(staged: staged, failure: failure, updater: updater)
        }
        self.task = task
        return task
    }

    private func isReplaceable(_ updater: UpdaterService) -> Bool {
        if let replaceable { return replaceable() }
        guard let controller = updater.controller else { return false }
        return controller.canCancelStagedUpdate && controller.downloadsUpdatesInBackground
    }

    private func finish(staged: String, failure: String?, updater: UpdaterService) {
        let probed = probing
        task = nil
        probing = nil
        if let probed, probed.pick != ringPicks, !installing {
            // The person picked a ring while this probe read the one before: read the ring now.
            if run(reason: "\(updater.ring.rawValue) ring picked", updater: updater) == nil { arm(updater) }
            return
        }
        let asked = probed?.asked ?? false
        guard let newer = newerBuild(than: staged, failure: failure, asked: asked, updater: updater) else {
            return keep(updater, asked: asked)
        }
        guard updater.cancelStaged() else {
            updater.log.append("build \(newer) is newer than staged build \(staged), but no installer was held to cancel")
            return keep(updater, asked: asked)
        }
        updater.log.append("build \(newer) on the \(updater.ring.rawValue) ring is newer than staged build \(staged): staging it instead")
        if let startCheck { startCheck() } else { updater.controller?.checkForUpdates() }
        // The person's own check (a check or a ring pick) now runs in Sparkle: another one joins it.
        if asked { updater.userCheckRunning = true }
    }

    /// The staged build stays: the person's check is answered by its card (the next check is not
    /// theirs), and the next probe is an interval away.
    private func keep(_ updater: UpdaterService, asked: Bool) {
        if asked { updater.flow.askAnswered() }
        arm(updater)
    }

    /// The build to stage instead of `staged`, or nil (the reason is logged).
    private func newerBuild(than staged: String, failure: String?, asked: Bool, updater: UpdaterService) -> String? {
        guard failure == nil else { return nil }
        // The person installed, or another build was staged, while the probe ran.
        guard case .ready = updater.flow.phase, !installing, !updater.flow.installRequested,
              updater.stagedBuild() == staged, isReplaceable(updater) else { return nil }
        guard case .updateAvailable(let item)? = updater.lastProbe?.outcome,
              AppcastSelector.isOlder(staged, than: item.version) else {
            updater.log.append("staged build \(staged) is the newest \(updater.ring.rawValue) build")
            return nil
        }
        return item.version
    }

    /// Ends the install session of a staged build that is not newer instead
    /// of only hiding it: left open, Sparkle installs that build again when
    /// the app quits, and Check for Updates is ignored behind it. This replies
    /// Skip to Sparkle's held ready prompt, which cancels the installer and
    /// records no skipped version, so the next check runs normally.
    ///
    /// Only a known `sparkle:version` at or below `CFBundleVersion` proves the
    /// build is not newer. An update of unknown version, or known only by its
    /// display version, may be a newer build the user asked for, so it stays
    /// hidden (``UpdaterService/offersStagedUpdate(version:)``) and keeps its installer.
    /// Sparkle's own silent driver hands over only an install block (nothing
    /// to cancel), and it stages only builds newer than `CFBundleVersion`.
    /// The log line is written only when an installer was cancelled, so at
    /// most once per staged item.
    func dropStale(updater: UpdaterService) {
        let running = updater.identity.build
        guard case .ready = updater.sourcePhase, let build = updater.stagedBuild(), !build.isEmpty,
              SUStandardVersionComparator.default.compareVersion(build, toVersion: running) != .orderedDescending,
              updater.cancelStaged() else { return }
        updater.log.append("staged build \(build) is not newer than build \(running): cancelling its installer")
    }
}

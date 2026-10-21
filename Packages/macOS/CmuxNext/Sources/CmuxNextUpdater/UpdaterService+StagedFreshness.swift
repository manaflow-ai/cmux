import CmuxNextWakeups
import CmuxUpdater
import Foundation
@preconcurrency import Sparkle

/// A staged update never goes stale (2026-10-21: NIGHTLY staged a build at 08:28Z and kept it for
/// 12 hours while about 25 newer ones shipped; Restart then installed the old one and the next
/// launch check staged another). Sparkle reads no feed while an update waits, so the read-only
/// probe does: on Sparkle's check interval and when cmux becomes active, at most once per
/// interval. A newer build cancels the staged installer and downloads the newest. The install
/// click reads the feed first when no probe answered in the last few minutes, and installs the
/// newest.
extension UpdaterService {
    /// How long a probe's answer stays current for the install click.
    static let installProbeFreshness: TimeInterval = 5 * 60
    /// How long the click waits for the feed before it installs the staged build anyway.
    static let installProbeWait: Duration = .seconds(4)

    /// Arms the next re-read while an update is staged, and drops it otherwise.
    func followStagedFreshness(_ phase: UpdateIndicatorPhase) {
        guard case .ready = phase, stagedBuild() != nil else { return stagedRecheckTimer.cancel() }
        stagedRecheckTimer.scheduleIfIdle(after: .seconds(stagedRecheckInterval)) { @MainActor [weak self] in
            self?.recheckStagedUpdate()
        }
    }

    /// cmux became active: re-reads the feed for a staged update, at most once per interval.
    func recheckStagedUpdateOnActivation() {
        guard case .ready = flow.phase, stagedBuild() != nil else { return }
        if let last = stagedCheckedAt, now().timeIntervalSince(last) < stagedRecheckInterval { return }
        recheckStagedUpdate()
    }

    /// Re-reads the feed while an update is staged; a newer build replaces the staged one.
    @discardableResult
    func recheckStagedUpdate() -> Task<Void, Never> {
        stagedCheckedAt = now()
        let probe = probe()
        return Task { [weak self] in
            let failure = await probe.value
            guard let self else { return }
            self.stagedRecheckTimer.cancel()
            self.followStagedFreshness(self.flow.phase)
            guard failure == nil, let newer = self.newerThanStaged() else { return }
            self.supersedeStaged(by: newer, install: false)
        }
    }

    /// The feed's newest build for this Mac (the last probe, which filters by ring and
    /// `sparkle:channel` as Sparkle does) when it is newer than the staged build and past
    /// Sparkle's rollback skip; nil otherwise.
    func newerThanStaged() -> AppcastItem? {
        guard case .ready = flow.phase, let staged = stagedBuild(), !staged.isEmpty,
              case .updateAvailable(let item)? = lastProbe?.outcome,
              Self.isNewer(item.version, than: staged) else { return nil }
        if let skip = controller?.skipsBuildsThrough, !Self.isNewer(item.version, than: skip) { return nil }
        return item
    }

    /// Cancels the staged installer and fetches the newest build: in the background, or, after
    /// the install click, as a check the person sees whose update installs once staged. False
    /// when no installer could be cancelled (Sparkle's silent driver holds none to cancel).
    @discardableResult
    func supersedeStaged(by newer: AppcastItem, install: Bool) -> Bool {
        let staged = stagedBuild() ?? "unknown"
        guard cancelStaged() else {
            log.append("staged build \(staged) is older than \(newer.version), but its installer cannot be cancelled")
            return false
        }
        log.append("staged build \(staged) superseded by \(newer.version): " + (install ? "installing the newest once it is staged" : "downloading it"))
        guard install else {
            recheck(false)
            return true
        }
        checkAndInstallNewest()
        return true
    }

    /// A check the person sees, whose update installs once it is staged.
    func checkAndInstallNewest() {
        recheck(true)
        syncFlowPhase()
        switch flow.phase {
        case .checking, .downloading, .available:
            send(.installRequested)
        case .hidden, .ready, .installing, .note:
            log.append("install: the check for the newest build did not start (\(flow.phase))")
        }
    }

    /// The gate's install: the newest build. Without a probe answer from the last few minutes
    /// it reads the feed first, for at most ``installProbeWait``; a feed that fails or does not
    /// answer in time installs the staged build.
    @discardableResult
    func installNewestStaged() -> Task<Void, Never> {
        if let installDecision { return installDecision }
        let task = Task { [weak self] in
            guard let self else { return }
            if self.stagedBuild() != nil, !self.probeIsCurrent {
                self.log.append("install: reading the feed for a newer build first")
                await self.waitForProbe(within: Self.installProbeWait)
            }
            if self.probeIsCurrent, let newer = self.newerThanStaged(), self.supersedeStaged(by: newer, install: true) {
                self.installDecision = nil
                return
            }
            await self.installStagedNow()
            self.installDecision = nil
        }
        installDecision = task
        return task
    }

    /// Hands the staged update to Sparkle: the preflight (with Sparkle only), the record, the windows, the install.
    func installStagedNow() async {
        await recordWrite?.value
        if controller != nil, let failure = installPreflightFailure() {
            failInstall(failure)
            return
        }
        recordBeforeInstall()
        willInstallStaged?()
        installStaged()
        #if DEBUG
        UpdateHarness.mark("install_handed_to_sparkle")
        #endif
    }

    /// The last probe answered, without an error, in the last ``installProbeFreshness``.
    private var probeIsCurrent: Bool {
        guard lastProbeError == nil, let checked = lastProbe?.checkedAt else { return false }
        return now().timeIntervalSince(checked) < Self.installProbeFreshness
    }

    /// Waits for a probe, at most `limit` (a one-shot deadline).
    private func waitForProbe(within limit: Duration) async {
        let probe = probe()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let once = ResumeOnce(done)
            installProbeTimer.schedule(after: limit) { @MainActor in once.resume() }
            // task-owner: ends with the probe, whose fetch has its own deadline; the timer above caps the wait
            Task { @MainActor in
                _ = await probe.value
                once.resume()
            }
        }
        installProbeTimer.cancel()
    }

    private static func isNewer(_ build: String, than other: String) -> Bool {
        SUStandardVersionComparator.default.compareVersion(build, toVersion: other) == .orderedDescending
    }
}

/// Resumes a continuation once: the probe's answer or its deadline, whichever comes first.
@MainActor private final class ResumeOnce {
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

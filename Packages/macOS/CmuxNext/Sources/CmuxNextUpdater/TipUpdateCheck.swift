import CmuxNextWakeups
import Foundation

/// The tip app's fast check (Leo 2026-10-24: "I can have a separate thing going on, a separate
/// app where, like, that is able to just track the latest tip"). The tip feed gets a build every 5
/// to 15 minutes, but Sparkle checks once per `updates.checkIntervalSeconds` (an hour by default),
/// and release Sparkle raises any shorter scheduled interval to an hour; nothing checks on
/// activation. So the tip app lagged a merge by an hour or more.
///
/// In the tip app (``UpdateBuildIdentity/isTipBuild``) with `updates.checkAutomatically` on, this
/// reads the feed every ``interval`` while nothing is found, downloading, staged or installing
/// (the read-only probe, as ``StagedUpdateRefresh`` does). When the feed has a build newer than
/// the running one, it starts a check through this app's driver
/// (``UpdateController/checkForUpdates()``, never Sparkle's silent driver), which downloads the
/// build and stages it for the idle install and the Update Ready card; the flow takes a check
/// nobody asked for as a scheduled one, so nothing shows until the build is staged. Once staged,
/// ``StagedUpdateRefresh`` probes at the same interval and swaps in a newer tip. Each build is
/// asked for once: a download that fails waits for a newer build or Sparkle's own schedule, so a
/// broken build never downloads every interval.
///
/// Only where found updates download by themselves (the person's `updates.downloadAutomatically`,
/// their metered-network choice and the managed channel); elsewhere Sparkle's own schedule offers
/// the update. Never with the updater disabled, never while the update sheet is open (its details
/// stay as they are), and the person's interval setting is not changed.
///
/// Stop condition and cleanup: the one-shot ``timer`` is armed only while every condition above
/// holds, and is cancelled when the phase moves on (checking, downloading, found, staged,
/// installing), when automatic checks go off, when downloads stop being automatic, and at a
/// deadline that finds the updater disabled or the sheet open (``UpdaterService/applyDownloadPolicy()``,
/// run on every download and managed policy change, and ``UpdaterService/updateSheetClosed()`` arm
/// it again). One probe runs at a time and the next waits a whole interval. The timer cancels its
/// sleep when this object goes; a probe in flight ends with its 15-second fetch deadline.
///
/// A cmux NEXT NIGHTLY (track ``UpdateTrack/nightly``, not the tip app) runs the same check every
/// ``nightlyInterval`` (Leo 2026-10-26: "am I on the latest nightly here, or not? ... why is the
/// last nightly, like, four fucking hours away?"). nightly-next ships every 20 to 40 minutes, and
/// the hourly Sparkle schedule left a NIGHTLY an hour or more behind. A newer build is asked for at
/// once, whether or not its deltas are listed yet: the full update is never held back for them.
@MainActor
final class TipUpdateCheck {
    /// How often the tip app reads its feed while nothing waits (an internal constant, not a setting).
    static let interval: TimeInterval = 300
    /// How often a NIGHTLY reads its feed while nothing waits (an internal constant, not a setting).
    static let nightlyInterval: TimeInterval = 900
    /// The read interval for `identity`'s app: the tip app's, a NIGHTLY's, or nil (no fast check).
    static func interval(for identity: UpdateBuildIdentity) -> TimeInterval? {
        if identity.isTipBuild { return interval }
        return identity.track == .nightly ? nightlyInterval : nil
    }
    /// Starts the check that downloads the newer build; nil runs the driver's ``UpdateController/checkForUpdates()``.
    var startCheck: (() -> Void)?
    /// Whether found updates download by themselves; nil reads the driver (``UpdateController/downloadsUpdatesInBackground``).
    var downloadsInBackground: (() -> Bool)?
    /// `updates.checkAutomatically` (``reschedule(automatic:updater:)``).
    private(set) var automatic = true
    /// The probe in flight, if any.
    private(set) var task: Task<Void, Never>?
    /// The newest build this check asked the driver for.
    private(set) var asked: String?
    let timer: DemandTimer

    init(clock: any Clock<Duration>) {
        timer = DemandTimer(owner: "UpdaterService.tipCheck", clock: clock)
    }

    /// A changed `updates.checkAutomatically`: off ends the pending deadline, on arms one an interval from now.
    func reschedule(automatic: Bool, updater: UpdaterService) {
        if self.automatic != automatic {
            self.automatic = automatic
            timer.cancel()
        }
        refresh(updater)
    }

    /// Arms the next read an interval from now while the tip app may check, else ends the pending one.
    /// Called when the phase, the schedule, the download or managed policy moves, and when the sheet closes.
    func refresh(_ updater: UpdaterService) {
        guard mayCheck(updater) else { return timer.cancel() }
        guard task == nil, !timer.isScheduled, let interval = Self.interval(for: updater.identity) else { return }
        timer.schedule(after: .seconds(interval)) { @MainActor [weak self, weak updater] in
            guard let self, let updater else { return }
            self.run(updater)
        }
    }

    /// The release push (``UpdaterService/releasePushed(_:)``): read the feed now instead of at the
    /// interval's deadline. Joins a read in flight; nothing reads where the interval's read would not.
    /// Returns whether a read runs.
    @discardableResult
    func readNow(_ updater: UpdaterService) -> Bool {
        guard task == nil else { return true }
        guard mayCheck(updater) else { return false }
        timer.cancel()
        run(updater)
        return task != nil
    }

    private func mayCheck(_ updater: UpdaterService) -> Bool {
        guard Self.interval(for: updater.identity) != nil, automatic, updater.isStarted, updater.disabledReason == nil,
              !updater.flow.installRequested, !updater.isSheetPresented(), downloads(updater) else { return false }
        switch updater.flow.phase {
        case .hidden, .note: return true
        case .checking, .downloading, .available, .ready, .installing: return false
        }
    }

    func downloads(_ updater: UpdaterService) -> Bool {
        if let downloadsInBackground { return downloadsInBackground() }
        return updater.controller?.downloadsUpdatesInBackground ?? false
    }

    private func run(_ updater: UpdaterService) {
        guard task == nil, mayCheck(updater) else { return }
        let probe = updater.probe()
        task = Task { [weak self, weak updater] in
            let failure = await probe.value
            guard let self, let updater else { return }
            self.task = nil
            self.finish(failure: failure, updater: updater)
            self.refresh(updater)
        }
    }

    /// The feed answered: a build newer than the running one (and than a rollback's skip) is checked for once.
    private func finish(failure: String?, updater: UpdaterService) {
        guard failure == nil, mayCheck(updater), case .updateAvailable(let item)? = updater.lastProbe?.outcome else { return }
        if let skip = updater.defaults.string(forKey: UpdaterService.skipsBuildsThroughKey),
           !AppcastSelector.isOlder(skip, than: item.version) { return }
        if let asked, !AppcastSelector.isOlder(asked, than: item.version) { return }
        asked = item.version
        updater.log.append("fast check: build \(item.version) is newer than build \(updater.identity.build): checking")
        if let startCheck { startCheck() } else { updater.controller?.checkForUpdates() }
    }
}

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
/// it again). One probe runs at a time and the next waits a whole interval. A released timer never
/// fires; a probe in flight ends with its 15-second fetch deadline.
///
/// Nobody waits on the read: the ``timer`` is a `background` ``MainDeadline`` on the app's deadline
/// scheduler, aligned to the app's hidden wakes (whole seconds, then one a minute after 5 hidden
/// minutes: Blink's hidden-page wake-up throttling, page_scheduler_impl.h), and the probe's answer
/// comes back with its landing (``UpdaterService/probe(_:then:)``).
@MainActor
final class TipUpdateCheck {
    /// How often the tip app reads its feed while nothing waits (an internal constant, not a setting).
    static let interval: TimeInterval = 300
    /// Starts the check that downloads the newer build; nil runs the driver's ``UpdateController/checkForUpdates()``.
    var startCheck: (() -> Void)?
    /// Whether found updates download by themselves; nil reads the driver (``UpdateController/downloadsUpdatesInBackground``).
    var downloadsInBackground: (() -> Bool)?
    /// `updates.checkAutomatically` (``reschedule(automatic:updater:)``).
    private(set) var automatic = true
    /// The probe in flight, if any.
    private(set) var task: Task<String?, Never>?
    /// The newest build this check asked the driver for.
    private(set) var asked: String?
    let timer: MainDeadline

    /// `checkNode` is the app's visibility node (nil: the reads are only flexible).
    init(deadlines: MainDeadlineScheduler, checkNode: VisibilityNode?) {
        timer = MainDeadline(owner: "UpdaterService.tipCheck", workClass: .background,
                             alignment: checkNode.map(TimerAlignment.whenHidden) ?? .flexible, scheduler: deadlines)
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
        guard task == nil, !timer.isScheduled else { return }
        timer.schedule(after: .seconds(Self.interval)) { [weak self, weak updater] in
            guard let self, let updater else { return }
            self.run(updater)
        }
    }

    private func mayCheck(_ updater: UpdaterService) -> Bool {
        guard updater.identity.isTipBuild, automatic, updater.isStarted, updater.disabledReason == nil,
              !updater.flow.installRequested, !updater.isSheetPresented(), downloads(updater) else { return false }
        switch updater.flow.phase {
        case .hidden, .note: return true
        case .checking, .downloading, .available, .ready, .installing: return false
        }
    }

    private func downloads(_ updater: UpdaterService) -> Bool {
        if let downloadsInBackground { return downloadsInBackground() }
        return updater.controller?.downloadsUpdatesInBackground ?? false
    }

    private func run(_ updater: UpdaterService) {
        guard task == nil, mayCheck(updater) else { return }
        task = updater.probe(.visible) { [weak self, weak updater] failure in
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
        updater.log.append("tip check: build \(item.version) is newer than build \(updater.identity.build): checking")
        if let startCheck { startCheck() } else { updater.controller?.checkForUpdates() }
    }
}

import AppKit
import Foundation

/// Checks after the Mac wakes, for hosts that never prompt (``installsUpdatesInBackground``).
/// Sparkle's schedule does not run while the Mac sleeps, so a build published overnight would
/// otherwise wait for the next interval. A found update downloads and waits staged, like one a
/// scheduled check found.
extension UpdateController {
    /// How long a check waits after a wake: Wi-Fi usually needs a few seconds to rejoin, and a
    /// check without a network only logs a failure.
    static let wakeCheckDelay: Duration = .seconds(20)
    /// A wake within this long of Sparkle's last check does not check again (a lid closed and
    /// opened again).
    static let wakeCheckMinimumGap: TimeInterval = 10 * 60

    /// Follows `NSWorkspace.didWakeNotification` (idempotent).
    func observeSystemWake() {
        guard wakeObservation == nil else { return }
        wakeObservation = Task { [weak self] in
            for await _ in NSWorkspace.shared.notificationCenter.notifications(named: NSWorkspace.didWakeNotification) {
                self?.systemDidWake()
            }
        }
    }

    /// The Mac woke: checks after ``wakeCheckDelay``; a second wake before then restarts the delay.
    public func systemDidWake() {
        wakeCheckTask?.cancel()
        wakeCheckTask = Task { @MainActor [weak self] in
            guard let clock = self?.clock else { return }
            try? await clock.sleep(for: Self.wakeCheckDelay)
            guard !Task.isCancelled, let self else { return }
            self.wakeCheckTask = nil
            self.checkAfterWake(lastCheck: self.updater.lastUpdateCheckDate)
        }
    }

    /// Runs the wake check now. Skipped before the updater started, with automatic checks off,
    /// in DEV/staging builds, under the managed policy, while an update is already on its way
    /// (checking, downloading, staged, installing), or when Sparkle checked within
    /// ``wakeCheckMinimumGap``. Returns whether a check started.
    @discardableResult
    func checkAfterWake(lastCheck: Date?, now: Date = Date()) -> Bool {
        guard didStartUpdater, !isDevLikeBundle, updater.automaticallyChecksForUpdates, !isDisabledByPolicy() else { return false }
        guard stagedUpdate == nil else { return skipWakeCheck("an update is staged") }
        switch model.state {
        case .idle, .notFound, .error, .updateAvailable:
            break
        case .permissionRequest, .preparingCheck, .checking, .startingDownload, .downloading, .extracting, .installing:
            return skipWakeCheck("update \(describeLifecycleState(model.state))")
        }
        if let lastCheck, now.timeIntervalSince(lastCheck) < Self.wakeCheckMinimumGap {
            return skipWakeCheck("last check \(Int(now.timeIntervalSince(lastCheck)))s ago")
        }
        log.append("wake check")
        checkInBackground()
        return true
    }

    private func skipWakeCheck(_ reason: String) -> Bool {
        log.append("wake check skipped (\(reason))")
        return false
    }
}

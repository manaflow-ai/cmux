public import Foundation
@preconcurrency import Sparkle

/// The one-click auto-update flows layered on ``UpdateController``: kicking the silent
/// background download when a probe detects an update, retrying transient background
/// failures, and the deferred "restart when idle" loop.
///
/// Split from `UpdateController.swift` to keep that file within the repo's Swift file-length
/// budget; state lives on the class (see the "One-click auto-update state" properties there).
extension UpdateController {
    // MARK: - Silent background download

    /// Starts Sparkle's background session (which downloads and stages the update silently when
    /// automatic downloads are enabled) once the session that detected the update has finished.
    ///
    /// Without this, the payload isn't fetched until Sparkle's next scheduled check, so the
    /// user who clicks "install" pays the download (and any transient CDN failure, #5632) at
    /// click time. Keyed on Sparkle's `didFinishUpdateCycle` signal (not a timer); the same
    /// 100ms teardown beat as the re-check path lets Sparkle finish tearing the session down
    /// before a new one starts, and the `canCheckForUpdates`/idle guards keep it from
    /// interrupting a user-initiated flow.
    func startSilentDownloadIfKickPending() {
        guard pendingSilentDownloadKick else { return }
        guard !isDevLikeBundle else {
            pendingSilentDownloadKick = false
            return
        }
        guard updater.automaticallyDownloadsUpdates else {
            pendingSilentDownloadKick = false
            return
        }
        silentDownloadKickTask?.cancel()
        silentDownloadKickTask = Task { @MainActor [weak self] in
            defer { self?.silentDownloadKickTask = nil }
            guard let self else { return }
            try? await self.clock.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            guard self.model.state.isIdle, self.model.overrideState == nil else { return }
            guard self.updater.canCheckForUpdates else { return }
            let version = self.model.detectedUpdateVersion
            if version != self.silentDownloadKickedVersion {
                self.backgroundRetryCount = 0
            }
            self.pendingSilentDownloadKick = false
            self.silentDownloadKickedVersion = version
            self.log.append("starting silent background download of detected update")
            self.updater.checkForUpdatesInBackground()
        }
    }

    /// Schedules a bounded silent retry after a transient background failure (GitHub's release
    /// CDN intermittently 504s individual objects; Sparkle itself never retries, #5632).
    /// Non-transient failures and exhausted retries fall back to the next scheduled check.
    func scheduleBackgroundRetryIfTransient(_ error: any Error) {
        guard isTransientUpdateNetworkError(error) else { return }
        guard backgroundRetryCount < backgroundRetryLimit else {
            log.append("background update retry limit reached; waiting for next scheduled check")
            return
        }
        backgroundRetryCount += 1
        log.append("scheduling background update retry \(backgroundRetryCount)/\(backgroundRetryLimit)")
        backgroundRetryTask?.cancel()
        backgroundRetryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await self.clock.sleep(for: self.backgroundRetryDelay)
            guard !Task.isCancelled else { return }
            guard self.model.state.isIdle, self.updater.canCheckForUpdates else { return }
            self.log.append("retrying silent background update download")
            self.updater.checkForUpdatesInBackground()
        }
    }

    // MARK: - Restart when idle

    /// Defers the staged update's restart until the host reports the user is idle
    /// (``UpdateActionDelegate/updaterIsSafeToRestartNow()``), then completes the install.
    ///
    /// The poll is a genuine periodic schedule on the injected clock, cancelled when the user
    /// restarts manually or the staged install goes away (see `handleStateChange`).
    public func requestRestartWhenIdle() {
        guard case .installing = model.effectiveState else {
            log.append("restart-when-idle ignored (no staged install)")
            return
        }
        model.setRestartWhenIdleArmed(true)
        log.append("restart-when-idle armed")
        guard case .installing = model.state else {
            // Debug override without a real staged install: arm the UI state only.
            return
        }
        restartWhenIdleTask?.cancel()
        restartWhenIdleTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                try? await self.clock.sleep(for: self.restartWhenIdlePollInterval)
                guard !Task.isCancelled else { return }
                guard self.model.isRestartWhenIdleArmed,
                      case .installing(let installing) = self.model.state else {
                    self.cancelRestartWhenIdleLoop()
                    return
                }
                guard self.actionDelegate?.updaterIsSafeToRestartNow() == true else { continue }
                self.log.append("restart-when-idle firing (host reports idle)")
                installing.retryTerminatingApplication()
            }
        }
    }

    func cancelRestartWhenIdleLoop() {
        restartWhenIdleTask?.cancel()
        restartWhenIdleTask = nil
    }

    // MARK: - Toast mute expiry

    func scheduleToastMuteExpiryIfNeeded() {
        toastMuteExpiryTask?.cancel()
        toastMuteExpiryTask = nil

        guard let mutedUntil = model.updateReadyToastMutedUntil else { return }
        let delay = max(0, mutedUntil.timeIntervalSince(model.now()))
        toastMuteExpiryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await self.clock.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self.model.expireUpdateReadyToastMuteIfNeeded()
            self.toastMuteExpiryTask = nil
        }
    }
}

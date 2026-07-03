import Foundation

/// The "attempt update" policy: the single user-facing install entry point, the actions it
/// performs on behalf of ``AttemptUpdateCoordinator``, and the ``InstallWatchdog`` trip handling
/// that turns a silent stall into a visible, retryable error.
extension UpdateController {
    // MARK: - Attempt update

    /// Re-check for updates and auto-confirm the install of whatever the fresh check resolves.
    ///
    /// This is the single user-facing "install the update" entry point. It deliberately runs a
    /// fresh check instead of installing the update that was captured when the prompt was first
    /// surfaced, so a newer release published in the meantime is installed directly rather than
    /// prompting the user again right after relaunch (issue #6366).
    public func attemptUpdate() {
        let action = attemptCoordinator.requestInstallLatest(currentState: model.state)
        if action == .startFreshCheck {
            // The user committed to installing. Arm the watchdog so that if the flow never reaches
            // downloading/installing (or another visible outcome) it surfaces an error instead of
            // silently looping on "Update Available".
            installWatchdog.arm { [weak self] in self?.fireInstallWatchdogIfStalled() }
        }
        performAttemptAction(action)
    }

    private func fireInstallWatchdogIfStalled() {
        installWatchdog.disarm()
        let attemptWasMonitoring = attemptCoordinator.isMonitoring
        // The attempt is over regardless of what shows below: a coordinator left monitoring past
        // its deadline would silently auto-confirm an install off a later, unrelated check.
        attemptCoordinator.cancel()
        guard installWatchdog.installAttemptStalled(model.state) else { return }
        log.append("install watchdog fired: update did not start within \(Int(installWatchdog.timeoutSeconds))s")
        if attemptWasMonitoring {
            // Resolve the in-flight Sparkle session (reply .dismiss to a pending "Update
            // Available" prompt / cancel a running check) before replacing the state, so Sparkle
            // is not left waiting on a dropped callback. Skipped post-confirm: that prompt's
            // reply was already consumed by `.install`. The driver ignores Sparkle's follow-up
            // dismiss callback while an error is visible, so the error state set below survives.
            model.cancelActiveStateForNewCheck()
        }
        let error = NSError(
            domain: UpdateStateModel.updateErrorDomain,
            code: UpdateStateModel.installDidNotStartCode,
            userInfo: [NSLocalizedDescriptionKey: String(
                localized: "update.error.didNotStart.message",
                defaultValue: "cmux couldn’t start the update. Check your internet connection and try again."
            )]
        )
        model.setState(.error(.init(
            error: error,
            retry: { [weak self] in
                self?.model.setState(.idle)
                self?.attemptUpdate()
            },
            dismiss: { [weak self] in self?.model.setState(.idle) },
            technicalDetails: "install attempt stalled without reaching download",
            feedURLString: driver.resolvedFeedURLString()
        )))
    }

    func performAttemptAction(_ action: AttemptUpdateCoordinator.Action) {
        switch action {
        case .none:
            break
        case .startFreshCheck:
            checkForUpdates()
        case .confirmInstall:
            // Reactions process drained snapshots, so the live state can have moved past the
            // snapshot that produced this action. Confirm only a live "Update Available" prompt
            // (its reply is unconsumed; a snapshot's may already have been answered). If the
            // prompt vanished in the meantime (e.g. the user dismissed it mid-drain), the
            // attempt is over — disarm the watchdog so the leftover deadline can't fire a
            // spurious "Update Didn't Start" over whatever the user does next.
            if case .updateAvailable(let available) = model.state, !available.reply.isConsumed {
                log.append("attemptUpdate installing freshly resolved update")
                model.state.confirm()
            } else {
                log.append("attemptUpdate hand-off skipped (prompt no longer showing)")
                installWatchdog.disarm()
            }
        }
    }
}

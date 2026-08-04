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
        model.discardPendingChanges()
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
        guard installWatchdog.installAttemptStalled(model.state) else { return }
        setInstallDidNotStartError(
            diagnostic: "install watchdog fired after \(Int(installWatchdog.timeoutSeconds))s (state=\(model.state))"
        )
    }

    /// Ends the accepted-install lifecycle with an actionable retry instead of an empty pill.
    func setInstallDidNotStartError(diagnostic: String) {
        installWatchdog.disarm()
        cancelReadinessRetry()
        attemptCoordinator.cancel()
        pendingCheckIntent = nil
        activeCheckIntent = nil
        log.append("accepted update did not start: \(diagnostic)")
        let error = NSError(
            domain: UpdateStateModel.updateErrorDomain,
            code: UpdateStateModel.installDidNotStartCode,
            userInfo: [NSLocalizedDescriptionKey: String(
                localized: "update.error.didNotStart.message",
                defaultValue: "cmux couldn’t start the update. Check your internet connection and try again."
            )]
        )
        let errorState = UpdateState.error(.init(
            error: error,
            retry: { [weak self] in
                self?.model.setState(.idle)
                self?.attemptUpdate()
            },
            dismiss: { [weak self] in self?.model.setState(.idle) },
            technicalDetails: String(
                localized: "update.error.didNotStart.technicalDetails",
                defaultValue: "Install attempt stalled without reaching download."
            ),
            feedURLString: driver.resolvedFeedURLString()
        ))
        // Publish the actionable terminal before ending whichever Sparkle callback it replaces.
        // Sparkle may synchronously emit its identity-free dismissal while the reply/cancellation
        // runs; because the error is already visible and that callback is diagnostic-only, there
        // is no empty-pill window and no unresolved session left behind.
        model.replaceActiveState(with: errorState)
    }

    func performAttemptAction(_ action: AttemptUpdateCoordinator.Action) {
        switch action {
        case .none:
            break
        case .startFreshCheck:
            requestUpdateCheck(.installLatest)
        case .confirmInstall:
            // Reactions process drained snapshots, so the live state can have moved past the
            // snapshot that produced this action. Confirm only a live "Update Available" prompt
            // (its reply is unconsumed; a snapshot's may already have been answered). If the
            // prompt vanished in the meantime (e.g. the user dismissed it mid-drain), the
            // causal source distinguishes that explicit choice from an un-attributed loss.
            if case .updateAvailable(let available) = model.state, !available.reply.isConsumed {
                log.append(
                    "attemptUpdate accepted freshly resolved update (version=\(available.appcastItem.displayVersionString), prompt=\(available.reply.id))"
                )
                // Publish ownership before invoking Sparkle because its callbacks may be
                // synchronous. The pill stays visible until download or a retryable error.
                model.setState(.startingDownload)
                available.reply.consume(.install, source: .installAttempt)
            } else if case .updateAvailable(let available) = model.state,
                      available.reply.consumedSource == .user {
                log.append("attemptUpdate hand-off cancelled by explicit user prompt choice")
                attemptCoordinator.cancel()
                installWatchdog.disarm()
            } else {
                setInstallDidNotStartError(
                    diagnostic: "fresh prompt disappeared before install reply (state=\(model.state))"
                )
            }
        case .installFailed:
            setInstallDidNotStartError(
                diagnostic: "accepted install reached unexpected terminal state (state=\(model.state))"
            )
        }
    }
}

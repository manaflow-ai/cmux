import Foundation
@preconcurrency import Sparkle

/// Foreground update-check lifecycle. A single owner serializes manual checks and accepted
/// installs across Sparkle sessions; replacement checks start only after Sparkle's authoritative
/// cycle-finished callback.
extension UpdateController {
    /// Check for updates (used by the menu item).
    public func checkForUpdates() {
        requestUpdateCheck(.manual)
    }

    /// Check for updates using the custom popover-based UI.
    public func checkForUpdatesInCustomUI() {
        requestUpdateCheck(.manual)
    }

    func requestUpdateCheck(_ intent: UpdateCheckIntent) {
        // A coincident menu check must not downgrade ownership after the user already accepted an
        // install. It may replace the transport session, but its result still serves that install.
        let intent = attemptCoordinator.isMonitoring ? UpdateCheckIntent.installLatest : intent
        log.append(
            "update check requested (intent=\(intent.rawValue), session=\(updater.sessionInProgress), state=\(describeLifecycleState(model.state)))"
        )

        switch model.state {
        case .startingDownload, .downloading, .extracting, .installing:
            log.append("update check ignored while install is progressing (intent=\(intent.rawValue))")
            return
        default:
            break
        }

        if isDevLikeBundle {
            // DEV/staging builds are not on the public release train (#6292).
            log.append("manual update check suppressed (dev/staging build, intent=\(intent.rawValue))")
            cancelReadinessRetry()
            pendingCheckIntent = nil
            activeCheckIntent = nil
            attemptCoordinator.cancel()
            installWatchdog.disarm()
            model.setState(.notFound(.init(acknowledgement: {})))
            return
        }

        cancelReadinessRetry()
        guard startUpdaterIfNeeded(retryAfterFailure: { [weak self] in
            self?.requestUpdateCheck(intent)
        }) else {
            log.append("update check halted because updater startup failed (intent=\(intent.rawValue))")
            return
        }
        ensureSparkleInstallationCache()

        if mustFinishCurrentCycleBeforeChecking {
            queueReplacementCheck(intent)
            return
        }

        beginCheckWhenReady(intent)
    }

    private var mustFinishCurrentCycleBeforeChecking: Bool {
        if updater.sessionInProgress || activeCheckIntent != nil {
            return true
        }
        switch model.state {
        case .checking, .updateAvailable:
            // The model is also a defensive signal for tests and for any brief lag in Sparkle's
            // sessionInProgress observation.
            return true
        default:
            return false
        }
    }

    private func queueReplacementCheck(_ intent: UpdateCheckIntent) {
        pendingCheckIntent = pendingCheckIntent?.merged(with: intent) ?? intent
        log.append(
            "replacement check queued (intent=\(pendingCheckIntent?.rawValue ?? intent.rawValue), active=\(activeCheckIntent?.rawValue ?? "external"))"
        )

        guard case .preparingCheck = model.state else {
            showPreparingCheck()
            return
        }
    }

    private func beginCheckWhenReady(_ intent: UpdateCheckIntent) {
        pendingCheckIntent = intent
        let canCheck = updater.canCheckForUpdates
        log.append(
            "foreground check readiness (intent=\(intent.rawValue), canCheck=\(canCheck), session=\(updater.sessionInProgress))"
        )
        guard canCheck, !updater.sessionInProgress else {
            showPreparingCheck()
            waitForReadinessThenCheck()
            return
        }
        startPendingCheck()
    }

    private func startPendingCheck() {
        guard let intent = pendingCheckIntent else { return }
        pendingCheckIntent = nil
        activeCheckIntent = intent
        if intent == .installLatest {
            attemptCoordinator.didStartFreshCheck()
        }
        showPreparingCheck()
        log.append("starting foreground Sparkle check (intent=\(intent.rawValue))")
        updater.checkForUpdates()
    }

    private func showPreparingCheck() {
        if case .preparingCheck = model.state { return }
        let state = UpdateState.preparingCheck(.init(cancellationHandler: { [weak self] source in
            guard source == .user else { return }
            self?.cancelQueuedCheckByUser()
        }))
        model.replaceActiveState(with: state)
    }

    private func waitForReadinessThenCheck() {
        readyCheckTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var remaining = self.readyRetryCount
            while remaining > 0 {
                if self.updater.canCheckForUpdates, !self.updater.sessionInProgress {
                    self.startPendingCheck()
                    return
                }
                remaining -= 1
                try? await self.clock.sleep(for: self.readyRetryDelay)
                if Task.isCancelled { return }
            }

            // Read once more after the final bounded wait. Readiness may have changed during that
            // last suspension, and reporting a timeout without observing it would drop the check.
            if self.updater.canCheckForUpdates, !self.updater.sessionInProgress {
                self.startPendingCheck()
                return
            }

            guard let intent = self.pendingCheckIntent else { return }
            self.pendingCheckIntent = nil
            self.log.append(
                "foreground check readiness timed out (intent=\(intent.rawValue), session=\(self.updater.sessionInProgress))"
            )
            if intent == .installLatest {
                self.attemptCoordinator.cancel()
                self.installWatchdog.disarm()
                self.setUpdaterNotReadyError(retry: { [weak self] in self?.attemptUpdate() })
            } else {
                self.setUpdaterNotReadyError(retry: { [weak self] in self?.checkForUpdates() })
            }
        }
    }

    private func cancelQueuedCheckByUser() {
        let intent = pendingCheckIntent
        log.append("queued update check cancelled by user (intent=\(intent?.rawValue ?? "none"))")
        pendingCheckIntent = nil
        activeCheckIntent = nil
        cancelReadinessRetry()
        attemptCoordinator.cancel()
        installWatchdog.disarm()
        model.setState(.idle)
    }

    private func setUpdaterNotReadyError(retry: @escaping () -> Void) {
        let error = NSError(
            domain: UpdateStateModel.updateErrorDomain,
            code: UpdateStateModel.updaterNotReadyCode,
            userInfo: [NSLocalizedDescriptionKey: String(
                localized: "update.error.notReady",
                defaultValue: "Updater is still starting. Try again in a moment."
            )]
        )
        model.setState(.error(.init(
            error: error,
            retry: retry,
            dismiss: { [weak self] in self?.model.setState(.idle) }
        )))
    }

    func cancelReadinessRetry() {
        readyCheckTask?.cancel()
        readyCheckTask = nil
    }

    private func describeLifecycleState(_ state: UpdateState) -> String {
        switch state {
        case .idle: return "idle"
        case .permissionRequest: return "permissionRequest"
        case .preparingCheck: return "preparingCheck"
        case .checking: return "checking"
        case .updateAvailable: return "updateAvailable"
        case .notFound: return "notFound"
        case .error: return "error"
        case .startingDownload: return "startingDownload"
        case .downloading: return "downloading"
        case .extracting: return "extracting"
        case .installing: return "installing"
        }
    }
}

extension UpdateController: UpdateDriverEventDelegate {
    func updateDriverDidFinishCycle(_ updateCheck: SPUUpdateCheck, error: NSError?) {
        let finishedIntent = activeCheckIntent
        activeCheckIntent = nil
        log.append(
            "controller observed cycle finish (check=\(updateCheck.rawValue), active=\(finishedIntent?.rawValue ?? "external"), pending=\(pendingCheckIntent?.rawValue ?? "none"), state=\(describeLifecycleState(model.state)), error=\(error?.code.description ?? "none"))"
        )

        if pendingCheckIntent != nil {
            cancelReadinessRetry()
            beginCheckWhenReady(pendingCheckIntent!)
            return
        }

        if finishedIntent == .installLatest, attemptCoordinator.isMonitoring {
            switch model.state {
            case .downloading, .extracting, .installing, .error:
                return
            case .idle, .permissionRequest, .preparingCheck, .checking, .updateAvailable,
                    .notFound, .startingDownload:
                setInstallDidNotStartError(
                    diagnostic: "accepted install cycle finished before download (check=\(updateCheck.rawValue), error=\(error.map(driver.formatErrorForLog) ?? "none"))"
                )
            }
            return
        }

        guard finishedIntent == .manual else { return }
        switch model.state {
        case .idle, .notFound, .error, .downloading, .extracting, .installing:
            return
        case .permissionRequest, .preparingCheck, .checking, .updateAvailable, .startingDownload:
            setForegroundCycleEndedError(updateCheck: updateCheck, underlyingError: error)
        }
    }

    private func setForegroundCycleEndedError(updateCheck: SPUUpdateCheck, underlyingError: NSError?) {
        let diagnostic = underlyingError.map(driver.formatErrorForLog) ?? "none"
        log.append(
            "manual update cycle ended without a visible terminal (check=\(updateCheck.rawValue), state=\(describeLifecycleState(model.state)), error=\(diagnostic))"
        )
        let error = underlyingError ?? NSError(
            domain: UpdateStateModel.updateErrorDomain,
            code: UpdateStateModel.foregroundCycleEndedCode,
            userInfo: [NSLocalizedDescriptionKey: String(
                localized: "update.error.failed.message",
                defaultValue: "Something went wrong while checking for updates. Try again, or check the update log for details."
            )]
        )
        model.clearDetectedUpdate()
        model.setState(.error(.init(
            error: error,
            retry: { [weak self] in
                self?.model.setState(.idle)
                self?.checkForUpdates()
            },
            dismiss: { [weak self] in self?.model.setState(.idle) },
            technicalDetails: underlyingError.map(driver.formatErrorForLog),
            feedURLString: driver.resolvedFeedURLString()
        )))
    }

    func updateDriverUserDidCancelCheck() {
        log.append("controller observed explicit user check cancellation")
        activeCheckIntent = nil
        pendingCheckIntent = nil
        cancelReadinessRetry()
        attemptCoordinator.cancel()
        installWatchdog.disarm()
    }

    func updateDriverUserDidDismissPrompt() {
        log.append("controller observed explicit user prompt dismissal")
        activeCheckIntent = nil
        pendingCheckIntent = nil
        cancelReadinessRetry()
        attemptCoordinator.cancel()
        installWatchdog.disarm()
    }
}

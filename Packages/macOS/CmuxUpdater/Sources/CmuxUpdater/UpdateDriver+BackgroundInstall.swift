@preconcurrency import Sparkle

/// Background installs (``UpdateController/installsUpdatesInBackground``): no prompt is ever
/// published. A found update is accepted at once so Sparkle downloads it, and Sparkle's
/// ready-to-install reply is held as "Restart to Complete Update" until the host installs, or
/// handed to the relaunch gate when the host's idle-install policy is enabled. Sparkle still
/// installs a held update when the app quits on its own.
extension UpdateDriver {
    func acceptInBackground(_ available: UpdateState.UpdateAvailable) {
        log.append("background install: accepting \(available.appcastItem.displayVersionString)")
        backgroundItem = available.appcastItem
        quitInstallItem = nil
        stagedInstall = nil
        stagedCancel = nil
        setState(.startingDownload)
        available.reply.consume(.install, source: .background)
    }

    func stageInBackground(_ reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void) {
        stagedInstall = { reply(.install) }
        stagedCancel = { reply(.skip) }
        if installsWhenStaged {
            log.append("background install: staged, installing for the user's click")
            installStaged()
            return
        }
        if installsWhenIdle {
            if actionDelegate?.updaterPrepareAutomaticInstall() ?? true {
                log.append("background install: staged, waiting for a safe idle relaunch")
                installStaged(automatic: true)
                return
            }
            log.append("background install: the host declined the automatic install")
        }
        log.append("background install: staged, waiting for the user")
        setState(.installing(.init(
            isAutoUpdate: true,
            retryTerminatingApplication: { [weak self] in _ = self?.installStaged() },
            dismiss: {}
        )))
    }

    /// The staged update, or nil when nothing waits for the user: this driver's held download,
    /// the update whose relaunch the gate holds, else the one Sparkle's silent driver staged
    /// while its install still waits.
    var stagedItem: SUAppcastItem? {
        if stagedInstall != nil { return backgroundItem }
        guard case .installing(let installing) = model.state else { return nil }
        if installing.relaunchBlockers != nil { return heldRelaunchItem }
        guard installing.isAutoUpdate else { return nil }
        return quitInstallItem
    }

    /// Whether `state` ends a click's request to install when ready: nothing
    /// was found, or the flow failed, so a later download waits for a new click.
    static func endsInstallRequest(_ state: UpdateState) -> Bool {
        switch state {
        case .notFound, .error, .idle: true
        default: false
        }
    }

    /// Sends the held install reply once; Sparkle installs and relaunches. False when this driver
    /// holds no staged update. `automatic` marks an idle-policy install nobody clicked, whose
    /// relaunch also waits for quiet input and a confirmed daemon mirror.
    ///
    /// An automatic install whose host reopens itself (``UpdateActionDelegate/updaterQuitsForAutomaticInstall(build:)``)
    /// leaves the held reply unanswered: Sparkle's prepared installer installs when the app exits
    /// and does not relaunch it. The relaunch gate is not involved, so only a host without it
    /// (`holdsUserInstalls` off) is asked.
    @discardableResult
    func installStaged(automatic: Bool = false) -> Bool {
        guard let install = stagedInstall else { return false }
        log.append("background install: installing staged update (automatic=\(automatic))")
        let item = backgroundItem, cancel = stagedCancel
        stagedInstall = nil
        stagedCancel = nil
        installsWhenStaged = false
        backgroundItem = nil
        if automatic, !holdsUserInstalls, let item {
            // Set before asking: the host may start its quit at once.
            quitInstall = (item, install, cancel)
            if actionDelegate?.updaterQuitsForAutomaticInstall(build: item.versionString) == true {
                log.append("background install: the app quits for the install; Sparkle installs as it exits, the app reopens itself")
                setState(.installing(.init(retryTerminatingApplication: {}, dismiss: {})))
                return true
            }
            quitInstall = nil
        }
        setState(.installing(.init(retryTerminatingApplication: {}, dismiss: {})))
        relaunchIsAutomatic = automatic
        install()
        return true
    }

    /// The automatic install the host quit for did not end the app (its quit was refused, or the
    /// host could not reopen itself): the update is staged again, with Sparkle's reply still held,
    /// so a click installs it and Sparkle still installs it when the app quits. False when no
    /// such install waits.
    @discardableResult
    func restageAfterDeclinedQuit() -> Bool {
        guard let pending = quitInstall else { return false }
        quitInstall = nil
        log.append("background install: the app did not quit for the install; staged again, waiting for the user")
        backgroundItem = pending.item
        stagedInstall = pending.install
        stagedCancel = pending.cancel
        setState(.installing(.init(
            isAutoUpdate: true,
            retryTerminatingApplication: { [weak self] in _ = self?.installStaged() },
            dismiss: {}
        )))
        return true
    }

    /// The automatic install the host meant to quit for is now one the user is in the app for:
    /// Sparkle installs and relaunches (activating), once. False when no such install waits.
    @discardableResult
    func relaunchHeldInstallThroughSparkle() -> Bool {
        guard let pending = quitInstall else { return false }
        quitInstall = nil
        log.append("background install: relaunching through Sparkle")
        pending.install()
        return true
    }

    /// Replies Skip to the held ready prompt once: Sparkle cancels the installer that would run
    /// when the app quits. Unlike Skip on the update-found prompt, this records no skipped
    /// version, so the next check offers the update again. False when this driver holds no
    /// staged installer.
    @discardableResult
    func cancelStaged() -> Bool {
        guard let cancel = stagedCancel else { return false }
        log.append("background install: cancelling the staged update's installer")
        stagedInstall = nil
        stagedCancel = nil
        installsWhenStaged = false
        backgroundItem = nil
        setState(.idle)
        cancel()
        return true
    }
}

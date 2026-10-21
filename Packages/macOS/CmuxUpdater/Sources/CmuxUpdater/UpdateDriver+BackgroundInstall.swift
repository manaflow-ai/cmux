@preconcurrency import Sparkle

/// Background installs (``UpdateController/installsUpdatesInBackground``): no prompt is ever
/// published. A found update is accepted at once so Sparkle downloads it, and Sparkle's
/// ready-to-install reply is held as "Restart to Complete Update" until the host installs.
/// Sparkle still installs a held update when the app quits on its own.
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

    /// Holds Sparkle's reply as the staged update. `resumed` names the build of an installer
    /// Sparkle resumed from update-found, where Skip is the only cancel and also records the
    /// build as skipped (in a main-queue block the reply enqueues): the cancel forgets that
    /// record in the block after it (the main queue runs them in order), so it skips nothing.
    func stageInBackground(_ reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void, resumed: String? = nil) {
        log.append("background install: staged, waiting for the user")
        stagedInstall = { reply(.install) }
        stagedCancel = { [weak self] in
            reply(.skip)
            guard let resumed, let forget = self?.forgetSkippedVersion else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { forget(resumed) } }
        }
        if installsWhenStaged {
            installStaged()
            return
        }
        setState(.installing(.init(
            isAutoUpdate: true,
            retryTerminatingApplication: { [weak self] in _ = self?.installStaged() },
            dismiss: {}
        )))
    }

    /// The staged update, or nil when nothing waits for the user: this driver's held download,
    /// else the one Sparkle's silent driver staged while its install still waits.
    var stagedItem: SUAppcastItem? {
        if stagedInstall != nil { return backgroundItem }
        guard case .installing(let installing) = model.state, installing.isAutoUpdate else { return nil }
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
    /// holds no staged update.
    @discardableResult
    func installStaged() -> Bool {
        guard let install = stagedInstall else { return false }
        log.append("background install: installing staged update")
        stagedInstall = nil
        stagedCancel = nil
        installsWhenStaged = false
        backgroundItem = nil
        setState(.installing(.init(retryTerminatingApplication: {}, dismiss: {})))
        install()
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

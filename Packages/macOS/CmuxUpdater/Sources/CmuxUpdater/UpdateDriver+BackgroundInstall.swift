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
        stagedInstall = nil
        stagedCancel = nil
        setState(.startingDownload)
        available.reply.consume(.install, source: .background)
    }

    func stageInBackground(_ reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void) {
        stagedInstall = { reply(.install) }
        stagedCancel = { reply(.skip) }
        if installsWhenIdle || installsWhenStaged {
            log.append("background install: staged, waiting for a safe idle relaunch")
            installStaged()
            return
        }
        log.append("background install: staged, waiting for the user")
        setState(.installing(.init(
            isAutoUpdate: true,
            retryTerminatingApplication: { [weak self] in _ = self?.installStaged() },
            dismiss: {}
        )))
    }

    /// The staged update, or nil when nothing waits for the user.
    var stagedItem: SUAppcastItem? {
        stagedInstall == nil ? nil : backgroundItem
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
    /// version, so the next check offers the update again.
    func cancelStaged() {
        guard let cancel = stagedCancel else { return }
        log.append("background install: cancelling the staged update's installer")
        stagedInstall = nil
        stagedCancel = nil
        installsWhenStaged = false
        backgroundItem = nil
        setState(.idle)
        cancel()
    }
}

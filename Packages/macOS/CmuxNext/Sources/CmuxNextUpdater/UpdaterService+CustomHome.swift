import CmuxUpdater
import Foundation

/// An app in a custom home (the release rollback drill's throwaway home: `HOME` other than the
/// account's, `CFFIXED_USER_HOME` set) comes back in it after an update. Sparkle relaunches through
/// LaunchServices, which starts the new build with the login session's environment, so the
/// relaunched app would write the account's real cmux folders and defaults. There the app quits
/// for the install and its helper reopens it with `open --env` (``RelaunchHome``); in the account's
/// own home nothing changes and Sparkle relaunches as before.
extension UpdaterService {
    /// What a nil ``reopenInHome`` runs: the relaunch helper, opening the app in front with `open --env`. A quit the
    /// person refuses (a quit dialog's Cancel) stops it, and the update stays staged.
    func startReopenInHome(willQuit: @escaping @MainActor () async -> Bool, declined: @escaping @MainActor () -> Void) {
        let helper = UpdateRelaunchBehind(app: Bundle.main.bundleURL, bundleIdentifier: Bundle.main.bundleIdentifier ?? "", behind: false)
        onNextQuitRefused?({ helper.quitRefused() })
        helper.start(willQuit: willQuit, declined: declined, inFront: declined)
    }

    public var updaterRunsInCustomHome: Bool { !RelaunchHome.openArguments().isEmpty }

    public func updaterReopensInItsHome(build: String, declined: @escaping @MainActor () -> Void) {
        log.append("will install \(build); relaunching in the app's own home: quitting for the install, then open --env")
        // What Sparkle's `willInstallUpdate` would run (keep the running build for rollback), as the automatic quit does.
        updaterWillInstallUpdate(build: build)
        let reopen = reopenInHome ?? { [weak self] willQuit, declined in
            guard let self else { return declined() }
            self.startReopenInHome(willQuit: willQuit, declined: declined)
        }
        reopen({ [weak self] in
            self?.updaterWillRelaunchApplication()
            return true
        }, { [weak self] in
            self?.log.append("update relaunch in a custom home: the app did not quit; the update waits for a click")
            self?.abandonInstall()
            declined()
        })
    }
}

import Foundation

/// Update relaunches: every relaunch waits for the host's session capture, and an automatic
/// install also waits in ``UpdateRelaunchGate`` for a quiet moment.
extension UpdateDriver {
    /// Sparkle asks this once before every install that relaunches cmux: Install and Relaunch,
    /// Restart Now on the install-on-quit prompt, and an automatic install started by
    /// ``beginAutomaticInstall(_:)``. It always holds the relaunch, because the host needs a
    /// moment to capture every agent session before the relaunch save (see
    /// ``UpdateActionDelegate/updaterPrepareForRelaunch()``).
    ///
    /// An install the user asked for relaunches as soon as that capture finishes (#15084). An
    /// automatic install waits in ``UpdateRelaunchGate`` for a quiet moment first.
    func handleShouldPostponeRelaunch(installHandler: @escaping () -> Void) -> Bool {
        if automaticInstallRequested {
            automaticInstallRequested = false
            holdAutomaticRelaunch(install: installHandler)
        } else {
            relaunchAfterPreparing(install: installHandler)
        }
        return true
    }

    /// Starts installing an update Sparkle downloaded in the background, for a user who turned
    /// on automatic installs. Sparkle's immediate-install block leads straight back to
    /// ``handleShouldPostponeRelaunch(installHandler:)``, which holds it for a quiet moment.
    func beginAutomaticInstall(_ immediateInstall: @escaping () -> Void) {
        log.append("automatic install: starting")
        automaticInstallRequested = true
        immediateInstall()
    }

    /// Ends any relaunch hold because the update session that owned it ended.
    func endRelaunchHold() {
        automaticInstallRequested = false
        relaunchGate.cancel()
    }

    private func currentReadiness() -> UpdateRelaunchGate.Readiness {
        guard let actionDelegate else {
            return .init(blockers: .empty, idle: .seconds(Int64.max))
        }
        return .init(
            blockers: actionDelegate.updaterRelaunchBlockers(),
            idle: actionDelegate.updaterTimeSinceLastUserInput()
        )
    }

    private func prepareForRelaunch() async {
        await actionDelegate?.updaterPrepareForRelaunch()
    }

    /// Runs the host's pre-relaunch capture, then `install`. `install` runs at most once.
    private func relaunchAfterPreparing(install: @escaping () -> Void) {
        let once = InstallOnce(install)
        Task { @MainActor [weak self] in
            await self?.prepareForRelaunch()
            once.run()
        }
    }

    /// Holds an automatic install's relaunch until a quiet moment. Later leaves the downloaded
    /// update on "Restart to Complete Update"; Sparkle still installs it when cmux quits.
    private func holdAutomaticRelaunch(install: @escaping () -> Void) {
        let once = InstallOnce(install)
        relaunchGate.hold(
            readiness: { [weak self] in
                self?.currentReadiness() ?? .init(blockers: .empty, idle: .zero)
            },
            isShown: { [weak self] in
                guard case .installing(let installing) = self?.model.state else { return false }
                return installing.relaunchBlockers != nil
            },
            publish: { [weak self] state in self?.setState(state) },
            prepare: { [weak self] in await self?.prepareForRelaunch() },
            relaunch: once.run,
            later: { [weak self] in self?.showRestartToComplete(install: once.run) }
        )
    }

    /// The postponed Sparkle session stays open until `install` runs, so this state keeps it
    /// reachable: Restart Later only closes the popover (dropping `install` would leave every
    /// later check waiting on a session that never ends), and Restart Now relaunches at most once.
    private func showRestartToComplete(install: @escaping () -> Void) {
        setState(.installing(.init(
            isAutoUpdate: true,
            retryTerminatingApplication: { [weak self] in
                guard let self else {
                    install()
                    return
                }
                self.relaunchAfterPreparing(install: install)
            },
            dismiss: {}
        )))
    }
}

/// Runs a Sparkle install handler at most once.
private final class InstallOnce {
    private var install: (() -> Void)?

    init(_ install: @escaping () -> Void) {
        self.install = install
    }

    func run() {
        guard let install else { return }
        self.install = nil
        install()
    }
}

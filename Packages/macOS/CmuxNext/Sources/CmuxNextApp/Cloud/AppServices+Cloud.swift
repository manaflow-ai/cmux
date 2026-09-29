import CmuxNextActions
import CmuxNextDaemon
import Observation

extension AppServices {
    /// The daemon of the active window's workspace: the local daemon, or its
    /// Cloud machine. Focus-scoped handlers (tab, pane, workspace verbs)
    /// command this daemon, so they act on a Cloud workspace the same way.
    var activeDaemon: DaemonService {
        windows?.active.flatMap { machines.daemon(machine: $0.state.machineID) } ?? daemon
    }

    /// Publishes `signedIn` / `signedOut` / `cloudWorkspace` to the action
    /// registry. `cloudWorkspace` means "a Cloud machine exists", so the
    /// palette offers machine actions; each handler still resolves its
    /// machine (explicit target, the window's machine, or the only one).
    func cloudContextDidChange() {
        var context = registry.context
        let signedIn = cloud.isSignedIn
        context.remove([.signedIn, .signedOut, .cloudWorkspace])
        context.insert(signedIn ? .signedIn : .signedOut)
        if signedIn, !machines.cloud.isEmpty { context.insert(.cloudWorkspace) }
        if registry.context != context { registry.context = context }
    }

    /// Starts Cloud and keeps the registry context current.
    func startCloud() -> Task<Void, Never> {
        cloud.start()
        let cloud = cloud!, machines = machines
        return Task { [weak self] in
            var account: String?
            for await state in Observations({ (cloud.isSignedIn, machines.cloud.count, cloud.auth.user?.id, cloud.auth.teamID) }) {
                guard let self else { return }
                self.cloudContextDidChange()
                // Phone access follows the account: start after sign-in,
                // restart on a user or team switch, stop on sign-out.
                let current = state.0 ? state.2.flatMap { user in state.3.map { "\(user)/\($0)" } } : nil
                guard current != account else { continue }
                account = current
                if let auth = CloudMobileAuth(auth: cloud.auth) {
                    self.mobile.start(auth: auth, launch: self.environment.launch, daemon: self.daemon)
                } else {
                    self.mobile.stop()
                }
            }
        }
    }
}

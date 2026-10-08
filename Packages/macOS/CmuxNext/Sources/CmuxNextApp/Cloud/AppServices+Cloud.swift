import CmuxNextActions
import CmuxNextDaemon
import CmuxNextMobileConnect
import Observation

extension AppServices {
    /// The daemon handlers command: while an action runs, the machine that
    /// owns its explicit target (`ActionRouting`); otherwise the active
    /// window's machine (the local daemon, or its Cloud machine).
    var activeDaemon: DaemonService {
        if let routedDaemon { return routedDaemon }
        guard let machine = windows?.active?.state.machineID else { return daemon }
        // A window of a machine turned off by policy (DisabledFeatures) keeps
        // its blocked daemon: commands fail there, never land on this Mac.
        return machines.daemon(machine: machine) ?? machines.anyDaemon(machine: machine) ?? daemon
    }

    /// Publishes `signedIn` / `signedOut` / `cloudWorkspace` to the action
    /// registry. `cloudWorkspace` means the active window shows a Cloud
    /// machine's workspace, so the palette offers machine actions for it.
    /// An explicit `machine:` target satisfies it too
    /// (`ActionContext.implied(by:)`), so the CLI and a right-click on a
    /// machine header work from any window.
    func cloudContextDidChange() {
        var context = registry.context
        let signedIn = cloud.isSignedIn
        context.remove([.signedIn, .signedOut, .cloudWorkspace])
        context.insert(signedIn ? .signedIn : .signedOut)
        if signedIn, let machine = windows?.active?.state.machineID, machines.session(machine) != nil {
            context.insert(.cloudWorkspace)
        }
        if registry.context != context { registry.context = context }
    }

    /// Starts Cloud and keeps the registry context current.
    func startCloud() -> Task<Void, Never> {
        cloud.start()
        let cloud = cloud!, machines = machines
        let apiBaseURL = feed.apiBaseURL, launch = environment.launch
        // The phone link runs as this Mac's install for the signed-in account.
        AppMobileLinkServices.configure(self, cloud: cloud, apiBaseURL: apiBaseURL, launch: launch)
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

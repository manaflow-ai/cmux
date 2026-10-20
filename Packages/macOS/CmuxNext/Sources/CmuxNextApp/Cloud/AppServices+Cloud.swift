import CmuxNextActions
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextHomeEngine
import CmuxNextMobileHost
import CmuxNextPhoneAccess
import Observation

extension AppServices {
    /// The daemon handlers command: while an action runs, the machine that
    /// owns its explicit target (`ActionRouting`); otherwise the active
    /// window's machine (the local daemon, or its Cloud machine).
    var activeDaemon: DaemonService {
        if let routedDaemon { return routedDaemon }
        guard let machine = windows.active?.state.machineID else { return daemon }
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
        if signedIn, let machine = windows.active?.state.machineID, machines.session(machine) != nil {
            context.insert(.cloudWorkspace)
        }
        if registry.context != context { registry.context = context }
    }

    /// Starts Cloud and keeps the registry context current.
    func startCloud() -> Task<Void, Never> {
        cloud.confirmWindow = { [weak self] in self?.windows.active?.window }
        cloud.start()
        iphone.wire(auth: cloud.auth, daemon: daemon, acpmuxHost: { [weak self] in self?.agentTabs.host }, acpmuxEnvironment: QuitAgents.environment(self),
                    agentTabHost: { [weak self] in self?.agentTabs.localHost },
                    newChatPicks: { [weak self] in
                        NewChatPicks(lastAgent: self?.newTabChoices.agent, picks: self?.newTabChoices.picks)
                    },
                    // hostd serves phones this build's own Chief (a DEV or tagged build's is not the default home).
                    chief: { [weak self] in
                        guard let owner = self?.home.chief else { return nil }
                        return IPhoneHostService.ChiefPlacement(session: owner.home.session, socket: await owner.socketPath())
                    },
                    settings: { [weak self] in self?.settings },
                    bundleID: environment.launch.bundleID, computerName: { await MacName().computerName() })
        iphone.pairWindow = { [weak self] in self?.windows.active?.window }
        iphone.pairNotices = IPhonePairNotices(post: { [weak self] in self?.notifications.desktop.post(id: IPhonePairNotices.id, title: $0,
            body: $1, surface: nil, workspace: nil, defaultSound: true, category: IPhonePairNotices.category) },
            withdraw: { [weak self] in self?.notifications.desktop.withdraw([IPhonePairNotices.id]) })
        let cloud = cloud, machines = machines
        return Task { [weak self] in
            var account: String?
            var routerUser: String??
            for await state in ObservationStream({ (cloud.isSignedIn, machines.cloud.count, cloud.auth.user?.id, cloud.auth.teamID) }) {
                guard let self else { return }
                self.cloudContextDidChange()
                // The local model relay follows the signed-in user (ModelRouterLease).
                let user = state.0 ? state.2 : nil
                if routerUser != .some(user) {
                    routerUser = .some(user)
                    self.modelRouter?.accountChanged(user)
                }
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

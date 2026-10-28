import CmuxNextMobile
import CmuxNextWakeups

/// What the host follows once wired: hostd's streams, read off main and applied as visible
/// tasks, and the setting, the account, the workspace folders and the New Tab picks, each one
/// `ServiceObservation` on the app's scheduler (a person's settings edit or sign-in applies in their turn).
extension IPhoneHostService {
    /// Follows hostd's state and pairing streams off main (R-hop): each item applies as one visible task, in
    /// the order hostd reported it. Once, when wired: before that nothing starts hostd.
    func followSupervisor(on mainWork: MainWorkScheduler) {
        guard watching == nil else { return }
        let states = supervisor.states, pairing = supervisor.pairing
        // task-owner: lives as long as the app; follows the supervisor's state stream
        watching = Task { @concurrent [weak self] in
            for await next in states {
                guard self != nil else { return }
                mainWork.postFromAnyThread(.visible, owner: "IPhoneHost.state") { [weak self] in self?.stateArrived(next) }
            }
        }
        // task-owner: lives as long as the app; answers hostd's pairing requests in order
        pairingWatch = Task { @concurrent [weak self] in
            for await event in pairing {
                guard self != nil else { return }
                mainWork.postFromAnyThread(.visible, owner: "IPhoneHost.pairing") { [weak self] in self?.pairingEvent(event) }
            }
        }
    }

    /// Follows the setting: every writer (the Settings page, `cmux settings`, an
    /// edit of cmux.json) reaches the host through the settings file. `visible`: Settings > Mobile shows it.
    func follow(allowed read: @escaping @MainActor @Sendable () -> Bool, on mainWork: MainWorkScheduler) {
        following?.cancel()
        following = ServiceObservation(.visible, owner: "IPhoneHost.allowed", on: mainWork, read: read) { [weak self] value in
            self?.setAllowed(value)
        }
    }

    /// Follows the signed-in account (sign-in, sign-out, a user or team switch).
    func followAccount(_ read: @escaping @MainActor @Sendable () -> Account?, on mainWork: MainWorkScheduler) {
        followingAccount?.cancel()
        followingAccount = ServiceObservation(.visible, owner: "IPhoneHost.account", on: mainWork, read: read) { [weak self] account in
            self?.accountChanged(account)
        }
    }

    /// Hands acpmux the folders of this Mac's workspaces while iPhone connections are allowed
    /// for a signed-in account (none otherwise), so a phone's agent chat starts there.
    /// `background`: nothing on screen waits for acpmux to hold them.
    func followWorkspaceFolders(on mainWork: MainWorkScheduler) {
        followingFolders?.cancel()
        followingFolders = ServiceObservation(.background, owner: "IPhoneHost.workspaceFolders", on: mainWork) { [weak self] in
            guard let self, allowed, account != nil else { return [String]() }
            return dependencies?.workspaceFolders() ?? []
        } apply: { [weak self] folders in
            guard let self else { return }
            (folders.isEmpty ? approverSync : ensureApproverSync())?.updateWorkspaceRoots(folders)
        }
    }

    /// Hands acpmux the agent and model this Mac's New Tab page picked last while iPhone
    /// connections are allowed for a signed-in account, so a phone's New Agent Chat starts
    /// where this Mac's does (the Mac keeps them locally: `newTab.lastAgent`, `newTab.lastPicks`).
    func followNewChatPicks(on mainWork: MainWorkScheduler) {
        followingPicks?.cancel()
        followingPicks = ServiceObservation(.background, owner: "IPhoneHost.newChatPicks", on: mainWork) { [weak self] () -> NewChatPicks? in
            guard let self, allowed, account != nil else { return nil }
            return dependencies?.newChatPicks()
        } apply: { [weak self] picks in
            guard let self else { return }
            guard let picks, !picks.isEmpty else {
                // Off, signed out or nothing picked: acpmux forgets what it holds.
                approverSync?.updateNewChatPicks(nil)
                return
            }
            ensureApproverSync()?.updateNewChatPicks(picks.params)
        }
    }

    /// The approver sync on the app's scheduler, made on first need; nil before ``wire`` or without agents.
    @discardableResult
    func ensureApproverSync() -> MobileHostApproverSync? {
        if let approverSync { return approverSync }
        guard let environment = dependencies?.acpmuxEnvironment, let deadlines else { return nil }
        let sync = MobileHostApproverSync(environment: environment, deadlines: deadlines)
        approverSync = sync
        return sync
    }
}

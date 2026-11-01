import CmuxNextDaemon
import CmuxNextMobile

/// Phones never see an incognito workspace (leo-workspace design/spaces.md "Incognito"; spaces-incognito-audit
/// leak 3): the phone gate hides `ids` (the incognito windows' workspaces, claimed ones still being created
/// included) and every ephemeral workspace the local daemon flags, before or after a window lists it.
@MainActor enum PhoneIncognitoHiding {
    static func publish(_ ids: Set<String>, _ windows: WindowManager) {
        windows.services.mobile.access.setHiddenWorkspaces(ids.union(ephemeralIDs(windows.services.daemon)))
    }

    /// The workspaces `daemon` flags ephemeral. Membership observes them (`observeMembership`): a flag can land
    /// after reconcile placed its workspace in a normal window, and phones hide it then (#31039).
    static func ephemeralIDs(_ daemon: DaemonService) -> Set<String> {
        Set(daemon.store.workspaces.lazy.filter(\.ephemeral).map(\.id))
    }
}

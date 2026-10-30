/// What ``CloudWorkspaceAbsences`` reads of the app: the machines, the window state and the Cloud account.
@MainActor public protocol CloudWorkspaceAbsenceHost: AnyObject {
    /// A machine's tree lists workspace `id` now.
    func cloudAbsenceIsListed(workspace id: String) -> Bool
    /// The machine workspace `id` was last seen on (this run, or the saved window record), if any.
    func cloudAbsenceSavedMachine(workspace id: String) -> String?
    /// `machineID` names a Cloud machine (not this Mac, an SSH machine or a paired server).
    func cloudAbsenceIsCloudMachine(_ machineID: String) -> Bool
    /// Workspace `id` is known gone (its machine loaded without it, or it left the account).
    func cloudAbsenceIsGone(workspace id: String) -> Bool
    /// cmux Cloud is turned on here, the person is signed in, the saved sign-in is still restoring.
    func cloudAbsenceAccount() -> (cloudOn: Bool, signedIn: Bool, restoring: Bool)
    /// The account's machine list has `machineID`, and it runs (not paused).
    func cloudAbsenceMachine(_ machineID: String) -> (listed: Bool, live: Bool)
}

/// Which workspaces a window keeps while no machine lists them, and why (P-AUSTIN B7): a Cloud
/// workspace that is not gone, while signed out, Cloud off, or its machine paused or not loaded.
/// Built once by the composition root; windows and sidebars ask it, so none of them decides alone.
@MainActor public final class CloudWorkspaceAbsences {
    private weak var host: (any CloudWorkspaceAbsenceHost)?

    public init(host: any CloudWorkspaceAbsenceHost) {
        self.host = host
    }

    /// Why workspace `id` shows as not connected, or nil: a machine lists it, it is gone, or it is not
    /// on a Cloud machine.
    public func absence(of id: String) -> CloudWorkspaceAbsence? {
        guard let host, !host.cloudAbsenceIsListed(workspace: id), let machine = host.cloudAbsenceSavedMachine(workspace: id),
              host.cloudAbsenceIsCloudMachine(machine), !host.cloudAbsenceIsGone(workspace: id) else { return nil }
        let account = host.cloudAbsenceAccount(), state = host.cloudAbsenceMachine(machine)
        return CloudWorkspaceAbsence(cloudOn: account.cloudOn, signedIn: account.signedIn, restoring: account.restoring,
                                     machineListed: state.listed, machineLive: state.live)
    }
}

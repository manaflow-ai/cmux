public import CmuxNextCloud
public import CmuxNextMobile

extension MobileHostCloudLink {
    /// One Cloud machine as hostd's directory sees it: its live link socket when there is one
    /// (none: asleep), its status, and whether it has run.
    ///
    /// Ownership: a live link carries the Cloud API's caller-relative answer (`vmKind == "owner"`).
    /// Without one, the link's last ownership answer (`cachedOwner`, the same `vmKind`; false until
    /// one came) or else the machine record's creator, since the attach answer gives a machine's
    /// creator `owner` too (#28788). A record without a creator is never owned here, so hostd never
    /// serves a teammate's machine as the caller's.
    public init(machine: CloudMachine, machineID: String, teamID: String, socket: CloudLinkSocket?, cachedOwner: Bool,
                user: String) {
        self.init(machineID: socket?.key.machine ?? machineID, teamID: teamID, name: machine.shownName ?? machineID,
                  socket: socket?.path, owner: socket?.callerOwnsVM ?? (cachedOwner || machine.createdBy == user),
                  status: machine.shownStatus.rawValue, ran: machine.hasRun)
    }
}

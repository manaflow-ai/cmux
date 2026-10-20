/// Where a workspace made with "New Workspace" in a group runs (remote-groups-DESIGN.md R6).
struct GroupSpawnHost<Machine: AnyObject> {
    /// The machine each current member of the group runs on.
    let memberHomes: [Machine]
    /// This Mac's machine.
    let local: Machine

    /// Today every group workspace is made on this Mac.
    var host: Machine { local }
}

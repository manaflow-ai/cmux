/// A persisted binding between a workspace and a cmux-tui cloud machine.
struct SessionCloudVMBindingSnapshot: Codable, Sendable, Equatable {
    var vmID: String
    var isBase: Bool
    /// The machine's cmux-tui workspace this local workspace stands for; absent in
    /// legacy snapshots and for machine-only bindings (`vm shell`).
    var remoteWorkspaceID: String? = nil
}

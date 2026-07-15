/// Capability and connection gate shared by every workspace-diff entry point.
struct WorkspaceDiffEntryGate: Sendable, Equatable {
    let supportsWorkspaceDiffs: Bool
    let isConnected: Bool

    var canPresent: Bool {
        supportsWorkspaceDiffs && isConnected
    }
}

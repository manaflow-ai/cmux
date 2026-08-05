/// Which Mac contributes rows to the workspace list.
enum WorkspaceMacSelection: Hashable, Sendable {
    case automatic
    case all
    /// A pairing id for saved app instances, or a bare device id for an
    /// unpaired workspace-only computer.
    case machine(String)
}

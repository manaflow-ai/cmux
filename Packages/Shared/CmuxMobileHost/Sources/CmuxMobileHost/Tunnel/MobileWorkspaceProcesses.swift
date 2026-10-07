/// The processes of the user's workspaces (the app fills it from the daemon's
/// terminal process trees). Only their listeners are detected as dev servers.
public protocol MobileWorkspaceProcesses: Sendable {
    func processes() async -> [MobileWorkspaceProcess]
}

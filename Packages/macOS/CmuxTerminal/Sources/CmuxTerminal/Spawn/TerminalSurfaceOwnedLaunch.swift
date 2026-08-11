/// A resolved launch and the resources that must remain valid for its process.
public struct TerminalSurfaceOwnedLaunch: Sendable {
    /// The immutable process launch request.
    public let resolvedLaunch: TerminalSurfaceResolvedLaunch
    /// The installed command-shim directory, when the launch uses one.
    public let commandShimLease: TerminalSurfaceAgentCommandShimLease?

    /// Creates a launch with its optional command-shim resource lease.
    public init(
        resolvedLaunch: TerminalSurfaceResolvedLaunch,
        commandShimLease: TerminalSurfaceAgentCommandShimLease?
    ) {
        self.resolvedLaunch = resolvedLaunch
        self.commandShimLease = commandShimLease
    }
}

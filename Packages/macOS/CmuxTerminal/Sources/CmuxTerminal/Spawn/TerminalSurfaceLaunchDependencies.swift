/// Pure launch assembly inputs shared by embedded and daemon-owned terminals.
///
/// Shell configuration is exposed through narrow closures instead of a
/// ``TerminalEngineHosting`` reference, so daemon launch resolution cannot
/// reach a native surface constructor.
@MainActor
public struct TerminalSurfaceLaunchDependencies {
    public let spawnPolicyProvider: any TerminalSurfaceSpawnPolicyProviding
    public let runtimeFilesystem: TerminalSurfaceRuntimeFilesystem
    public let sessionPortBase: Int
    public let sessionPortRangeSize: Int
    public let userGhosttyShellIntegrationMode: @MainActor () -> String
    public let resolvedUserShell: @MainActor () -> String?
    public let userGhosttyCommand: @MainActor () -> GhosttyConfiguredCommand?
    public let agentCommandShimInstallDeadline: Duration
    public let agentCommandShimInstallDeadlineClock: any Clock<Duration>

    public init(
        spawnPolicyProvider: any TerminalSurfaceSpawnPolicyProviding,
        runtimeFilesystem: TerminalSurfaceRuntimeFilesystem,
        sessionPortBase: Int,
        sessionPortRangeSize: Int,
        userGhosttyShellIntegrationMode: @escaping @MainActor () -> String,
        resolvedUserShell: @escaping @MainActor () -> String? = { nil },
        userGhosttyCommand: @escaping @MainActor () -> GhosttyConfiguredCommand? = { nil },
        agentCommandShimInstallDeadline: Duration = .seconds(5),
        agentCommandShimInstallDeadlineClock: any Clock<Duration> = ContinuousClock()
    ) {
        self.spawnPolicyProvider = spawnPolicyProvider
        self.runtimeFilesystem = runtimeFilesystem
        self.sessionPortBase = sessionPortBase
        self.sessionPortRangeSize = sessionPortRangeSize
        self.userGhosttyShellIntegrationMode = userGhosttyShellIntegrationMode
        self.resolvedUserShell = resolvedUserShell
        self.userGhosttyCommand = userGhosttyCommand
        self.agentCommandShimInstallDeadline = agentCommandShimInstallDeadline
        self.agentCommandShimInstallDeadlineClock = agentCommandShimInstallDeadlineClock
    }
}

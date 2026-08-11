/// Pure launch assembly inputs shared by embedded and daemon-owned terminals.
///
/// Shell configuration is exposed through narrow closures instead of a
/// ``TerminalEngineHosting`` reference, so daemon launch resolution cannot
/// reach a native surface constructor.
@MainActor
public struct TerminalSurfaceLaunchDependencies {
    /// Selects the process spawn policy for each launch request.
    public let spawnPolicyProvider: any TerminalSurfaceSpawnPolicyProviding
    /// Provides the filesystem locations and shim installer used during launch.
    public let runtimeFilesystem: TerminalSurfaceRuntimeFilesystem
    /// The first port available to terminal sessions.
    public let sessionPortBase: Int
    /// The number of consecutive ports available from ``sessionPortBase``.
    public let sessionPortRangeSize: Int
    /// Reads the current Ghostty shell-integration mode.
    public let userGhosttyShellIntegrationMode: @MainActor () -> String
    /// Resolves the user's login shell, or returns `nil` to use the fallback shell.
    public let resolvedUserShell: @MainActor () -> String?
    /// Reads the configured direct Ghostty command, or returns `nil` for a shell launch.
    public let userGhosttyCommand: @MainActor () -> GhosttyConfiguredCommand?
    /// The maximum time allowed for one per-surface shim installation.
    public let agentCommandShimInstallDeadline: Duration
    /// The cancellable clock used to enforce ``agentCommandShimInstallDeadline``.
    public let agentCommandShimInstallDeadlineClock: any Clock<Duration>

    /// Creates the shared launch dependencies for embedded and daemon-owned terminals.
    ///
    /// - Parameters:
    ///   - spawnPolicyProvider: The provider that selects the process spawn policy.
    ///   - runtimeFilesystem: The runtime filesystem and shim installation services.
    ///   - sessionPortBase: The first port available to terminal sessions.
    ///   - sessionPortRangeSize: The number of consecutive session ports.
    ///   - userGhosttyShellIntegrationMode: A closure that reads the current shell-integration mode.
    ///   - resolvedUserShell: A closure that returns the user's shell. The default defers to the fallback shell.
    ///   - userGhosttyCommand: A closure that returns the configured direct command. The default requests a shell launch.
    ///   - agentCommandShimInstallDeadline: The shim installation deadline. The default is five seconds.
    ///   - agentCommandShimInstallDeadlineClock: The cancellable deadline clock. The default is ``ContinuousClock``.
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

/// Pure launch assembly inputs shared by embedded and daemon-owned terminals.
///
/// The shell-integration value is exposed through a narrow closure instead of
/// a ``TerminalEngineHosting`` reference, so daemon launch resolution cannot
/// reach an in-process Ghostty app or native surface constructor.
@MainActor
public struct TerminalSurfaceLaunchDependencies {
    public let spawnPolicyProvider: any TerminalSurfaceSpawnPolicyProviding
    public let runtimeFilesystem: TerminalSurfaceRuntimeFilesystem
    public let sessionPortBase: Int
    public let sessionPortRangeSize: Int
    public let userGhosttyShellIntegrationMode: @MainActor () -> String

    public init(
        spawnPolicyProvider: any TerminalSurfaceSpawnPolicyProviding,
        runtimeFilesystem: TerminalSurfaceRuntimeFilesystem,
        sessionPortBase: Int,
        sessionPortRangeSize: Int,
        userGhosttyShellIntegrationMode: @escaping @MainActor () -> String
    ) {
        self.spawnPolicyProvider = spawnPolicyProvider
        self.runtimeFilesystem = runtimeFilesystem
        self.sessionPortBase = sessionPortBase
        self.sessionPortRangeSize = sessionPortRangeSize
        self.userGhosttyShellIntegrationMode = userGhosttyShellIntegrationMode
    }
}

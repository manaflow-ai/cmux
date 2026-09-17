internal import Foundation

/// Capabilities that can create and destroy an in-process Ghostty surface.
///
/// Only the embedded initializer accepts this type. Persistent backend
/// composition never constructs or stores it.
public struct TerminalSurfaceEmbeddedRuntimeDependencies {
    /// The in-process Ghostty engine that owns native surface handles.
    public let engine: any TerminalEngineHosting
    /// The output tee bound to the lifetime of each embedded surface.
    public let byteTee: any TerminalByteTeeBinding
    /// The scheduler that realizes embedded renderer presentations.
    public let rendererRealization: any TerminalRendererRealizationScheduling
    /// The coordinator that proves native runtime teardown is complete.
    public let runtimeTeardown: TerminalSurfaceRuntimeTeardownCoordinator
    /// The scheduler that paces restored embedded surface creation.
    public let restoreSpawnScheduler: any TerminalSurfaceRuntimeSpawnScheduling
    /// The filesystem services that install and remove per-surface command shims.
    public let runtimeFilesystem: TerminalSurfaceRuntimeFilesystem
    /// The single fixed app-bundle inspection shared by embedded launches.
    public let launchResourceProvider: TerminalSurfaceLaunchResourceProvider
    /// The maximum time that shim installation may delay native surface creation.
    public let agentCommandShimInstallDeadline: Duration
    /// The injected cancellable clock that enforces the shim installation deadline.
    public let agentCommandShimInstallDeadlineClock: any Clock<Duration>
    /// The first TCP port assigned to terminal sessions.
    public let sessionPortBase: Int
    /// The number of consecutive ports reserved for each session ordinal.
    public let sessionPortRangeSize: Int

    /// Creates the complete capability set for one embedded Ghostty owner.
    ///
    /// The surface lifecycle retains these dependencies. The injected
    /// filesystem owns shim installation and removal, while `runtimeTeardown`
    /// owns native handle reclamation. A `nil` resource provider creates one
    /// process-local snapshot of `Bundle.main` resources.
    ///
    /// - Parameters:
    ///   - engine: The in-process Ghostty engine.
    ///   - byteTee: The embedded output tee.
    ///   - rendererRealization: The renderer presentation scheduler.
    ///   - runtimeTeardown: The native runtime teardown coordinator.
    ///   - restoreSpawnScheduler: The restored-surface spawn scheduler.
    ///   - runtimeFilesystem: The command-shim filesystem services.
    ///   - launchResourceProvider: An optional shared bundle-resource snapshot provider.
    ///   - agentCommandShimInstallDeadline: The maximum shim installation delay.
    ///   - agentCommandShimInstallDeadlineClock: The cancellable deadline clock.
    ///   - sessionPortBase: The first terminal session port.
    ///   - sessionPortRangeSize: The port count reserved per session ordinal.
    public init(
        engine: any TerminalEngineHosting,
        byteTee: any TerminalByteTeeBinding,
        rendererRealization: any TerminalRendererRealizationScheduling,
        runtimeTeardown: TerminalSurfaceRuntimeTeardownCoordinator,
        restoreSpawnScheduler: any TerminalSurfaceRuntimeSpawnScheduling,
        runtimeFilesystem: TerminalSurfaceRuntimeFilesystem,
        launchResourceProvider: TerminalSurfaceLaunchResourceProvider? = nil,
        agentCommandShimInstallDeadline: Duration = .seconds(5),
        agentCommandShimInstallDeadlineClock: any Clock<Duration> = ContinuousClock(),
        sessionPortBase: Int,
        sessionPortRangeSize: Int
    ) {
        self.engine = engine
        self.byteTee = byteTee
        self.rendererRealization = rendererRealization
        self.runtimeTeardown = runtimeTeardown
        self.restoreSpawnScheduler = restoreSpawnScheduler
        self.runtimeFilesystem = runtimeFilesystem
        self.launchResourceProvider = launchResourceProvider
            ?? TerminalSurfaceLaunchResourceProvider(
                resourceURL: Bundle.main.resourceURL,
                isExecutableFile: runtimeFilesystem.isExecutableFile,
                directoryExists: runtimeFilesystem.directoryExists
            )
        self.agentCommandShimInstallDeadline = agentCommandShimInstallDeadline
        self.agentCommandShimInstallDeadlineClock = agentCommandShimInstallDeadlineClock
        self.sessionPortBase = sessionPortBase
        self.sessionPortRangeSize = sessionPortRangeSize
    }
}

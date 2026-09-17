public import CmuxTerminalCore
internal import Foundation

/// Complete dependency graph for the legacy embedded Ghostty owner.
public struct TerminalSurfaceRuntimeDependencies {
    /// Dependencies shared by embedded and external presentations.
    public let presentation: TerminalSurfacePresentationDependencies

    /// Dependencies that own the embedded Ghostty runtime.
    public let embeddedRuntime: TerminalSurfaceEmbeddedRuntimeDependencies

    /// Creates a dependency graph from its presentation and runtime parts.
    public init(
        presentation: TerminalSurfacePresentationDependencies,
        embeddedRuntime: TerminalSurfaceEmbeddedRuntimeDependencies
    ) {
        self.presentation = presentation
        self.embeddedRuntime = embeddedRuntime
    }

    /// Compatibility initializer for existing embedded-only call sites.
    public init(
        registry: any TerminalSurfaceRegistering,
        engine: any TerminalEngineHosting,
        viewProvider: any TerminalSurfaceViewProviding,
        spawnPolicy: any TerminalSurfaceSpawnPolicyProviding,
        byteTee: any TerminalByteTeeBinding,
        rendererRealization: any TerminalRendererRealizationScheduling,
        hibernationRecorder: any AgentHibernationRecording,
        runtimeTeardown: TerminalSurfaceRuntimeTeardownCoordinator,
        restoreSpawnScheduler: any TerminalSurfaceRuntimeSpawnScheduling,
        runtimeFilesystem: TerminalSurfaceRuntimeFilesystem,
        launchResourceProvider: TerminalSurfaceLaunchResourceProvider? = nil,
        agentCommandShimInstallDeadline: Duration = .seconds(5),
        agentCommandShimInstallDeadlineClock: any Clock<Duration> = ContinuousClock(),
        sessionPortBase: Int,
        sessionPortRangeSize: Int,
        scrollbackReplayEnvironmentKey: String,
        globalFontMagnificationPercent: @escaping @Sendable () -> Int = { 100 }
    ) {
        presentation = TerminalSurfacePresentationDependencies(
            registry: registry,
            viewProvider: viewProvider,
            spawnPolicy: spawnPolicy,
            hibernationRecorder: hibernationRecorder,
            scrollbackReplayEnvironmentKey: scrollbackReplayEnvironmentKey,
            globalFontMagnificationPercent: globalFontMagnificationPercent
        )
        embeddedRuntime = TerminalSurfaceEmbeddedRuntimeDependencies(
            engine: engine,
            byteTee: byteTee,
            rendererRealization: rendererRealization,
            runtimeTeardown: runtimeTeardown,
            restoreSpawnScheduler: restoreSpawnScheduler,
            runtimeFilesystem: runtimeFilesystem,
            launchResourceProvider: launchResourceProvider,
            agentCommandShimInstallDeadline: agentCommandShimInstallDeadline,
            agentCommandShimInstallDeadlineClock: agentCommandShimInstallDeadlineClock,
            sessionPortBase: sessionPortBase,
            sessionPortRangeSize: sessionPortRangeSize
        )
    }
}

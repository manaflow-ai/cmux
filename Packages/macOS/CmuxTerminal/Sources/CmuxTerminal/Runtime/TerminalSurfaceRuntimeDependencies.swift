public import CmuxTerminalCore
internal import Foundation

/// The font configuration values a presentation needs for durable lineage.
///
/// This value exposes no embedded Ghostty handle or runtime ownership.
public struct TerminalFontConfigurationSnapshot: Sendable, Equatable {
    public let generation: UInt64
    public let runtimePoints: Float32

    public init(generation: UInt64, runtimePoints: Float32) {
        self.generation = generation
        self.runtimePoints = runtimePoints
    }
}

/// Capabilities shared by embedded and externally-owned terminal presentations.
///
/// This bundle deliberately contains no Ghostty app/config handle, PTY output
/// tee, native-surface teardown queue, runtime filesystem, or spawn scheduler.
/// An external terminal can therefore be constructed without gaining an
/// accidental path back to process-local terminal ownership.
public struct TerminalSurfacePresentationDependencies {
    /// The process-wide surface registry.
    public let registry: any TerminalSurfaceRegistering

    /// The factory for the surface's native view pair.
    public let viewProvider: any TerminalSurfaceViewProviding

    /// Live settings reads folded into spawn environments.
    public let spawnPolicy: any TerminalSurfaceSpawnPolicyProviding

    /// The agent-hibernation input recorder.
    public let hibernationRecorder: any AgentHibernationRecording

    /// The environment key carrying one-shot session scrollback replay; the
    /// surface strips it after the first runtime spawn.
    public let scrollbackReplayEnvironmentKey: String

    /// Provides the app's current global font magnification percent.
    public let globalFontMagnificationPercent: @Sendable () -> Int

    /// Reads the current font configuration without exposing its runtime owner.
    public let fontConfigurationSnapshot:
        @MainActor @Sendable () -> TerminalFontConfigurationSnapshot?

    /// Creates the dependency bundle.
    public init(
        registry: any TerminalSurfaceRegistering,
        viewProvider: any TerminalSurfaceViewProviding,
        spawnPolicy: any TerminalSurfaceSpawnPolicyProviding,
        hibernationRecorder: any AgentHibernationRecording,
        scrollbackReplayEnvironmentKey: String,
        globalFontMagnificationPercent: @escaping @Sendable () -> Int = { 100 },
        fontConfigurationSnapshot: @escaping
            @MainActor @Sendable () -> TerminalFontConfigurationSnapshot? = { nil }
    ) {
        self.registry = registry
        self.viewProvider = viewProvider
        self.spawnPolicy = spawnPolicy
        self.hibernationRecorder = hibernationRecorder
        self.scrollbackReplayEnvironmentKey = scrollbackReplayEnvironmentKey
        self.globalFontMagnificationPercent = globalFontMagnificationPercent
        self.fontConfigurationSnapshot = fontConfigurationSnapshot
    }
}

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

/// Complete dependency graph for the legacy embedded Ghostty owner.
public struct TerminalSurfaceRuntimeDependencies {
    public let presentation: TerminalSurfacePresentationDependencies
    public let embeddedRuntime: TerminalSurfaceEmbeddedRuntimeDependencies

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

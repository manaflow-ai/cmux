public import CmuxTerminalCore

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

    /// The serialized native-surface free queue.
    public let runtimeTeardown: TerminalSurfaceRuntimeTeardownCoordinator

    /// The paced native-surface creation queue for restored terminal sessions.
    public let restoreSpawnScheduler: any TerminalSurfaceRuntimeSpawnScheduling

    /// Filesystem probes and writers used by runtime creation.
    public let runtimeFilesystem: TerminalSurfaceRuntimeFilesystem

    /// The bounded grace period runtime creation waits for the optional
    /// Claude command-shim install before spawning without it.
    ///
    /// The shim is a PATH convenience; a hung install must never starve PTY
    /// spawn (issue #9769). Defaults to five seconds.
    public let claudeCommandShimInstallDeadline: Duration

    /// The clock driving ``claudeCommandShimInstallDeadline``; injectable so
    /// tests control the deadline deterministically.
    public let claudeCommandShimInstallDeadlineClock: any Clock<Duration>

    /// The first port of the per-session `CMUX_PORT` allocation
    /// (snapshotted once per app session by the composition root).
    public let sessionPortBase: Int

    /// The per-workspace port range size (snapshotted once per app session
    /// by the composition root).
    public let sessionPortRangeSize: Int

    /// The environment key carrying one-shot session scrollback replay; the
    /// surface strips it after the first runtime spawn.
    public let scrollbackReplayEnvironmentKey: String

    /// Provides the app's current global font magnification percent.
    public let globalFontMagnificationPercent: @Sendable () -> Int

    /// Creates the dependency bundle.
    public init(
        registry: any TerminalSurfaceRegistering,
        viewProvider: any TerminalSurfaceViewProviding,
        spawnPolicy: any TerminalSurfaceSpawnPolicyProviding,
        hibernationRecorder: any AgentHibernationRecording,
        scrollbackReplayEnvironmentKey: String,
        globalFontMagnificationPercent: @escaping @Sendable () -> Int = { 100 }
    ) {
        self.registry = registry
        self.viewProvider = viewProvider
        self.spawnPolicy = spawnPolicy
        self.hibernationRecorder = hibernationRecorder
        self.scrollbackReplayEnvironmentKey = scrollbackReplayEnvironmentKey
        self.globalFontMagnificationPercent = globalFontMagnificationPercent
    }
}

/// Capabilities that can create and destroy an in-process Ghostty surface.
///
/// Only the embedded initializer accepts this type. Persistent backend
/// composition never constructs or stores it.
public struct TerminalSurfaceEmbeddedRuntimeDependencies {
    public let engine: any TerminalEngineHosting
    public let byteTee: any TerminalByteTeeBinding
    public let rendererRealization: any TerminalRendererRealizationScheduling
    public let runtimeTeardown: TerminalSurfaceRuntimeTeardownCoordinator
    public let restoreSpawnScheduler: any TerminalSurfaceRuntimeSpawnScheduling
    public let runtimeFilesystem: TerminalSurfaceRuntimeFilesystem
    public let sessionPortBase: Int
    public let sessionPortRangeSize: Int

    public init(
        engine: any TerminalEngineHosting,
        byteTee: any TerminalByteTeeBinding,
        rendererRealization: any TerminalRendererRealizationScheduling,
        runtimeTeardown: TerminalSurfaceRuntimeTeardownCoordinator,
        restoreSpawnScheduler: any TerminalSurfaceRuntimeSpawnScheduling,
        runtimeFilesystem: TerminalSurfaceRuntimeFilesystem,
        sessionPortBase: Int,
        sessionPortRangeSize: Int
    ) {
        self.engine = engine
        self.byteTee = byteTee
        self.rendererRealization = rendererRealization
        self.runtimeTeardown = runtimeTeardown
        self.restoreSpawnScheduler = restoreSpawnScheduler
        self.runtimeFilesystem = runtimeFilesystem
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
        claudeCommandShimInstallDeadline: Duration = .seconds(5),
        claudeCommandShimInstallDeadlineClock: any Clock<Duration> = ContinuousClock(),
        sessionPortBase: Int,
        sessionPortRangeSize: Int,
        scrollbackReplayEnvironmentKey: String,
        globalFontMagnificationPercent: @escaping @Sendable () -> Int = { 100 }
    ) {
        self.registry = registry
        self.engine = engine
        self.viewProvider = viewProvider
        self.spawnPolicy = spawnPolicy
        self.byteTee = byteTee
        self.rendererRealization = rendererRealization
        self.hibernationRecorder = hibernationRecorder
        self.runtimeTeardown = runtimeTeardown
        self.restoreSpawnScheduler = restoreSpawnScheduler
        self.runtimeFilesystem = runtimeFilesystem
        self.claudeCommandShimInstallDeadline = claudeCommandShimInstallDeadline
        self.claudeCommandShimInstallDeadlineClock = claudeCommandShimInstallDeadlineClock
        self.sessionPortBase = sessionPortBase
        self.sessionPortRangeSize = sessionPortRangeSize
        self.scrollbackReplayEnvironmentKey = scrollbackReplayEnvironmentKey
        self.globalFontMagnificationPercent = globalFontMagnificationPercent
    }
}

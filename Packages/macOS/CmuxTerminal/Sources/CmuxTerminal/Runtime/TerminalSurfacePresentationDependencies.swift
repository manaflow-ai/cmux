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

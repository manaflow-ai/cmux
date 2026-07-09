import Foundation

/// Settings under the dotted-id prefix `terminal.*`.
public struct TerminalCatalogSection: SettingCatalogSection {
    /// Default multiplier applied to terminal scroll deltas.
    public static let scrollSpeedDefault = 1.0
    /// Minimum allowed multiplier for terminal scroll deltas.
    public static let scrollSpeedMinimum = 0.25
    /// Maximum allowed multiplier for terminal scroll deltas.
    public static let scrollSpeedMaximum = 3.0

    public let showScrollBar = DefaultsKey<Bool>(
        id: "terminal.showScrollBar",
        defaultValue: true,
        userDefaultsKey: "terminal.showScrollBar"
    )

    public let copyOnSelect = DefaultsKey<Bool>(
        id: "terminal.copyOnSelect",
        defaultValue: false,
        userDefaultsKey: "terminal.copyOnSelect"
    )

    public let inlineImageThumbnails = DefaultsKey<Bool>(
        id: "terminal.inlineImageThumbnails",
        defaultValue: true,
        userDefaultsKey: "terminal.inlineImageThumbnails"
    )

    public let autoResumeAgentSessions = DefaultsKey<Bool>(
        id: "terminal.autoResumeAgentSessions",
        defaultValue: true,
        userDefaultsKey: "terminal.autoResumeAgentSessions"
    )

    public let agentHibernationEnabled = DefaultsKey<Bool>(
        id: "terminal.agentHibernation.enabled",
        defaultValue: false,
        userDefaultsKey: "terminal.agentHibernation.enabled"
    )

    public let agentHibernationIdleSeconds = DefaultsKey<Double>(
        id: "terminal.agentHibernation.idleSeconds",
        defaultValue: 5,
        userDefaultsKey: "terminal.agentHibernation.idleSeconds"
    )

    public let agentHibernationMaxLiveTerminals = DefaultsKey<Int>(
        id: "terminal.agentHibernation.maxLiveTerminals",
        defaultValue: 12,
        userDefaultsKey: "terminal.agentHibernation.maxLiveTerminals"
    )

    /// Whether off-screen terminals release their GPU renderer memory while
    /// idle (rebuilt instantly on re-show). Non-destructive; on by default.
    public let rendererRealizationEnabled = DefaultsKey<Bool>(
        id: "terminal.rendererRealization.enabled",
        defaultValue: true,
        userDefaultsKey: "terminal.rendererRealization.enabled"
    )

    /// Seconds a terminal must stay off-screen before its renderer memory is
    /// reclaimed.
    public let rendererRealizationIdleSeconds = DefaultsKey<Double>(
        id: "terminal.rendererRealization.idleSeconds",
        defaultValue: 30,
        userDefaultsKey: "terminal.rendererRealization.idleSeconds"
    )

    /// Most-recently-visible terminals to keep renderer-ready so switching stays
    /// instant. Extra off-screen renderers are reclaimed oldest first.
    public let rendererRealizationMaxWarmRenderers = DefaultsKey<Int>(
        id: "terminal.rendererRealization.maxWarmRenderers",
        defaultValue: 12,
        userDefaultsKey: "terminal.rendererRealization.maxWarmRenderers"
    )

    /// Opt-in throttle for high-frequency terminal title changes. Default-off
    /// so existing title freshness stays unchanged unless users choose the
    /// performance tradeoff.
    public let titleUpdateCoalescingEnabled = DefaultsKey<Bool>(
        id: "terminal.titleUpdates.coalescing.enabled",
        defaultValue: false,
        userDefaultsKey: "terminal.titleUpdates.coalescing.enabled"
    )

    /// Delay used when title-update coalescing is enabled.
    public let titleUpdateCoalescingMilliseconds = DefaultsKey<Int>(
        id: "terminal.titleUpdates.coalescing.delayMilliseconds",
        defaultValue: 500,
        userDefaultsKey: "terminal.titleUpdates.coalescing.delayMilliseconds",
        legacyUserDefaultsKeys: ["terminal.titleUpdates.coalescingMilliseconds"]
    )

    /// Enables DEBUG title-update enqueue/flush diagnostics.
    public let titleUpdateDiagnostics = DefaultsKey<Bool>(
        id: "terminal.titleUpdates.diagnostics",
        defaultValue: false,
        userDefaultsKey: "terminal.titleUpdates.diagnostics"
    )

    public let showTextBoxOnNewTerminals = DefaultsKey<Bool>(
        id: "terminal.showTextBoxOnNewTerminals",
        defaultValue: false,
        userDefaultsKey: "terminal.showTextBoxOnNewTerminals"
    )

    public let focusTextBoxOnNewTerminals = DefaultsKey<Bool>(
        id: "terminal.focusTextBoxOnNewTerminals",
        defaultValue: false,
        userDefaultsKey: "terminal.focusTextBoxOnNewTerminals"
    )

    public let textBoxMaxLines = DefaultsKey<Int>(
        id: "terminal.textBoxMaxLines",
        defaultValue: 10,
        userDefaultsKey: "terminal.textBoxMaxLines"
    )

    /// Default TextBox submit action used when a terminal is eligible to launch a new agent session.
    public let textBoxDefaultSubmitAction = DefaultsKey<String>(
        id: "terminal.textBoxDefaultSubmitAction",
        defaultValue: "text-entry",
        userDefaultsKey: "terminal.textBoxDefaultSubmitAction"
    )

    /// Configured TextBox submit action catalog encoded as JSON.
    public let textBoxSubmitActions = DefaultsKey<String>(
        id: "terminal.textBoxSubmitActions",
        defaultValue: "",
        userDefaultsKey: "terminal.textBoxSubmitActions"
    )

    public let resumeCommands = JSONKey<[String]>(
        id: "terminal.resumeCommands",
        defaultValue: []
    )

    /// Host-scoped rules that replace the built-in `scp` for terminal file
    /// drops/pastes over ssh; cmux runs the matching command and inserts its
    /// output. See ``TerminalUploadCommandRule``.
    public let uploadCommands = JSONKey<[TerminalUploadCommandRule]>(
        id: "terminal.uploadCommands",
        defaultValue: []
    )

    /// Multiplier applied to terminal scroll wheel and trackpad deltas.
    public let scrollSpeed = DefaultsKey<Double>(
        id: "terminal.scrollSpeed",
        defaultValue: TerminalCatalogSection.scrollSpeedDefault,
        userDefaultsKey: "terminal.scrollSpeed"
    )

    /// Whether the per-pane runaway-memory guardrail is active. When on, cmux
    /// polls each pane's process-tree memory and warns (badge + dismissible
    /// banner with a kill action) when one crosses the threshold, before the OS
    /// can OOM-suspend the whole app. On by default.
    public let runawayMemoryGuardrailEnabled = DefaultsKey<Bool>(
        id: "terminal.runawayMemoryGuardrail.enabled",
        defaultValue: true,
        userDefaultsKey: "terminal.runawayMemoryGuardrail.enabled"
    )

    /// Process-tree resident-memory threshold, in gigabytes, at which a pane is
    /// flagged as a runaway. Default 8 GB.
    public let runawayMemoryGuardrailThresholdGB = DefaultsKey<Double>(
        id: "terminal.runawayMemoryGuardrail.thresholdGB",
        defaultValue: 8,
        userDefaultsKey: "terminal.runawayMemoryGuardrail.thresholdGB"
    )

    public init() {}
}

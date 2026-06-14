import Foundation

/// Settings under the dotted-id prefix `terminal.*`.
public struct TerminalCatalogSection: SettingCatalogSection {
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

    /// The screen position used by the floating quick terminal panel.
    ///
    /// Valid values are `"top"`, `"bottom"`, `"left"`, `"right"`, and
    /// `"center"`. The default is `"top"`. The `UserDefaults` key intentionally
    /// uses the existing `quickTerminal.*` namespace so preferences written by
    /// the quick-terminal runtime continue to be read by the settings catalog.
    ///
    /// ```swift
    /// let key = SettingCatalog().terminal.quickTerminalPosition
    /// ```
    public let quickTerminalPosition = DefaultsKey<String>(
        id: "terminal.quickTerminalPosition",
        defaultValue: "top",
        userDefaultsKey: "quickTerminal.position"
    )

    /// The quick terminal size ratio along the slide-in axis.
    ///
    /// Values are clamped by the quick-terminal runtime to the range
    /// `0.2...1.0`. For top and bottom positions this controls height; for
    /// left and right positions this controls width. The default is `0.38`.
    ///
    /// ```swift
    /// let key = SettingCatalog().terminal.quickTerminalPrimarySizeRatio
    /// ```
    public let quickTerminalPrimarySizeRatio = DefaultsKey<Double>(
        id: "terminal.quickTerminalPrimarySizeRatio",
        defaultValue: 0.38,
        userDefaultsKey: "quickTerminal.primarySizeRatio"
    )

    /// The quick terminal size ratio across the axis opposite the slide-in direction.
    ///
    /// Values are clamped by the quick-terminal runtime to the range
    /// `0.2...1.0`. For top and bottom positions this controls width; for left,
    /// right, and center positions this controls height. The default is `1.0`.
    ///
    /// ```swift
    /// let key = SettingCatalog().terminal.quickTerminalSecondarySizeRatio
    /// ```
    public let quickTerminalSecondarySizeRatio = DefaultsKey<Double>(
        id: "terminal.quickTerminalSecondarySizeRatio",
        defaultValue: 1.0,
        userDefaultsKey: "quickTerminal.secondarySizeRatio"
    )

    /// Whether the quick terminal hides automatically after losing key focus.
    ///
    /// The default is `true`. When disabled, the panel remains visible until a
    /// toggle, hide command, or app shutdown closes it.
    ///
    /// ```swift
    /// let key = SettingCatalog().terminal.quickTerminalAutoHide
    /// ```
    public let quickTerminalAutoHide = DefaultsKey<Bool>(
        id: "terminal.quickTerminalAutoHide",
        defaultValue: true,
        userDefaultsKey: "quickTerminal.autoHide"
    )

    public let textBoxMaxLines = DefaultsKey<Int>(
        id: "terminal.textBoxMaxLines",
        defaultValue: 10,
        userDefaultsKey: "terminal.textBoxMaxLines"
    )

    public let resumeCommands = JSONKey<[String]>(
        id: "terminal.resumeCommands",
        defaultValue: []
    )

    public init() {}
}

/// The settings-derived inputs ``TerminalSurface`` folds into a spawned
/// process's environment.
///
/// The surface model reads these through
/// ``TerminalSurfaceSpawnPolicyProviding`` at the exact point the legacy code
/// read the individual settings stores, so each spawn observes the same live
/// values in the same order.
public struct TerminalSurfaceSpawnPolicy: Sendable {
    /// Protected authentication values exported into the spawned terminal.
    public var socketAuthenticationEnvironment: [String: String]

    /// Whether Claude Code hooks are enabled (`CMUX_CLAUDE_HOOKS_DISABLED`).
    public var claudeHooksEnabled: Bool

    /// Whether Codex hooks (the `codex` wrapper) are enabled
    /// (`CMUX_CODEX_HOOKS_DISABLED`).
    public var codexHooksEnabled: Bool

    /// The user's custom `claude` executable path
    /// (`CMUX_CUSTOM_CLAUDE_PATH`), if set.
    public var customClaudePath: String?

    /// The environment key carrying the subagent-notification suppression
    /// flag.
    public var subagentNotificationEnvironmentKey: String

    /// Whether subagent notifications are suppressed (exported as `"1"`/`"0"`
    /// under ``subagentNotificationEnvironmentKey``).
    public var suppressSubagentNotifications: Bool

    /// Whether Cursor hooks are enabled (`CMUX_CURSOR_HOOKS_DISABLED`).
    public var cursorHooksEnabled: Bool

    /// Whether Gemini hooks are enabled (`CMUX_GEMINI_HOOKS_DISABLED`).
    public var geminiHooksEnabled: Bool

    /// Whether Kiro hooks are enabled (`CMUX_KIRO_HOOKS_DISABLED`).
    public var kiroHooksEnabled: Bool

    /// The Kiro notification level raw value
    /// (`CMUX_KIRO_NOTIFICATION_LEVEL`).
    public var kiroNotificationLevel: String

    /// Whether Amp hooks are enabled (`CMUX_AMP_HOOKS_DISABLED`).
    public var ampHooksEnabled: Bool

    /// Whether cmux shell integration is enabled (the
    /// `sidebarShellIntegration` setting).
    public var shellIntegrationEnabled: Bool

    /// Whether sidebar git-status watching is enabled (`CMUX_NO_GIT_WATCH`).
    public var watchGitStatusEnabled: Bool

    /// Whether sidebar pull-request watching is enabled (`CMUX_NO_PR_WATCH`).
    public var showPullRequestsEnabled: Bool

    /// Creates a spawn policy snapshot.
    public init(
        socketAuthenticationEnvironment: [String: String] = [:],
        claudeHooksEnabled: Bool,
        codexHooksEnabled: Bool = true,
        customClaudePath: String?,
        subagentNotificationEnvironmentKey: String,
        suppressSubagentNotifications: Bool,
        cursorHooksEnabled: Bool,
        geminiHooksEnabled: Bool,
        kiroHooksEnabled: Bool,
        kiroNotificationLevel: String,
        ampHooksEnabled: Bool,
        shellIntegrationEnabled: Bool,
        watchGitStatusEnabled: Bool,
        showPullRequestsEnabled: Bool
    ) {
        self.socketAuthenticationEnvironment = socketAuthenticationEnvironment
        self.claudeHooksEnabled = claudeHooksEnabled
        self.codexHooksEnabled = codexHooksEnabled
        self.customClaudePath = customClaudePath
        self.subagentNotificationEnvironmentKey = subagentNotificationEnvironmentKey
        self.suppressSubagentNotifications = suppressSubagentNotifications
        self.cursorHooksEnabled = cursorHooksEnabled
        self.geminiHooksEnabled = geminiHooksEnabled
        self.kiroHooksEnabled = kiroHooksEnabled
        self.kiroNotificationLevel = kiroNotificationLevel
        self.ampHooksEnabled = ampHooksEnabled
        self.shellIntegrationEnabled = shellIntegrationEnabled
        self.watchGitStatusEnabled = watchGitStatusEnabled
        self.showPullRequestsEnabled = showPullRequestsEnabled
    }
}

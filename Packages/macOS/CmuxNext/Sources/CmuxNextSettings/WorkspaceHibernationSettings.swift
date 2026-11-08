// The paths, defaults and range are generated from schemas/settings/source/workspace-hibernation.json
// (Schema/SettingsSchema+WorkspaceHibernation.generated.swift); this file only parses.

/// `workspaces.hibernation.*` in cmux.json (plans/cmux-next/workspace-hibernation-DESIGN.md): whether
/// idle workspaces leave memory on their own, and after how long. Absent keys take their defaults
/// (on, 60 minutes); a bad value takes its default (a number out of range, the nearest bound) plus a
/// diagnostic.
public nonisolated struct WorkspaceHibernationSettings: Sendable, Equatable {
    /// Whether idle workspaces hibernate on their own.
    public var enabled: Bool
    /// Minutes a workspace stays idle before it hibernates (memory pressure shortens it).
    public var idleMinutes: Double
    /// Minutes a workspace of a space no window shows stays idle before it hibernates.
    public var hiddenSpaceMinutes: Double
    /// `workspaces.freeing.enabled`: whether a hibernated workspace's idle shells end (off by default).
    public var freeingEnabled: Bool
    /// `workspaces.freeing.idleMinutes`: minutes of no use before a hibernated workspace's idle shells end.
    public var freeingIdleMinutes: Double
    /// `workspaces.freeing.agents`: whether an idle Claude Code or Codex TUI with a recorded session frees too (on).
    public var freeingAgents: Bool
    /// `workspaces.freeing.runningCommands`: whether a running command keeps its terminal (`never`, the default) or
    /// ends and is typed again on show (`relaunch`).
    public var freeingRunningCommands: WorkspaceFreeingRunningCommandsSetting
    /// `agents.hiddenChats.discard`: whether a hidden agent chat's page is let go on its own, without
    /// `browser.hibernation` (off by default).
    public var hiddenChatDiscard: Bool
    /// `agents.hiddenChats.discardAfterMinutes`: minutes a chat stays hidden before its page is let go.
    public var hiddenChatDiscardAfterMinutes: Double

    /// The chat-only release policy the hidden chat pages follow (``HiddenChatDiscardSetting``).
    public var hiddenChatDiscardSetting: HiddenChatDiscardSetting {
        HiddenChatDiscardSetting(enabled: hiddenChatDiscard, afterMinutes: hiddenChatDiscardAfterMinutes)
    }

    /// - Parameters:
    ///   - enabled: on by default.
    ///   - idleMinutes: 60 by default.
    ///   - hiddenSpaceMinutes: the generated default (``hiddenSpaceMinutesDefault``).
    ///   - freeingEnabled: off by default (``freeingEnabledDefault``).
    ///   - freeingIdleMinutes: one day by default (``freeingIdleMinutesDefault``).
    ///   - freeingAgents: on by default (``freeingAgentsDefault``).
    ///   - freeingRunningCommands: `never` by default (``freeingRunningCommandsDefault``).
    ///   - hiddenChatDiscard: off by default (``hiddenChatDiscardDefault``).
    ///   - hiddenChatDiscardAfterMinutes: 15 by default (``hiddenChatDiscardAfterMinutesDefault``).
    public init(enabled: Bool = Self.enabledDefault, idleMinutes: Double = Self.idleMinutesDefault,
                hiddenSpaceMinutes: Double = Self.hiddenSpaceMinutesDefault,
                freeingEnabled: Bool = Self.freeingEnabledDefault, freeingIdleMinutes: Double = Self.freeingIdleMinutesDefault,
                freeingAgents: Bool = Self.freeingAgentsDefault,
                freeingRunningCommands: WorkspaceFreeingRunningCommandsSetting = Self.freeingRunningCommandsDefault,
                hiddenChatDiscard: Bool = Self.hiddenChatDiscardDefault,
                hiddenChatDiscardAfterMinutes: Double = Self.hiddenChatDiscardAfterMinutesDefault) {
        self.enabled = enabled
        self.idleMinutes = idleMinutes
        self.hiddenSpaceMinutes = hiddenSpaceMinutes
        self.freeingEnabled = freeingEnabled
        self.freeingIdleMinutes = freeingIdleMinutes
        self.freeingAgents = freeingAgents
        self.freeingRunningCommands = freeingRunningCommands
        self.hiddenChatDiscard = hiddenChatDiscard
        self.hiddenChatDiscardAfterMinutes = hiddenChatDiscardAfterMinutes
    }

    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> Self {
        var result = Self()
        if var reader = ConfigFieldReader(root, at: ["workspaces", "hibernation"], diagnostics: &diagnostics) {
            result.enabled = reader.bool("enabled") ?? enabledDefault
            result.idleMinutes = reader.number("idleMinutes", range: idleMinutesRange) ?? idleMinutesDefault
            result.hiddenSpaceMinutes = reader.number("hiddenSpaceMinutes", range: hiddenSpaceMinutesRange) ?? hiddenSpaceMinutesDefault
            diagnostics += reader.diagnostics
        }
        // `workspaces.freeing.*` (plans/cmux-next/sidebar-recents-and-freeing-DESIGN.md): the tier under hibernation.
        if var reader = ConfigFieldReader(root, at: ["workspaces", "freeing"], diagnostics: &diagnostics) {
            result.freeingEnabled = reader.bool("enabled") ?? freeingEnabledDefault
            result.freeingIdleMinutes = reader.number("idleMinutes", range: freeingIdleMinutesRange) ?? freeingIdleMinutesDefault
            result.freeingAgents = reader.bool("agents") ?? freeingAgentsDefault
            result.freeingRunningCommands = reader.choice("runningCommands", WorkspaceFreeingRunningCommandsSetting.self)
                ?? freeingRunningCommandsDefault
            diagnostics += reader.diagnostics
        }
        // `agents.hiddenChats.*`: hidden agent chats give back their memory (HiddenChatPages, CmuxNextHibernation).
        if var reader = ConfigFieldReader(root, at: ["agents", "hiddenChats"], diagnostics: &diagnostics) {
            result.hiddenChatDiscard = reader.bool("discard") ?? hiddenChatDiscardDefault
            result.hiddenChatDiscardAfterMinutes = reader.number("discardAfterMinutes", range: hiddenChatDiscardAfterMinutesRange)
                ?? hiddenChatDiscardAfterMinutesDefault
            diagnostics += reader.diagnostics
        }
        return result
    }
}

/// `agents.hiddenChats.*` as the hidden agent chat pages read it (Leo, 2026-11-07: "if it really isn't
/// being used after a while, can't things be more aggressive?"): when on, a chat hidden `afterMinutes`
/// lets its page go without `browser.hibernation`. Chats only; browser tabs never follow it.
public nonisolated struct HiddenChatDiscardSetting: Sendable, Equatable {
    /// Whether hidden chats are let go on their own.
    public var enabled: Bool
    /// Minutes hidden before a chat's page goes (memory pressure shortens it).
    public var afterMinutes: Double

    /// - Parameters:
    ///   - enabled: whether hidden chats are let go on their own.
    ///   - afterMinutes: minutes hidden before a chat's page goes.
    public init(enabled: Bool, afterMinutes: Double = WorkspaceHibernationSettings.hiddenChatDiscardAfterMinutesDefault) {
        self.enabled = enabled
        self.afterMinutes = afterMinutes
    }

    /// The default: off.
    public static var off: Self { Self(enabled: false) }
}

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

    /// - Parameters:
    ///   - enabled: on by default.
    ///   - idleMinutes: 60 by default.
    ///   - hiddenSpaceMinutes: the generated default (``hiddenSpaceMinutesDefault``).
    ///   - freeingEnabled: off by default (``freeingEnabledDefault``).
    ///   - freeingIdleMinutes: one day by default (``freeingIdleMinutesDefault``).
    ///   - freeingAgents: on by default (``freeingAgentsDefault``).
    ///   - freeingRunningCommands: `never` by default (``freeingRunningCommandsDefault``).
    public init(enabled: Bool = Self.enabledDefault, idleMinutes: Double = Self.idleMinutesDefault,
                hiddenSpaceMinutes: Double = Self.hiddenSpaceMinutesDefault,
                freeingEnabled: Bool = Self.freeingEnabledDefault, freeingIdleMinutes: Double = Self.freeingIdleMinutesDefault,
                freeingAgents: Bool = Self.freeingAgentsDefault,
                freeingRunningCommands: WorkspaceFreeingRunningCommandsSetting = Self.freeingRunningCommandsDefault) {
        self.enabled = enabled
        self.idleMinutes = idleMinutes
        self.hiddenSpaceMinutes = hiddenSpaceMinutes
        self.freeingEnabled = freeingEnabled
        self.freeingIdleMinutes = freeingIdleMinutes
        self.freeingAgents = freeingAgents
        self.freeingRunningCommands = freeingRunningCommands
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
        return result
    }
}

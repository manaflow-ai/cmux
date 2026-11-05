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

    /// - Parameters:
    ///   - enabled: on by default.
    ///   - idleMinutes: 60 by default.
    ///   - hiddenSpaceMinutes: the generated default (``hiddenSpaceMinutesDefault``).
    public init(enabled: Bool = Self.enabledDefault, idleMinutes: Double = Self.idleMinutesDefault,
                hiddenSpaceMinutes: Double = Self.hiddenSpaceMinutesDefault) {
        self.enabled = enabled
        self.idleMinutes = idleMinutes
        self.hiddenSpaceMinutes = hiddenSpaceMinutes
    }

    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> Self {
        guard var reader = ConfigFieldReader(root, at: ["workspaces", "hibernation"], diagnostics: &diagnostics) else { return Self() }
        let enabled = reader.bool("enabled") ?? enabledDefault
        let idleMinutes = reader.number("idleMinutes", range: idleMinutesRange) ?? idleMinutesDefault
        let hiddenSpaceMinutes = reader.number("hiddenSpaceMinutes", range: hiddenSpaceMinutesRange) ?? hiddenSpaceMinutesDefault
        diagnostics += reader.diagnostics
        return Self(enabled: enabled, idleMinutes: idleMinutes, hiddenSpaceMinutes: hiddenSpaceMinutes)
    }
}

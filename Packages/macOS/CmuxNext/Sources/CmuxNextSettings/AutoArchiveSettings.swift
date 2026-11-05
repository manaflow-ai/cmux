// The paths, defaults, range and choices are generated from
// schemas/settings/source/auto-archive.json (Schema/SettingsSchema+AutoArchive.generated.swift);
// this file only parses.

/// `workspaces.autoArchive.*` in cmux.json (plans/cmux-next/auto-archive-DESIGN.md): what cmux does
/// with workspaces nobody used for a while. Absent keys take their defaults (suggest, 3 days); a bad
/// value takes its default plus a diagnostic.
public nonisolated struct AutoArchiveSettings: Sendable, Equatable {
    /// How idle workspaces leave the way: a card, on their own, only in groups with a rule, only on
    /// Archive Idle Workspaces, or never.
    public var style: AutoArchiveStyle
    /// Days a workspace stays idle before it counts (a group's own rule wins).
    public var idleDays: Double

    public init(style: AutoArchiveStyle = Self.styleDefault, idleDays: Double = Self.idleDaysDefault) {
        self.style = style
        self.idleDays = idleDays
    }

    /// `idleDays` in seconds.
    public var idleSeconds: Double { idleDays * 86_400 }

    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> Self {
        guard var reader = ConfigFieldReader(root, at: ["workspaces", "autoArchive"], diagnostics: &diagnostics) else { return Self() }
        let style = reader.choice("style", AutoArchiveStyle.self) ?? styleDefault
        let idleDays = reader.number("idleDays", range: idleDaysRange) ?? idleDaysDefault
        diagnostics += reader.diagnostics
        return Self(style: style, idleDays: idleDays)
    }
}

extension SettingsController {
    /// Writes `workspaces.autoArchive.style` by its name (an ``AutoArchiveStyle`` raw value) through
    /// the schema's validated write, so a name the schema does not list is refused. The Tidy Up
    /// card's Always Archive writes `quiet`; the sidebar's coordinator knows no settings types.
    public func setAutoArchiveStyle(named name: String) async throws {
        try await setSetting(at: AutoArchiveSettings.stylePath, to: .string(name), by: .caller("auto-archive"))
    }
}

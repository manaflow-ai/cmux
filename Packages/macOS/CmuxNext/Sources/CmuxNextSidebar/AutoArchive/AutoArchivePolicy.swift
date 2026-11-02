/// What auto-archive does with idle workspaces (plans/cmux-next/auto-archive-DESIGN.md): the App maps
/// `workspaces.autoArchive` (CmuxNextSettings' `AutoArchiveSettings`) onto this value, so the sidebar's
/// logic needs no settings dependency.
public nonisolated struct AutoArchivePolicy: Equatable, Sendable {
    /// How idle workspaces leave the way (the setting's `style` values).
    public nonisolated enum Style: String, CaseIterable, Sendable {
        /// A sidebar card lists them; Archive archives, Always Archive switches to ``quiet``, the x waits a day.
        case suggest
        /// They archive on their own; a toast offers Undo.
        case quiet
        /// Only members of groups with their own rule archive on their own.
        case groups
        /// Only Archive Idle Workspaces archives; nothing pops up. The default.
        case manual
        /// Never in the background; group rules are ignored.
        case off
    }

    public var style: Style
    /// Days a workspace stays idle before it counts (a group's own rule wins).
    public var idleDays: Double

    public init(style: Style = .manual, idleDays: Double = 3) {
        self.style = style
        self.idleDays = idleDays
    }

    /// The policy a settings file names (`workspaces.autoArchive.style` and `.idleDays`); nil or an
    /// unknown style takes the default.
    public init(styleName: String?, idleDays: Double?) {
        self.init(style: styleName.flatMap(Style.init(rawValue:)) ?? .manual, idleDays: idleDays ?? 3)
    }

    /// `idleDays` in seconds.
    public var idleSeconds: Double { idleDays * 86_400 }
}

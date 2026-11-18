/// `sidebar.groupHeader.background` (Lawrence 2026-11-05: "invariant: groups must always have a visible bg
/// color, groups should support both glassy and solid bgs too"): how a sidebar group header's background
/// draws. Every style but `sections` keeps the background visible against the sidebar (`GroupBackground`).
public nonisolated enum SidebarGroupBackgroundStyle: String, Hashable, Sendable, CaseIterable {
    /// cmux's own group look (Leo's tinted glass, 2026-11-05; Debug `sidebar.groupGlass` may set it solid). The default.
    case auto
    /// A translucent fill the window's glass shows through, edged with a hairline rim.
    case glass
    /// An opaque fill.
    case solid
    /// No background: each group draws as a plain section heading, its name in the quiet ink with no fill and no
    /// members' line (Leo 2026-11-05: "they have these sections ... maybe we can also have an option to have that").
    case sections

    /// Whether the background draws as glass, given whether cmux's own group look (`appLooksGlassy`) is glass.
    ///
    /// - Parameter appLooksGlassy: cmux's own group look is glass (Debug `sidebar.groupGlass` is not solid).
    /// - Returns: True for the glass look, false for the solid one.
    public func drawsGlass(appLooksGlassy: Bool) -> Bool {
        switch self {
        case .auto: appLooksGlassy
        case .glass: true
        case .solid, .sections: false
        }
    }

    /// Whether a group draws a background (a fill, a rim and its members' line) at all: false only for `sections`.
    public var drawsBackground: Bool { self != .sections }
}

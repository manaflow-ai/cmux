/// `sidebar.groupHeader.background` (Lawrence 2026-11-05: "invariant: groups must always have a visible bg
/// color, groups should support both glassy and solid bgs too"): how a sidebar group header's background
/// draws. Every style keeps the background visible against the sidebar (`GroupBackground`).
public nonisolated enum SidebarGroupBackgroundStyle: String, Hashable, Sendable, CaseIterable {
    /// cmux's own group look (Leo's tinted glass, 2026-11-05; Debug `sidebar.groupGlass` may set it solid). The default.
    case auto
    /// A translucent fill the window's glass shows through, edged with a hairline rim.
    case glass
    /// An opaque fill.
    case solid

    /// Whether the background draws as glass, given whether cmux's own group look (`appLooksGlassy`) is glass.
    ///
    /// - Parameter appLooksGlassy: cmux's own group look is glass (Debug `sidebar.groupGlass` is not solid).
    /// - Returns: True for the glass look, false for the solid one.
    public func drawsGlass(appLooksGlassy: Bool) -> Bool {
        switch self {
        case .auto: appLooksGlassy
        case .glass: true
        case .solid: false
        }
    }
}

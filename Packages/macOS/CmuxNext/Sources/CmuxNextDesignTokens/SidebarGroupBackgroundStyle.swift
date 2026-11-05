/// `sidebar.groupHeader.background` (Lawrence 2026-11-05: "invariant: groups must always have a visible bg
/// color, groups should support both glassy and solid bgs too"): how a sidebar group header's background
/// draws. Every style keeps the background visible against the sidebar (`GroupBackground`).
public nonisolated enum SidebarGroupBackgroundStyle: String, Hashable, Sendable, CaseIterable {
    /// Glass where the sidebar is see-through (a `background-opacity` below 1), else solid. The default.
    case auto
    /// A translucent fill the window's glass shows through, edged with a hairline rim.
    case glass
    /// An opaque fill.
    case solid

    /// Whether the background draws as glass in a sidebar that is see-through (`seeThrough`) or opaque.
    ///
    /// - Parameter seeThrough: The sidebar's background is translucent (the theme's `background-opacity` below 1).
    /// - Returns: True for the glass look, false for the solid one.
    public func drawsGlass(seeThrough: Bool) -> Bool {
        switch self {
        case .auto: seeThrough
        case .glass: true
        case .solid: false
        }
    }
}

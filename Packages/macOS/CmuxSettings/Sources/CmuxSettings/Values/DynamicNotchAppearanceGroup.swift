/// A group used to organize Dynamic Notch appearance tokens in editors.
public enum DynamicNotchAppearanceGroup: String, CaseIterable, Sendable {
    /// Window, row, icon, and corner geometry.
    case layout

    /// Gaps between controls and content sections.
    case spacing

    /// Semantic foreground and background colors.
    case colors

    /// Animation, opacity, line limits, and scroll behavior.
    case behavior
}

public import CoreGraphics

/// Layout constants shared by chrome components.
public enum Metrics {
    /// Default sidebar width when visible.
    public static let sidebarWidth: CGFloat = 240

    /// Height of the tab strip; matches the unified titlebar height so the
    /// strip sits beside the traffic lights.
    public static let tabStripHeight: CGFloat = 40

    /// Inset between the window edge and floating glass panels.
    public static let panelInset: CGFloat = 8

    /// Corner radius for floating glass panels (sidebar, palette).
    public static let panelCornerRadius: CGFloat = 12

    /// Corner radius for tabs and rows.
    public static let itemCornerRadius: CGFloat = 7

    /// Space reserved at the leading edge of the titlebar for traffic lights.
    public static let trafficLightInset: CGFloat = 78
}

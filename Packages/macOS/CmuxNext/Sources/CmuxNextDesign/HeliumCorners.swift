public import CoreGraphics

/// Helium's tab corner (Lawrence 2026-10-31: "match helium roundess"), from Helium 0.17.2.1
/// (Chromium 156) source, not by eye. The default outer radius (`densityPaneCornerRadius`) is
/// chosen so the concentric tab keeps it.
extension Metrics {
    /// patches/helium/ui/tabs.patch: `TabStyle::GetTopCornerRadius` and `GetBottomCornerRadius`
    /// return 8, and every tab fill is one detached circular-arc `SkRRect`: four 8 pt corners.
    public static let heliumTabCornerRadius: CGFloat = 8
}

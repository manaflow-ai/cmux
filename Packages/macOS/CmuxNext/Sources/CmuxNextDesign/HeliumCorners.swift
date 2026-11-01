public import CoreGraphics

/// Helium's corners (Lawrence 2026-10-31: "match helium roundess, and round the pane bg thing
/// more"), from Helium 0.17.2.1 (Chromium 156) source, not by eye.
extension Metrics {
    /// patches/helium/ui/tabs.patch: `TabStyle::GetTopCornerRadius` and `GetBottomCornerRadius`
    /// return 8, and every tab fill is one detached circular-arc `SkRRect`: four 8 pt corners.
    public static let heliumTabCornerRadius: CGFloat = 8

    /// patches/helium/ui/frame-radius-helper.patch: the content card's corner at the window,
    /// `GetSystemWindowRadius() - kHeliumBasePadding`, 17 - 3 = 14 pt on macOS 26.
    public static let heliumContentCornerRadius: CGFloat = 14
}

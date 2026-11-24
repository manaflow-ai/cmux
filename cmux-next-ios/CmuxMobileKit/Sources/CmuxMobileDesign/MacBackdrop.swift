#if os(iOS)
import SwiftUI

/// The ground of the sidebar and Home: the Mac's wallpaper under its tint when the chrome follows
/// a Mac that shows one (as the Mac's sidebar sits clear over its window's picture), else the
/// plain background (ask-87d30da8e5). The background policy (``CmuxMobileBackgroundPolicy``) also
/// lays it under other screens, with `minTint` raising the tint where text is read.
public struct CmuxMobileBackdrop: View {
    private let macTheme: CmuxMobileMacTheme
    private let minTint: Double
    private let grouped: Bool

    public init(macTheme: CmuxMobileMacTheme = .shared, minTint: Double = 0, grouped: Bool = false) {
        self.macTheme = macTheme
        self.minTint = minTint
        self.grouped = grouped
    }

    /// A list row's ground over Home's backdrop: clear over the Mac's wallpaper (the rows sit on it,
    /// as the Mac's sidebar rows do), else the plain background.
    public static var listRow: Color {
        let legacy = CmuxMobileMacTheme.shared.wallpaper == nil ? CmuxMobileTheme.standard.colors.bg.color : Color.clear
        guard CmuxMobileBackgroundSetting.shared.policy != .current else { return legacy }
        return CmuxMobileGroundRows.showsWallpaper(.root) ? .clear : CmuxMobileGroundRows.opaque(CmuxMobileTheme.standard.colors.bg).color
    }

    public var body: some View {
        let bg = grouped ? CmuxMobileTheme.standard.colors.bgGrouped : CmuxMobileTheme.standard.colors.bg
        if let wallpaper = macTheme.wallpaper {
            GeometryReader { proxy in
                Image(uiImage: wallpaper.image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
                    .overlay(bg.color.opacity(max(wallpaper.tint, minTint)))
            }
            .accessibilityHidden(true)
        } else if CmuxMobileBackgroundSetting.shared.policy == .current {
            bg.color
        } else {
            CmuxMobileGroundRows.opaque(bg).color
        }
    }
}
#endif

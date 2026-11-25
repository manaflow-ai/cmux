#if os(iOS)
import SwiftUI

/// The ground of the sidebar and Home: the Mac's wallpaper under its tint when the chrome follows
/// a Mac that shows one (as the Mac's sidebar sits clear over its window's picture), else the
/// plain background (ask-87d30da8e5).
public struct CmuxMobileBackdrop: View {
    private let macTheme: CmuxMobileMacTheme

    public init(macTheme: CmuxMobileMacTheme = .shared) {
        self.macTheme = macTheme
    }

    /// A list row's ground over the backdrop: clear over the Mac's wallpaper (the rows sit on it,
    /// as the Mac's sidebar rows do), else the plain background.
    public static var listRow: Color {
        CmuxMobileMacTheme.shared.wallpaper == nil ? CmuxMobileTheme.standard.colors.bg.color : .clear
    }

    public var body: some View {
        let bg = CmuxMobileTheme.standard.colors.bg
        if let wallpaper = macTheme.wallpaper {
            GeometryReader { proxy in
                Image(uiImage: wallpaper.image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
                    .overlay(bg.color.opacity(wallpaper.tint))
            }
            .accessibilityHidden(true)
        } else {
            bg.color
        }
    }
}
#endif

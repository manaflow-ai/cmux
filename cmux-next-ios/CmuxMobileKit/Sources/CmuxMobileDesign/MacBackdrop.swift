#if os(iOS)
import SwiftUI

/// The ground of the sidebar and Home: the plain background, black in dark and white in light.
/// The Mac's wallpaper is not drawn on the phone for now (2026-11-25: every background black; the
/// options were PR #53342); ``CmuxMobileMacTheme/wallpaper`` still carries it.
public struct CmuxMobileBackdrop: View {
    /// The ground's color; nil is the chrome's background.
    private let background: Color?

    /// - Parameter background: A terminal page's ground (its Mac's terminal background, so the page
    ///   meets the terminal without a seam), nil for the chrome's.
    public init(macTheme: CmuxMobileMacTheme = .shared, background: Color? = nil) {
        self.background = background
    }

    /// A list row's ground over the backdrop: the plain background.
    public static var listRow: Color { CmuxMobileTheme.standard.colors.bg.color }

    public var body: some View {
        background ?? CmuxMobileTheme.standard.colors.bg.color
    }
}
#endif

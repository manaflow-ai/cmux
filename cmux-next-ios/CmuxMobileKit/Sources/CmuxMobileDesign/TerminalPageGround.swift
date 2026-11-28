#if os(iOS)
import SwiftUI
import UIKit

/// A terminal page's ground in SwiftUI: its Mac's wallpaper under the terminal background at the
/// Mac's tint, else that background (what `TerminalGroundView` paints under the surface). The
/// workspace's top bar band shows it, so the band over a terminal continues the page under it.
///
/// Leo, 2026-11-25: "the top area is black and has no background nor theming". The band behind
/// the top bar (#53596) was black for every page with a light status bar, so a terminal's top
/// edge lost its theme and wallpaper.
public struct TerminalPageGround: View {
    let macID: String?

    public init(macID: String?) {
        self.macID = macID
    }

    /// The terminal background of `macID`'s terminals: its Mac's theme (Match Mac theme), else the
    /// phone's own (``CmuxMobileTerminalTheme/stock``).
    @MainActor
    public static func background(macID: String?) -> UIColor {
        (CmuxMobileTerminalThemes.shared.theme(for: macID) ?? .stock).backgroundColor
    }

    public var body: some View {
        CmuxMobileBackdrop(background: Color(uiColor: Self.background(macID: macID)))
    }
}
#endif

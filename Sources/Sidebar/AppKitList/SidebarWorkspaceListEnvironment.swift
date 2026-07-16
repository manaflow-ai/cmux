import CmuxFoundation
import Foundation

/// List-wide presentation inputs shared by every AppKit sidebar cell.
///
/// Cells derive colors from `effectiveAppearance` natively; only inputs that
/// AppKit cannot observe on its own are forwarded here as plain values.
struct SidebarWorkspaceListEnvironment: Equatable {
    let globalFontMagnificationPercent: Int
    let rowSpacing: CGFloat

    static let `default` = SidebarWorkspaceListEnvironment(
        globalFontMagnificationPercent: 100,
        rowSpacing: 2
    )

    /// Point size for sidebar text: base size scaled by the per-sidebar font
    /// scale and the app-wide font magnification, mirroring the SwiftUI rows'
    /// `magnifiedFont(scaledFontSize(_:))`.
    func fontSize(base: CGFloat, sidebarFontScale: CGFloat) -> CGFloat {
        GlobalFontMagnification.scaledSize(
            base * sidebarFontScale,
            percent: globalFontMagnificationPercent
        )
    }
}

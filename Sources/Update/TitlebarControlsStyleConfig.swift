import AppKit
import SwiftUI

struct TitlebarControlsStyleConfig {
    let spacing: CGFloat
    let iconSize: CGFloat
    let buttonSize: CGFloat
    let badgeSize: CGFloat
    let badgeOffset: CGSize
    let groupBackground: Bool
    let groupPadding: EdgeInsets
    let buttonBackground: Bool
    let buttonCornerRadius: CGFloat
    let hoverBackground: Bool
}

struct TitlebarControlsLayoutModelSnapshot: Equatable {
    let style: TitlebarControlsStyle
    let contentSize: NSSize
}

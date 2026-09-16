import CmuxSidebar
import SwiftUI

struct SidebarPullRequestChecksIcon: View {
    let checks: SidebarPullRequestChecks
    let pointSize: CGFloat
    let neutralColor: Color

    var body: some View {
        let display = SidebarPullRequestChecksDisplay(checks: checks)
        CmuxSystemSymbolImage(
            magnified: display.iconName,
            pointSize: pointSize,
            weight: .semibold,
            tint: display.tint.map(Color.init(nsColor:)) ?? neutralColor
        )
        .frame(width: pointSize * 4 / 3, height: pointSize * 4 / 3)
        .safeHelp(display.tooltip)
        .accessibilityLabel(display.tooltip)
        .accessibilityIdentifier("SidebarPullRequestChecks")
    }
}

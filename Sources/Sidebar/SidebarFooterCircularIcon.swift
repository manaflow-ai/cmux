import CmuxSettingsUI
import SwiftUI

struct SidebarFooterCircularIcon: View {
    let systemName: String
    let style: SidebarFooterCircularIconStyle
    @Environment(\.chromePalette) private var chromePalette

    var body: some View {
        CmuxSystemSymbolImage(
            systemName: systemName,
            pointSize: style.pointSize,
            weight: style.weight
        )
        .foregroundStyle(chromePalette.textSecondary.swiftUIColor)
    }
}

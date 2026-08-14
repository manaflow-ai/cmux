import CmuxFoundation
import CmuxNotifications
import CmuxSettingsUI
import SwiftUI

struct TitlebarNotificationBadge: View {
    let unreadModel: SidebarUnreadModel
    let config: TitlebarControlsStyleConfig
    @Environment(\.cmuxGlobalFontMagnificationPercent) private var globalFontPercent
    @Environment(\.chromePalette) private var chromePalette

    var body: some View {
        let unreadCount = unreadModel.totalUnreadCount
        if unreadCount > 0 {
            Text("\(min(unreadCount, 99))")
                .cmuxFont(
                    size: titlebarNotificationBadgeFontSize(for: config)
                        / max(1, GlobalFontMagnification.scale(for: globalFontPercent)),
                    weight: .semibold
                )
                .foregroundColor((chromePalette.textOnAccent).cmuxColor)
                .frame(width: config.badgeSize, height: config.badgeSize)
                .background(Circle().fill(chromePalette.cmuxAccentColor))
                .offset(x: config.badgeOffset.width, y: config.badgeOffset.height)
        }
    }
}

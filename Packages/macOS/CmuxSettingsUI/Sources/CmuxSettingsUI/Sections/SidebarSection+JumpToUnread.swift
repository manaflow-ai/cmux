import CmuxSettings
import SwiftUI

extension SidebarSection {
    /// The `sidebar.showJumpToUnreadButton` toggle. The button's × turns the
    /// setting off, so this row is how it comes back.
    @ViewBuilder
    var jumpToUnreadButtonRow: some View {
        SettingsCardDivider()
        SettingsCardRow(
            configurationReview: .json("sidebar.showJumpToUnreadButton"),
            String(localized: "settings.app.showJumpToUnreadButton", defaultValue: "Show Jump to Unread Button"),
            subtitle: String(localized: "settings.app.showJumpToUnreadButton.subtitle", defaultValue: "Show a button above the sidebar footer that jumps to the latest unread notification while any are unread.")
        ) {
            Toggle("", isOn: Binding(get: { showJumpToUnreadButton.current }, set: { showJumpToUnreadButton.set($0) }))
                .labelsHidden()
                .controlSize(.small)
        }
    }
}

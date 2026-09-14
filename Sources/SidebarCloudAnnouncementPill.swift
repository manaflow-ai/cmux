import CmuxFoundation
import SwiftUI

#if DEBUG
/// A compact sibling of the existing update pill, immediately after help.
struct SidebarCloudAnnouncementPill: View {
    let accent: Color
    let onOpen: () -> Void
    let onDismiss: () -> Void

    private let title = String(localized: "sidebar.cloudAnnouncement.pill", defaultValue: "Cloud is here")
    private let changelog = String(localized: "sidebar.cloudAnnouncement.changelog", defaultValue: "Read the changelog")
    private let dismiss = String(localized: "sidebar.cloudAnnouncement.dismiss", defaultValue: "Dismiss announcement")

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 5) {
                Image(systemName: "cloud")
                    .cmuxFont(size: 12)
                Text(title)
                    .cmuxFont(size: 10, weight: .medium)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 8)
            .frame(height: SidebarFooterButtonMetrics.buttonSize)
            .foregroundStyle(accent.opacity(0.8))
            .background(Capsule().fill(accent.opacity(0.1)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .safeHelp(changelog)
        .accessibilityLabel(String(localized: "sidebar.cloudAnnouncement.title", defaultValue: "cmux Cloud is here"))
        .accessibilityHint(changelog)
        .accessibilityIdentifier("CloudAnnouncementOpen")
        .accessibilityAction(named: Text(dismiss), onDismiss)
        .contextMenu {
            Button(changelog, action: onOpen)
            Button(dismiss, action: onDismiss)
        }
    }
}
#endif

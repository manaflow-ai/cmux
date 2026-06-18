import CmuxMobileSupport
import SwiftUI

/// Custom back control for the workspace detail that folds the unread-workspace
/// count INTO the back button itself (one button), instead of a separate pill.
/// When other workspaces are unread it reads as "‹ 3"; otherwise it is just the
/// chevron. Tinted with the primary label color (white on the dark terminal bar,
/// black on a light bar) rather than the accent blue, so the count reads as plain
/// text with no colored background. The button widens to fit the count.
struct WorkspaceBackButton: View {
    let unreadCount: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "chevron.backward")
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                if unreadCount > 0 {
                    Text(countText)
                        // Smaller than the chevron, on a small mono circle.
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                        // Number contrasts the circle: dark on the white circle
                        // (dark bar) / light on the black circle (light bar).
                        .foregroundStyle(Color(.systemBackground))
                        .padding(2)
                        .frame(minWidth: 18, minHeight: 18)
                        // White/black circle (adapts), not the accent blue.
                        .background(.primary, in: .circle)
                }
            }
            .contentShape(.rect)
        }
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier("MobileWorkspaceBackButton")
    }

    /// Cap the visible glyphs so a large fleet does not stretch the bar; VoiceOver
    /// still hears the exact count via the label.
    private var countText: String {
        unreadCount > 99 ? "99+" : "\(unreadCount)"
    }

    private var accessibilityLabel: String {
        let back = L10n.string("mobile.workspace.back", defaultValue: "Back")
        guard unreadCount > 0 else { return back }
        let unread = String(
            format: L10n.string(
                "mobile.workspace.backUnreadCountFormat",
                defaultValue: "%d unread workspaces"
            ),
            unreadCount
        )
        return "\(back), \(unread)"
    }
}

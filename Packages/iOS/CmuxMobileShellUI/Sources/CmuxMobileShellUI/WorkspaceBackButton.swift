import CmuxMobileSupport
import SwiftUI

struct WorkspaceBackButtonConfiguration {
    let unreadCount: Int
    let badgeContrast: WorkspaceBackButtonBadgeContrast
    let action: () -> Void
}

/// Custom back control for the workspace detail that folds the unread-workspace
/// count INTO the back button itself (one button), instead of a separate pill.
/// When other workspaces are unread it reads as "‹ 3"; otherwise it is just the
/// chevron.
struct WorkspaceBackButton: View {
    let unreadCount: Int
    var badgeContrast: WorkspaceBackButtonBadgeContrast = .lightBackground
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
                        .foregroundStyle(badgeTextColor)
                        .padding(2)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(badgeFillColor, in: .circle)
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

    private var badgeFillColor: Color {
        switch badgeContrast {
        case .darkBackground:
            .white
        case .lightBackground:
            .black
        }
    }

    private var badgeTextColor: Color {
        switch badgeContrast {
        case .darkBackground:
            .black
        case .lightBackground:
            .white
        }
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

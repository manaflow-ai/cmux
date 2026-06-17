import CmuxMobileSupport
import SwiftUI

/// Unread-workspace count shown next to the back button on the workspace detail
/// screen, so at a glance you can see how many OTHER workspaces have unread
/// activity waiting back in the list. iMessage-style accent pill that reuses the
/// same `Color.accentColor` as `WorkspaceUnreadDot`; renders nothing at zero so
/// the back area stays clean when everything is read.
struct WorkspaceBackUnreadBadge: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Text(badgeText)
                .font(.footnote.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .frame(minWidth: 20, minHeight: 20)
                .background(Color.accentColor, in: .capsule)
                .accessibilityLabel(accessibilityLabel)
                .accessibilityIdentifier("MobileBackUnreadBadge")
        }
    }

    /// Cap the visible glyphs so a large fleet does not stretch the pill across
    /// the bar; VoiceOver still hears the exact count via the label.
    private var badgeText: String {
        count > 99 ? "99+" : "\(count)"
    }

    private var accessibilityLabel: String {
        String(
            format: L10n.string(
                "mobile.workspace.backUnreadCountFormat",
                defaultValue: "%d unread workspaces"
            ),
            count
        )
    }
}

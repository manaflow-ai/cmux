#if os(iOS)
import SwiftUI

/// Compact replacement for the system inline navigation bar on the workspace
/// detail panes (terminal / chat / browser). A single thin row — back button,
/// title, trailing actions — sized well under the ~44pt fixed UIKit inline bar
/// so the terminal grid reclaims that vertical space. Mounted via
/// `safeAreaInset(edge: .top)` with the system nav bar hidden.
struct MobileCompactWorkspaceHeader<Trailing: View>: View {
    let title: String
    /// Pop back to the workspace list. When nil (e.g. the iPad split layout has
    /// no pushed stack) the back affordance is omitted.
    let onBack: (() -> Void)?
    /// Other-workspace unread count, folded into the back button ("‹ 3").
    let unreadCount: Int
    @ViewBuilder var trailing: () -> Trailing

    /// Bar content height, excluding the top safe-area inset. The UIKit inline
    /// bar is ~44pt; this is deliberately much shorter to maximize the grid.
    static var contentHeight: CGFloat { 30 }

    var body: some View {
        HStack(spacing: 10) {
            if let onBack {
                WorkspaceBackButton(
                    unreadCount: unreadCount,
                    badgeContrast: .darkBackground,
                    action: onBack
                )
            }
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing()
        }
        .foregroundStyle(TerminalPalette.foreground)
        .padding(.horizontal, 12)
        .frame(height: Self.contentHeight)
        .frame(maxWidth: .infinity)
        // Force a dark scheme so the translucent material reads as a dark bar
        // over the terminal and the chevron/buttons stay light.
        .environment(\.colorScheme, .dark)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 0.5)
        }
    }
}
#endif

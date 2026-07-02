import AppKit
import SwiftUI

/// Corner "Pro" badge in the sidebar footer. Opens the shared pricing
/// destination (``AuthEnvironment/pricingURL``) in the default browser,
/// same as the Settings Account card, command palette entry, and Help
/// menu item. Rendered in both the Release footer and the DEBUG dev
/// footer via `SidebarFooterButtons`.
struct SidebarProBadge: View {
    @State private var isHovered = false

    private var badgeTitle: String {
        String(localized: "sidebar.pro.badge", defaultValue: "Pro")
    }

    private var helpTitle: String {
        String(localized: "menu.help.upgradeToPro", defaultValue: "Upgrade to cmux Pro…")
    }

    var body: some View {
        Button {
            NSWorkspace.shared.open(AuthEnvironment.pricingURL)
        } label: {
            Text(badgeTitle)
                .cmuxFont(size: 10, weight: .semibold)
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .padding(.horizontal, 7)
                .frame(height: 16)
                .background(
                    Capsule()
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                        .background(
                            Capsule().fill(isHovered ? Color(nsColor: .quaternaryLabelColor) : .clear)
                        )
                )
        }
        .buttonStyle(.plain)
        .frame(height: 22, alignment: .center)
        .onHover { isHovered = $0 }
        .safeHelp(helpTitle)
        .accessibilityLabel(helpTitle)
        .accessibilityIdentifier("SidebarProBadgeButton")
    }
}

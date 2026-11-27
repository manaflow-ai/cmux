import SwiftUI

/// Corner "Pro" badge in the sidebar footer: renders the active
/// ``ProBadgeStyle`` (Debug > Pro Badge Style switches variants) and opens
/// the shared pricing destination, same as the Settings Account card,
/// command palette entry, and Help menu item. Rendered in both the Release
/// footer and the DEBUG dev footer via `SidebarFooterButtons`.
struct SidebarProBadge: View {
    var body: some View {
        ProBadgeView()
    }
}

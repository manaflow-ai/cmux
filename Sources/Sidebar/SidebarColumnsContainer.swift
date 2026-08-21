import AppKit
import SwiftUI

/// Finder-style two-column sidebar region: machines on the left, the
/// selected machine's workspaces next. Column widths arrive as resolved
/// values (regular width or icon rail), so this container stays a dumb
/// geometry shell.
///
/// The divider here is VISUAL ONLY (a hairline). Interaction — synchronous
/// drag tracking, cursor management, occlusion, double-click collapse —
/// lives in ContentView's shared resizer overlay (`.columnDivider` handle),
/// the same machinery as the region divider, so both dividers feel
/// identical.
struct SidebarColumnsContainer<Leading: View, Trailing: View>: View {
    let leadingWidth: CGFloat
    let trailingWidth: CGFloat
    /// Stable identity for the trailing subtree (the selected machine's
    /// route) so switching machines resets scroll and selection state.
    let trailingIdentity: String
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 0) {
            leading()
                .frame(width: max(0, leadingWidth))
                .frame(maxHeight: .infinity)
                // No divider line (a line either cuts through the titlebar
                // and footer strips or dangles between them). The machines
                // column separates from the workspaces column the way a
                // rail does everywhere else: a slightly darker wash.
                .background(
                    Color.black.opacity(colorScheme == .dark ? 0.14 : 0.05)
                        .allowsHitTesting(false)
                )
                .clipped()

            trailing()
                .id(trailingIdentity)
                .frame(width: max(0, trailingWidth))
                .frame(maxHeight: .infinity)
                .clipped()
        }
        .frame(width: max(0, leadingWidth) + max(0, trailingWidth))
    }
}

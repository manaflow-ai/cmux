import CmuxAppKitSupportUI
import SwiftUI

/// Sidebar-footer button that reveals the full keyboard-shortcut list in a
/// native popover. It is mounted only while the Command-hold shortcut-hint
/// signal is active (see `SidebarFooterButtons`), matching the modifier-hold
/// reveal used for the per-row shortcut badges, so it appears next to the
/// update pill / help button while ⌘ is held and hides on release.
///
/// Uses the same AppKit popover host as Help so the content resolves its colors
/// from the popover's appearance, independently of the sidebar's color scheme.
struct ShortcutDiscoveryButton: View {
    private let buttonSize: CGFloat = 22
    private let iconSize: CGFloat = 11
    private let helpText = String(
        localized: "shortcutDiscovery.button.help",
        defaultValue: "Show all shortcuts"
    )

    /// Owned by the footer so the popover survives releasing ⌘ (which unmounts
    /// the ⌘-hold reveal); the footer keeps this view mounted while it is true.
    @Binding var isPopoverPresented: Bool

    var body: some View {
        Button {
            isPopoverPresented.toggle()
        } label: {
            CmuxSystemSymbolImage(systemName: "keyboard", pointSize: iconSize, weight: .medium, tint: Color(nsColor: .secondaryLabelColor))
                .frame(width: buttonSize, height: buttonSize, alignment: .center)
        }
        .buttonStyle(SidebarFooterIconButtonStyle())
        .frame(width: buttonSize, height: buttonSize, alignment: .center)
        .background(ArrowlessPopoverAnchor(
            isPresented: $isPopoverPresented,
            preferredEdge: .maxY,
            detachedGap: 4
        ) {
            AllShortcutsPopover()
        })
        .accessibilityElement(children: .ignore)
        .safeHelp(helpText)
        .accessibilityLabel(helpText)
        .accessibilityIdentifier("SidebarShortcutDiscoveryButton")
    }
}

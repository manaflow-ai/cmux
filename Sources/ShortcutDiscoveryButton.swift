import SwiftUI

/// Sidebar-footer button that reveals the full keyboard-shortcut list in a
/// native popover. It is mounted only while the Command-hold shortcut-hint
/// signal is active (see `SidebarFooterButtons`), matching the modifier-hold
/// reveal used for the per-row shortcut badges, so it appears next to the
/// update pill / help button while ⌘ is held and hides on release.
///
/// The popover is a native SwiftUI `.popover` (not an AppKit host): it has no
/// first-responder text field, so the hover-tracking pitfalls that pushed other
/// surfaces onto a custom AppKit anchor do not apply here.
struct ShortcutDiscoveryButton: View {
    private let buttonSize: CGFloat = 22
    private let iconSize: CGFloat = 11
    private let helpText = String(
        localized: "shortcutDiscovery.button.help",
        defaultValue: "Show all shortcuts"
    )

    @State private var isPopoverPresented = false

    var body: some View {
        Button {
            isPopoverPresented.toggle()
        } label: {
            CmuxSystemSymbolImage(systemName: "keyboard", pointSize: iconSize, weight: .medium)
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .frame(width: buttonSize, height: buttonSize, alignment: .center)
        }
        .buttonStyle(SidebarFooterIconButtonStyle())
        .frame(width: buttonSize, height: buttonSize, alignment: .center)
        .popover(isPresented: $isPopoverPresented, arrowEdge: .top) {
            AllShortcutsPopover()
        }
        .accessibilityElement(children: .ignore)
        .safeHelp(helpText)
        .accessibilityLabel(helpText)
        .accessibilityIdentifier("SidebarShortcutDiscoveryButton")
    }
}

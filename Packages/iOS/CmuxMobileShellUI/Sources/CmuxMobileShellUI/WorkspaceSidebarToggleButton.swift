#if os(iOS)
import CmuxMobileSupport
import SwiftUI

/// A single shared split-view action. Its owner moves between the sidebar
/// toolbar and the detail bar as the sidebar column changes, so both placements
/// have the same hit target and accessibility identity.
struct WorkspaceSidebarToggleButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "sidebar.left")
                .frame(width: 22, height: 22)
        }
        .accessibilityLabel(
            L10n.string("mobile.sidebar.toggle", defaultValue: "Show or Hide Sidebar")
        )
        .accessibilityIdentifier("MobileSplitSidebarToggle")
        .buttonStyle(.plain)
        .frame(width: WorkspaceRootToolbarSizing.controlHeight, height: WorkspaceRootToolbarSizing.controlHeight)
        .fixedSize()
    }
}

#endif

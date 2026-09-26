import SwiftUI

/// The built-in Beads host on the existing right rail; it owns no terminal panes.
struct BeadsSidebarView: View {
    var body: some View {
        ContentUnavailableView {
            Label(String(localized: "rightSidebar.mode.beads", defaultValue: "Beads"), systemImage: "checklist")
        } description: {
            Text(String(localized: "rightSidebar.beads.unavailable", defaultValue: "This integration is not available yet."))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("RightSidebarBeads")
    }
}

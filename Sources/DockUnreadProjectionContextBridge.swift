import SwiftUI

/// Synchronizes a Dock's changing panel and visibility context into its unread projection.
struct DockUnreadProjectionContextBridge: View {
    let projection: DockUnreadPanelProjection
    let panelIDs: Set<UUID>
    let isActive: Bool

    var body: some View {
        Color.clear
            .onAppear { projection.updateContext(panelIDs: panelIDs, isActive: isActive) }
            .onChange(of: panelIDs) { _, panelIDs in
                projection.updateContext(panelIDs: panelIDs, isActive: isActive)
            }
            .onChange(of: isActive) { _, isActive in
                projection.updateContext(panelIDs: panelIDs, isActive: isActive)
            }
    }
}

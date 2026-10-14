import AppKit
import Observation

/// The sidebar tunables workspace rows draw from (agent mark, presence dots),
/// observed once for every row. Each `WorkspaceRowView.configure` used to arm
/// its own observation, so every status tick left one more registration
/// behind; now a change redraws the live rows from one registration.
@MainActor
final class SidebarTunablesWatch {
    static let shared = SidebarTunablesWatch()

    private let rows = NSHashTable<WorkspaceRowView>.weakObjects()
    private var current: (agentMark: SidebarAgentMarkVariant, presenceDots: Bool)?

    /// The current values; `row` is redrawn when one changes.
    func values(for row: WorkspaceRowView) -> (agentMark: SidebarAgentMarkVariant, presenceDots: Bool) {
        rows.add(row)
        if let current { return current }
        let values = withObservationTracking {
            (SidebarTunables.agentMark.value, SidebarTunables.presenceDots.value)
        } onChange: {
            Task { @MainActor in SidebarTunablesWatch.shared.changed() }
        }
        current = values
        return values
    }

    private func changed() {
        current = nil
        for row in rows.allObjects { row.redrawLastConfiguration() }
    }
}

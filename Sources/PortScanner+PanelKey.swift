import Foundation

extension PortScanner {
    /// Stable identity for one panel's TTY-scoped port snapshot.
    struct PanelKey: Hashable, Sendable {
        let workspaceId: UUID
        let panelId: UUID
    }
}

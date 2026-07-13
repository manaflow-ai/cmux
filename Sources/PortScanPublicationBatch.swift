import Foundation

/// Latest-value publication batch drained as one bounded MainActor pass.
struct PortScanPublicationBatch: Sendable {
    var panelPublicationsByKey: [PortScanner.PanelKey: PanelPortScanPublication] = [:]
    var agentPublicationsByWorkspace: [UUID: AgentPortScanPublication] = [:]

    var isEmpty: Bool {
        panelPublicationsByKey.isEmpty && agentPublicationsByWorkspace.isEmpty
    }
}

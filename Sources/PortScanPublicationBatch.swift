import Foundation

/// Latest-value publication batch drained as one bounded MainActor pass.
struct PortScanPublicationBatch: Sendable {
    var panelPublicationsByKey: [PortScanner.PanelKey: PanelPortScanPublication] = [:]
    var agentPublicationsByWorkspace: [UUID: AgentPortScanPublication] = [:]

    var isEmpty: Bool {
        panelPublicationsByKey.isEmpty && agentPublicationsByWorkspace.isEmpty
    }
}

/// Immutable arrays materialized on the scanner queue before delivery hops to
/// the main actor. This keeps dictionary storage walks and allocation out of
/// the UI publication loop.
struct PortScanPublicationDeliveryBatch: Sendable {
    let panelPublications: [PanelPortScanPublication]
    let agentPublications: [AgentPortScanPublication]
}

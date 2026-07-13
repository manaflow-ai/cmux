import Foundation

/// Latest-value publication batch drained as one bounded MainActor pass.
struct PortScanPublicationBatch: Sendable {
    var panelPortsByKey: [PortScanner.PanelKey: [Int]] = [:]
    var agentPublicationsByWorkspace: [UUID: AgentPortScanPublication] = [:]

    var isEmpty: Bool {
        panelPortsByKey.isEmpty && agentPublicationsByWorkspace.isEmpty
    }
}

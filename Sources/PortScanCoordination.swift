import Foundation

/// Queue-confined ordering and in-flight bounds for local port scans.
struct PortScanCoordination {
    private var nextRequestID: UInt64 = 0
    private var lastAppliedPanelRequestID: UInt64 = 0
    private var lastAppliedAgentRequestIDByWorkspace: [UUID: UInt64] = [:]
    private var panelScanInFlight = false
    private var panelScanPending = false
    private var agentScanInFlight = false
    private var pendingAgentScan: AgentPortScanRequest?

    mutating func makeRequestID() -> UInt64 {
        nextRequestID &+= 1
        return nextRequestID
    }

    mutating func beginPanelScan() -> Bool {
        guard !panelScanInFlight else {
            panelScanPending = true
            return false
        }
        panelScanInFlight = true
        return true
    }

    mutating func finishPanelScan() -> Bool {
        let hadPendingScan = panelScanPending
        panelScanInFlight = false
        panelScanPending = false
        return hadPendingScan
    }

    mutating func shouldApplyPanelResult(requestID: UInt64) -> Bool {
        guard requestID > lastAppliedPanelRequestID else { return false }
        lastAppliedPanelRequestID = requestID
        return true
    }

    mutating func enqueueAgentScan(_ request: AgentPortScanRequest) -> AgentPortScanRequest? {
        guard !agentScanInFlight else {
            pendingAgentScan = pendingAgentScan?.merging(request) ?? request
            return nil
        }
        agentScanInFlight = true
        return request
    }

    mutating func finishAgentScan() -> AgentPortScanRequest? {
        let next = pendingAgentScan
        pendingAgentScan = nil
        agentScanInFlight = next != nil
        return next
    }

    mutating func newAgentWorkspaces(
        _ workspaceIds: Set<UUID>,
        eligibleWorkspaceIds: Set<UUID>,
        requestID: UInt64
    ) -> Set<UUID> {
        let result = Set(workspaceIds.intersection(eligibleWorkspaceIds).filter {
            lastAppliedAgentRequestIDByWorkspace[$0, default: 0] < requestID
        })
        for workspaceId in result {
            lastAppliedAgentRequestIDByWorkspace[workspaceId] = requestID
        }
        return result
    }

    func isLatestAgentResult(workspaceId: UUID, requestID: UInt64) -> Bool {
        lastAppliedAgentRequestIDByWorkspace[workspaceId] == requestID
    }

    mutating func removeAgentWorkspaces(_ workspaceIds: Set<UUID>) {
        for workspaceId in workspaceIds {
            lastAppliedAgentRequestIDByWorkspace.removeValue(forKey: workspaceId)
        }
    }
}

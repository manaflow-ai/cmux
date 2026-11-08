import CmuxControlSocket
import AppKit
import Foundation

/// Process-backed diagnostic adapters; census ownership is shared off-main.
extension TerminalController {
    func taskManagerTopPayload(includeProcesses: Bool) async throws -> [String: Any] {
        try Task.checkCancellation()
        v2RefreshKnownRefs()

        let identifyPayload = v2Identify(params: [:])
        let focused = identifyPayload["focused"] as? [String: Any] ?? [:]
        var windowNodes: [[String: Any]] = []

        if let app = AppDelegate.shared {
            let summaries = app.listMainWindowSummaries()

            for (windowIndex, summary) in summaries.enumerated() {
                guard let manager = app.tabManagerFor(windowId: summary.windowId) else { continue }
                let workspaceNodes = manager.tabs.enumerated().map { workspaceIndex, workspace in
                    v2TopWorkspaceNode(
                        workspace: workspace,
                        index: workspaceIndex,
                        selected: workspace.id == manager.selectedTabId
                    )
                }
                windowNodes.append(
                    v2TopWindowNode(
                        summary: summary,
                        index: windowIndex,
                        workspaceNodes: workspaceNodes
                    )
                )
            }
        }
        v2AttachTopApplicationProcess(to: &windowNodes)

        let payload = await processTopPayload(
            windows: JSONValue(foundationObject: windowNodes) ?? .array([]),
            includeProcesses: includeProcesses
        )
        try Task.checkCancellation()
        var result = JSONValue.object(payload).foundationObject as? [String: Any] ?? [:]
        result["active"] = focused.isEmpty ? (NSNull() as Any) : focused
        result["caller"] = NSNull()
        return result
    }

    nonisolated func processAggregates(
        from processSnapshot: CmuxTopProcessSnapshot,
        totalPIDs: Set<Int>
    ) -> (programs: [[String: Any]], codingAgents: [[String: Any]]) {
        (
            programs: processSnapshot.programSummaryPayload(for: totalPIDs),
            codingAgents: processSnapshot.codingAgentSummaryPayload(for: totalPIDs)
        )
    }

}

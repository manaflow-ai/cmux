import Foundation

extension CmuxTaskManagerSnapshot {
    /// Builds the Coding Agents section: one total row per agent program,
    /// followed by one child row per workspace or surface running it. Child
    /// rows carry the owner IDs so selecting them jumps to that agent.
    static func codingAgentRows(
        from payloads: [[String: Any]],
        hierarchyRows: [CmuxTaskManagerRow]
    ) -> [CmuxTaskManagerRow] {
        let titles = CodingAgentOwnerTitles(hierarchyRows: hierarchyRows)
        var rows: [CmuxTaskManagerRow] = []
        for payload in payloads {
            guard let id = nonEmptyString(payload["id"]),
                  let title = nonEmptyString(payload["display_name"]) else { continue }
            let resources = CmuxTaskManagerResources(payload["resources"] as? [String: Any] ?? [:])
            guard resources.processCount > 0 else { continue }
            let assetName = nonEmptyString(payload["asset_name"])
            rows.append(CmuxTaskManagerRow(
                id: "codingAgentAggregate:\(id)",
                kind: .codingAgentAggregate,
                level: 0,
                title: title,
                detail: processCountDetail(resources.processCount),
                resources: resources,
                isDimmed: false,
                workspaceId: nil,
                surfaceId: nil,
                terminalSurfaceId: nil,
                processId: nil,
                rootProcessIds: resources.processIds,
                foregroundProcessGroupIds: [],
                agentAssetName: assetName
            ))
            let instances = payload["instances"] as? [[String: Any]] ?? []
            rows.append(contentsOf: instances.compactMap { instance in
                codingAgentInstanceRow(instance, agentId: id, assetName: assetName, titles: titles)
            })
        }
        return rows
    }

    private static func codingAgentInstanceRow(
        _ instance: [String: Any],
        agentId: String,
        assetName: String?,
        titles: CodingAgentOwnerTitles
    ) -> CmuxTaskManagerRow? {
        guard let workspaceId = uuid(instance["workspace_id"]) else { return nil }
        let resources = CmuxTaskManagerResources(instance["resources"] as? [String: Any] ?? [:])
        guard resources.processCount > 0 else { return nil }
        let surfaceId = uuid(instance["surface_id"])
        let isTerminal = nonEmptyString(instance["surface_type"])?.lowercased() == "terminal"
        let workspaceTitle = titles.workspaceTitles[workspaceId]
            ?? nonEmptyString(instance["workspace_ref"])
            ?? workspaceId.uuidString
        let surfaceTitle = surfaceId.flatMap { titles.surfaceTitles[$0] }
        var detailParts: [String] = []
        if let surfaceTitle, surfaceTitle != workspaceTitle {
            detailParts.append(surfaceTitle)
        }
        detailParts.append(processCountDetail(resources.processCount))
        let ownerKey = nonEmptyString(instance["id"])
            ?? surfaceId?.uuidString
            ?? workspaceId.uuidString
        return CmuxTaskManagerRow(
            id: "codingAgentInstance:\(agentId):\(ownerKey)",
            kind: surfaceId == nil ? .workspace : (isTerminal ? .terminalSurface : .browserSurface),
            level: 1,
            title: workspaceTitle,
            detail: detailParts.joined(separator: " / "),
            resources: resources,
            isDimmed: false,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            terminalSurfaceId: isTerminal ? surfaceId : nil,
            processId: nil,
            rootProcessIds: resources.processIds,
            foregroundProcessGroupIds: [],
            agentAssetName: assetName
        )
    }
}

/// Workspace and surface titles already parsed from the window hierarchy,
/// so agent rows show the same names as the Hierarchy section.
private struct CodingAgentOwnerTitles {
    var workspaceTitles: [UUID: String] = [:]
    var surfaceTitles: [UUID: String] = [:]

    init(hierarchyRows: [CmuxTaskManagerRow]) {
        for row in hierarchyRows {
            switch row.kind {
            case .workspace:
                if let workspaceId = row.workspaceId, workspaceTitles[workspaceId] == nil {
                    workspaceTitles[workspaceId] = row.title
                }
            case .terminalSurface, .browserSurface:
                if let surfaceId = row.surfaceId, surfaceTitles[surfaceId] == nil {
                    surfaceTitles[surfaceId] = row.title
                }
            default:
                continue
            }
        }
    }
}

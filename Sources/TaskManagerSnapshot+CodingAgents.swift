import Foundation

extension CmuxTaskManagerSnapshot {
    /// Builds the Coding Agents section: one total row per agent program,
    /// followed by one child row per workspace or surface running it. Child
    /// rows carry the owner IDs so selecting them jumps to that agent, and
    /// the terminal's agent state when `agentPanels` reports one.
    /// Hibernated agents have no process to sample, so they are added from
    /// `agentPanels` under their program with zero usage.
    static func codingAgentRows(
        from payloads: [[String: Any]],
        hierarchyRows: [CmuxTaskManagerRow],
        agentPanels: [[String: Any]] = [],
        now: Date = Date()
    ) -> [CmuxTaskManagerRow] {
        let titles = CodingAgentOwnerTitles(hierarchyRows: hierarchyRows)
        let panels = CodingAgentPanelStates(payloads: agentPanels, now: now)
        var groups: [CodingAgentRowGroup] = []
        for payload in payloads {
            guard let id = nonEmptyString(payload["id"]),
                  let title = nonEmptyString(payload["display_name"]) else { continue }
            let resources = CmuxTaskManagerResources(payload["resources"] as? [String: Any] ?? [:])
            guard resources.processCount > 0 else { continue }
            let assetName = nonEmptyString(payload["asset_name"])
            let instances = payload["instances"] as? [[String: Any]] ?? []
            groups.append(CodingAgentRowGroup(
                id: id,
                title: title,
                assetName: assetName,
                resources: resources,
                children: instances.compactMap { instance in
                    codingAgentInstanceRow(
                        instance,
                        agentId: id,
                        assetName: assetName,
                        titles: titles,
                        panels: panels
                    )
                }
            ))
        }
        let liveSurfaceIds = Set(groups.flatMap { $0.children.compactMap(\.surfaceId) })
        for panel in panels.hibernated where !liveSurfaceIds.contains(panel.surfaceId) {
            let agentName = panel.agentName ?? String(
                localized: "taskManager.agentStatus.hibernatedAgent",
                defaultValue: "Hibernated agent"
            )
            // Group by the program's stable id rather than by the name shown:
            // a registered agent can be renamed in project config, and a few
            // program names are localized, so a name comparison can start a
            // second group for a program that already has one. The name match
            // remains for payloads that carry no id.
            let hibernatedGroupId = "hibernated:\(panel.agentId ?? agentName.lowercased())"
            let groupIndex: Int
            if let existingIndex = groups.firstIndex(where: { group in
                if let agentId = panel.agentId {
                    return group.id == agentId || group.id == hibernatedGroupId
                }
                return group.title == agentName
            }) {
                groupIndex = existingIndex
            } else {
                groups.append(CodingAgentRowGroup(
                    id: hibernatedGroupId,
                    title: agentName,
                    assetName: agentAssetName(for: [panel.agentId, agentName]),
                    resources: .zero,
                    children: []
                ))
                groupIndex = groups.count - 1
            }
            let group = groups[groupIndex]
            groups[groupIndex].children.append(hibernatedAgentRow(
                panel,
                agentId: group.id,
                assetName: group.assetName,
                titles: titles
            ))
        }
        return groups.flatMap { $0.rows() }
    }

    private static func codingAgentInstanceRow(
        _ instance: [String: Any],
        agentId: String,
        assetName: String?,
        titles: CodingAgentOwnerTitles,
        panels: CodingAgentPanelStates
    ) -> CmuxTaskManagerRow? {
        guard let workspaceId = uuid(instance["workspace_id"]) else { return nil }
        let resources = CmuxTaskManagerResources(instance["resources"] as? [String: Any] ?? [:])
        guard resources.processCount > 0 else { return nil }
        let surfaceId = uuid(instance["surface_id"])
        let isTerminal = nonEmptyString(instance["surface_type"])?.lowercased() == "terminal"
        let ownerKey = nonEmptyString(instance["id"])
            ?? surfaceId?.uuidString
            ?? workspaceId.uuidString
        return CmuxTaskManagerRow(
            id: "codingAgentInstance:\(agentId):\(ownerKey)",
            kind: surfaceId == nil ? .workspace : (isTerminal ? .terminalSurface : .browserSurface),
            level: 1,
            title: titles.workspaceTitle(workspaceId, fallbackRef: nonEmptyString(instance["workspace_ref"])),
            detail: titles.detail(
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                processCount: processIdentityDetail(instance["processes"] as? [[String: Any]] ?? [])
                    ?? processCountDetail(resources.processCount)
            ),
            resources: resources,
            isDimmed: false,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            terminalSurfaceId: isTerminal ? surfaceId : nil,
            processId: nil,
            rootProcessIds: resources.processIds,
            foregroundProcessGroupIds: [],
            agentAssetName: assetName,
            agentStatus: isTerminal ? surfaceId.flatMap { panels.statusBySurfaceId[$0] } : nil
        )
    }

    /// "PID 61879 (2.1.283)": the PID and OS process name Activity Monitor
    /// shows, so a version-numbered row there maps back to this agent.
    /// Falls back to the process count past three processes.
    static func processIdentityDetail(_ processes: [[String: Any]]) -> String? {
        let identities = processes.compactMap { process -> String? in
            guard let pid = process["pid"] as? Int else { return nil }
            // String(format:) keeps the PID ungrouped ("61879", not "61,879")
            // so it matches Activity Monitor's PID column.
            let pidText = String(format: String(
                localized: "taskManager.killProcess.target.pid",
                defaultValue: "PID %lld"
            ), Int64(pid))
            // The sampler writes "pid-<n>" when it can't read a name.
            guard let name = nonEmptyString(process["name"]), !name.hasPrefix("pid-") else { return pidText }
            return "\(pidText) (\(name))"
        }
        guard !identities.isEmpty, identities.count <= 3 else { return nil }
        return identities.joined(separator: ", ")
    }

    private static func hibernatedAgentRow(
        _ panel: CodingAgentPanelState,
        agentId: String,
        assetName: String?,
        titles: CodingAgentOwnerTitles
    ) -> CmuxTaskManagerRow {
        CmuxTaskManagerRow(
            id: "codingAgentInstance:\(agentId):hibernated:\(panel.surfaceId.uuidString)",
            kind: .terminalSurface,
            level: 1,
            title: titles.workspaceTitle(panel.workspaceId, fallbackRef: nil),
            detail: titles.detail(workspaceId: panel.workspaceId, surfaceId: panel.surfaceId, processCount: nil),
            resources: .zero,
            isDimmed: true,
            workspaceId: panel.workspaceId,
            surfaceId: panel.surfaceId,
            terminalSurfaceId: panel.surfaceId,
            processId: nil,
            rootProcessIds: [],
            foregroundProcessGroupIds: [],
            agentAssetName: assetName,
            agentStatus: panel.status
        )
    }
}

private struct CodingAgentRowGroup {
    let id: String
    let title: String
    let assetName: String?
    let resources: CmuxTaskManagerResources
    var children: [CmuxTaskManagerRow]

    func rows() -> [CmuxTaskManagerRow] {
        let total = CmuxTaskManagerRow(
            id: "codingAgentAggregate:\(id)",
            kind: .codingAgentAggregate,
            level: 0,
            title: title,
            detail: resources.processCount > 0
                ? CmuxTaskManagerSnapshot.processCountDetail(resources.processCount)
                : "",
            resources: resources,
            isDimmed: false,
            workspaceId: nil,
            surfaceId: nil,
            terminalSurfaceId: nil,
            processId: nil,
            rootProcessIds: resources.processIds,
            foregroundProcessGroupIds: [],
            agentAssetName: assetName
        )
        return [total] + children
    }
}

/// Agent state per terminal, parsed from the `agent_panels` payload.
private struct CodingAgentPanelState {
    let workspaceId: UUID
    let surfaceId: UUID
    let status: CmuxTaskManagerAgentStatus
    let agentName: String?
    let agentId: String?
}

private struct CodingAgentPanelStates {
    var statusBySurfaceId: [UUID: CmuxTaskManagerAgentStatus] = [:]
    var hibernated: [CodingAgentPanelState] = []

    init(payloads: [[String: Any]], now: Date) {
        for payload in payloads {
            guard let workspaceId = CmuxTaskManagerSnapshot.uuid(payload["workspace_id"]),
                  let surfaceId = CmuxTaskManagerSnapshot.uuid(payload["surface_id"]) else { continue }
            let state = CmuxTaskManagerAgentStatus.State(
                wireValue: CmuxTaskManagerSnapshot.nonEmptyString(payload["state"]),
                statusText: CmuxTaskManagerSnapshot.nonEmptyString(payload["status_text"])
            )
            let since = CmuxTaskManagerFormat.iso8601Date(CmuxTaskManagerSnapshot.nonEmptyString(payload["since"]))
            let status = CmuxTaskManagerAgentStatus(state: state, since: since, now: now)
            statusBySurfaceId[surfaceId] = status
            if state == .hibernated {
                hibernated.append(CodingAgentPanelState(
                    workspaceId: workspaceId,
                    surfaceId: surfaceId,
                    status: status,
                    agentName: CmuxTaskManagerSnapshot.nonEmptyString(payload["agent_name"]),
                    agentId: CmuxTaskManagerSnapshot.nonEmptyString(payload["agent_id"])
                ))
            }
        }
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

    func workspaceTitle(_ workspaceId: UUID, fallbackRef: String?) -> String {
        workspaceTitles[workspaceId] ?? fallbackRef ?? workspaceId.uuidString
    }

    func detail(workspaceId: UUID, surfaceId: UUID?, processCount: String?) -> String {
        var parts: [String] = []
        if let surfaceTitle = surfaceId.flatMap({ surfaceTitles[$0] }),
           surfaceTitle != workspaceTitles[workspaceId] {
            parts.append(surfaceTitle)
        }
        if let processCount {
            parts.append(processCount)
        }
        return parts.joined(separator: " / ")
    }
}

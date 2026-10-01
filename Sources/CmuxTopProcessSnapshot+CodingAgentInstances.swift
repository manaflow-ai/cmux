import Foundation

extension CmuxTopProcessSnapshot {
    /// Adds an `instances` array to each coding-agent aggregate payload.
    ///
    /// An instance groups the agent's processes by the narrowest cmux owner
    /// (surface, pane or workspace) the top attribution resolved for them, so
    /// the Task Manager can show where each agent runs and jump there.
    /// Processes without a single owner stay counted in the aggregate totals
    /// but produce no instance, so a row never navigates to a guessed owner.
    func codingAgentPayloads(
        _ aggregates: [[String: Any]],
        attributingInstancesWith attributionByPID: [Int: CmuxTopProcessAttribution]
    ) -> [[String: Any]] {
        aggregates.map { aggregate in
            let resources = aggregate["resources"] as? [String: Any] ?? [:]
            let pids = (resources["pids"] as? [Int]) ?? []
            var payload = aggregate
            payload["instances"] = codingAgentInstancePayloads(
                pids: pids,
                attributionByPID: attributionByPID
            )
            return payload
        }
    }

    func codingAgentInstancePayloads(
        pids: [Int],
        attributionByPID: [Int: CmuxTopProcessAttribution]
    ) -> [[String: Any]] {
        var pidsByOwnerKey: [String: Set<Int>] = [:]
        var ownerByKey: [String: CmuxTopProcessOwner] = [:]
        for pid in pids {
            guard let owner = attributionByPID[pid]?.owner,
                  owner.workspaceID != nil,
                  let key = owner.identityKey else { continue }
            pidsByOwnerKey[key, default: []].insert(pid)
            ownerByKey[key] = ownerByKey[key] ?? owner
        }
        return pidsByOwnerKey.keys.sorted().compactMap { key in
            guard let owner = ownerByKey[key],
                  let ownerPIDs = pidsByOwnerKey[key] else { return nil }
            return [
                "id": key,
                "workspace_id": owner.workspaceID?.uuidString as Any? ?? NSNull(),
                "workspace_ref": owner.workspaceRef as Any? ?? NSNull(),
                "pane_id": owner.paneID?.uuidString as Any? ?? NSNull(),
                "surface_id": owner.surfaceID?.uuidString as Any? ?? NSNull(),
                "surface_ref": owner.surfaceRef as Any? ?? NSNull(),
                "surface_type": owner.surfaceType as Any? ?? NSNull(),
                "resources": summaryPayload(for: ownerPIDs),
                // The OS process name is what Activity Monitor lists (for
                // Claude Code, its version number), so the Task Manager can
                // map an Activity Monitor row back to a workspace.
                "processes": ownerPIDs.sorted().compactMap { pid -> [String: Any]? in
                    guard let process = process(pid: pid) else { return nil }
                    return ["pid": pid, "name": process.name]
                }
            ]
        }
    }
}

import CmuxTopMemory
import Darwin
import Foundation

extension TerminalController {
    /// Produces per-process evidence for an annotated top-memory node.
    nonisolated func v2TopProcessAttributionReasons(
        for pids: Set<Int>,
        rootPIDs: Set<Int>,
        processSnapshot: CmuxTopProcessSnapshot,
        rootReason: String
    ) -> [String: String] {
        var reasons: [String: String] = [:]
        for pid in pids.sorted() {
            guard let process = processSnapshot.process(pid: pid) else { continue }
            let reason: String
            if let explicitReason = process.cmuxAttributionReason {
                reason = explicitReason
            } else if rootPIDs.contains(pid) {
                reason = rootReason
            } else if pids.contains(process.parentPID) {
                reason = "child-process"
            } else {
                reason = "included-process"
            }
            reasons[String(pid)] = reason
        }
        return reasons
    }

    /// Filters TTY candidates after the single annotated-window traversal.
    nonisolated func v2TopUnattributedTTYProcessIDs(
        candidates: Set<Int>,
        processSnapshot: CmuxTopProcessSnapshot,
        provenProcessIDs: Set<Int>
    ) -> Set<Int> {
        let appPID = Int(Darwin.getpid())
        return Set(candidates.filter { processID in
            processID > 1 &&
                processID != appPID &&
                processSnapshot.process(pid: processID) != nil &&
                !provenProcessIDs.contains(processID)
        })
    }

    /// Resolves annotated tags, surfaces, and WebKit roots in one pass.
    nonisolated func v2TopMemoryAttributionByPID(
        in windows: [[String: Any]],
        unattributedTTYProcessIDs: inout Set<Int>
    ) -> [Int: CmuxTopProcessAttribution] {
        var nodes: [CmuxTopMemoryAttributionNode] = []
        for window in windows {
            let workspaces = window["workspaces"] as? [[String: Any]] ?? []
            for workspace in workspaces {
                let workspaceID = v2TopUUID(workspace["id"])
                let workspaceRef = v2TopString(workspace["ref"])

                let tags = workspace["tags"] as? [[String: Any]] ?? []
                for tag in tags {
                    nodes.append(topMemoryAttributionNode(
                        workspaceID: workspaceID,
                        workspaceRef: workspaceRef,
                        paneID: nil,
                        paneRef: nil,
                        surfaceID: nil,
                        surfaceRef: nil,
                        surfaceType: nil,
                        defaultReason: "status-tag-process-tree",
                        from: tag
                    ))
                }

                let panes = workspace["panes"] as? [[String: Any]] ?? []
                for pane in panes {
                    let paneID = v2TopUUID(pane["id"])
                    let paneRef = v2TopString(pane["ref"])
                    let surfaces = pane["surfaces"] as? [[String: Any]] ?? []
                    for surface in surfaces {
                        unattributedTTYProcessIDs.formUnion(
                            v2TopIntArray(surface["tty_unattributed_process_pids"])
                        )
                        let surfaceID = v2TopUUID(surface["id"])
                        let surfaceRef = v2TopString(surface["ref"])
                        let surfaceType = v2TopString(surface["type"])
                        nodes.append(topMemoryAttributionNode(
                            workspaceID: workspaceID,
                            workspaceRef: workspaceRef,
                            paneID: paneID,
                            paneRef: paneRef,
                            surfaceID: surfaceID,
                            surfaceRef: surfaceRef,
                            surfaceType: surfaceType,
                            defaultReason: "surface-process-tree",
                            from: surface
                        ))

                        let webviews = surface["webviews"] as? [[String: Any]] ?? []
                        for webview in webviews {
                            nodes.append(topMemoryAttributionNode(
                                workspaceID: workspaceID,
                                workspaceRef: workspaceRef,
                                paneID: paneID,
                                paneRef: paneRef,
                                surfaceID: surfaceID,
                                surfaceRef: surfaceRef,
                                surfaceType: surfaceType,
                                defaultReason: "surface-process-tree",
                                from: webview
                            ))
                        }
                    }
                }
            }
        }

        let resolved = CmuxTopMemoryAttributionResolver().resolve(nodes: nodes)
        return resolved.reduce(into: [:]) { result, entry in
            result[entry.key] = CmuxTopProcessAttribution(
                workspaceID: entry.value.workspaceID,
                workspaceRef: entry.value.workspaceRef,
                paneID: entry.value.paneID,
                paneRef: entry.value.paneRef,
                surfaceID: entry.value.surfaceID,
                surfaceRef: entry.value.surfaceRef,
                surfaceType: entry.value.surfaceType,
                reason: entry.value.reason
            )
        }
    }

    /// Converts one annotated payload node to the package's value input.
    private nonisolated func topMemoryAttributionNode(
        workspaceID: UUID?,
        workspaceRef: String?,
        paneID: UUID?,
        paneRef: String?,
        surfaceID: UUID?,
        surfaceRef: String?,
        surfaceType: String?,
        defaultReason: String,
        from node: [String: Any]
    ) -> CmuxTopMemoryAttributionNode {
        let resources = node["resources"] as? [String: Any] ?? [:]
        return CmuxTopMemoryAttributionNode(
            owner: CmuxTopMemoryOwner(
                workspaceID: workspaceID,
                workspaceRef: workspaceRef,
                paneID: paneID,
                paneRef: paneRef,
                surfaceID: surfaceID,
                surfaceRef: surfaceRef,
                surfaceType: surfaceType
            ),
            defaultReason: defaultReason,
            processIDs: v2TopIntArray(resources["pids"]),
            processReasons: topMemoryProcessReasons(node["process_attribution_reasons"])
        )
    }

    /// Reads the string-keyed reason map emitted by surface annotation.
    private nonisolated func topMemoryProcessReasons(_ raw: Any?) -> [Int: String] {
        if let reasons = raw as? [String: String] {
            return reasons.reduce(into: [:]) { result, entry in
                if let pid = Int(entry.key) { result[pid] = entry.value }
            }
        }
        guard let reasons = raw as? [String: Any] else { return [:] }
        return reasons.reduce(into: [:]) { result, entry in
            guard let pid = Int(entry.key), let reason = entry.value as? String else { return }
            result[pid] = reason
        }
    }
}

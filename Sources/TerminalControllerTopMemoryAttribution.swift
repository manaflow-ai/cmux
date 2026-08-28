import Darwin
import Foundation

extension TerminalController {
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

    nonisolated func v2TopUnattributedTTYProcessIDs(
        in windows: [[String: Any]],
        processSnapshot: CmuxTopProcessSnapshot,
        provenProcessIDs: Set<Int>
    ) -> Set<Int> {
        var processIDs: Set<Int> = []
        for window in windows {
            let workspaces = window["workspaces"] as? [[String: Any]] ?? []
            for workspace in workspaces {
                let panes = workspace["panes"] as? [[String: Any]] ?? []
                for pane in panes {
                    let surfaces = pane["surfaces"] as? [[String: Any]] ?? []
                    for surface in surfaces {
                        processIDs.formUnion(v2TopIntArray(surface["tty_unattributed_process_pids"]))
                    }
                }
            }
        }
        let appPID = Int(Darwin.getpid())
        return Set(processIDs.filter { processID in
            processID > 1 &&
                processID != appPID &&
                processSnapshot.process(pid: processID) != nil &&
                !provenProcessIDs.contains(processID)
        })
    }

    nonisolated func v2TopMemoryAttributionByPID(in windows: [[String: Any]]) -> [Int: CmuxTopProcessAttribution] {
        var result: [Int: CmuxTopProcessAttribution] = [:]
        var ambiguousSpecificityByPID: [Int: Int] = [:]
        var commonOwnerSourceSpecificityByPID: [Int: Int] = [:]
        for window in windows {
            let workspaces = window["workspaces"] as? [[String: Any]] ?? []
            for workspace in workspaces {
                let workspaceID = v2TopUUID(workspace["id"])
                let workspaceRef = v2TopString(workspace["ref"])

                let tags = workspace["tags"] as? [[String: Any]] ?? []
                for tag in tags {
                    let attribution = CmuxTopProcessAttribution(
                        workspaceID: workspaceID,
                        workspaceRef: workspaceRef,
                        paneID: nil,
                        paneRef: nil,
                        surfaceID: nil,
                        surfaceRef: nil,
                        surfaceType: nil,
                        reason: "status-tag-process-tree"
                    )
                    assignTopMemoryAttribution(
                        attribution,
                        from: tag,
                        to: &result,
                        ambiguousSpecificityByPID: &ambiguousSpecificityByPID,
                        commonOwnerSourceSpecificityByPID: &commonOwnerSourceSpecificityByPID
                    )
                }

                let panes = workspace["panes"] as? [[String: Any]] ?? []
                for pane in panes {
                    let paneID = v2TopUUID(pane["id"])
                    let paneRef = v2TopString(pane["ref"])
                    let surfaces = pane["surfaces"] as? [[String: Any]] ?? []
                    for surface in surfaces {
                        let attribution = CmuxTopProcessAttribution(
                            workspaceID: workspaceID,
                            workspaceRef: workspaceRef,
                            paneID: paneID,
                            paneRef: paneRef,
                            surfaceID: v2TopUUID(surface["id"]),
                            surfaceRef: v2TopString(surface["ref"]),
                            surfaceType: v2TopString(surface["type"]),
                            reason: "surface-process-tree"
                        )
                        assignTopMemoryAttribution(
                            attribution,
                            from: surface,
                            to: &result,
                            ambiguousSpecificityByPID: &ambiguousSpecificityByPID,
                            commonOwnerSourceSpecificityByPID: &commonOwnerSourceSpecificityByPID
                        )

                        let webviews = surface["webviews"] as? [[String: Any]] ?? []
                        for webview in webviews {
                            assignTopMemoryAttribution(
                                attribution,
                                from: webview,
                                to: &result,
                                ambiguousSpecificityByPID: &ambiguousSpecificityByPID,
                                commonOwnerSourceSpecificityByPID: &commonOwnerSourceSpecificityByPID
                            )
                        }
                    }
                }
            }
        }
        return result
    }

    private nonisolated func assignTopMemoryAttribution(
        _ attribution: CmuxTopProcessAttribution,
        from node: [String: Any],
        to result: inout [Int: CmuxTopProcessAttribution],
        ambiguousSpecificityByPID: inout [Int: Int],
        commonOwnerSourceSpecificityByPID: inout [Int: Int]
    ) {
        let resources = node["resources"] as? [String: Any] ?? [:]
        let newSpecificity = v2TopMemoryAttributionSpecificity(attribution)
        var seenPIDs = Set<Int>()
        for pid in v2TopIntArray(resources["pids"]) where seenPIDs.insert(pid).inserted {
            let processReason = v2TopProcessReason(
                for: pid,
                in: node["process_attribution_reasons"]
            ) ?? attribution.reason
            let processAttribution = processReason == attribution.reason
                ? attribution
                : CmuxTopProcessAttribution(
                    owner: attribution.owner,
                    reason: processReason
                )
            if let ambiguousSpecificity = ambiguousSpecificityByPID[pid] {
                guard newSpecificity > ambiguousSpecificity else { continue }
                ambiguousSpecificityByPID.removeValue(forKey: pid)
                commonOwnerSourceSpecificityByPID.removeValue(forKey: pid)
            }
            guard let existing = result[pid] else {
                result[pid] = processAttribution
                continue
            }
            if existing == processAttribution { continue }
            let existingSpecificity = v2TopMemoryAttributionSpecificity(existing)
            let commonOwnerSourceSpecificity = commonOwnerSourceSpecificityByPID[pid]
            let existingSourceSpecificity = commonOwnerSourceSpecificity ?? existingSpecificity
            let mergedSourceSpecificity = max(existingSourceSpecificity, newSpecificity)
            if let commonOwner = existing.owner.commonOwner(with: processAttribution.owner),
               commonOwnerSourceSpecificity != nil || newSpecificity == existingSourceSpecificity {
                let sharedReason: String
                switch commonOwner.specificity {
                case 3: sharedReason = "shared-surface-process-tree"
                case 2: sharedReason = "shared-pane-process-tree"
                default: sharedReason = "shared-workspace-process-tree"
                }
                result[pid] = CmuxTopProcessAttribution(owner: commonOwner, reason: sharedReason)
                commonOwnerSourceSpecificityByPID[pid] = mergedSourceSpecificity
            } else if newSpecificity > existingSourceSpecificity {
                result[pid] = processAttribution
                commonOwnerSourceSpecificityByPID.removeValue(forKey: pid)
            } else if newSpecificity == existingSourceSpecificity {
                result.removeValue(forKey: pid)
                ambiguousSpecificityByPID[pid] = newSpecificity
                commonOwnerSourceSpecificityByPID.removeValue(forKey: pid)
            } else {
                continue
            }
        }
    }

    private nonisolated func v2TopProcessReason(
        for pid: Int,
        in rawReasons: Any?
    ) -> String? {
        if let reasons = rawReasons as? [String: String] {
            return reasons[String(pid)]
        }
        guard let reasons = rawReasons as? [String: Any] else { return nil }
        return reasons[String(pid)] as? String
    }

    private nonisolated func v2TopMemoryAttributionSpecificity(_ attribution: CmuxTopProcessAttribution) -> Int {
        attribution.owner.specificity
    }
}

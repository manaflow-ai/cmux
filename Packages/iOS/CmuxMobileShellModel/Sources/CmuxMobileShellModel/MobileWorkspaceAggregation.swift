public import Foundation

/// Pure derivations from the per-Mac state map to aggregated workspace and group shapes.
///
public struct MobileWorkspaceAggregation: Sendable {
    private let rowIDSeparator = "\u{1F}"

    /// Create a workspace aggregation derivation helper.
    public init() {}

    /// The aggregate keys in deterministic display order. A key is the
    /// foreground owner key or a pairing/device id for secondaries; sibling
    /// builds of one Mac order deterministically by instance tag.
    ///
    /// `computerPriority` lists Mac device ids the user ordered by hand
    /// (``MobileWorkspaceSortMode/computerPriority``): matching Macs come
    /// first, in list order, ahead of even the foreground Mac — an explicit
    /// choice must beat the automatic rule or it is not a choice. Sibling
    /// builds of one prioritized Mac stay adjacent (same rank, tag tiebreak),
    /// and Macs not in the list keep the automatic order after the
    /// prioritized ones. Ids that match no live state are ignored.
    ///
    /// `lastOpenedAt` (Mac device id → when this device last used that
    /// computer) drives the automatic "Last Opened" order: foreground first,
    /// then most recent, with unknown computers alphabetical last.
    public func orderedMacIDs(
        statesByMac: [String: MacWorkspaceState],
        foregroundMacDeviceID foregroundKey: String?,
        computerPriority: [String] = [],
        lastOpenedAt: [String: Date] = [:]
    ) -> [String] {
        var priorityRank: [String: Int] = [:]
        for (index, deviceID) in computerPriority.enumerated()
            where !deviceID.isEmpty && priorityRank[deviceID] == nil {
            priorityRank[deviceID] = index
        }
        return statesByMac.sorted { lhs, rhs in
            let lhsRank = priorityRank[lhs.value.macDeviceID] ?? Int.max
            let rhsRank = priorityRank[rhs.value.macDeviceID] ?? Int.max
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            let lhsForeground = lhs.key == foregroundKey
            let rhsForeground = rhs.key == foregroundKey
            if lhsForeground != rhsForeground { return lhsForeground }
            // "Last Opened": most recently used computers lead; unknown ones
            // fall through to the name order below. The foreground check above
            // stays authoritative — the connected Mac is "opened now" even
            // when its stored timestamp lags.
            switch (lastOpenedAt[lhs.value.macDeviceID], lastOpenedAt[rhs.value.macDeviceID]) {
            case let (lhsDate?, rhsDate?) where lhsDate != rhsDate:
                return lhsDate > rhsDate
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                break
            }
            let lhsName = lhs.value.displayName ?? lhs.value.macDeviceID
            let rhsName = rhs.value.displayName ?? rhs.value.macDeviceID
            if lhsName != rhsName { return lhsName.localizedCaseInsensitiveCompare(rhsName) == .orderedAscending }
            if lhs.value.macDeviceID != rhs.value.macDeviceID {
                return lhs.value.macDeviceID < rhs.value.macDeviceID
            }
            return (lhs.value.instanceTag ?? "") < (rhs.value.instanceTag ?? "")
        }.map(\.key)
    }

    /// Return stable color index assignments after appending any newly seen Macs.
    ///
    /// Existing assignments are preserved verbatim. New non-empty Mac IDs are
    /// processed in sorted order and assigned unique slots after the currently
    /// assigned table, so cold-start assignment stays deterministic while a Mac
    /// that was seen earlier keeps its slot across transient live-set changes.
    public func machineColorIndex(
        existingAssignments: [String: Int],
        adding macIDs: [String]
    ) -> [String: Int] {
        var result = existingAssignments
        var usedSlots = Set(result.values)
        var nextSlot = (usedSlots.max() ?? -1) + 1
        for macID in Set(macIDs.filter { !$0.isEmpty }).sorted() where result[macID] == nil {
            while usedSlots.contains(nextSlot) {
                nextSlot += 1
            }
            result[macID] = nextSlot
            usedSlots.insert(nextSlot)
            nextSlot += 1
        }
        return result
    }

    /// Stable row id for one Mac-local workspace inside the aggregated list.
    ///
    /// The separator is the ASCII unit separator, which is not emitted by cmux
    /// workspace ids. The id is opaque and never parsed; the original Mac-local
    /// id remains on ``MobileWorkspacePreview/remoteWorkspaceID`` for RPC.
    public func rowID(
        macDeviceID: String,
        instanceTag: String? = nil,
        workspaceID: MobileWorkspacePreview.ID
    ) -> MobileWorkspacePreview.ID {
        guard let instanceTag, !instanceTag.isEmpty else {
            return MobileWorkspacePreview.ID(
                rawValue: "\(macDeviceID)\(rowIDSeparator)\(workspaceID.rawValue)"
            )
        }
        return MobileWorkspacePreview.ID(
            rawValue: "\(macDeviceID)\(rowIDSeparator)\(instanceTag)\(rowIDSeparator)\(workspaceID.rawValue)"
        )
    }

    /// Stable display id for one Mac-local group inside an aggregated list.
    private func groupID(
        macDeviceID: String,
        instanceTag: String?,
        groupID: MobileWorkspaceGroupPreview.ID
    ) -> MobileWorkspaceGroupPreview.ID {
        guard let instanceTag, !instanceTag.isEmpty else {
            return MobileWorkspaceGroupPreview.ID(
                rawValue: "\(macDeviceID)\(rowIDSeparator)\(groupID.rawValue)"
            )
        }
        return MobileWorkspaceGroupPreview.ID(
            rawValue: "\(macDeviceID)\(rowIDSeparator)\(instanceTag)\(rowIDSeparator)\(groupID.rawValue)"
        )
    }

    /// Derive the flat, ordered workspace list across all Macs.
    public func derivedWorkspaces(
        statesByMac: [String: MacWorkspaceState],
        foregroundMacDeviceID: String?,
        machineColorIndex: [String: Int],
        macIDsInDisplayOrder: [String]? = nil
    ) -> [MobileWorkspacePreview] {
        let shouldScopeRowIDs = statesByMac.keys.filter { !$0.isEmpty }.count > 1
        let orderedMacIDs = macIDsInDisplayOrder ?? orderedMacIDs(
            statesByMac: statesByMac,
            foregroundMacDeviceID: foregroundMacDeviceID
        )
        var result: [MobileWorkspacePreview] = []
        for macID in orderedMacIDs {
            guard let state = statesByMac[macID] else { continue }
            for workspace in state.workspaces {
                let ownerID = workspace.macDeviceID ?? state.macDeviceID
                var stamped = workspace
                if !ownerID.isEmpty {
                    stamped.macDeviceID = ownerID
                    stamped.macDisplayName = state.displayName
                    stamped.machineColorIndex = machineColorIndex[ownerID]
                }
                stamped.macInstanceTag = workspace.macInstanceTag ?? state.instanceTag
                let remoteID = workspace.remoteWorkspaceID ?? workspace.id
                stamped.remoteWorkspaceID = shouldScopeRowIDs && !ownerID.isEmpty ? remoteID : workspace.remoteWorkspaceID
                stamped.macConnectionStatus = state.status
                stamped.actionCapabilities = state.actionCapabilities
                if shouldScopeRowIDs && !ownerID.isEmpty {
                    stamped.id = rowID(
                        macDeviceID: ownerID,
                        instanceTag: stamped.macInstanceTag,
                        workspaceID: remoteID
                    )
                    if let remoteGroupID = workspace.groupID {
                        stamped.groupID = groupID(
                            macDeviceID: ownerID,
                            instanceTag: stamped.macInstanceTag,
                            groupID: remoteGroupID
                        )
                    }
                }
                result.append(stamped)
            }
        }
        return result
    }

    /// Derive group sections from every Mac in the same order as workspaces.
    ///
    /// Group ids are Mac-local, so a multi-Mac list namespaces both group ids
    /// and anchor workspace ids. The original group id remains available through
    /// ``MobileWorkspaceGroupPreview/rpcGroupID`` for mutations.
    public func derivedGroups(
        statesByMac: [String: MacWorkspaceState],
        foregroundMacDeviceID: String?,
        macIDsInDisplayOrder: [String]? = nil
    ) -> [MobileWorkspaceGroupPreview] {
        let shouldScopeIDs = statesByMac.keys.filter { !$0.isEmpty }.count > 1
        let orderedMacIDs = macIDsInDisplayOrder ?? orderedMacIDs(
            statesByMac: statesByMac,
            foregroundMacDeviceID: foregroundMacDeviceID
        )
        var result: [MobileWorkspaceGroupPreview] = []
        for macID in orderedMacIDs {
            guard let state = statesByMac[macID] else { continue }
            let remoteWorkspaceIDByLocalID = Dictionary(
                uniqueKeysWithValues: state.workspaces.map { workspace in
                    (workspace.id, workspace.remoteWorkspaceID ?? workspace.id)
                }
            )
            for group in state.groups {
                let remoteGroupID = group.remoteGroupID ?? group.id
                var stamped = group
                stamped.remoteGroupID = shouldScopeIDs ? remoteGroupID : group.remoteGroupID
                stamped.macDeviceID = state.macDeviceID
                stamped.macInstanceTag = state.instanceTag
                guard shouldScopeIDs, !state.macDeviceID.isEmpty else {
                    result.append(stamped)
                    continue
                }
                stamped.id = groupID(
                    macDeviceID: state.macDeviceID,
                    instanceTag: state.instanceTag,
                    groupID: remoteGroupID
                )
                let remoteAnchorID = remoteWorkspaceIDByLocalID[group.anchorWorkspaceID]
                    ?? group.anchorWorkspaceID
                stamped.anchorWorkspaceID = rowID(
                    macDeviceID: state.macDeviceID,
                    instanceTag: state.instanceTag,
                    workspaceID: remoteAnchorID
                )
                result.append(stamped)
            }
        }
        return result
    }
}

import CMUXMobileCore
public import Foundation

/// Pure derivations from the per-Mac state map to aggregated workspace and group shapes.
///
public struct MobileWorkspaceAggregation: Sendable {
    /// Create a workspace aggregation derivation helper.
    public init() {}

    /// The aggregate keys in deterministic display order. A key is the
    /// foreground owner key or a pairing/device id for secondaries; sibling
    /// builds of one Mac order deterministically by instance tag.
    ///
    /// `computerPriority` lists aggregate computer identities the user ordered
    /// by hand
    /// (``MobileWorkspaceSortMode/computerPriority``): matching Macs come
    /// first, in list order, ahead of even the foreground Mac — an explicit
    /// choice must beat the automatic rule or it is not a choice. An identity
    /// is the same device-plus-instance-tag key used by `statesByMac`, so
    /// sibling builds can be ordered independently. Legacy bare device ids
    /// only rank untagged rows, since tagged builds are independent computers.
    /// Ids that match no live state are ignored.
    ///
    /// `lastOpenedAt` (exact pairing id → when this build last used that
    /// computer) drives the automatic "Last Opened" order: foreground first,
    /// then most recent, with unknown computers alphabetical last. Legacy bare
    /// device keys remain readable for untagged callers.
    public func orderedMacIDs(
        statesByMac: [String: MacWorkspaceState],
        foregroundMacDeviceID foregroundKey: String?,
        computerPriority: [String] = [],
        lastOpenedAt: [String: Date] = [:]
    ) -> [String] {
        var priorityRank: [String: Int] = [:]
        for (index, computerID) in computerPriority.enumerated()
            where !computerID.isEmpty {
            let identityID = CmxMacAppInstanceIdentity(id: computerID).id
            if priorityRank[identityID] == nil {
                priorityRank[identityID] = index
            }
        }
        let normalizedLastOpenedAt = lastOpenedAt.reduce(into: [String: Date]()) { result, entry in
            let identityID = CmxMacAppInstanceIdentity(id: entry.key).id
            if result[identityID] == nil { result[identityID] = entry.value }
        }
        let normalizedForegroundID = foregroundKey.map {
            CmxMacAppInstanceIdentity(id: $0).id
        }
        return statesByMac.sorted { lhs, rhs in
            let lhsIdentityID = CmxMacAppInstanceIdentity(
                macDeviceID: lhs.value.macDeviceID,
                instanceTag: lhs.value.instanceTag
            ).id
            let rhsIdentityID = CmxMacAppInstanceIdentity(
                macDeviceID: rhs.value.macDeviceID,
                instanceTag: rhs.value.instanceTag
            ).id
            let lhsRank = priorityRank[lhsIdentityID]
                ?? (lhs.value.instanceTag == nil
                    ? priorityRank[CmxMacAppInstanceIdentity(
                        macDeviceID: lhs.value.macDeviceID,
                        instanceTag: nil
                    ).id]
                    : nil)
                ?? Int.max
            let rhsRank = priorityRank[rhsIdentityID]
                ?? (rhs.value.instanceTag == nil
                    ? priorityRank[CmxMacAppInstanceIdentity(
                        macDeviceID: rhs.value.macDeviceID,
                        instanceTag: nil
                    ).id]
                    : nil)
                ?? Int.max
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            let lhsForeground = lhsIdentityID == normalizedForegroundID
            let rhsForeground = rhsIdentityID == normalizedForegroundID
            if lhsForeground != rhsForeground { return lhsForeground }
            // "Last Opened": most recently used computers lead; unknown ones
            // fall through to the name order below. The foreground check above
            // stays authoritative — the connected Mac is "opened now" even
            // when its stored timestamp lags.
            let lhsLastOpened = normalizedLastOpenedAt[lhsIdentityID]
                ?? (lhs.value.instanceTag == nil
                    ? normalizedLastOpenedAt[CmxMacAppInstanceIdentity(
                        macDeviceID: lhs.value.macDeviceID,
                        instanceTag: nil
                    ).id]
                    : nil)
            let rhsLastOpened = normalizedLastOpenedAt[rhsIdentityID]
                ?? (rhs.value.instanceTag == nil
                    ? normalizedLastOpenedAt[CmxMacAppInstanceIdentity(
                        macDeviceID: rhs.value.macDeviceID,
                        instanceTag: nil
                    ).id]
                    : nil)
            switch (lhsLastOpened, rhsLastOpened) {
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
        let ownerID = CmxMacAppInstanceIdentity(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag
        ).id
        return MobileWorkspacePreview.ID(
            rawValue: "\(ownerID)\u{1F}\(workspaceID.rawValue)"
        )
    }

    /// Stable display id for one Mac-local group inside an aggregated list.
    private func groupID(
        macDeviceID: String,
        instanceTag: String?,
        groupID: MobileWorkspaceGroupPreview.ID
    ) -> MobileWorkspaceGroupPreview.ID {
        let ownerID = CmxMacAppInstanceIdentity(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag
        ).id
        return MobileWorkspaceGroupPreview.ID(
            rawValue: "\(ownerID)\u{1F}\(groupID.rawValue)"
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
                }
                stamped.macInstanceTag = workspace.macInstanceTag ?? state.instanceTag
                stamped.machineColorIndex = machineColorIndex[
                    pairingID(macDeviceID: ownerID, instanceTag: stamped.macInstanceTag)
                ] ?? (stamped.macInstanceTag == nil ? machineColorIndex[ownerID] : nil)
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

    private func pairingID(macDeviceID: String, instanceTag: String?) -> String {
        CmxMacAppInstanceIdentity(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag
        ).id
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
                // Group actions are scoped to the owning Mac, so retain that
                // capability snapshot even when this group has no live anchor
                // workspace to carry it.
                stamped.actionCapabilities = state.actionCapabilities
                guard shouldScopeIDs, !state.macDeviceID.isEmpty else {
                    result.append(stamped)
                    continue
                }
                stamped.id = groupID(
                    macDeviceID: state.macDeviceID,
                    instanceTag: state.instanceTag,
                    groupID: remoteGroupID
                )
                if let liveAnchorWorkspaceID = group.liveAnchorWorkspaceID {
                    let remoteAnchorID = remoteWorkspaceIDByLocalID[liveAnchorWorkspaceID]
                        ?? liveAnchorWorkspaceID
                    stamped.anchorWorkspaceID = rowID(
                        macDeviceID: state.macDeviceID,
                        instanceTag: state.instanceTag,
                        workspaceID: remoteAnchorID
                    )
                } else {
                    // Empty headers have no workspace row to namespace; use
                    // the already-namespaced group id only as a stable UI row
                    // identity, never as a workspace capability.
                    stamped.anchorWorkspaceID = stamped.id
                }
                result.append(stamped)
            }
        }
        return result
    }
}

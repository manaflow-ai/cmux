import Foundation

/// Pure derivations from the per-Mac state map to the flat, user-facing shapes.
///
public struct MobileWorkspaceAggregation: Sendable {
    private let rowIDSeparator = "\u{1F}"

    /// Create a workspace aggregation derivation helper.
    public init() {}

    /// The Macs in deterministic display order.
    public func orderedMacIDs(
        statesByMac: [String: MacWorkspaceState],
        foregroundMacDeviceID: String?
    ) -> [String] {
        statesByMac.values.sorted { lhs, rhs in
            let lhsForeground = lhs.macDeviceID == foregroundMacDeviceID
            let rhsForeground = rhs.macDeviceID == foregroundMacDeviceID
            if lhsForeground != rhsForeground { return lhsForeground }
            let lhsName = lhs.displayName ?? lhs.macDeviceID
            let rhsName = rhs.displayName ?? rhs.macDeviceID
            if lhsName != rhsName { return lhsName.localizedCaseInsensitiveCompare(rhsName) == .orderedAscending }
            return lhs.macDeviceID < rhs.macDeviceID
        }.map(\.macDeviceID)
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
        workspaceID: MobileWorkspacePreview.ID
    ) -> MobileWorkspacePreview.ID {
        MobileWorkspacePreview.ID(rawValue: "\(macDeviceID)\(rowIDSeparator)\(workspaceID.rawValue)")
    }

    /// Derive the flat, ordered workspace list across all Macs.
    public func derivedWorkspaces(
        statesByMac: [String: MacWorkspaceState],
        foregroundMacDeviceID: String?,
        machineColorIndex: [String: Int]
    ) -> [MobileWorkspacePreview] {
        let shouldScopeRowIDs = statesByMac.keys.filter { !$0.isEmpty }.count > 1
        var result: [MobileWorkspacePreview] = []
        for macID in orderedMacIDs(statesByMac: statesByMac, foregroundMacDeviceID: foregroundMacDeviceID) {
            guard let state = statesByMac[macID] else { continue }
            for workspace in state.workspaces {
                let ownerID = workspace.macDeviceID ?? state.macDeviceID
                var stamped = workspace
                if !ownerID.isEmpty {
                    stamped.macDeviceID = ownerID
                    stamped.macDisplayName = state.displayName
                    stamped.machineColorIndex = machineColorIndex[ownerID]
                }
                let remoteID = workspace.remoteWorkspaceID ?? workspace.id
                stamped.remoteWorkspaceID = shouldScopeRowIDs && !ownerID.isEmpty ? remoteID : workspace.remoteWorkspaceID
                stamped.macConnectionStatus = state.status
                stamped.actionCapabilities = state.actionCapabilities
                if shouldScopeRowIDs && !ownerID.isEmpty {
                    stamped.id = rowID(macDeviceID: ownerID, workspaceID: remoteID)
                }
                result.append(stamped)
            }
        }
        return result
    }

    /// Derive the group sections to show for the foreground Mac.
    public func derivedGroups(
        statesByMac: [String: MacWorkspaceState],
        foregroundMacDeviceID: String?
    ) -> [MobileWorkspaceGroupPreview] {
        guard let foregroundMacDeviceID, let state = statesByMac[foregroundMacDeviceID] else { return [] }
        let shouldScopeRowIDs = statesByMac.keys.filter { !$0.isEmpty }.count > 1
        guard shouldScopeRowIDs, !foregroundMacDeviceID.isEmpty else { return state.groups }
        let remoteIDByLocalID = Dictionary(
            uniqueKeysWithValues: state.workspaces.map { workspace in
                (workspace.id, workspace.remoteWorkspaceID ?? workspace.id)
            }
        )
        return state.groups.map { group in
            var scoped = group
            let remoteID = remoteIDByLocalID[group.anchorWorkspaceID] ?? group.anchorWorkspaceID
            scoped.anchorWorkspaceID = rowID(macDeviceID: foregroundMacDeviceID, workspaceID: remoteID)
            return scoped
        }
    }
}

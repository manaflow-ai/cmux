/// Pure derivations from the per-Mac state map to the flat, user-facing shapes.
///
/// This is intentionally a pure namespace, not an injectable service: every
/// function is a total, side-effect-free function of its inputs (same input,
/// same output), and unit tests cover the derivation directly.
public enum MobileWorkspaceAggregation {
    /// The Macs in deterministic display order.
    public static func orderedMacIDs(
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

    /// A distinct stable color index per Mac, keyed by `macDeviceID`.
    public static func machineColorIndex(
        statesByMac: [String: MacWorkspaceState]
    ) -> [String: Int] {
        var result: [String: Int] = [:]
        for (offset, macID) in statesByMac.keys.filter({ !$0.isEmpty }).sorted().enumerated() {
            result[macID] = offset
        }
        return result
    }

    /// Derive the flat, ordered, de-duplicated workspace list across all Macs.
    public static func derivedWorkspaces(
        statesByMac: [String: MacWorkspaceState],
        foregroundMacDeviceID: String?
    ) -> [MobileWorkspacePreview] {
        let colorIndex = machineColorIndex(statesByMac: statesByMac)
        var result: [MobileWorkspacePreview] = []
        var seen = Set<MobileWorkspacePreview.ID>()
        for macID in orderedMacIDs(statesByMac: statesByMac, foregroundMacDeviceID: foregroundMacDeviceID) {
            guard let state = statesByMac[macID] else { continue }
            for workspace in state.workspaces where seen.insert(workspace.id).inserted {
                var stamped = workspace
                stamped.machineColorIndex = workspace.macDeviceID.flatMap { colorIndex[$0] }
                result.append(stamped)
            }
        }
        return result
    }

    /// Derive the group sections to show for the foreground Mac.
    public static func derivedGroups(
        statesByMac: [String: MacWorkspaceState],
        foregroundMacDeviceID: String?
    ) -> [MobileWorkspaceGroupPreview] {
        guard let foregroundMacDeviceID, let state = statesByMac[foregroundMacDeviceID] else { return [] }
        return state.groups
    }
}

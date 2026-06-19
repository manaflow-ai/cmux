public import Foundation

/// The phone's view of ONE Mac's workspaces: the per-Mac source of truth behind
/// the aggregated multi-Mac workspace list. The published flat list (and group
/// sections) is a PURE DERIVATION over every Mac's `MacWorkspaceState` — see
/// ``MobileWorkspaceAggregation``. Nothing assigns the flat list directly; it is
/// always `derive(statesByMac:foregroundMacDeviceID:)`, so a stale or
/// half-merged aggregate is unrepresentable.
///
/// Deliberately transport-agnostic. Today each entry is fed by a direct
/// phone→Mac live subscription (N connections). The planned end-state routes
/// every Mac through a single Durable Object that the phone holds ONE connection
/// to, which delivers per-Mac deltas; the data model and the derivation are
/// identical either way — only the writer of these entries changes. So this type
/// carries no connection/RPC/route detail, only the observable facts about a
/// Mac's workspaces.
public struct MacWorkspaceState: Identifiable, Equatable, Sendable {
    /// The stable device id of the Mac this state describes. Also the dictionary
    /// key in the aggregate, and the `id` for `Identifiable`.
    public var macDeviceID: String
    /// The Mac's user-facing display name, for per-Mac sections/labels.
    public var displayName: String?
    /// This Mac's workspaces, each already tagged with `macDeviceID` so the
    /// derived list can group and filter by machine without re-stamping.
    public var workspaces: [MobileWorkspacePreview]
    /// This Mac's workspace groups, in section order (empty when the Mac reports
    /// none or is too old to emit them).
    public var groups: [MobileWorkspaceGroupPreview]
    /// Liveness of THIS Mac's data, so the UI can show per-Mac
    /// connecting/reconnecting/offline and the derivation can decide whether a
    /// dropped Mac's last-known rows stay (greyed) or are dropped.
    public var status: MobileMacConnectionStatus

    public var id: String { macDeviceID }

    public init(
        macDeviceID: String,
        displayName: String? = nil,
        workspaces: [MobileWorkspacePreview] = [],
        groups: [MobileWorkspaceGroupPreview] = [],
        status: MobileMacConnectionStatus = .reconnecting
    ) {
        self.macDeviceID = macDeviceID
        self.displayName = displayName
        self.workspaces = workspaces
        self.groups = groups
        self.status = status
    }
}

/// Pure derivations from the per-Mac state map to the flat, user-facing shapes.
///
/// Every function here is a total, side-effect-free function of its inputs (same
/// input → same output), so the aggregate can be recomputed any time a single
/// Mac's `MacWorkspaceState` changes, from any source (direct connection today,
/// a Durable Object stream later), with no ordering or staleness coupling.
public enum MobileWorkspaceAggregation {
    /// The Macs in display order: the foreground Mac first (its workspaces are the
    /// interactive ones and sort to the top), then the rest by display name, then
    /// by `macDeviceID` as a stable tiebreaker. Deterministic so the list never
    /// reshuffles on an unrelated per-Mac update.
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

    /// Derive the flat, ordered, de-duplicated workspace list across all Macs.
    /// Foreground Mac first, then the rest in `orderedMacIDs` order. De-dup by
    /// workspace id (the foreground Mac wins a collision, since its row is the
    /// live interactive one). Pure and transport-agnostic.
    public static func derivedWorkspaces(
        statesByMac: [String: MacWorkspaceState],
        foregroundMacDeviceID: String?
    ) -> [MobileWorkspacePreview] {
        var result: [MobileWorkspacePreview] = []
        var seen = Set<MobileWorkspacePreview.ID>()
        for macID in orderedMacIDs(statesByMac: statesByMac, foregroundMacDeviceID: foregroundMacDeviceID) {
            guard let state = statesByMac[macID] else { continue }
            for workspace in state.workspaces where seen.insert(workspace.id).inserted {
                result.append(workspace)
            }
        }
        return result
    }

    /// Derive the group sections to show. Groups are a per-Mac concept and the
    /// list currently renders one Mac's sections, so this returns the foreground
    /// Mac's groups (empty when there is no foreground Mac or it reports none).
    /// Per-Mac group sections are a follow-on; keeping this a pure function of the
    /// state map means that change is local to this derivation.
    public static func derivedGroups(
        statesByMac: [String: MacWorkspaceState],
        foregroundMacDeviceID: String?
    ) -> [MobileWorkspaceGroupPreview] {
        guard let foregroundMacDeviceID, let state = statesByMac[foregroundMacDeviceID] else { return [] }
        return state.groups
    }
}

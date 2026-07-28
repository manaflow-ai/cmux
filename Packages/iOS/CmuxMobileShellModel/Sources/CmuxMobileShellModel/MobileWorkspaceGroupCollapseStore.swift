public import Foundation

/// Device-local collapse state for workspace groups, persisted in an injected
/// `UserDefaults`.
///
/// Folder collapse is a per-device UI preference, not shared state: collapsing a
/// group on the phone must not collapse it on the Mac, and vice versa. The Mac
/// still owns the group model (name, membership, pin), and its workspace-list RPC
/// reports an `isCollapsed`, but iOS treats that value only as the SEED for a
/// group it has never seen. After first sight the group's collapse is whatever
/// this device last chose; the Mac's value no longer overrides it, and a local
/// toggle is never sent back to the Mac.
///
/// The backing `UserDefaults` is injected so the store is testable without
/// touching `.standard` (mirroring `MobileOnboardingStore`); the app constructs it
/// at the composition root with `UserDefaults.standard`.
///
/// ```swift
/// var store = MobileWorkspaceGroupCollapseStore(defaults: .standard)
/// let shown = store.apply(to: groupsFromMac)   // seeds unknown groups, applies local
/// store.set(groupID, collapsed: true)          // device-local, not sent to the Mac
/// ```
public struct MobileWorkspaceGroupCollapseStore: Sendable {
    /// The defaults key under which the `[groupID: collapsed]` map is stored.
    public static let defaultsKey = "dev.cmux.mobile.workspaceGroup.collapse.v1"

    // UserDefaults is Apple-documented thread-safe; OK to hold nonisolated.
    private nonisolated(unsafe) let defaults: UserDefaults
    /// groupID.rawValue -> this device's collapse decision. The map doubles as the
    /// "have I seen this group?" set: a present key means the group's collapse is
    /// device-owned; an absent key means it still inherits the Mac's seed.
    private var map: [String: Bool]

    /// Create a store backed by the given defaults.
    /// - Parameter defaults: The persistence store for the collapse map. Inject a
    ///   suite-scoped `UserDefaults` in tests; the app passes `.standard`.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([String: Bool].self, from: data) {
            map = decoded
        } else {
            map = [:]
        }
    }

    /// This device's collapse decision for a group, or `nil` if the group has not
    /// been seen yet (still inheriting the Mac's seed).
    public func isCollapsed(_ id: String) -> Bool? { map[id] }

    /// Record a device-local collapse decision for a group. Persists immediately
    /// and never contacts the Mac.
    public mutating func set(_ id: String, collapsed: Bool) {
        guard map[id] != collapsed else { return }
        map[id] = collapsed
        persist()
    }

    /// Apply device-local collapse to a freshly received group list from the Mac.
    ///
    /// For each group: if this device already has a decision, override the group's
    /// `isCollapsed` with it; otherwise seed the device decision from the Mac's
    /// reported value (initial inheritance) and keep that. Entries for groups no
    /// longer present are dropped so the map stays bounded by the live group count.
    /// - Parameter groups: The groups as reported by the Mac.
    /// - Returns: The same groups with `isCollapsed` reflecting this device.
    public mutating func apply(to groups: [MobileWorkspaceGroupPreview]) -> [MobileWorkspaceGroupPreview] {
        let liveIDs = Set(groups.map(\.id.rawValue))
        var changed = false

        // Prune decisions for groups that no longer exist (renamed-away/deleted),
        // keeping the map bounded by the number of live groups.
        for key in map.keys where !liveIDs.contains(key) {
            map.removeValue(forKey: key)
            changed = true
        }

        let resolved = groups.map { group -> MobileWorkspaceGroupPreview in
            var group = group
            let key = group.id.rawValue
            if let local = map[key] {
                group.isCollapsed = local
            } else {
                // First time this device sees the group: inherit the Mac's value.
                map[key] = group.isCollapsed
                changed = true
            }
            return group
        }

        if changed { persist() }
        return resolved
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(map) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}

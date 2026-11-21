import Foundation

/// What a window's saved record takes from the window's workspace list: its own workspaces' keys, the machine of those
/// not on this Mac, and the set the record's other fields are checked against. A workspace, space or tab switch
/// changes none of them, so the save it asks for keeps them (`WindowRecordSaver`) and walks no workspace: the checks
/// of `matches` answer from storage identity while the list, its guests and the machines map are the ones it was
/// built from (`SwitchSaveCostTests`).
public struct WindowListMembership<Key: Hashable> {
    private let workspaceIDs: [String]
    private let guests: Set<String>
    private var machines: [String: String]
    public let listed: Set<String>
    /// The window's own workspaces (not its guests: a guest is its owner's to save), as `key` makes them.
    public let ownedKeys: [Key]
    /// The machine each listed workspace was last seen on, when not `localID`.
    public let workspaceMachines: [String: String]

    public init(window: WindowRegistry.Window, machines: [String: String], localID: String, key: (String) -> Key) {
        workspaceIDs = window.workspaceIDs
        guests = window.guests
        self.machines = machines
        listed = Set(window.workspaceIDs)
        ownedKeys = window.ownedIDs.map(key)
        var seen: [String: String] = [:]
        for workspace in window.workspaceIDs {
            if let machine = machines[workspace], machine != localID { seen[workspace] = machine }
        }
        workspaceMachines = seen
    }

    /// Whether this was built from `window`'s list and guests and from `machines`. An equal map in other storage
    /// (written again with the same values) is kept, so the next check answers from identity again.
    public mutating func matches(_ window: WindowRegistry.Window, machines: [String: String]) -> Bool {
        guard workspaceIDs == window.workspaceIDs, guests == window.guests, self.machines == machines else { return false }
        self.machines = machines
        return true
    }
}

/// Each window's `WindowListMembership`, kept while its list, guests and machines are the same.
public struct WindowListMemberships<Key: Hashable> {
    private var kept: [String: WindowListMembership<Key>] = [:]
    /// Workspace lists walked, since it was made: one per membership change, none per switch (`SwitchSaveCostTests`).
    public private(set) var builds = 0

    public init() {}

    public mutating func of(_ window: WindowRegistry.Window, machines: [String: String], localID: String,
                            key: (String) -> Key) -> WindowListMembership<Key> {
        if var membership = kept[window.id], membership.matches(window, machines: machines) {
            kept[window.id] = membership
            return membership
        }
        builds += 1
        let built = WindowListMembership(window: window, machines: machines, localID: localID, key: key)
        kept[window.id] = built
        return built
    }

    /// Forgets the windows `exists` no longer finds.
    public mutating func keep(_ exists: (String) -> Bool) {
        kept = kept.filter { exists($0.key) }
    }
}

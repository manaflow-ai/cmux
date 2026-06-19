/// A compound predicate over workspace rows, shared by every surface that lists
/// workspaces (the flat workspace list and the device tree).
///
/// Two orthogonal, composable dimensions instead of one flat toggle, so the
/// aggregated multi-Mac list can express e.g. "unread on Mac X and Mac Y":
///   - `readState`: all rows, or only those with unread activity.
///   - `machines`: a set of `macDeviceID`s to include; empty means every machine.
///
/// A row passes when it satisfies BOTH dimensions. The identity filter
/// (`readState == .all`, `machines` empty) shows everything.
public struct MobileWorkspaceListFilter: Hashable, Sendable {
    /// The read-state dimension.
    public enum ReadState: String, CaseIterable, Hashable, Sendable {
        /// No read-state narrowing; every row matches.
        case all
        /// Only workspaces with unread activity (the iMessage-style unread dot).
        case unread
    }

    public var readState: ReadState
    /// `macDeviceID`s to include. Empty means all machines (no machine narrowing).
    public var machines: Set<String>

    public init(readState: ReadState = .all, machines: Set<String> = []) {
        self.readState = readState
        self.machines = machines
    }

    /// The identity filter: show every workspace.
    public static let all = MobileWorkspaceListFilter()

    /// Whether `workspace` passes both dimensions.
    /// - Parameter workspace: The workspace row under consideration.
    /// - Returns: `true` when the row should be shown.
    public func matches(_ workspace: MobileWorkspacePreview) -> Bool {
        let readOK: Bool
        switch readState {
        case .all: readOK = true
        case .unread: readOK = workspace.hasUnread
        }
        // A machine filter only matches rows whose owning Mac is in the set; a
        // row with an unknown machine (an older Mac that didn't report one) is
        // excluded while a machine filter is active, since it can't be confirmed
        // to belong to a selected machine.
        let machineOK = machines.isEmpty || (workspace.macDeviceID.map(machines.contains) ?? false)
        return readOK && machineOK
    }

    /// Whether this filter actually narrows the list (drives the filled-vs-
    /// outlined filter icon and the empty-state copy).
    public var isActive: Bool { readState != .all || !machines.isEmpty }

    /// Add or remove a machine from the filter set.
    public mutating func toggleMachine(_ macDeviceID: String) {
        if machines.contains(macDeviceID) {
            machines.remove(macDeviceID)
        } else {
            machines.insert(macDeviceID)
        }
    }
}

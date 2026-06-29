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
    /// Read-state narrowing for the filter.
    public var readState: MobileWorkspaceReadStateFilter
    /// `macDeviceID`s to include. Empty means all machines (no machine narrowing).
    public var machines: Set<String>

    /// Create a workspace list filter from read-state and machine dimensions.
    public init(readState: MobileWorkspaceReadStateFilter = .all, machines: Set<String> = []) {
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

    /// The distinct machine ids present in a workspace list, in first-appearance
    /// order. Drives the machine multi-select in the filter menu: only machines
    /// that actually have rows are offered, and the menu hides the section
    /// entirely when there are fewer than two. Workspaces with no known machine
    /// are skipped (they can't be filtered by machine).
    public static func machineIDs(in workspaces: [MobileWorkspacePreview]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for workspace in workspaces {
            guard let macDeviceID = workspace.macDeviceID else { continue }
            if seen.insert(macDeviceID).inserted {
                ordered.append(macDeviceID)
            }
        }
        return ordered
    }

    /// Drop any selected machines that are no longer present in the list, so a
    /// machine filter for a Mac that disconnected/disappeared does not silently
    /// hide everything. Returns whether the filter changed.
    @discardableResult
    public mutating func pruneMachines(notIn present: [String]) -> Bool {
        let presentSet = Set(present)
        let kept = machines.intersection(presentSet)
        guard kept != machines else { return false }
        machines = kept
        return true
    }
}

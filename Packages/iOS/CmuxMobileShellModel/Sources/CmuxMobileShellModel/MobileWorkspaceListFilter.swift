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
        matches(workspace, parsedMachines: Self.parsedMachineEntries(machines))
    }

    /// Row-projection variant: `parsedMachines` is this filter's `machines`
    /// parsed once by the caller, so filtering N rows does not re-split each
    /// scope entry N times.
    public func matches(
        _ workspace: MobileWorkspacePreview,
        parsedMachines: [ParsedMachineEntry]
    ) -> Bool {
        let readOK: Bool
        switch readState {
        case .all: readOK = true
        case .unread: readOK = workspace.hasUnread
        }
        // A machine filter only matches rows whose owning Mac is in the set; a
        // row with an unknown machine (an older Mac that didn't report one) is
        // excluded while a machine filter is active, since it can't be confirmed
        // to belong to a selected machine. An entry may be a bare device id
        // (matches every build on that device) or a pairing id
        // (device + unit separator + tag: matches only that build's rows).
        let machineOK = parsedMachines.isEmpty || (workspace.macDeviceID.map { deviceID in
            parsedMachines.contains(where: {
                $0.matches(deviceID: deviceID, rowTag: workspace.macInstanceTag)
            })
        } ?? false)
        return readOK && machineOK
    }

    /// The pairing-id separator shared with `MobilePairedMac.pairingID`.
    private static let pairingSeparator: Character = "\u{1F}"

    public static func machineEntryMatches(
        _ entry: String,
        deviceID: String,
        rowTag: String?
    ) -> Bool {
        ParsedMachineEntry(entry).matches(deviceID: deviceID, rowTag: rowTag)
    }

    /// One preparsed scope entry (a bare device id or a composite pairing id).
    /// Row projection runs per workspace row and per retained notification, so
    /// callers parse each selected entry ONCE and reuse it instead of
    /// splitting/allocating strings on every row.
    public struct ParsedMachineEntry: Sendable {
        public let deviceID: String
        /// `nil` for a device-level entry; a device-level entry matches every
        /// build's rows on that device.
        public let instanceTag: String?

        public init(_ entry: String) {
            let parts = entry.split(
                separator: pairingSeparator, maxSplits: 1, omittingEmptySubsequences: false
            )
            self.deviceID = parts.first.map(String.init) ?? entry
            self.instanceTag = parts.count == 2 ? String(parts[1]) : nil
        }

        public func matches(deviceID rowDeviceID: String, rowTag: String?) -> Bool {
            guard deviceID == rowDeviceID else { return false }
            guard let instanceTag else { return true }
            // An exact pairing entry matches only rows proven to be that
            // build. Unknown-tag rows stay visible under device entries and
            // All Computers, never inside a sibling build's scope where
            // acting on them could route to the wrong build.
            guard let rowTag, !rowTag.isEmpty else { return false }
            return instanceTag == rowTag
        }
    }

    /// Parse a scope's entries once for reuse across row projection.
    public static func parsedMachineEntries<S: Sequence>(
        _ entries: S
    ) -> [ParsedMachineEntry] where S.Element == String {
        entries.map(ParsedMachineEntry.init)
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

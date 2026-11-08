import CMUXMobileCore

/// A compound predicate over workspace rows, shared by every surface that lists
/// workspaces (the flat workspace list and the device tree).
///
/// Two orthogonal, composable dimensions instead of one flat toggle, so the
/// aggregated multi-Mac list can express e.g. "unread on Mac X and Mac Y":
///   - `readState`: all rows, or only those with unread activity.
///   - `machines`: a set of exact pairing ids (`macDeviceID` + instance tag) to
///     include; legacy bare device ids remain readable for untagged rows only.
///     Empty means every machine.
///
/// A row passes when it satisfies BOTH dimensions. The identity filter
/// (`readState == .all`, `machines` empty) shows everything.
public struct MobileWorkspaceListFilter: Hashable, Sendable {
    /// Read-state narrowing for the filter.
    public var readState: MobileWorkspaceReadStateFilter
    /// Exact pairing ids to include. A bare device id is a legacy untagged-row
    /// entry; empty means all machines (no machine narrowing).
    public var machines: Set<String>

    /// Create a workspace list filter from read-state and machine dimensions.
    public init(readState: MobileWorkspaceReadStateFilter = .all, machines: Set<String> = []) {
        self.readState = readState
        self.machines = Self.normalizedMachineIDs(machines)
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
        // to belong to a selected machine. A bare device id matches only a
        // legacy untagged row. A pairing id (device + unit separator + tag)
        // matches only that build's rows.
        let machineOK = parsedMachines.isEmpty || (workspace.macDeviceID.map { deviceID in
            parsedMachines.contains(where: {
                $0.matches(deviceID: deviceID, rowTag: workspace.macInstanceTag)
            })
        } ?? false)
        return readOK && machineOK
    }

    /// The pairing-id separator shared with `MobilePairedMac.pairingID`.
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
        /// `nil` for a legacy untagged-row entry. Tagged builds never match a
        /// bare entry, so Stable and Nightly remain distinct computers.
        public let instanceTag: String?

        public init(_ entry: String) {
            let identity = CmxMacAppInstanceIdentity(id: entry)
            self.deviceID = identity.macDeviceID
            self.instanceTag = identity.instanceTag
        }

        public func matches(deviceID rowDeviceID: String, rowTag: String?) -> Bool {
            let rowIdentity = CmxMacAppInstanceIdentity(
                macDeviceID: rowDeviceID,
                instanceTag: rowTag
            )
            guard deviceID == rowIdentity.macDeviceID else { return false }
            guard let instanceTag else { return rowIdentity.instanceTag == nil }
            // An exact pairing entry matches only rows proven to be that
            // build. Unknown-tag rows stay visible under device entries and
            // All Computers, never inside a sibling build's scope where
            // acting on them could route to the wrong build.
            guard let rowTag = rowIdentity.instanceTag else { return false }
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
        let identityID = CmxMacAppInstanceIdentity(id: macDeviceID).id
        if machines.contains(identityID) {
            machines.remove(identityID)
        } else {
            machines.insert(identityID)
        }
    }

    /// The distinct exact computer ids present in a workspace list, in
    /// first-appearance order. Tagged rows use their pairing id, so sibling
    /// builds are offered independently. Legacy rows without a tag retain a
    /// bare device id because their build cannot be proven.
    public static func machineIDs(in workspaces: [MobileWorkspacePreview]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for workspace in workspaces {
            guard let macDeviceID = workspace.macDeviceID else { continue }
            let machineID = Self.pairingID(
                macDeviceID: macDeviceID,
                instanceTag: workspace.macInstanceTag
            )
            if seen.insert(machineID).inserted {
                ordered.append(machineID)
            }
        }
        return ordered
    }

    private static func pairingID(macDeviceID: String, instanceTag: String?) -> String {
        CmxMacAppInstanceIdentity(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag
        ).id
    }

    /// Drop any selected machines that are no longer present in the list, so a
    /// machine filter for a Mac that disconnected/disappeared does not silently
    /// hide everything. Returns whether the filter changed.
    @discardableResult
    public mutating func pruneMachines(notIn present: [String]) -> Bool {
        let presentSet = Self.normalizedMachineIDs(present)
        let kept = machines.intersection(presentSet)
        guard kept != machines else { return false }
        machines = kept
        return true
    }

    private static func normalizedMachineIDs<S: Sequence>(_ entries: S) -> Set<String>
    where S.Element == String {
        Set(entries.map { CmxMacAppInstanceIdentity(id: $0).id })
    }
}

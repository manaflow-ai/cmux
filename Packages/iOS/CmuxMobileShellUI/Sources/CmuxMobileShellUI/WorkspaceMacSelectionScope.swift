import CmuxMobilePairedMac
import CmuxMobileShellModel

struct WorkspaceMacSelectionScope {
    let selection: WorkspaceMacSelection
    let aliasIndex: WorkspaceMacPickerAliasIndex
    let machineIDs: Set<String>
    let foregroundMachineIDs: Set<String>
    let workspaces: [MobileWorkspacePreview]
    private let displayPairedMacs: [MobilePairedMac]
    /// The LIVE foreground connection's instance tag. Stored `isActive` flags
    /// can lag promotion (written with `reloadAfterWrite: false`), so
    /// correctness-critical gates use this instead of presentation state.
    private let foregroundInstanceTag: String?

    init(
        selection: WorkspaceMacSelection,
        workspaces: [MobileWorkspacePreview],
        displayPairedMacs: [MobilePairedMac],
        notificationFeedItems: [MobileNotificationFeedItem] = [],
        foregroundMacDeviceID: String?,
        foregroundInstanceTag: String? = nil,
        aliasesFor: (String, String?) -> [String]
    ) {
        let aliasIndex = WorkspaceMacPickerAliasIndex(
            displayPairedMacs: displayPairedMacs,
            aliasesFor: aliasesFor
        )
        var machineIDs = Set<String>()
        for id in MobileWorkspaceListFilter.machineIDs(in: workspaces) {
            machineIDs.insert(aliasIndex.representativeID(for: id))
        }
        for mac in displayPairedMacs {
            machineIDs.insert(mac.id)
        }
        for item in notificationFeedItems {
            let itemPairingID = MobilePairedMac.pairingID(
                macDeviceID: item.macDeviceID,
                instanceTag: item.macInstanceTag
            )
            machineIDs.insert(aliasIndex.representativeID(for: itemPairingID))
        }
        let foregroundMachineIDs: Set<String>
        if let foregroundMacDeviceID {
            let foregroundPairingID = MobilePairedMac.pairingID(
                macDeviceID: foregroundMacDeviceID,
                instanceTag: foregroundInstanceTag
            )
            foregroundMachineIDs = aliasIndex.filterMachineIDs(for: foregroundPairingID)
            machineIDs.insert(aliasIndex.representativeID(for: foregroundPairingID))
        } else {
            foregroundMachineIDs = []
        }

        self.selection = selection
        self.aliasIndex = aliasIndex
        self.machineIDs = machineIDs
        self.foregroundMachineIDs = foregroundMachineIDs
        self.workspaces = workspaces
        self.displayPairedMacs = displayPairedMacs
        self.foregroundInstanceTag = foregroundInstanceTag
    }

    init(
        selection: WorkspaceMacSelection,
        workspaces: [MobileWorkspacePreview],
        displayPairedMacs: [MobilePairedMac],
        notificationFeedItems: [MobileNotificationFeedItem] = [],
        foregroundMacDeviceID: String?,
        foregroundInstanceTag: String? = nil,
        aliasesFor: (String) -> [String]
    ) {
        self.init(
            selection: selection,
            workspaces: workspaces,
            displayPairedMacs: displayPairedMacs,
            notificationFeedItems: notificationFeedItems,
            foregroundMacDeviceID: foregroundMacDeviceID,
            foregroundInstanceTag: foregroundInstanceTag,
            aliasesFor: { deviceID, _ in aliasesFor(deviceID) }
        )
    }

    var visibleSelection: WorkspaceMacSelection {
        switch selection {
        case .automatic:
            return .all
        case .machine(let id):
            let representativeID = aliasIndex.representativeID(for: id)
            return machineIDs.contains(representativeID) ? .machine(representativeID) : .all
        case .all:
            return .all
        }
    }

    func activeFilter(base filter: MobileWorkspaceListFilter) -> MobileWorkspaceListFilter {
        var active = filter
        switch visibleSelection {
        case .automatic:
            active.machines = expandedFilterMachineIDs(active.machines)
        case .all:
            active.machines = expandedFilterMachineIDs(active.machines)
        case .machine(let id):
            active.machines = aliasIndex.filterMachineIDs(for: id)
        }
        return active
    }

    /// The exact saved app instance selected by a pairing-scoped menu entry.
    func switchTarget(for id: String) -> (macDeviceID: String, instanceTag: String?)? {
        displayPairedMacs.first { $0.id == id }
            .map { ($0.macDeviceID, $0.instanceTag) }
    }

    /// Whether selecting `id` must move the foreground connection to another
    /// saved app instance. Workspace-only device entries remain local filters.
    func shouldSwitch(to id: String) -> Bool {
        guard let target = displayPairedMacs.first(where: { $0.id == id }) else {
            return false
        }
        // The live connection is authoritative; stored isActive lags promotion.
        if !foregroundMachineIDs.isEmpty {
            let targetMachineIDs = aliasIndex.filterMachineIDs(for: target.id)
            return foregroundMachineIDs.isDisjoint(with: targetMachineIDs)
        }
        if let active = displayPairedMacs.first(where: \.isActive) {
            return active.id != target.id
        }
        return true
    }

    /// Empty/whitespace tags read as "no tag", matching the store's authority
    /// normalization.
    private static func normalizedTag(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// The selection's exact pairing entries, including historical device-id
    /// aliases for that same build.
    private func selectedPairingIDs(for id: String) -> Set<String> {
        Set(aliasIndex.filterMachineIDs(for: id).map(aliasIndex.representativeID))
    }

    func canCreateWorkspace(base canCreateWorkspace: Bool, switchPending: Bool = false) -> Bool {
        guard canCreateWorkspace else { return false }
        guard !switchPending else { return false }
        switch visibleSelection {
        case .machine(let id):
            // Creating requires the foreground connection to BE the selected
            // pairing: same device, and for a tagged selection the same build.
            guard !foregroundMachineIDs.isDisjoint(with: selectedPairingIDs(for: id)) else {
                return false
            }
            guard let selectedTag = MobilePairedMac.pairingIdentity(from: id).instanceTag else {
                // An untagged selection names a legacy pairing. It matches
                // only an untagged live foreground: a tagged sibling on the
                // same device is a DIFFERENT app instance, and a missing tag
                // is not proof of ownership.
                return Self.normalizedTag(foregroundInstanceTag) == nil
            }
            // Prefer the live connection's tag; stored isActive lags promotion.
            if let liveTag = Self.normalizedTag(foregroundInstanceTag) {
                return liveTag == Self.normalizedTag(selectedTag)
            }
            if let activePairing = displayPairedMacs.first(where: \.isActive) {
                return Self.normalizedTag(activePairing.instanceTag) == Self.normalizedTag(selectedTag)
            }
            // Same device proven, but not WHICH build owns the live client.
            // Creating a workspace is a mutation, so missing identity is a
            // denial, not permission.
            return false
        case .all, .automatic:
            return true
        }
    }

    /// Whether content owned by this exact Mac app instance belongs to the
    /// computer scope shown by the shared title picker.
    func includes(macDeviceID: String, instanceTag: String?) -> Bool {
        let pairingID = MobilePairedMac.pairingID(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag
        )
        switch visibleSelection {
        case .machine(let id):
            return selectedPairingIDs(for: id).contains(
                aliasIndex.representativeID(for: pairingID)
            )
        case .all, .automatic:
            return true
        }
    }

    /// Applies the shared computer selection to notification rows through the
    /// same entry matching used by workspace rows: a tagged selection scopes to
    /// that build's notifications, legacy untagged items stay visible.
    func notificationFeedItems(
        from items: [MobileNotificationFeedItem]
    ) -> [MobileNotificationFeedItem] {
        switch visibleSelection {
        case .machine(let id):
            let entries = aliasIndex.filterMachineIDs(for: id)
            return items.filter { item in
                entries.contains(where: { entry in
                    MobileWorkspaceListFilter.machineEntryMatches(
                        entry, deviceID: item.macDeviceID, rowTag: item.macInstanceTag
                    )
                })
            }
        case .all, .automatic:
            return items
        }
    }

    /// The selection's raw filter entries (bare device ids or pairing ids),
    /// for consumers that must preserve the selected build's identity, like
    /// the notification feed projection.
    var selectedScopeEntries: Set<String>? {
        switch visibleSelection {
        case .machine(let id):
            aliasIndex.filterMachineIDs(for: id)
        case .all, .automatic:
            nil
        }
    }

    /// Exact pairing identifiers represented by a machine selection. `nil` means
    /// the global All Computers scope.
    var selectedMachineIDs: Set<String>? {
        switch visibleSelection {
        case .machine(let id):
            selectedPairingIDs(for: id)
        case .all, .automatic:
            nil
        }
    }

    /// Whether foreground-only group mutations such as reorder and create-in-
    /// group are safe for the current picker scope. Rendering is independent:
    /// every Mac's immutable group snapshot can render under All Computers.
    var canMutateForegroundGroupsForSelection: Bool {
        switch visibleSelection {
        case .machine(let id):
            // Groups belong to the exact foreground BUILD: device match alone
            // would render the foreground's groups under the sibling selection.
            guard !foregroundMachineIDs.isDisjoint(with: selectedPairingIDs(for: id)) else {
                return false
            }
            guard let selectedTag = MobilePairedMac.pairingIdentity(from: id).instanceTag else {
                // Same rule as workspace creation: an untagged selection
                // matches only an untagged live foreground build.
                return Self.normalizedTag(foregroundInstanceTag) == nil
            }
            return Self.normalizedTag(selectedTag) == Self.normalizedTag(foregroundInstanceTag)
        case .all, .automatic:
            return visibleRowsAreOnlyForegroundMac
        }
    }

    private var visibleRowsAreOnlyForegroundMac: Bool {
        guard !workspaces.isEmpty else { return false }
        guard !foregroundMachineIDs.isEmpty else { return false }
        return workspaces.allSatisfy { workspace in
            guard let macDeviceID = workspace.macDeviceID else { return false }
            // Exact pairing: a sibling build's rows on the foreground DEVICE
            // are served by a secondary connection, and group/reorder RPCs
            // must never mix builds whose local ids can collide.
            let rowPairingID = MobilePairedMac.pairingID(
                macDeviceID: macDeviceID,
                instanceTag: workspace.macInstanceTag
            )
            return foregroundMachineIDs.contains(
                aliasIndex.representativeID(for: rowPairingID)
            )
                && Self.normalizedTag(workspace.macInstanceTag)
                    == Self.normalizedTag(foregroundInstanceTag)
        }
    }

    private func expandedFilterMachineIDs(_ machineIDs: Set<String>) -> Set<String> {
        guard !machineIDs.isEmpty else { return [] }
        var expanded = Set<String>()
        for id in machineIDs {
            expanded.formUnion(aliasIndex.filterMachineIDs(for: id))
        }
        return expanded
    }
}

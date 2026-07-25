import CmuxMobilePairedMac
import CmuxMobileShellModel

struct WorkspaceMacSelectionScope {
    let selection: WorkspaceMacSelection
    let aliasIndex: WorkspaceMacPickerAliasIndex
    let machineIDs: Set<String>
    let foregroundMachineIDs: Set<String>
    let workspaces: [MobileWorkspacePreview]
    private let displayPairedMacs: [MobilePairedMac]

    init(
        selection: WorkspaceMacSelection,
        workspaces: [MobileWorkspacePreview],
        displayPairedMacs: [MobilePairedMac],
        notificationFeedItems: [MobileNotificationFeedItem] = [],
        foregroundMacDeviceID: String?,
        aliasesFor: (String) -> [String]
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
            machineIDs.insert(aliasIndex.representativeID(for: item.macDeviceID))
        }
        let foregroundMachineIDs: Set<String>
        if let foregroundMacDeviceID {
            foregroundMachineIDs = aliasIndex.filterMachineIDs(for: foregroundMacDeviceID)
            machineIDs.insert(aliasIndex.representativeID(for: foregroundMacDeviceID))
        } else {
            foregroundMachineIDs = []
        }

        self.selection = selection
        self.aliasIndex = aliasIndex
        self.machineIDs = machineIDs
        self.foregroundMachineIDs = foregroundMachineIDs
        self.workspaces = workspaces
        self.displayPairedMacs = displayPairedMacs
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
        if let active = displayPairedMacs.first(where: \.isActive) {
            return active.id != target.id
        }
        let targetIDs = aliasIndex.filterMachineIDs(for: target.id)
        return foregroundMachineIDs.isDisjoint(with: targetIDs)
    }

    /// Empty/whitespace tags read as "no tag", matching the store's authority
    /// normalization.
    private static func normalizedTag(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// The selection's filter entries projected to bare device ids (entries may
    /// be pairing ids since the tuple-aware filter).
    private func selectedDeviceIDs(for id: String) -> Set<String> {
        Set(aliasIndex.filterMachineIDs(for: id).map {
            MobilePairedMac.pairingIdentity(from: $0).macDeviceID
        })
    }

    func canCreateWorkspace(base canCreateWorkspace: Bool, switchPending: Bool = false) -> Bool {
        guard canCreateWorkspace else { return false }
        guard !switchPending else { return false }
        switch visibleSelection {
        case .machine(let id):
            // Creating requires the foreground connection to BE the selected
            // pairing: same device, and for a tagged selection the same build.
            guard !foregroundMachineIDs.isDisjoint(with: selectedDeviceIDs(for: id)) else {
                return false
            }
            guard let selectedTag = MobilePairedMac.pairingIdentity(from: id).instanceTag,
                  let activePairing = displayPairedMacs.first(where: \.isActive) else {
                return true
            }
            return Self.normalizedTag(activePairing.instanceTag) == Self.normalizedTag(selectedTag)
        case .all, .automatic:
            return true
        }
    }

    /// Whether content owned by `macDeviceID` belongs to the computer scope
    /// shown by the shared title picker. Device-level: sibling builds share it.
    func includes(macDeviceID: String) -> Bool {
        switch visibleSelection {
        case .machine(let id):
            return selectedDeviceIDs(for: id).contains(macDeviceID)
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

    /// Exact Mac DEVICE identifiers represented by a machine selection. `nil`
    /// means the global All Computers scope. Device-level by design: status
    /// consumers reason about physical reachability.
    var selectedMachineIDs: Set<String>? {
        switch visibleSelection {
        case .machine(let id):
            selectedDeviceIDs(for: id)
        case .all, .automatic:
            nil
        }
    }

    var canRenderGroupsForSelection: Bool {
        switch visibleSelection {
        case .machine(let id):
            return !foregroundMachineIDs.isDisjoint(with: selectedDeviceIDs(for: id))
        case .all, .automatic:
            return visibleRowsAreOnlyForegroundMac
        }
    }

    private var visibleRowsAreOnlyForegroundMac: Bool {
        guard !workspaces.isEmpty else { return false }
        guard !foregroundMachineIDs.isEmpty else { return false }
        return workspaces.allSatisfy { workspace in
            guard let macDeviceID = workspace.macDeviceID else { return false }
            return foregroundMachineIDs.contains(macDeviceID)
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

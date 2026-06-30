import CmuxMobilePairedMac
import CmuxMobileShellModel

struct WorkspaceMacSelectionScope {
    let selection: WorkspaceMacSelection
    let aliasIndex: WorkspaceMacPickerAliasIndex
    let machineIDs: Set<String>
    let connectedMacDeviceID: String?
    let workspaces: [MobileWorkspacePreview]

    init(
        selection: WorkspaceMacSelection,
        workspaces: [MobileWorkspacePreview],
        displayPairedMacs: [MobilePairedMac],
        connectedMacDeviceID: String?,
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
            machineIDs.insert(mac.macDeviceID)
        }
        if let connectedMacDeviceID {
            machineIDs.insert(aliasIndex.representativeID(for: connectedMacDeviceID))
        }

        self.selection = selection
        self.aliasIndex = aliasIndex
        self.machineIDs = machineIDs
        self.connectedMacDeviceID = connectedMacDeviceID
        self.workspaces = workspaces
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
            break
        case .all:
            active.machines.removeAll()
        case .machine(let id):
            active.machines = aliasIndex.filterMachineIDs(for: id)
        }
        return active
    }

    func canCreateWorkspace(base canCreateWorkspace: Bool) -> Bool {
        guard canCreateWorkspace else { return false }
        switch visibleSelection {
        case .machine(let id):
            guard let connectedMacDeviceID else { return false }
            return aliasIndex.filterMachineIDs(for: id).contains(connectedMacDeviceID)
        case .all, .automatic:
            return true
        }
    }

    var canRenderGroupsForSelection: Bool {
        switch visibleSelection {
        case .machine(let id):
            guard let connectedMacDeviceID else { return false }
            return aliasIndex.filterMachineIDs(for: id).contains(connectedMacDeviceID)
        case .all, .automatic:
            return visibleRowsAreOnlyForegroundMac
        }
    }

    private var visibleRowsAreOnlyForegroundMac: Bool {
        guard !workspaces.isEmpty else { return false }
        guard let connectedMacDeviceID else { return false }
        let foregroundIDs = aliasIndex.filterMachineIDs(for: connectedMacDeviceID)
        return workspaces.allSatisfy { workspace in
            guard let macDeviceID = workspace.macDeviceID else { return false }
            return foregroundIDs.contains(macDeviceID)
        }
    }
}

import CmuxMobileShellModel

struct WorkspaceMachineSnapshots: Equatable {
    var filterMachines: [WorkspaceFilterMachine]
    var macPickerMachines: [WorkspaceFilterMachine]

    static let empty = WorkspaceMachineSnapshots(filterMachines: [], macPickerMachines: [])

    init(filterMachines: [WorkspaceFilterMachine], macPickerMachines: [WorkspaceFilterMachine]) {
        self.filterMachines = filterMachines
        self.macPickerMachines = macPickerMachines
    }

    init(
        workspaces: [MobileWorkspacePreview],
        macPickerMachineIDs: Set<String>,
        namesByID: [String: String],
        fallbackName: String
    ) {
        let filterMachineIDs = Set(MobileWorkspaceListFilter.machineIDs(in: workspaces))
        self.filterMachines = filterMachineIDs.count > 1
            ? filterMachineIDs
                .map { WorkspaceFilterMachine(id: $0, namesByID: namesByID, fallbackName: fallbackName) }
                .sortedForMenuDisplay()
            : []
        self.macPickerMachines = macPickerMachineIDs
            .map { WorkspaceFilterMachine(id: $0, namesByID: namesByID, fallbackName: fallbackName) }
            .sortedForMenuDisplay()
    }
}

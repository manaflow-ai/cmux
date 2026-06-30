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
        filterMachineIDFor: (String) -> String = { $0 },
        macPickerMachineIDs: Set<String>,
        namesByID: [String: String],
        fallbackName: String
    ) {
        let filterMachineIDs = Set(
            MobileWorkspaceListFilter.machineIDs(in: workspaces).map(filterMachineIDFor)
        )
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

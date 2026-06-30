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
            ? Self.machines(
                ids: filterMachineIDs,
                namesByID: namesByID,
                fallbackName: fallbackName
            )
            : []
        self.macPickerMachines = Self.machines(
            ids: macPickerMachineIDs,
            namesByID: namesByID,
            fallbackName: fallbackName
        )
    }

    private static func machines(
        ids: Set<String>,
        namesByID: [String: String],
        fallbackName: String
    ) -> [WorkspaceFilterMachine] {
        ids
            .map { WorkspaceFilterMachine(id: $0, namesByID: namesByID, fallbackName: fallbackName) }
            .sortedForMenuDisplay()
    }
}

import CmuxMobileShellModel
import CmuxMobileSupport

struct WorkspaceMachineSnapshots: Equatable {
    var filterMachines: [WorkspaceFilterMachine]
    var macPickerMachines: [WorkspaceFilterMachine]
    /// Workspaces the All Computers picker row would show; `nil` renders no
    /// count signifier.
    var allWorkspaceCount: Int? = nil

    static let empty = WorkspaceMachineSnapshots(filterMachines: [], macPickerMachines: [])

    init(
        filterMachines: [WorkspaceFilterMachine],
        macPickerMachines: [WorkspaceFilterMachine],
        allWorkspaceCount: Int? = nil
    ) {
        self.filterMachines = filterMachines
        self.macPickerMachines = macPickerMachines
        self.allWorkspaceCount = allWorkspaceCount
    }

    init(
        workspaces: [MobileWorkspacePreview],
        filterMachineIDFor: (String) -> String = { $0 },
        macPickerMachineIDs: Set<String>,
        namesByID: [String: String],
        buildLabelsByID: [String: String] = [:],
        fallbackName: String,
        pickerCounts: WorkspaceMacPickerCounts? = nil
    ) {
        let filterMachineIDs = Set(
            MobileWorkspaceListFilter.machineIDs(in: workspaces).map(filterMachineIDFor)
        )
        self.filterMachines = filterMachineIDs.count > 1
            ? filterMachineIDs
                .map {
                    WorkspaceFilterMachine(
                        id: $0,
                        namesByID: namesByID,
                        buildLabel: nil,
                        fallbackName: fallbackName
                    )
                }
                .sortedForMenuDisplay()
            : []
        self.macPickerMachines = macPickerMachineIDs
            .map { id in
                WorkspaceFilterMachine(
                    id: id,
                    namesByID: namesByID,
                    buildLabel: buildLabelsByID[id],
                    fallbackName: fallbackName,
                    workspaceCount: pickerCounts?.count(for: id)
                )
            }
            .sortedForMenuDisplay()
        self.allWorkspaceCount = pickerCounts?.all
    }

    /// Collapsed title for a machine selection. Sibling builds of one physical
    /// Mac share a name, so the build label joins the title exactly when the
    /// name alone would be ambiguous.
    func macPickerTitle(for id: String, fallback: String) -> String {
        guard let machine = macPickerMachines.first(where: { $0.id == id }) else {
            return fallback
        }
        let hasSibling = macPickerMachines.contains {
            $0.id != machine.id && $0.macDeviceID == machine.macDeviceID
        }
        guard hasSibling, let buildLabel = machine.buildLabel else {
            return machine.name
        }
        let format = L10n.string(
            "mobile.workspaces.macPicker.titleWithBuildFormat",
            defaultValue: "%1$@ · %2$@"
        )
        return String(format: format, machine.name, buildLabel)
    }
}

import CmuxMobileShellModel
import CmuxMobileSupport

struct WorkspaceMachineSnapshots: Equatable {
    var filterMachines: [WorkspaceFilterMachine]
    var macPickerMachines: [WorkspaceFilterMachine]
    private var representativeIDByMachineID: [String: String]

    static let empty = WorkspaceMachineSnapshots(filterMachines: [], macPickerMachines: [])

    init(filterMachines: [WorkspaceFilterMachine], macPickerMachines: [WorkspaceFilterMachine]) {
        self.filterMachines = filterMachines
        self.macPickerMachines = macPickerMachines
        self.representativeIDByMachineID = Dictionary(
            (filterMachines + macPickerMachines).map { ($0.id, $0.id) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    init(
        workspaces: [MobileWorkspacePreview],
        filterMachineIDFor: (String) -> String = { $0 },
        macPickerMachineIDs: Set<String>,
        namesByID: [String: String],
        buildLabelsByID: [String: String] = [:],
        fallbackName: String
    ) {
        let sourceMachineIDs = MobileWorkspaceListFilter.machineIDs(in: workspaces)
        var representativeIDByMachineID = Dictionary(
            sourceMachineIDs.map { ($0, filterMachineIDFor($0)) },
            uniquingKeysWith: { first, _ in first }
        )
        for id in macPickerMachineIDs {
            representativeIDByMachineID[id] = id
        }
        self.representativeIDByMachineID = representativeIDByMachineID
        let filterMachineIDs = Set(sourceMachineIDs.compactMap { representativeIDByMachineID[$0] })
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
            .map {
                WorkspaceFilterMachine(
                    id: $0,
                    namesByID: namesByID,
                    buildLabel: buildLabelsByID[$0],
                    fallbackName: fallbackName
                )
            }
            .sortedForMenuDisplay()
    }

    func representativeID(for machineID: String) -> String {
        representativeIDByMachineID[machineID] ?? machineID
    }

    /// Collapsed title for a machine selection. Sibling builds of one physical
    /// Mac builds share a name, so the build label joins the title exactly when
    /// the name alone would be ambiguous.
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

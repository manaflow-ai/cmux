import CmuxMobileShellModel

/// Only the values displayed by the menu, separate from the live toolbar label.
struct WorkspaceMacTitlePickerMenuValue {
    let selection: WorkspaceMacSelection
    let machines: [WorkspaceFilterMachine]
    let canAddDevice: Bool
}

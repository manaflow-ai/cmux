import CmuxMobileShellModel

struct WorkspaceMacTitlePickerActions {
    let select: (WorkspaceMacSelection) -> Void
    let addDevice: (() -> Void)?
    /// Opens the Computers screen from the menu. Set only where the picker
    /// stands in for the toolbar's Computers button.
    var openDevices: (() -> Void)? = nil
}

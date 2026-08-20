import CmuxMobileShellModel

struct WorkspaceMacTitlePickerActions {
    let select: (WorkspaceMacSelection) -> Void
    let addDevice: (() -> Void)?
    /// Switch the app-wide connection method from the picker menu. `nil`
    /// hides the method group.
    var selectConnectionMethod: ((MobileConnectionMethod) -> Void)?
}

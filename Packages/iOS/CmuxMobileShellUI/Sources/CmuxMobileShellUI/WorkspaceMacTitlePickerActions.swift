import CmuxMobileShellModel

struct WorkspaceMacTitlePickerActions {
    let select: (WorkspaceMacSelection) -> Void
    let addDevice: (() -> Void)?
    /// Manual reconnect, offered in the picker menu while the status line
    /// reads Not Connected (the inline Retry chrome it replaces is gone).
    var reconnect: (() -> Void)?
    /// Switch the app-wide connection method from the picker menu. `nil`
    /// hides the method group.
    var selectConnectionMethod: ((MobileConnectionMethod) -> Void)?
}

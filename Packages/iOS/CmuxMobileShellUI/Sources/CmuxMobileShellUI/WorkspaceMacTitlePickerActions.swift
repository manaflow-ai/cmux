struct WorkspaceMacTitlePickerActions {
    let select: (WorkspaceMacSelection) -> Void
    let addDevice: (() -> Void)?
    /// Manual reconnect, offered in the picker menu while the status line
    /// reads Not Connected (the inline Retry chrome it replaces is gone).
    var reconnect: (() -> Void)?
}

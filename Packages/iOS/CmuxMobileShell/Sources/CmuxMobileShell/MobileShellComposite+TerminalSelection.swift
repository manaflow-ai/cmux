public import CmuxMobileShellModel

extension MobileShellComposite {
    /// Select the active terminal by id without changing workspace selection.
    public func selectTerminal(_ id: MobileTerminalPreview.ID?) {
        selectedTerminalID = id
    }
}

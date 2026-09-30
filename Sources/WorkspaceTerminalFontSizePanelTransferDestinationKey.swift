extension WorkspaceTerminalFontSizeArbiter {
    enum PanelTransferDestinationKey: Hashable {
        case workspace(ObjectIdentifier)
        case windowDock(ObjectIdentifier)
    }
}

extension WorkspaceTerminalFontSizeCoordinator.TransferResourceState {
    struct RequestRetirement {
        let resourceBecameIdle: Bool
        let obligationsToRemove: [WorkspaceTerminalFontSizeCoordinator.TransferObligation]
        let obligationsToRepair: [WorkspaceTerminalFontSizeCoordinator.TransferObligation]
    }
}

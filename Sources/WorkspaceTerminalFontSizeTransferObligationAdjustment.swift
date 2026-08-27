extension WorkspaceTerminalFontSizeCoordinator.TransferResourceState {
    struct ObligationAdjustment {
        let obligationsToRemove: [WorkspaceTerminalFontSizeCoordinator.TransferObligation]
        let obligationsToRepair: [WorkspaceTerminalFontSizeCoordinator.TransferObligation]
    }
}

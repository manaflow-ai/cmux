extension WorkspaceTerminalFontSizeCoordinator {
    enum MutationRetryDisposition {
        case ready
        case backoff
        case awaitingSignal
        case awaitingPanelTransferStage
    }
}

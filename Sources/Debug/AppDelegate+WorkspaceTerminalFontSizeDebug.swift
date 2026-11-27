#if DEBUG
extension WorkspaceTerminalFontSizeCoordinator {
    func flushOneDrainForVerification() {
        invalidateScheduledDrain()
        signalMutationRetry(scheduleIfOutstanding: false)
        drain()
    }

    func drainAllForVerification() {
        invalidateScheduledDrain()
        signalMutationRetry(scheduleIfOutstanding: false)
        while outstandingRequestCount > 0 {
            if mutationRetryDisposition == .backoff {
                mutationRetryDisposition = .ready
            } else if mutationRetryDisposition == .awaitingSignal {
                break
            } else if mutationRetryDisposition
                        == .awaitingPanelTransferStage {
                break
            }
            drain(scheduleContinuation: false)
        }
    }

    var outstandingRequestCountForVerification: Int {
        outstandingRequestCount
    }
}

extension AppDelegate {
    func flushPendingWorkspaceTerminalFontSizeChangesForVerification() {
        for context in mainWindowContexts.values {
            context.workspaceTerminalFontSizeCoordinator
                .flushOneDrainForVerification()
        }
    }

    func drainAllPendingWorkspaceTerminalFontSizeChangesForVerification() {
        for context in mainWindowContexts.values {
            context.workspaceTerminalFontSizeCoordinator
                .drainAllForVerification()
        }
    }

    var pendingWorkspaceTerminalFontSizeChangeCountForVerification: Int {
        mainWindowContexts.values.reduce(into: 0) {
            $0 += $1.workspaceTerminalFontSizeCoordinator
                .pendingRequestCountForVerification
        }
    }
}
#endif

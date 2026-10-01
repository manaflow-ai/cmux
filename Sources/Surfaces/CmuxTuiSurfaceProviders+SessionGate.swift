import CmuxCloud

@MainActor
extension CmuxTuiSurfaceProvider {
    /// Stops this machine's automatic work after the shared session gate rejects
    /// the current credentials. Existing panes retain the session-ended card.
    func noteSessionRejected() {
        for task in browserPaneTasks.values { task.cancel() }
        browserPaneTasks.removeAll()
        displayCoordinator.stop(); portDiscovery.invalidate(); terminalMutationQueue.cancelAll()
        for task in restoredAttachTasks.values { task.cancel() }
        restoredAttachTasks.removeAll(); attachmentRetry.stop()
        for session in manualMirrorSessions.values { session.stop(reason: .signedOut) }
        manualMirrorSessions.removeAll()
        guard isRegisteredInCatalog() else { return }
        info.linkFailure = .sessionRejected; info.linkState = .error
        info.linkError = CloudTuiManualMirrorStopReason.signedOut.endedPresentation?.detail
        catalog.updateMachine(info, from: self)
    }

    /// Clears only the session gate after an authenticated credential change.
    func resetSessionRejectionAfterAuthChange() {
        guard info.linkFailure == .sessionRejected else { return }
        info.linkFailure = nil; info.linkError = nil; info.linkState = .connecting
        attachmentRetry.reset(); catalog.updateMachine(info, from: self)
    }
}

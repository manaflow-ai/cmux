extension WindowController {
    /// A window on a workspace of paused Cloud machine `machineID` (a relaunch connects only live ones) resumes it once,
    /// as any attach does, and shows its progress, Resume or Retry until the workspace is mirrored (#33483).
    func showPausedMachine(_ machineID: String) -> Bool {
        guard let session = services.machines.session(machineID), !session.isPermanentlyDisconnected else { return false }
        let shown = (root.content as? CloudMachineProgressView)?.creation.session === session
        guard session.machine.status == .paused || shown && !session.daemon.store.isLoaded else { return false }
        if shown { return true }
        parkContentForPage()
        root.show(CloudMachineProgressView(creation: CloudMachineCreation(windowID: state.id, session: session), actions: .init(
            retry: { $0.session?.attach(origin: .user) }, dismiss: { [weak self] _ in self?.state.workspaceID = nil })))
        themeScope.show(nil)
        root.titlebar.title = session.machine.title
        session.attach(origin: .user)
        if services.windows.awaitingContent.removeValue(forKey: state.id) != nil { services.windows.present(self) } // off screen until now
        return true
    }
}

import CmuxNextCloudUI

extension WindowController {
    /// A window on paused machine `machineID`'s workspace resumes it once and shows its progress until it is mirrored (#33483).
    func showPausedMachine(_ machineID: String) -> Bool {
        guard let session = services.machines.session(machineID), !session.isPermanentlyDisconnected else { return false }
        let shown = ((root.content as? CloudProgressHost)?.source as? CloudMachineCreation)?.session === session
        guard session.machine.status == .paused || shown && !session.daemon.store.isLoaded else { return false }
        if shown { return true }
        parkContentForPage()
        let creation = CloudMachineCreation(windowID: state.id, session: session)
        let view = CloudProgressHost(source: creation, actions: .progress(
            retry: { [weak session] in session?.attach(origin: .user) }, dismiss: { [weak self] in self?.state.workspaceID = nil }))
        creation.progressHost = view
        root.show(view)
        window?.makeFirstResponder(view) // Return and keys reach the page (Resume, Retry), as for a new workspace
        themeScope.show(nil)
        root.titlebar.title = session.machine.title
        session.attach(origin: .user)
        if services.windows.awaitingContent.removeValue(forKey: state.id) != nil { services.windows.present(self) } // off screen until now
        return true
    }
}

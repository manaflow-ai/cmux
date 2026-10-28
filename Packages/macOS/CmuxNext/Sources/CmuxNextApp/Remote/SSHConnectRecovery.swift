import AppKit
import CmuxNextActions
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextRemote

/// One user-requested connection. Its sheet remains actionable during automatic retries,
/// and disappears when the workspace loads, the user dismisses it, or the session closes.
@MainActor final class SSHConnectRecovery {
    private weak var session: SSHMachineSession?
    private let context: AppActionContext
    private weak var window: NSWindow?
    private var task: Task<Void, Never>?
    private var dialog: Int?
    private var windowObserver: (any NSObjectProtocol)?

    init(session: SSHMachineSession, context: AppActionContext) {
        self.session = session
        self.context = context
        window = CloudHandlers.window(context)
        if let window {
            windowObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.stop() }
            }
        }
    }

    func start() {
        guard let session else { return }
        let daemon = session.daemon
        // task-owner: cancelled by stop(), session close, dismissal, or a loaded workspace.
        task = Task { @MainActor [weak self] in
            for await (loaded, status, daemonFailure) in ObservationStream({
                (daemon.store.isLoaded && daemon.connection != nil, session.linkStatus, session.daemonFailure)
            }) {
                guard let self, !Task.isCancelled else { return }
                if loaded {
                    self.dismiss()
                    let id: String?
                    if let first = daemon.store.workspaces.first { id = first.id }
                    else { id = await self.context.services.windows.createWorkspace(on: daemon) }
                    if let id, !Task.isCancelled { CloudHandlers.show(id, self.context) }
                    self.stop()
                    return
                }
                if status == .offline { self.stop(); return }
                if Self.isFailure(status) || daemonFailure != nil { self.present() }
            }
        }
    }

    func stop() {
        if let windowObserver {
            NotificationCenter.default.removeObserver(windowObserver)
            self.windowObserver = nil
        }
        task?.cancel()
        task = nil
        dismiss()
        if session?.connectRecovery === self { session?.connectRecovery = nil }
    }

    private func dismiss() {
        if let id = dialog {
            dialog = nil
            CmuxDialogCenter.shared.dismiss(id)
        }
    }

    private func present() {
        guard dialog == nil, let session, let window else { return }
        let detail = RemoteStrings.detail(session) ?? ""
        let error = RemoteStrings.sshError(session) ?? detail
        dialog = CmuxDialogCenter.shared.present(Self.spec(name: session.host.label, detail: detail), in: .window(window)) { [weak self] answer in
            guard let self, self.dialog != nil else { return }
            self.dialog = nil
            guard let session = self.session else { self.stop(); return }
            switch answer.button {
            case "retry": self.context.services.ssh.reconnect(session)
            case "copy":
                self.context.copy(error)
                self.present()
            case "check":
                let target = ActionTargetRef(kind: .machine, id: session.machineID)
                self.context.services.registry.perform("machine.doctor", invocation: ActionInvocation(target: target))
                self.stop()
            default: self.stop()
            }
        }
    }

    static func isFailure(_ status: SSHConnectionMachine.Status) -> Bool {
        switch status {
        case .unreachable, .failed, .authFailed, .hostKeyUntrusted, .installFailed: true
        default: false
        }
    }

    static func spec(name: String, detail: String) -> CmuxDialogSpec {
        CmuxDialogSpec(title: RemoteStrings.connectFailedTitle(name), lines: [detail],
                       buttons: [.cancel(CloudStrings.cancel),
                                 CmuxDialogButton(id: "copy", title: RemoteStrings.copyError),
                                 CmuxDialogButton(id: "check", title: RemoteStrings.checkMachine),
                                 CmuxDialogButton(id: "retry", title: RemoteStrings.retry, role: .default)],
                       identifier: "cmux.dialog.remote.connectFailed")
    }
}

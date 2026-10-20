import CmuxNextActions
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextRemote
import CmuxNextSidebar

/// New Remote Group (remote-groups-DESIGN.md slice 4): one action from a host name to a remote group.
/// It connects the host through `SSHService` as `remote.connect` does (an existing machine for the same
/// host is reused, never added twice), shows its first workspace, and marks its machine section a remote
/// group on the sidebar document once its daemon names its session, so the section keeps its header,
/// with the host's name and status, in one list. New workspaces in it run on the host.
@MainActor
enum RemoteGroupHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let ssh = context.services.ssh
        CloudHandlers.bind("remote.newGroup", registry, reason: { ssh.unavailableReason }) { invocation in
            let interactive = !registry.isCapturingRefusal
            let make = { (text: String) throws in
                let session = try ssh.connect(destination: text, session: nil, offerInstall: interactive)
                markWhenNamed(session)
                if interactive { RemoteHandlers.showWhenConnected(session, context) }
            }
            if let text = invocation["destination"]?.stringValue { return try make(text) }
            CloudPresenter.askText(RemoteStrings.newGroupTitle, initial: "", button: RemoteStrings.connect, in: CloudHandlers.window(context)) { text in
                guard let text, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                do { try make(text) } catch { CloudPresenter.failure(error, in: CloudHandlers.window(context)) }
            }
        }
    }

    /// Marks `session`'s machine section a remote group once its daemon names its session; gives up
    /// when the machine stops connecting.
    static func markWhenNamed(_ session: SSHMachineSession) {
        let daemon = session.daemon
        // task-owner: ends when the daemon names its session or the machine stops connecting
        Task { @MainActor in
            for await (name, status) in ObservationStream({ (daemon.store.registryID, session.linkStatus) }) {
                if let name {
                    mark(session: name)
                    return
                }
                switch status {
                case .connecting, .connected, .reconnecting, .installing, .needsInstall, .unreachable, .failed: continue
                case .offline, .authFailed, .hostKeyUntrusted, .installFailed: return
                }
            }
        }
    }

    /// Sends the document ops that make the machine section of daemon session `session` a remote group.
    static func mark(session: String) {
        guard let store = SidebarDocStore.current, SidebarDocWiring.isActive else { return }
        let ops = SidebarDocHostGroupPlan(session: session, records: store.records).ops
        guard !ops.isEmpty else { return }
        store.send(ops: ops, title: RemoteStrings.newGroupTitle, undoable: false)
    }
}

import AppKit
import CmuxNextActions
import CmuxNextDaemon
import CmuxNextRemote

/// SSH machine actions (`SSHService`). A machine is the invocation's
/// `machine:` target (a section header's context menu, CLI `--machine`,
/// matched by id, sidebar name or destination), else the machine of the
/// active window's workspace, else the only SSH machine. Connecting and
/// installing run in tasks; failures surface as a sheet in the UI and as a
/// refusal on the control socket.
enum RemoteHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let ssh = context.services.ssh
        let available: @MainActor () -> String? = { ssh.unavailableReason }
        let hasMachine: @MainActor () -> String? = { ssh.unavailableReason ?? (ssh.sessions.isEmpty ? RemoteStrings.noMachine : nil) }
        ssh.offerInstall = { [weak registry] session in
            // Asks through the registry's confirmation sheet (remote.install is destructive).
            _ = registry?.perform("remote.install", invocation: ActionInvocation(target: ActionTargetRef(kind: .machine, id: session.machineID)))
        }
        CloudHandlers.bind("remote.connect", registry, reason: available) { invocation in
            let interactive = !registry.isCapturingRefusal
            let connect = { (text: String) in
                let session = try ssh.connect(destination: text, session: invocation["session"]?.stringValue,
                                              binary: invocation["binary"]?.stringValue, stateDir: invocation["stateDir"]?.stringValue,
                                              offerInstall: interactive)
                if interactive { showWhenConnected(session, context) }
            }
            if let text = invocation["destination"]?.stringValue {
                return try connect(text)
            }
            CloudPresenter.askText(RemoteStrings.connectTitle, initial: "", button: RemoteStrings.connect, in: CloudHandlers.window(context)) { text in
                guard let text, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                do { try connect(text) } catch { CloudPresenter.failure(error, in: CloudHandlers.window(context)) }
            }
        }
        // A terminal of another machine in this pane (a mixed workspace,
        // plans/cmux-next/data-model.md 1.2b): any connected session, SSH,
        // Cloud or this Mac; the pane's own machine just gets a new tab.
        registry.bind("remote.openTerminalHere", run: { invocation in
            guard let pane = context.daemonPane(invocation) else { throw ActionFailure.invalidTarget(RefusalStrings.noPaneID(invocation.target?.id ?? "focused")) }
            guard let machine = invocation["machine"]?.targetValue?.id ?? invocation["machine"]?.stringValue,
                  let daemon = context.services.machines.daemon(machine: machine) else {
                throw ActionFailure.invalidTarget(WorkspaceVerbStrings.noMachine)
            }
            let home = context.services.daemon(for: pane)
            if daemon === home {
                registry.perform("newSurface", invocation: ActionInvocation(target: ActionTargetRef(kind: .pane, id: pane.id)))
                return
            }
            if let failure = context.services.remoteTerminals.openTerminal(on: daemon, in: pane, home: home, cwd: nil) {
                throw ActionFailure(message: failure.message)
            }
        })
        CloudHandlers.bind("remote.newWorkspace", registry, reason: hasMachine) { invocation in
            let session = try machine(invocation, context)
            guard session.daemon.connection != nil else { throw ActionFailure(message: RemoteStrings.notConnected(session.host.label)) }
            let work: ActionWork = Task {
                guard let id = await context.services.windows.createWorkspace(on: session.daemon) else {
                    return ActionWorkFailure(RemoteStrings.notConnected(session.host.label))
                }
                CloudHandlers.show(id, context)
                return nil
            }
            registry.track(work)
        }
        CloudHandlers.bind("remote.reconnect", registry, reason: hasMachine) { invocation in
            ssh.reconnect(try machine(invocation, context))
        }
        CloudHandlers.bind("remote.disconnect", registry, reason: hasMachine) { invocation in
            ssh.disconnect(try machine(invocation, context))
        }
        // Destructive: the registry confirmed it (sheet, or `confirm: true`).
        CloudHandlers.bind("remote.install", registry, reason: hasMachine) { invocation in
            let session = try machine(invocation, context)
            let interactive = !registry.isCapturingRefusal
            let work: ActionWork = Task {
                do {
                    try await ssh.install(session)
                    return nil
                } catch {
                    if interactive { CloudPresenter.failure(error, in: CloudHandlers.window(context)) }
                    return ActionWorkFailure(String(describing: error))
                }
            }
            registry.track(work)
        }
        CloudHandlers.bind("remote.forget", registry, reason: hasMachine) { invocation in
            let session = try machine(invocation, context)
            let work: ActionWork = Task {
                await ssh.forget(session)
                return nil
            }
            registry.track(work)
        }
    }

    /// The SSH machine an invocation acts on.
    static func machine(_ invocation: ActionInvocation, _ context: AppActionContext) throws -> SSHMachineSession {
        let machines = context.services.machines
        if let target = invocation.target, target.kind == .machine {
            if let session = machines.sshSession(target.id) { return session }
            let wanted = target.id.lowercased()
            let matches = machines.ssh.filter { session in
                [session.host.label, session.host.destination.description, session.host.destination.displayName,
                 session.host.destination.sshArgument].contains { $0.lowercased() == wanted }
            }
            if matches.count == 1, let only = matches.first { return only }
            throw ActionFailure(message: RemoteStrings.unknownMachine(target.id))
        }
        if let state = context.services.windows.active?.state, let session = machines.sshSession(state.machineID) { return session }
        if machines.ssh.count == 1, let only = machines.ssh.first { return only }
        throw ActionFailure(message: RemoteStrings.noMachine)
    }

    /// After a Connect from the UI: shows the machine's first workspace in
    /// the active window once its tree loads (creating one when it has
    /// none). Gives up when the machine stops connecting.
    static func showWhenConnected(_ session: SSHMachineSession, _ context: AppActionContext) {
        let daemon = session.daemon
        // task-owner: ends when the tree loads or the machine stops connecting
        Task { @MainActor in
            for await (loaded, status) in Observations({ (daemon.store.isLoaded && daemon.connection != nil, session.linkStatus) }) {
                if loaded {
                    let id: String?
                    if let first = daemon.store.workspaces.first { id = first.id } else { id = await context.services.windows.createWorkspace(on: daemon) }
                    if let id { CloudHandlers.show(id, context) }
                    return
                }
                switch status {
                case .connecting, .connected, .installing, .needsInstall, .unreachable, .failed: continue
                case .offline, .authFailed, .hostKeyUntrusted, .installFailed:
                    if status != .offline { CloudPresenter.show(RemoteStrings.connectFailedTitle(session.host.label),
                                                                 RemoteStrings.detail(session) ?? "", in: CloudHandlers.window(context)) }
                    return
                }
            }
        }
    }
}

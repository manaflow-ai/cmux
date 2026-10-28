import AppKit
import CmuxNextActions
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextRemote
import CmuxNextServer

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
            // The host as a Cmd-Shift-P step; Return runs this again with it.
            registry.ask("remote.connect", invocation, ActionArgumentAsk(argument: "destination"))
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
            let cwd = invocation["cwd"]?.stringValue
            // Rex-style placement words too (`below`, `bottom`); the daemon splits right or down only.
            var direction: SplitDirection?
            if let word = invocation["direction"]?.stringValue {
                switch word {
                case "right": direction = .right
                case "down", "below", "bottom": direction = .down
                default: throw ActionFailure(message: RemoteStrings.splitRightOrDown)
                }
            }
            if daemon === home && direction == nil && cwd == nil {
                registry.perform("newSurface", invocation: ActionInvocation(target: ActionTargetRef(kind: .pane, id: pane.id)))
                return
            }
            if let failure = context.services.remoteTerminals.openTerminal(on: daemon, in: pane, home: home, cwd: cwd, splitting: direction) {
                throw ActionFailure(message: failure.message)
            }
        })
        bindOpenRemote(into: registry, context: context)
        CloudHandlers.bind("remote.newWorkspace", registry, reason: hasMachine) { invocation in
            let session = try machine(invocation, context)
            guard session.daemon.connection != nil else { throw ActionFailure(message: RemoteStrings.notConnected(session.host.label)) }
            let work: ActionWork = Task {
                let id: String
                do {
                    id = try await context.services.windows.createWorkspace(WorkspaceSpawn(), on: session.daemon)
                } catch {
                    // The real reason (a terminal start deadline on a slow
                    // host, a refusal), never a bare "not connected" (cx-tzlqb).
                    session.daemon.logger.error("remote new workspace failed: \(String(describing: error), privacy: .public)")
                    return ActionWorkFailure(RemoteStrings.newWorkspaceFailed(session.host.label, error))
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
        // The raw SSH or install error of a machine whose connect failed
        // (its sidebar header shows it as the tooltip, cx-zdh8).
        CloudHandlers.bind("remote.copyError", registry, reason: hasMachine) { invocation in
            let session = try machine(invocation, context)
            guard let error = RemoteStrings.sshError(session) else { throw ActionFailure(message: RemoteStrings.noSSHError(session.host.label)) }
            context.copy(error)
        }
        // No question (Lawrence 2026-10-07): a person's Forget hides the
        // machine at once and its undo toast writes it when it ends.
        CloudHandlers.bind("remote.forget", registry, reason: hasMachine) { invocation in
            let session = try machine(invocation, context)
            if invocation.origin == .user, let window = CloudHandlers.window(context) {
                return RemoteForgetUndo.forget(session, ssh: ssh, in: window)
            }
            let work: ActionWork = Task {
                await ssh.forget(session)
                return nil
            }
            registry.track(work)
        }
        // The Add Machine card (plans/cmux-next/add-machine-DESIGN.md). A destination (the CLI, MCP)
        // only fills the card: the enroll starts when the person presses Add, never from outside the
        // app alone (trust policy, the conservative default until it is decided).
        // Add Device (plans/cmux-next/add-device-DESIGN.md): the one entry; Add Machine and Add Server are its ways.
        registry.bind("device.add", run: { invocation in
            let way = invocation["way"]?.stringValue.flatMap(AddDeviceWay.init(rawValue:))
            context.services.addDevice.open(way: way, over: CloudHandlers.window(context))
        })
        CloudHandlers.bind("machine.add", registry, reason: available) { invocation in
            let card = context.services.addMachine
            card.open(destination: invocation["destination"]?.stringValue, name: invocation["name"]?.stringValue,
                      over: CloudHandlers.window(context))
        }
        // Check Machine: the same card's checklist for one SSH machine, with Fix.
        CloudHandlers.bind("machine.doctor", registry, reason: hasMachine) { invocation in
            let session = try machine(invocation, context), card = context.services.addMachine
            card.check(host: session.host.destination.description, machineID: session.machineID, over: CloudHandlers.window(context))
            registry.track(Task { await card.finished().map { ActionWorkFailure($0) } })
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
            for await (loaded, status) in ObservationStream({ (daemon.store.isLoaded && daemon.connection != nil, session.linkStatus) }) {
                if loaded {
                    let id: String?
                    if let first = daemon.store.workspaces.first { id = first.id } else { id = await context.services.windows.createWorkspace(on: daemon) }
                    if let id { CloudHandlers.show(id, context) }
                    return
                }
                switch status {
                case .connecting, .connected, .reconnecting, .installing, .needsInstall, .unreachable, .failed: continue
                case .offline, .authFailed, .hostKeyUntrusted, .installFailed:
                    if status != .offline { CloudPresenter.show(RemoteStrings.connectFailedTitle(session.host.label),
                                                                 RemoteStrings.detail(session) ?? "", in: CloudHandlers.window(context)) }
                    return
                }
            }
        }
    }
}

/// `cmux open-remote <host>` (manaflow-ai/cmux#25092): one idempotent verb that opens a persistent
/// terminal of a connected machine in a tab or a split, or focuses the one a first run made.
extension RemoteHandlers {
    static func bindOpenRemote(into registry: ActionRegistry, context: AppActionContext) {
        // action-wait-allow: the terminal is created on the remote daemon over the network, so nothing local can show before its reply.
        registry.bind("remote.openRemote", run: { invocation in
            let request: OpenRemoteRequest
            do { request = try OpenRemoteRequest(invocation) } catch let failure as OpenRemoteRequest.Failure {
                throw ActionFailure(message: message(for: failure))
            }
            guard let pane = context.daemonPane(invocation) else { throw ActionFailure.invalidTarget(RefusalStrings.noPaneID(invocation.target?.id ?? "focused")) }
            let machines = context.services.machines
            let known = machines.ssh.map { OpenRemoteMachine(id: $0.machineID, name: $0.host.label, destination: $0.host.destination.description) }
                + machines.cloud.map { OpenRemoteMachine(id: $0.machineID, name: $0.machine.title, destination: "") }
            guard let match = OpenRemoteMachine.match(request.host, in: known) else {
                throw ActionFailure.notFound(RemoteStrings.openRemoteHostNotFound(request.host))
            }
            guard let daemon = machines.daemon(machine: match.id), let session = daemon.identity?.sessionID else {
                throw ActionFailure(message: WorkspaceVerbStrings.machineNotConnected)
            }
            let home = context.services.daemon(for: pane)
            let title = RemoteStrings.terminalOn(context.services.remoteTerminals.sessionName(of: daemon))
            // Idempotent: the tab a first run made, anywhere in the home's workspaces.
            let existing = home.store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).first {
                $0.kind == .remoteTerminal && $0.remote?.sessionID == session
                    && request.matchesTab(name: $0.name, title: $0.displayTitle, defaultTitle: title)
            }
            if let existing {
                if request.focus {
                    registry.perform("tab.focus", invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: existing.id), origin: invocation.origin))
                }
                return
            }
            let direction: SplitDirection? = switch request.placement {
            case .tab: nil
            case .right: .right
            case .down: .down
            }
            if let failure = context.services.remoteTerminals.openTerminal(
                on: daemon, in: pane, home: home, cwd: request.cwd, splitting: direction, name: request.attach ?? request.name,
                command: request.cmd, ratio: request.ratio, keepFocus: !request.focus
            ) {
                throw ActionFailure(message: failure.message)
            }
        })
    }

    private static func message(for failure: OpenRemoteRequest.Failure) -> String {
        switch failure {
        case .missingHost: RemoteStrings.noMachine
        case .unsupportedSplit: RemoteStrings.splitRightOrDown
        case .badRatio(let text): RemoteStrings.openRemoteBadRatio(text)
        }
    }
}

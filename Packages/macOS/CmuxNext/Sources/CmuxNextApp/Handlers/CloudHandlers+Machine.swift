import AppKit
import CmuxNextActions
import CmuxNextCloud
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextSidebar
import CmuxNextWakeups

// Per-machine actions: open, terminal, rename, kill, pause/resume, copy,
// resize, status, ports, tools, handoff, snapshot, promote to template,
// restore, fork, and snapshot deletion.
extension CloudHandlers {
    static func bindMachineActions(into registry: ActionRegistry, context: AppActionContext, reason: @escaping @MainActor () -> String?) {
        let cloud = context.services.cloud
        bind("cloudOpenMachine", registry, reason: reason) { invocation in
            let session = try machine(invocation, context)
            // An app link waits for the user after it ended: opening the
            // machine connects it (a live link stays as it is), as `user`
            // only for the user's own gesture. A paused machine resumes first.
            run("open machine", context) {
                try await attached(session, invocation)
                show(try await firstWorkspace(on: session, context), context)
            }
        }
        bind("cloudOpenDesktop", registry, reason: reason) { invocation in
            try openDesktop(try machine(invocation, context), context, viewer: invocation["viewer"]?.stringValue)
        }
        bind("cloudSSH", registry, reason: reason) { invocation in
            let session = try machine(invocation, context)
            guard attachable(session) else { throw ActionFailure(message: CloudStrings.notConnected) }
            // A CLI or agent run gets the new tab's ids (machine, workspace, surface), so it can
            // type into it next; a paused machine resumes first and answers `pending` past the deadline.
            guard origin(of: invocation) == .user else {
                return result("open Cloud SSH terminal", context, pendingAfter: terminalAnswerWait, pending: terminalPending(session)) {
                    try await attachedAndConnected(session, invocation)
                    return try await newTerminalTab(on: session, at: try await terminalAnchor(on: session, context), invocation, context)
                }
            }
            runTracked("open Cloud SSH terminal", context) {
                try await attachedAndConnected(session, invocation)
                _ = try await newTerminalTab(on: session, at: try await terminalAnchor(on: session, context), invocation, context)
            }
        }
        bind("cloudExec", registry, reason: reason) { invocation in
            let session = try machine(invocation, context)
            let command = try commandArgument(invocation)
            // A CLI or agent run gets the command's exit code and output: it runs through the
            // Cloud API's exec and opens no tab (the CLI cannot read a tab on the machine's
            // daemon); a machine without API exec refuses it. A person's run types it into a new tab.
            if origin(of: invocation) != .user {
                // Typing into a tab gives a CLI or agent nothing to read: refuse instead.
                guard session.machine.allows(.exec) else { throw ActionFailure(message: CloudStrings.execUnavailable(session.machineID)) }
                return result("exec on Cloud machine", context) {
                    let ran = try await cloud.api.exec(session.machineID, command: command, timeoutMs: execTimeoutMs)
                    return ["machine_id": .string(session.machineID), "exit_code": .int(ran.exitCode),
                            "stdout": .string(ran.stdout), "stderr": .string(ran.stderr)]
                }
            }
            guard session.daemon.connection != nil else { throw ActionFailure(message: CloudStrings.notConnected) }
            runTracked("exec on Cloud machine", context) {
                let anchor = try await terminalAnchor(on: session, context)
                guard let connection = session.daemon.connection else { throw ActionFailure(message: CloudStrings.notConnected) }
                let created = try await connection.newTab(in: anchor.pane.handle, options: SpawnOptions(workspace: anchor.key))
                try await connection.send(created.surface, text: command + "\n")
                if invocation.allowsViewChange { reveal(created.surface, in: anchor.pane, workspaceID: anchor.id, context) }
            }
        }
        bind("cloudFilesList", registry, reason: reason) { invocation in
            let session = try machine(invocation, context), path = try filePath(invocation)
            answer("list Cloud files", invocation, context) {
                let entries = try await cloud.api.listFiles(session.machineID, path: path)
                let body = entries.map { entry in
                    var line = entry.kind == "directory" ? "d" : "-"
                    line += " \(entry.name)"
                    if let size = entry.size { line += " \(size) bytes" }
                    return line
                }.joined(separator: "\n")
                return CloudAnswer(title: CloudStrings.filesTitle, text: body.isEmpty ? "(empty)" : body,
                                   fields: ["path": .string(path), "count": .int(entries.count)])
            }
        }
        bind("cloudFileRead", registry, reason: reason) { invocation in
            let session = try machine(invocation, context), path = try filePath(invocation)
            answer("read Cloud file", invocation, context) {
                let contents = try await cloud.api.readFile(session.machineID, path: path)
                var fields: [String: ActionResultValue] = ["path": .string(path), "encoding": .string(contents.text == nil ? "base64" : "utf8")]
                if contents.text == nil { fields["data_base64"] = .string(contents.dataBase64) }
                if let size = contents.size { fields["size"] = .int(Int(size)) }
                return CloudAnswer(title: CloudStrings.fileContentsTitle, text: contents.text ?? contents.dataBase64, fields: fields)
            }
        }
        bind("cloudFileWrite", registry, reason: reason) { invocation in
            let session = try machine(invocation, context), path = try filePath(invocation)
            guard let contents = invocation["contents"]?.stringValue else { throw ActionFailure(message: CloudStrings.fileContentsRequired) }
            runTracked("write Cloud file", context) {
                try await cloud.api.writeFile(session.machineID, path: path, data: Data(contents.utf8))
            }
        }
        bind("cloudFileMkdir", registry, reason: reason) { invocation in
            let session = try machine(invocation, context), path = try filePath(invocation)
            runTracked("create Cloud directory", context) { try await cloud.api.makeDirectory(session.machineID, path: path) }
        }
        bind("cloudFileRemove", registry, reason: reason) { invocation in
            let session = try machine(invocation, context), path = try filePath(invocation)
            runTracked("remove Cloud file", context) { try await cloud.api.removeFile(session.machineID, path: path) }
        }
        bind("cloudFileStat", registry, reason: reason) { invocation in
            let session = try machine(invocation, context), path = try filePath(invocation)
            answer("stat Cloud file", invocation, context) {
                let stat = try await cloud.api.statFile(session.machineID, path: path)
                var body = ["kind: \(stat.kind)"]
                var fields: [String: ActionResultValue] = ["path": .string(path), "kind": .string(stat.kind)]
                if let size = stat.size {
                    body.append("size: \(size) bytes")
                    fields["size"] = .int(Int(size))
                }
                if let mode = stat.mode {
                    body.append(String(format: "mode: %o", mode))
                    fields["mode"] = .string(String(mode, radix: 8))
                }
                return CloudAnswer(title: CloudStrings.fileStatTitle, text: body.joined(separator: "\n"), fields: fields)
            }
        }
        bind("cloudPrepareSCP", registry, reason: reason) { invocation in
            let session = try machine(invocation, context)
            guard let publicKey = invocation["publicKey"]?.stringValue, !publicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ActionFailure(message: CloudStrings.publicKeyRequired)
            }
            answer("prepare Cloud file transfer", invocation, context) {
                let endpoint = try await cloud.api.prepareSCP(session.machineID, publicKey: publicKey)
                let body = ["host: \(endpoint.host)", "port: \(endpoint.port)", "user: \(endpoint.username)",
                            "host key: \(endpoint.hostPublicKey)", "expires: \(Date(timeIntervalSince1970: TimeInterval(endpoint.expiresAtUnix)))"].joined(separator: "\n")
                return CloudAnswer(title: CloudStrings.scpTitle, text: body, fields: [
                    "host": .string(endpoint.host), "port": .int(endpoint.port), "user": .string(endpoint.username),
                    "host_key": .string(endpoint.hostPublicKey), "expires_at": .int(Int(endpoint.expiresAtUnix)),
                ])
            }
        }
        bind("cloudNewTerminal", registry, reason: reason) { invocation in
            let session = try machine(invocation, context)
            let workspace = try machineWorkspaceArgument(invocation, machine: session.machineID)
            guard attachable(session) else { throw ActionFailure(message: CloudStrings.notConnected) }
            // A CLI or agent run gets the ids of what it made, and the window keeps what it shows
            // unless the run asked for focus.
            guard origin(of: invocation) == .user else {
                // A paused machine resumes first: answer `pending` if that outlasts the run's deadline.
                return result("new terminal on machine", context, pendingAfter: terminalAnswerWait, pending: terminalPending(session)) {
                    try await attachedAndConnected(session, invocation)
                    return try await newTerminal(on: session, in: workspace, invocation, context)
                }
            }
            run("new terminal on machine", context) {
                try await attachedAndConnected(session, invocation)
                _ = try await newTerminal(on: session, in: workspace, invocation, context)
            }
        }
        bind("cloudRenameMachine", registry, reason: reason) { invocation in
            let session = try machine(invocation, context)
            let rename = { (name: String) in
                result("rename machine", context) {
                    try await cloud.renameMachine(session.machineID, to: name)
                    return machineFields(session.machineID, ["name": .string(name)])
                }
            }
            if let name = invocation["name"]?.stringValue { return rename(name) }
            context.services.registry.ask("cloudRenameMachine", invocation,
                                          ActionArgumentAsk(argument: "name", initialText: session.machine.displayName ?? ""))
        }
        // Destructive: the registry confirmed it (sheet, or `confirm: true`).
        bind("cloudKillMachine", registry, reason: reason) { invocation in
            let session = try machine(invocation, context)
            result("kill machine", context, pendingAfter: machineAnswerWait, pending: machineFields(session.machineID)) {
                try await cloud.deleteMachine(session.machineID)
                return machineFields(session.machineID, ["status": .string("deleted")])
            }
        }
        bind("cloudPauseMachine", registry, reason: reason) { invocation in
            let session = try machine(invocation, context)
            runTracked("pause machine", context) {
                try await cloud.pauseMachine(session.machineID)
            }
        }
        bind("cloudResumeMachine", registry, reason: reason) { invocation in
            let session = try machine(invocation, context)
            runTracked("resume machine", context) {
                try await cloud.resumeMachine(session.machineID)
            }
        }
        bind("cloudCopyMachineID", registry, reason: reason) { invocation in CloudPresenter.copy(try machine(invocation, context).machineID) }
        bind("cloudCopyPort", registry, reason: reason) { invocation in
            let session = try machine(invocation, context), port = try port(invocation)
            guard let address = session.machine.address?.ipv4 else { throw ActionFailure(message: CloudStrings.noAddress) }
            CloudPresenter.copy("http://\(address):\(port)")
        }
        bind("cloudCopyLink", registry, reason: reason) { invocation in
            let session = try machine(invocation, context), port = try port(invocation); guard session.machine.allows(.ports) else { throw operationUnavailable }
            run("copy machine link", context) { CloudPresenter.copy(try await cloud.api.openPort(session.machineID, port: port).url) }
        }
        bind("cloudResizeMachine", registry, reason: reason) { invocation in
            let session = try machine(invocation, context); guard session.machine.allows(.sizing) else { throw operationUnavailable }
            guard let size = invocation["size"]?.stringValue, let (cpu, memory) = sizes[size] else {
                throw ActionFailure(message: CloudStrings.sizeMustBeOneOf(sizes.keys.sorted().joined(separator: ", ")))
            }
            result("resize machine", context, pendingAfter: machineAnswerWait, pending: machineFields(session.machineID, ["size": .string(size)])) {
                try await cloud.api.resize(session.machineID, cpu: cpu, memoryMb: memory)
                return machineFields(session.machineID, ["size": .string(size)])
            }
        }
        // The idle auto-pause (web/services/vms/idlePause.ts): cmux Cloud pauses the machine
        // after this many minutes with nothing attached, running or forwarded; `off` never.
        bind("cloudSetIdlePause", registry, reason: reason) { invocation in
            try setIdlePause(invocation, context) { try await cloud.setIdlePause($0, minutes: $1) }
        }
        // `cloud apply-machine-config --target machine:<id> [--machine-config FILE]` (CloudMachineConfig):
        // uploads FILE, or reapplies the --repo checkout's `.cmux/machine.toml` or the last upload.
        bind("cloudApplyMachineConfig", registry, reason: reason) { invocation in
            let session = try machine(invocation, context); guard session.machine.allows(.exec) else { throw operationUnavailable }
            // A bare `--machine-config` (no value) arrives as `true`: refuse it, never apply the automatic source instead.
            if invocation["machineConfig"] != nil, invocation["machineConfig"]?.stringValue?.isEmpty != false {
                throw ActionFailure(message: CloudStrings.machineConfigUnreadable("--machine-config"))
            }
            let path = invocation["machineConfig"]?.stringValue.map(expandingHome)
            let work = context.services.work, machineID = session.machineID
            result("apply machine config", context) {
                var request = CloudMachineRequest()
                request.machineConfigPath = path
                let config: CloudMachineConfig
                do { config = try await request.loadMachineConfig(work: work) ?? CloudMachineConfig(contents: nil) } catch let unreadable as CloudMachineRequest.ScriptUnreadable {
                    throw ActionFailure(message: CloudStrings.machineConfigUnreadable(unreadable.path))
                }
                let outcome = await config.apply(on: CloudMachineBootstrap.Machine(api: cloud.api, machineID: machineID))
                guard outcome.status != "failed" else { throw ActionFailure(message: outcome.reason ?? "apply machine config failed") }
                return ["machine_id": .string(machineID), "machine_config": machineConfigAnswer(outcome, machineID: machineID)]
            }
        }
        bind("cloudDeliverSecrets", registry, reason: reason) { invocation in try deliverSecrets(invocation, context) }
        bind("palette.cloud.status", registry, reason: reason) { invocation in
            let session = try machine(invocation, context); guard session.machine.allows(.stats) else { throw operationUnavailable }
            answer("machine status", invocation, context) {
                let stats = try await cloud.api.stats(session.machineID)
                return CloudAnswer(title: CloudStrings.statusTitle, text: describe(session, stats), fields: statusFields(session, stats))
            }
        }
        bind("palette.cloud.ports", registry, reason: reason) { invocation in
            let session = try machine(invocation, context)
            guard let connection = session.daemon.connection else { throw ActionFailure(message: CloudStrings.notConnected) }
            answer("machine ports", invocation, context) {
                let table = try await connection.request(MachineListeningTCPRequest()).stdout
                let ports = MachineListeningTCPRequest.ports(in: table)
                let body = ports.isEmpty ? CloudStrings.noPorts : ports.map(String.init).joined(separator: "\n")
                return CloudAnswer(title: CloudStrings.portsTitle, text: body, copyable: !ports.isEmpty,
                                   fields: ["machine_id": .string(session.machineID), "ports": .string(ports.map(String.init).joined(separator: ","))])
            }
        }
        bind("palette.cloud.tools", registry, reason: reason) { invocation in
            let session = try machine(invocation, context); guard session.machine.allows(.exec) else { throw operationUnavailable }
            answer("machine tools", invocation, context) {
                let result = try await cloud.api.exec(session.machineID, command: toolsProbe)
                return CloudAnswer(title: CloudStrings.toolsTitle, text: result.stdout,
                                   fields: ["machine_id": .string(session.machineID), "exit_code": .int(result.exitCode)])
            }
        }
        // `cmux vm handoff`: the live status plus the commands that attach to
        // and inspect the machine, for pasting to another person or agent.
        bind("palette.cloud.handoff", registry, reason: reason) { invocation in
            let session = try machine(invocation, context)
            answer("hand off machine", invocation, context) {
                let live = try await cloud.api.machine(session.machineID)
                return CloudAnswer(title: CloudStrings.handoffTitle, text: handoff(live),
                                   fields: ["machine_id": .string(live.id), "status": .string(live.status.rawValue)])
            }
        }
        bind("palette.cloud.snapshot", registry, reason: reason) { invocation in
            let session = try machine(invocation, context); guard session.machine.allows(.snapshot) else { throw operationUnavailable }
            answer("snapshot machine", invocation, context, pendingAfter: snapshotAnswerWait, pending: ["machine_id": .string(session.machineID)]) {
                let snapshot = try await cloud.api.snapshot(session.machineID, name: nil)
                return CloudAnswer(title: CloudStrings.snapshotTitle, text: CloudStrings.snapshotBody(snapshot.id),
                                   fields: ["machine_id": .string(session.machineID), "snapshot_id": .string(snapshot.id)])
            }
        }
        bind("palette.cloud.deleteSnapshot", registry, reason: reason) { invocation in
            let session = try machine(invocation, context)
            guard let snapshot = invocation["snapshot"]?.stringValue, !snapshot.isEmpty else {
                throw ActionFailure(message: CloudStrings.snapshotRequired)
            }
            runTracked("delete snapshot", context) {
                try await cloud.api.deleteSnapshot(session.machineID, snapshotID: snapshot)
                await cloud.refresh()
            }
        }
        // The old app's `cmux vm promote-template`: a snapshot named after the
        // machine, which Restore Cloud Machine then starts new machines from.
        bind("palette.cloud.promoteTemplate", registry, reason: reason) { invocation in
            let session = try machine(invocation, context); guard session.machine.allows(.snapshot) else { throw operationUnavailable }
            answer("promote machine to template", invocation, context, pendingAfter: snapshotAnswerWait, pending: ["machine_id": .string(session.machineID)]) {
                let snapshot = try await cloud.api.snapshot(session.machineID, name: templateName(session.machineID, at: Date()))
                return CloudAnswer(title: CloudStrings.templateTitle, text: CloudStrings.templateBody(snapshot.id),
                                   fields: ["machine_id": .string(session.machineID), "snapshot_id": .string(snapshot.id)])
            }
        }
        bind("palette.cloud.restore", registry, reason: reason) { invocation in
            guard let snapshot = invocation["snapshot"]?.stringValue, !snapshot.isEmpty else { throw ActionFailure(message: CloudStrings.snapshotRequired) }
            result("restore machine", context, pendingAfter: machineAnswerWait, pending: ["snapshot_id": .string(snapshot)]) {
                let restored = try await cloud.api.restore(snapshotID: snapshot)
                await cloud.refresh()
                return machineFields(restored.id, ["snapshot_id": .string(snapshot)])
            }
        }
        bind("palette.cloud.fork", registry, reason: reason) { invocation in
            let session = try machine(invocation, context); guard session.machine.allows(.fork) else { throw operationUnavailable }
            result("fork machine", context, pendingAfter: machineAnswerWait, pending: ["source_machine_id": .string(session.machineID)]) {
                let fork = try await cloud.api.fork(session.machineID, name: nil)
                await cloud.refresh()
                return machineFields(fork.id, ["source_machine_id": .string(session.machineID)])
            }
        }
    }

    // MARK: Terminals

    /// How long a CLI or agent `cloud ssh` or `new-terminal-on-machine` waits (a paused machine
    /// resumes first) before it answers `pending`: inside `action.run`'s 40 s result deadline.
    static let terminalAnswerWait: Duration = .seconds(30)

    /// The `pending` answer of a terminal run that outlasted ``terminalAnswerWait``.
    static func terminalPending(_ session: CloudMachineSession) -> [String: ActionResultValue] {
        session.machine.status == .paused
            ? ["machine_id": .string(session.machineID), "resuming": .bool(true)]
            : ["machine_id": .string(session.machineID)]
    }

    /// `--workspace <id>` of `new-terminal-on-machine` on `machine`: nil without one; a bare or
    /// blank flag refuses.
    static func machineWorkspaceArgument(_ invocation: ActionInvocation, machine: String) throws -> String? {
        guard let value = invocation["workspace"] else { return nil }
        guard let id = value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else {
            throw ActionFailure(message: CloudStrings.machineWorkspaceRequired(machine))
        }
        return id
    }

    /// Workspace `requested` (its id, or its `ws_…` id) on the machine's daemon, where a new tab
    /// lands: its first pane. Not found names the machine and the command that makes one. A
    /// workspace whose pane the store has not mirrored yet gets the same bounded wait
    /// ``terminalAnchor(on:_:)`` gives, then a refusal that names it.
    @MainActor static func machineWorkspace(_ requested: String, on session: CloudMachineSession) async throws -> (id: String, key: WorkspaceKey, pane: PaneModel) {
        guard let workspace = session.daemon.store.workspaces.first(where: { $0.id == requested || $0.resourceID?.rawValue == requested }) else {
            throw ActionFailure.notFound(CloudStrings.noSuchMachineWorkspace(session.machineID, requested))
        }
        if let anchor = anchor(id: workspace.id, on: session) { return anchor }
        if let anchor = await mirroredAnchor(id: workspace.id, on: session) { return anchor }
        throw ActionFailure(message: CloudStrings.machineWorkspaceHasNoPane(session.machineID, requested))
    }

    /// New Terminal Workspace on Machine: a terminal tab in workspace `workspace` of the machine
    /// when given, else a new workspace with a terminal. Answers the ids of what it made.
    @MainActor static func newTerminal(on session: CloudMachineSession, in workspace: String?, _ invocation: ActionInvocation,
                                       _ context: AppActionContext) async throws -> [String: ActionResultValue] {
        let daemon = session.daemon
        if let workspace {
            // The store holds every workspace the daemon has, also right after a resume; a
            // store that could not catch up is never read as "no such workspace".
            do { try await daemon.appliedThroughSyncBarrier() } catch {
                throw ActionFailure(message: CloudStrings.machineWorkspacesNotLoaded(session.machineID, workspace))
            }
            return try await newTerminalTab(on: session, at: try await machineWorkspace(workspace, on: session), invocation, context)
        }
        guard let id = await context.services.windows.createWorkspace(on: daemon) else { throw ActionFailure(message: CloudStrings.notConnected) }
        if invocation.allowsViewChange { show(id, context) }
        var fields: [String: ActionResultValue] = ["machine_id": .string(session.machineID), "workspace_id": .string(id)]
        // Its terminal's ids, only once the store holds the create's events (a person's run reads
        // nothing); a store that did not catch up answers the workspace without them.
        guard origin(of: invocation) != .user, let connection = daemon.connection,
              await daemon.appliedThroughReply(on: connection, after: "new terminal on machine") else { return fields }
        if let tab = daemon.store.workspaces.first(where: { $0.id == id })?.screens.first?.panes.first?.tabs.first {
            fields.merge(terminalFields(tab.surface, terminal: tab.terminalID)) { _, tab in tab }
        }
        return fields
    }

    /// A new terminal tab in `anchor`'s pane, shown when the run may change the view.
    @MainActor static func newTerminalTab(on session: CloudMachineSession, at anchor: (id: String, key: WorkspaceKey, pane: PaneModel),
                                          _ invocation: ActionInvocation, _ context: AppActionContext) async throws -> [String: ActionResultValue] {
        guard let connection = session.daemon.connection else { throw ActionFailure(message: CloudStrings.notConnected) }
        let created = try await connection.newTab(in: anchor.pane.handle, options: SpawnOptions(workspace: anchor.key))
        if invocation.allowsViewChange { reveal(created.surface, in: anchor.pane, workspaceID: anchor.id, context) }
        return ["machine_id": .string(session.machineID), "workspace_id": .string(anchor.id)]
            .merging(terminalFields(created.surface, terminal: created.terminalID)) { _, tab in tab }
    }

    /// A terminal tab's ids on the machine's daemon: `surface_id` (its handle there) and, from
    /// daemons that report one, the durable `terminal_id`.
    static func terminalFields(_ surface: SurfaceID, terminal: TerminalID?) -> [String: ActionResultValue] {
        var fields: [String: ActionResultValue] = ["surface_id": .string(surface.description)]
        if let terminal { fields["terminal_id"] = .string(terminal.rawValue) }
        return fields
    }

    /// `cloud deliver-secrets --target machine:<id> [--repo OWNER/NAME]` (CloudMachineSecrets): the values
    /// of the names the machine's last machine-config apply declared, from this Mac's Keychain to the
    /// machine over its daemon link: `--repo`'s values first, else the global ones (the person picks
    /// the scope, never the machine). Answers the names delivered and those with no value here; a
    /// machine that already has what the Mac holds gets nothing (`unchanged`); a machine that had
    /// values and now gets none has its set cleared.
    static func deliverSecrets(_ invocation: ActionInvocation, _ context: AppActionContext) throws {
        // The arguments first. A bare `--repo` (no value) arrives as `true`: refuse it, never deliver the global
        // values instead.
        if invocation["repo"] != nil, invocation["repo"]?.stringValue == nil { throw ActionFailure(message: CloudStrings.secretRepoInvalid("--repo")) }
        let repo = try invocation["repo"]?.stringValue.map { text in
            guard let scope = CloudMachineSecrets.repoScope(text) else { throw ActionFailure(message: CloudStrings.secretRepoInvalid(text)) }
            return scope
        }
        let cloud = context.services.cloud, work = context.services.work, session = try machine(invocation, context)
        guard session.machine.allows(.exec) else { throw operationUnavailable }
        guard let connection = session.daemon.connection else { throw ActionFailure(message: CloudStrings.notConnected) }
        let machineID = session.machineID, home = FileManager.default.homeDirectoryForCurrentUser
        let ledgerURL = cloud.paths.root.appendingPathComponent("secret-ledger.json")
        // One delivery per machine at a time (plan, delivery and ledger together): an older run that
        // finished after a newer one would leave the older values on the machine but the newer in the ledger.
        guard cloud.deliveringSecrets.insert(machineID).inserted else { throw ActionFailure(message: CloudStrings.secretsDeliveryRunning) }
        // A delivery waits up to a minute on each of the receiver's answers, past the CLI's result deadline:
        // the answer is then `pending`, the delivery goes on, and running the command again says how it ended
        // (`unchanged` once delivered, or that one is still running).
        let pending: [String: ActionResultValue] = ["machine_id": .string(machineID), "status": .string("delivering"),
                                                    "check": .string("cmux cloud deliver-secrets --target machine:\(machineID)")]
        result("deliver Cloud secrets", context, pendingAfter: .seconds(30), pending: pending) {
            defer { cloud.deliveringSecrets.remove(machineID) }
            let read = { (path: String) in (try? await cloud.api.readFile(machineID, path: path)).flatMap { Data(base64Encoded: $0.dataBase64) } }
            guard let declared = CloudMachineSecrets.declared(status: await read(CloudMachineConfig.statusPath)) else {
                throw ActionFailure(message: CloudStrings.machineConfigNotApplied)
            }
            let indexURL = home.appendingPathComponent(".config/cmux/cloud-secrets.json")
            // Never through a link, never waiting on a FIFO, bounded: the files lane is shared.
            let (index, ledgerFile) = try await work.run(.userBlocking, mayBlock: .files) {
                (CloudMachineSecrets.read(indexURL.path), CloudMachineSecrets.read(ledgerURL.path))
            }
            // A damaged or unreadable index is not "no secrets": delivering then would clear the machine's set.
            guard let stored = CloudMachineSecrets.index(from: index) else {
                throw ActionFailure(message: CloudStrings.secretIndexUnreadable(indexURL.path))
            }
            // The person picks the scope. When the machine says it holds a repo that has its own values
            // here, delivering global ones without a word would be the wrong values: ask for --repo.
            if repo == nil, let claimed = CloudMachineSecrets.claimedRepo(record: await read(CloudMachineBootstrap.directory + "/repo.json")),
               CloudMachineSecrets.hasRepoValues(for: declared, repo: claimed, index: stored) {
                throw ActionFailure(message: CloudStrings.secretRepoNeeded(claimed))
            }
            let (items, missing) = CloudMachineSecrets.plan(declared: declared, repo: repo, index: stored)
            let ledger = CloudMachineSecrets.Ledger(file: ledgerFile)
            var answer: [String: ActionResultValue] = ["machine_id": .string(machineID), "declared": .array(declared.map(ActionResultValue.string)),
                                                       "missing": .array(missing.map(ActionResultValue.string))]
            guard !ledger.isCurrent(items, on: machineID) else {
                answer["status"] = .string("unchanged")
                return answer
            }
            var values: [(name: String, value: String)] = []
            for item in items {
                let ran = try await AsyncProcess().run(ProcessRequest(URL(fileURLWithPath: "/usr/bin/security"),
                    ["find-generic-password", "-s", CloudMachineSecrets.service, "-a", item.account, "-w"], timeout: .seconds(30)))
                guard ran.succeeded else { throw ActionFailure(message: CloudStrings.secretUnreadable(item.name)) }
                let value = String(ran.text.dropLast(ran.text.hasSuffix("\n") ? 1 : 0))
                // One line, no NUL, as `cmux cloud secret set` stores it: an item made some other way never
                // turns into extra records on the machine.
                guard CloudMachineSecrets.isValue(value) else { throw ActionFailure(message: CloudStrings.secretUnreadable(item.name)) }
                values.append((item.name, value))
            }
            // 0644 and run with `sh`: the file API may write as root, and the terminal runs as the work user.
            // The receiver holds no value; the folder is the work user's 0700 one (the config apply made it),
            // so its ticket (below) is readable by that user and root only.
            try await cloud.api.writeFile(machineID, path: CloudMachineSecrets.receiverPath, data: Data(CloudMachineSecrets.receiver.utf8), mode: 0o644)
            let key = try await terminalAnchor(on: session, context).key
            // The handle is "<surface> <terminal id>": the surface takes input and waits, the id closes it.
            let surface: @Sendable (String) -> SurfaceID = { SurfaceID(rawValue: $0.split(separator: " ").first.flatMap { UInt64($0) } ?? 0) }
            // Read here, on the main actor (CloudStrings is main-actor isolated); the link's closures are not.
            let notConnected = CloudStrings.notConnected
            let link = CloudMachineSecrets.Link(
                // Like the receiver: 0644 in the work user's 0700 folder, so only it (and root) can read it.
                writeTicket: { ticket in
                    try await cloud.api.writeFile(machineID, path: CloudMachineSecrets.ticketPath, data: ticket, mode: 0o644)
                },
                start: { argv in
                    // An explicit empty environment: nil would take the app's terminal environment provider,
                    // whose values the daemon stores with the receipt. Only the daemon's placement ids are added.
                    let made = try await connection.createTerminal(in: key, argv: argv, name: "cmux secrets",
                                                                   size: CellSize(cols: CloudMachineSecrets.terminalColumns, rows: 24), env: [:], keep: false)
                    guard let surface = made.surface else { throw ActionFailure(message: notConnected) }
                    return "\(surface.rawValue) \(made.terminalID.rawValue)"
                },
                waitFor: { handle, pattern, seconds in
                    try await connection.request(WaitForTextRequest(surface: surface(handle), pattern: pattern, timeoutMs: seconds * 1000),
                                                 timeout: .seconds(seconds + 5)).text
                },
                type: { handle, bytes in try await connection.send(surface(handle), bytes: bytes) },
                close: { handle in
                    guard let id = handle.split(separator: " ").last else { return }
                    try? await connection.closeTerminal(TerminalID(rawValue: String(id)))
                })
            let count: Int
            do { count = try await CloudMachineSecrets.deliver(values, over: link) } catch {
                // A receiver that never started leaves its ticket: emptied, so no stale key stays behind.
                try? await cloud.api.writeFile(machineID, path: CloudMachineSecrets.ticketPath, data: Data(), mode: 0o644)
                guard let failed = error as? CloudMachineSecrets.DeliveryFailed else {
                    // Only the kind of failure: no error text near the values reaches a log or the caller.
                    throw ActionFailure(message: CloudStrings.secretsNotDelivered(String(describing: type(of: error))))
                }
                throw ActionFailure(message: CloudStrings.secretsNotDelivered(failed.reason))
            }
            // The values are on the machine either way; a ledger not written only means the next run delivers again.
            try? await work.run(.userBlocking, mayBlock: .files) { try CloudMachineSecrets.Ledger.record(items, on: machineID, at: ledgerURL) }
            answer["status"] = .string("delivered")
            answer["delivered"] = .array(items.map { .string($0.name) })
            answer["written"] = .int(count)
            answer["next"] = .string("cmux cloud apply-machine-config --target machine:\(machineID)")
            return answer
        }
    }

    private static var operationUnavailable: ActionFailure {
        ActionFailure(message: String(localized: "cloud.operationUnavailable",
            defaultValue: "This action is unavailable for this Cloud machine.", bundle: .module))
    }

    /// What `cmux vm tools` ran: the login shell, where each common tool is
    /// (or "missing"), and the zsh and gh versions.
    static let toolsProbe = [
        "printf 'shell: '; printf '%s\\n' \"$SHELL\"",
        "for tool in zsh git gh htop btop node bun python3; do if command -v \"$tool\" >/dev/null 2>&1; then printf '%-8s %s\\n' \"$tool\" \"$(command -v \"$tool\")\"; else printf '%-8s missing\\n' \"$tool\"; fi; done",
        "zsh --version 2>/dev/null || true",
        "gh --version 2>/dev/null | head -n 1 || true"
    ].joined(separator: "; ")

    /// The handoff text, with the old app's fields and the CLI verbs that
    /// open a terminal on the machine and report on it (`open-machine` and
    /// `machine-tools` are GUI-only on the CLI).
    static func handoff(_ machine: CloudMachine) -> String {
        let target = "--target machine:\(machine.id)"
        return ["\(machine.title) (\(machine.id))", "provider: \(machine.provider.isEmpty ? "?" : machine.provider)", "status: \(machine.status.rawValue)",
                "attach: cmux cloud new-terminal-on-machine \(target)", "inspect: cmux cloud machine-status \(target)"].joined(separator: "\n")
    }

    /// A machine action's `action.run` result: the machine's id and the
    /// `--target` that names it in the next command, plus `extra`.
    static func machineFields(_ machineID: String, _ extra: [String: ActionResultValue] = [:]) -> [String: ActionResultValue] {
        extra.merging(["machine_id": .string(machineID), "target": .string("machine:\(machineID)")]) { _, own in own }
    }

    /// How long a CLI or agent fork, restore, resize or kill waits for the
    /// server before it answers `pending`: inside `action.run`'s 40 s result
    /// deadline. The work finishes either way.
    static let machineAnswerWait: Duration = .seconds(30)

    /// How long a CLI or agent snapshot waits for its id before it answers
    /// `pending` (a snapshot may take minutes): inside `action.run`'s 40 s
    /// result deadline. The snapshot finishes either way.
    static let snapshotAnswerWait: Duration = .seconds(30)

    /// `template-<first 12 of the id>-<unix seconds>`, the old CLI's name.
    static func templateName(_ machineID: String, at date: Date) -> String {
        "template-\(machineID.prefix(12))-\(Int(date.timeIntervalSince1970))"
    }

    /// `size` choices -> (vCPUs, MiB). Pro allows up to 24 GiB.
    static let sizes: [String: (Int, Int)] = ["small": (2, 4096), "medium": (4, 8192), "large": (8, 16384), "xlarge": (16, 24576)]

    static func filePath(_ invocation: ActionInvocation) throws -> String {
        guard let path = invocation["path"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              path.hasPrefix("/"), !path.contains("\0"), !path.split(separator: "/").contains(".."), path.utf8.count <= 4096 else {
            throw ActionFailure(message: CloudStrings.filePathRequired)
        }
        return path
    }

    /// `cloud set-idle-pause --target machine:<id> --minutes off|15|30|60|120`. A CLI, agent or
    /// script run gets `machine_id` and `idle_pause_minutes` back as its result (#23155); a
    /// person's run reports a failure in a sheet. `set` stores it (`CloudService.setIdlePause`).
    static func setIdlePause(_ invocation: ActionInvocation, _ context: AppActionContext,
                             set: @escaping @MainActor (String, Int) async throws -> Void) throws {
        let session = try machine(invocation, context)
        let minutes = try idlePauseMinutes(invocation)
        let machineID = session.machineID
        guard origin(of: invocation) == .user else {
            return result("set idle pause", context) {
                try await set(machineID, minutes)
                return ["machine_id": .string(machineID), "idle_pause_minutes": .int(minutes)]
            }
        }
        runTracked("set idle pause", context) { try await set(machineID, minutes) }
    }

    /// The `minutes` argument of `cloud set-idle-pause`: `off` (0) or one of
    /// ``CloudMachine/idlePauseChoices``, as text or a number.
    static func idlePauseMinutes(_ invocation: ActionInvocation) throws -> Int {
        let value = invocation["minutes"]
        let text = (value?.stringValue ?? value?.intValue.map(String.init))?.trimmingCharacters(in: .whitespaces).lowercased()
        let minutes = text == "off" ? 0 : text.flatMap { Int($0) }
        guard let minutes, CloudMachine.idlePauseChoices.contains(minutes) else {
            throw ActionFailure(message: CloudStrings.idlePauseMustBeOneOf(
                (["off"] + CloudMachine.idlePauseChoices.filter { $0 > 0 }.map(String.init)).joined(separator: ", ")))
        }
        return minutes
    }

    static func port(_ invocation: ActionInvocation) throws -> Int {
        guard let port = invocation["port"]?.intValue, (1...65535).contains(port) else { throw ActionFailure(message: CloudStrings.invalidPort) }
        return port
    }

    /// `describe`'s facts as `action.run` result fields.
    static func statusFields(_ session: CloudMachineSession, _ stats: CloudMachineStats, now: Date = Date()) -> [String: ActionResultValue] {
        var fields: [String: ActionResultValue] = [
            "machine_id": .string(session.machineID), "title": .string(session.machine.title),
            "state": .string(stats.state), "status": .string(session.effectiveStatus.rawValue),
        ]
        if let cpus = stats.cpus { fields["cpus"] = .int(cpus) }
        if let percent = stats.cpuPercent { fields["cpu_percent"] = .double(percent) }
        if let used = stats.memoryUsedMb { fields["memory_used_mb"] = .double(used) }
        if let total = stats.memoryTotalMb { fields["memory_total_mb"] = .double(total) }
        if let used = stats.diskUsedMb { fields["disk_used_mb"] = .double(used) }
        if let total = stats.diskTotalMb { fields["disk_total_mb"] = .double(total) }
        if let address = session.machine.address?.ipv4 { fields["address"] = .string(address) }
        fields.merge(costFields(session.machine, now: now)) { _, new in new }
        return fields
    }

    /// The machine's cost as `action.run` fields, from server facts: `hourly_rate_usd`,
    /// `running_since` (ISO 8601) and `estimated_cost_usd` (rate x time running). A
    /// paused machine has no `running_since` or estimate.
    static func costFields(_ machine: CloudMachine, now: Date) -> [String: ActionResultValue] {
        guard let cost = CloudCreationRows.cost(machine, limits: nil) else { return [:] }
        var fields: [String: ActionResultValue] = [:]
        if let rate = cost.hourlyRateUsd { fields["hourly_rate_usd"] = .double(rate) }
        if let since = cost.runningSince { fields["running_since"] = .string(since.ISO8601Format()) }
        if let spent = cost.estimatedCostUsd(now: now) { fields["estimated_cost_usd"] = .double((spent * 10_000).rounded() / 10_000) }
        return fields
    }

    static func describe(_ session: CloudMachineSession, _ stats: CloudMachineStats, now: Date = Date()) -> String {
        var lines = ["\(session.machine.title) (\(session.machineID))", "state: \(stats.state), status: \(session.effectiveStatus.rawValue)"]
        if let cpus = stats.cpus { lines.append("cpus: \(cpus)" + (stats.cpuPercent.map { String(format: ", %.0f%%", $0) } ?? "")) }
        if let used = stats.memoryUsedMb, let total = stats.memoryTotalMb { lines.append(String(format: "memory: %.0f / %.0f MB", used, total)) }
        if let used = stats.diskUsedMb, let total = stats.diskTotalMb { lines.append(String(format: "disk: %.0f / %.0f MB", used, total)) }
        if let address = session.machine.address?.ipv4 { lines.append("address: \(address)") }
        if let usage = CloudCreationRows.cost(session.machine, limits: nil).flatMap({ $0.usage(now: now) }) { lines.append(usage) }
        return lines.joined(separator: "\n")
    }
}

/// `machine-listening-tcp` (cmux-tui protocol 12, `machine-listening-tcp-v1`):
/// the host's `ss -H -ltn` table, read over the machine's own link.
struct MachineListeningTCPRequest: DaemonRequest {
    struct Response: Decodable, Sendable { var stdout: String }
    static let command = "machine-listening-tcp"

    /// Distinct listening ports, ascending, from `ss`/`netstat` lines.
    static func ports(in table: String) -> [Int] {
        var ports = Set<Int>()
        for line in table.split(whereSeparator: \.isNewline) {
            for field in line.split(separator: " ") where field.contains(":") {
                guard let last = field.split(separator: ":").last, let port = Int(last), port > 0 else { continue }
                ports.insert(port)
                break
            }
        }
        return ports.sorted()
    }
}

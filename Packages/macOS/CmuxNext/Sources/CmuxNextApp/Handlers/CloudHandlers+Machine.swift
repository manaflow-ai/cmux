import AppKit
import CmuxNextActions
import CmuxNextCloud
import CmuxNextCloudUI
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextPalette
import CmuxNextSidebar
import CmuxNextWakeups

// Per-machine actions: open, terminal, rename, kill, pause/resume, copy,
// resize, status, ports, tools, handoff, snapshot, promote to template,
// restore, fork, and snapshot deletion.
extension CloudHandlers {
    static func bindMachineActions(into registry: ActionRegistry, context: AppActionContext, reason: @escaping @MainActor () -> String?) {
        let cloud = context.services.cloud, rules = CloudHandlerRules()
        bind("cloudOpenMachine", registry, reason: reason) { invocation in
            let session = try machine(invocation, context)
            // An app link waits for the user after it ended: opening the
            // machine connects it (a live link stays as it is), as `user`
            // only for the user's own gesture, which waits for it. A paused machine resumes first.
            run("open machine", context) {
                try await attached(session, invocation, waitsForLink: true)
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
            let command = try rules.text("command", invocation)
            // A CLI or agent run gets the command's exit code and output: it runs through the
            // Cloud API's exec and opens no tab (the CLI cannot read a tab on the machine's
            // daemon); a machine without API exec refuses it. A person's run types it into a new tab.
            if origin(of: invocation) != .user {
                // Typing into a tab gives a CLI or agent nothing to read: refuse instead.
                guard session.machine.allows(.exec) else { throw ActionFailure(message: CloudStrings.execUnavailable(session.machineID)) }
                return result("exec on Cloud machine", context) {
                    let ran = try await cloud.machineAPI.exec(session.machineID, command: command, timeoutMs: execTimeoutMs)
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
                let entries = try await cloud.machineAPI.listFiles(session.machineID, path: path)
                let facts: [[String: Any]] = entries.map { ["kind": $0.kind, "name": $0.name, "size": $0.size as Any].compacted }
                return cloudAnswer(CloudStrings.filesTitle, rules.answer(["kind": "filesList", "path": path, "entries": facts]))
            }
        }
        bind("cloudFileRead", registry, reason: reason) { invocation in
            let session = try machine(invocation, context), path = try filePath(invocation)
            answer("read Cloud file", invocation, context) {
                let contents = try await cloud.machineAPI.readFile(session.machineID, path: path)
                let facts: [String: Any] = ["kind": "fileRead", "path": path, "text": contents.text as Any, "dataBase64": contents.dataBase64,
                                            "size": contents.size.map { Int($0) } as Any]
                return cloudAnswer(CloudStrings.fileContentsTitle, rules.answer(facts.compacted))
            }
        }
        bind("cloudFileWrite", registry, reason: reason) { invocation in
            let session = try machine(invocation, context), path = try filePath(invocation)
            let contents = try rules.text("contents", invocation)
            runTracked("write Cloud file", context) {
                try await cloud.machineAPI.writeFile(session.machineID, path: path, data: Data(contents.utf8))
            }
        }
        bind("cloudFileMkdir", registry, reason: reason) { invocation in
            let session = try machine(invocation, context), path = try filePath(invocation)
            runTracked("create Cloud directory", context) { try await cloud.machineAPI.makeDirectory(session.machineID, path: path) }
        }
        bind("cloudFileRemove", registry, reason: reason) { invocation in
            let session = try machine(invocation, context), path = try filePath(invocation)
            runTracked("remove Cloud file", context) { try await cloud.machineAPI.removeFile(session.machineID, path: path) }
        }
        bind("cloudFileStat", registry, reason: reason) { invocation in
            let session = try machine(invocation, context), path = try filePath(invocation)
            answer("stat Cloud file", invocation, context) {
                let stat = try await cloud.machineAPI.statFile(session.machineID, path: path)
                let facts: [String: Any] = ["kind": "fileStat", "path": path, "fileKind": stat.kind, "size": stat.size.map { Int($0) } as Any,
                                            "mode": stat.mode.map { Int($0) } as Any]
                return cloudAnswer(CloudStrings.fileStatTitle, rules.answer(facts.compacted))
            }
        }
        bind("cloudPrepareSCP", registry, reason: reason) { invocation in
            let session = try machine(invocation, context)
            let publicKey = try rules.text("publicKey", invocation)
            answer("prepare Cloud file transfer", invocation, context) {
                let endpoint = try await cloud.machineAPI.prepareSCP(session.machineID, publicKey: publicKey)
                return cloudAnswer(CloudStrings.scpTitle, rules.answer([
                    "kind": "scp", "host": endpoint.host, "port": endpoint.port, "username": endpoint.username,
                    "hostPublicKey": endpoint.hostPublicKey, "expiresAtUnix": Int(endpoint.expiresAtUnix),
                ]))
            }
        }
        bind("cloudNewTerminal", registry, reason: reason) { invocation in
            let session = try machine(invocation, context)
            let workspace = try rules.arg("machineWorkspace", invocation, extra: ["machine": session.machineID]) as? String
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
                return deletionPending(session.machineID)
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
        // A live daemon proves Resume is redundant. Cached API status cannot: idle-pause
        // and app-link resume can both change the server without refreshing that record.
        // This only changes menu visibility; explicit commands remain idempotent.
        ActionTargetVisibility.hide("cloudResumeMachine", in: registry) { invocation in
            guard let session = try? machine(invocation, context), session.daemon.connection != nil else { return false }
            if case .connected = session.daemon.store.connectionState { return true }
            return false
        }
        bind("cloudCopyMachineID", registry, reason: reason) { invocation in CloudPresenter.copy(try machine(invocation, context).machineID) }
        bind("cloudCopyPort", registry, reason: reason) { invocation in
            let session = try machine(invocation, context), port = try rules.port(invocation)
            guard let address = session.machine.address?.ipv4 else { throw ActionFailure(message: CloudStrings.noAddress) }
            CloudPresenter.copy("http://\(address):\(port)")
        }
        bind("cloudCopyLink", registry, reason: reason) { invocation in
            let session = try machine(invocation, context), port = try rules.port(invocation); guard session.machine.allows(.ports) else { throw operationUnavailable }
            let names = CloudPortNames(session, port: port)
            run("copy machine link", context) { CloudPresenter.copy(try await previewShareLink(cloud.previewAPI, machine: session.machineID, port: port, names: names).url) }
        }
        bind("cloudResizeMachine", registry, reason: reason) { invocation in
            let session = try machine(invocation, context); guard session.machine.allows(.sizing) else { throw operationUnavailable }
            // A menu or palette run with neither still asks for the size, as when --size was required.
            if invocation["size"] == nil, invocation["disk"] == nil, origin(of: invocation) == .user,
               registry.ask("cloudResizeMachine", invocation, ActionArgumentAsk(argument: "size")) { return }
            let request = try resizeRequest(invocation), fields = machineFields(session.machineID, request.fields)
            result("resize machine", context, pendingAfter: machineAnswerWait, pending: fields) {
                try await cloud.machineChange("cloud.machine.resize", resizeArgs(request, machine: session.machineID), allow: allows("cloudResizeMachine", invocation, registry, context))
                return fields
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
            // A bare `--machine-config` (no value) arrives as `true`: refused, never the automatic source instead.
            let path = try rules.arg("applyMachineConfig", invocation, extra: ["home": NSHomeDirectory()]) as? String
            let work = context.services.work, machineID = session.machineID
            result("apply machine config", context) {
                var request = CloudMachineRequest()
                request.machineConfigPath = path
                let config: CloudMachineConfig
                do { config = try await request.loadMachineConfig(work: work) ?? CloudMachineConfig(contents: nil) } catch let unreadable as CloudMachineRequest.ScriptUnreadable {
                    throw ActionFailure(message: CloudStrings.machineConfigUnreadable(unreadable.path))
                }
                let outcome = await config.apply(on: CloudMachineBootstrap.Machine(api: cloud.machineAPI, machineID: machineID))
                guard outcome.status != "failed" else { throw ActionFailure(message: outcome.reason ?? "apply machine config failed") }
                return ["machine_id": .string(machineID), "machine_config": machineConfigAnswer(outcome, machineID: machineID)]
            }
        }
        // Not only for Cloud: an own machine needs no sign-in (deliverSecrets checks it for a Cloud machine).
        bind("cloudDeliverSecrets", registry, reason: { nil }) { invocation in try deliverSecrets(invocation, context) }
        bind("palette.cloud.status", registry, reason: reason) { invocation in
            let session = try machine(invocation, context); guard session.machine.allows(.stats) else { throw operationUnavailable }
            answer("machine status", invocation, context) {
                // Stats are a separate provider read, while idle-pause diagnostics
                // live on the VM record. Fetch both so a status action observes a
                // cron decision written after the sidebar last refreshed.
                let read = cloud.beginRecordRead(machineID: session.machineID)
                defer { cloud.finishRecordRead(read) }
                // From the API that made the machine: a Worker machine is not on /api/vm.
                let (record, stats) = try await cloud.machineStatus(session.machineID)
                // Through the list's own path: a pause suspends the link, a resume connects it.
                cloud.apply(record, to: session, read: read)
                let status = status(session, stats)
                return CloudAnswer(title: CloudStrings.statusTitle, text: status.text, fields: status.fields)
            }
        }
        bind("palette.cloud.ports", registry, reason: reason) { invocation in
            let session = try machine(invocation, context)
            if cloud.previewAPI != nil {
                return livePreviewPorts(session, invocation, context)
            }
            guard let connection = session.daemon.connection else { throw ActionFailure(message: CloudStrings.notConnected) }
            answer("machine ports", invocation, context) {
                let table = try await connection.request(MachineListeningTCPRequest()).stdout
                let ports = MachineListeningTCPRequest.ports(in: table).map { Int($0) }
                return cloudAnswer(CloudStrings.portsTitle, rules.answer(["kind": "ports", "machineId": session.machineID, "ports": ports]),
                                   none: CloudStrings.noPorts)
            }
        }
        bind("palette.cloud.tools", registry, reason: reason) { invocation in
            let session = try machine(invocation, context); guard session.machine.allows(.exec) else { throw operationUnavailable }
            answer("machine tools", invocation, context) {
                let probe = rules.ask("cloud_handler_constants", [:])?["toolsProbe"] as? String ?? ""
                let result = try await cloud.machineAPI.exec(session.machineID, command: probe)
                return cloudAnswer(CloudStrings.toolsTitle, rules.answer(["kind": "tools", "machineId": session.machineID,
                                                                          "exitCode": result.exitCode, "stdout": result.stdout]))
            }
        }
        // `cmux vm handoff`: the live status plus the commands that attach to and inspect the machine, to paste to someone.
        bind("palette.cloud.handoff", registry, reason: reason) { invocation in
            let session = try machine(invocation, context)
            answer("hand off machine", invocation, context) {
                let live = try await cloud.machineRecord(session.machineID)
                return CloudAnswer(title: CloudStrings.handoffTitle, text: handoff(live),
                                   fields: ["machine_id": .string(live.id), "status": .string(live.status.rawValue)])
            }
        }
        bind("palette.cloud.snapshot", registry, reason: reason) { invocation in
            let session = try machine(invocation, context); guard session.machine.allows(.snapshot) else { throw operationUnavailable }
            answer("snapshot machine", invocation, context, pendingAfter: snapshotAnswerWait, pending: ["machine_id": .string(session.machineID)]) {
                let snapshot = try await cloud.machineChange("cloud.snapshot.create", ["machine": .string(session.machineID)], answers: "snapshot", allow: allows("palette.cloud.snapshot", invocation, registry, context)) ?? ""
                return CloudAnswer(title: CloudStrings.snapshotTitle, text: CloudStrings.snapshotBody(snapshot),
                                   fields: ["machine_id": .string(session.machineID), "snapshot_id": .string(snapshot)])
            }
        }
        bind("palette.cloud.deleteSnapshot", registry, reason: reason) { invocation in
            // The machine must still be one of this account's; the snapshot id alone names what goes.
            _ = try machine(invocation, context)
            let snapshot = try rules.text("snapshot", invocation)
            runTracked("delete snapshot", context) {
                try await cloud.machineChange("cloud.snapshot.delete", ["snapshot": .string(snapshot)], allow: allows("palette.cloud.deleteSnapshot", invocation, registry, context))
                await cloud.refresh()
            }
        }
        // `cmux vm promote-template`: a snapshot named `template-<first 12 of the id>-<unix seconds>` that Restore starts machines from.
        bind("palette.cloud.promoteTemplate", registry, reason: reason) { invocation in
            let session = try machine(invocation, context); guard session.machine.allows(.snapshot) else { throw operationUnavailable }
            answer("promote machine to template", invocation, context, pendingAfter: snapshotAnswerWait, pending: ["machine_id": .string(session.machineID)]) {
                let name = rules.ask("cloud_handler_template_name", ["machineId": session.machineID, "unix": Int(Date().timeIntervalSince1970)])?["name"] as? String
                var args: [String: JSONValue] = ["machine": .string(session.machineID)]
                if let name { args["name"] = .string(name) }
                let snapshot = try await cloud.machineChange("cloud.snapshot.create", args, answers: "snapshot", allow: allows("palette.cloud.promoteTemplate", invocation, registry, context)) ?? ""
                return CloudAnswer(title: CloudStrings.templateTitle, text: CloudStrings.templateBody(snapshot),
                                   fields: ["machine_id": .string(session.machineID), "snapshot_id": .string(snapshot)])
            }
        }
        bind("palette.cloud.restore", registry, reason: reason) { invocation in
            let snapshot = try rules.text("snapshot", invocation)
            result("restore machine", context, pendingAfter: machineAnswerWait, pending: ["snapshot_id": .string(snapshot)]) {
                let restored = try await cloud.machineChange("cloud.snapshot.restore", ["snapshot": .string(snapshot)], answers: "machine", allow: allows("palette.cloud.restore", invocation, registry, context)) ?? ""
                await cloud.refresh()
                return machineFields(restored, ["snapshot_id": .string(snapshot)])
            }
        }
        bind("palette.cloud.fork", registry, reason: reason) { invocation in // A snapshot, then a machine from it (restored once it is ready), so it needs both ops, not `.fork`.
            let session = try machine(invocation, context); guard session.machine.allows(.snapshot), session.machine.allows(.restore) else { throw operationUnavailable }; result("fork machine", context, pendingAfter: machineAnswerWait, pending: ["source_machine_id": .string(session.machineID)]) {
                let snapshot = try await cloud.machineChange("cloud.snapshot.create", ["machine": .string(session.machineID)], answers: "snapshot", allow: allows("palette.cloud.fork", invocation, registry, context)) ?? ""; let forked = try await cloud.machineChange("cloud.snapshot.restore", ["snapshot": .string(snapshot)], answers: "machine", allow: { true }) ?? ""
                await cloud.refresh(); return machineFields(forked, ["source_machine_id": .string(session.machineID), "snapshot_id": .string(snapshot)]) }
        }
    }

    // MARK: Terminals

    /// How long a CLI or agent `cloud ssh` or `new-terminal-on-machine` waits (a paused machine
    /// resumes first) before it answers `pending`: inside `action.run`'s 40 s result deadline.
    static let terminalAnswerWait: Duration = .seconds(30)

    /// The handoff text: the machine, and the CLI verbs that open a terminal on it and report on it.
    static func handoff(_ machine: CloudMachine) -> String {
        CloudHandlerRules().ask("cloud_handler_handoff", ["title": machine.title, "machineId": machine.id, "provider": machine.provider,
                                                          "state": machine.status.rawValue])?["text"] as? String ?? machine.id
    }

    /// The `pending` answer of a kill that outlasted ``machineAnswerWait``.
    static func deletionPending(_ machineID: String) -> [String: ActionResultValue] {
        CloudHandlerRules().fields("cloud_handler_deletion_pending", ["machineId": machineID])
    }

    /// The `pending` answer of a terminal run that outlasted ``terminalAnswerWait``.
    static func terminalPending(_ session: CloudMachineSession) -> [String: ActionResultValue] {
        CloudHandlerRules().fields("cloud_handler_terminal_pending", ["machineId": session.machineID, "paused": session.machine.status == .paused])
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

    /// A terminal tab's ids on the machine's daemon: `surface_id` and, from daemons that report one, `terminal_id`.
    static func terminalFields(_ surface: SurfaceID, terminal: TerminalID?) -> [String: ActionResultValue] {
        CloudHandlerRules().fields("cloud_handler_terminal_fields", ["surface": surface.description, "terminal": terminal?.rawValue as Any].compacted)
    }

    /// `cloud deliver-secrets --target machine:<id> [--repo OWNER/NAME] [--names A,B]` (CloudMachineSecrets): the values
    /// of the names the machine's last machine-config apply declared, from this Mac's Keychain to the
    /// machine, sealed to its daemon over its carrier (`cmux carrier secrets`): `--repo`'s values first, else the global ones (the person picks
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
        let names = try secretNames(invocation)
        // An own machine (an SSH machine or an acpmux peer) over ssh, with the names the person gives
        // (CloudHandlers+OwnMachineSecrets).
        if let target = invocation.target, target.kind == .machine, !isCloudMachine(target.id, context) {
            return try deliverSecretsToOwnMachine(target.id, names: names, repo: repo, context)
        }
        // A Cloud machine's names are the ones its machine config declares.
        guard names == nil else { throw ActionFailure(message: CloudStrings.secretNamesOnCloudMachine) }
        if let reason = context.services.cloud.unavailableReason ?? (context.services.cloud.isSignedIn ? nil : CloudStrings.signInFirst) {
            throw ActionFailure(message: reason)
        }
        let cloud = context.services.cloud, work = context.services.work, session = try machine(invocation, context)
        guard session.machine.allows(.exec) else { throw operationUnavailable }
        let machineID = session.machineID, home = FileManager.default.homeDirectoryForCurrentUser
        let ledgerURL = cloud.paths.root.appendingPathComponent("secret-ledger.json")
        // One delivery per machine at a time (plan, delivery and ledger together): an older run that
        // finished after a newer one would leave the older values on the machine but the newer in the ledger.
        // Not beside an own-machine delivery, which may reach this same machine over ssh.
        guard !cloud.deliveringSecrets.contains(ownMachineDeliveryKey), cloud.deliveringSecrets.insert(machineID).inserted else { throw ActionFailure(message: CloudStrings.secretsDeliveryRunning) }
        // A delivery waits for the machine's carrier (up to 180 s), past the CLI's result deadline:
        // the answer is then `pending`, the delivery goes on, and running the command again says how it ended
        // (`unchanged` once delivered, or that one is still running).
        let pending: [String: ActionResultValue] = ["machine_id": .string(machineID), "status": .string("delivering"),
                                                    "check": .string("cmux cloud deliver-secrets --target machine:\(machineID)")]
        result("deliver Cloud secrets", context, pendingAfter: .seconds(30), pending: pending) {
            defer { cloud.deliveringSecrets.remove(machineID) }
            let read = { (path: String) in (try? await cloud.machineAPI.readFile(machineID, path: path)).flatMap { Data(base64Encoded: $0.dataBase64) } }
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
            let values = try await keychainValues(items)
            // Sealed on this Mac to the machine's daemon key and opened only there (`cmux carrier secrets`):
            // no value crosses the platform, a file API, a terminal or a log.
            let delivered = try await cloud.machineAPI.deliverSealedSecrets(machineID, values: values)
            guard case .wrote(let count) = delivered else {
                throw ActionFailure(message: CloudStrings.secretsNotDelivered(Self.sealedReason(delivered)))
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

    /// A sealed delivery's failure as its fixed code: the machine's refusal (`bad-name`, `replay`, `busy`)
    /// or the step that failed. Never a value or a machine's own text.
    static func sealedReason(_ answer: CloudAPIClient.SealedDelivery) -> String {
        switch answer {
        case .wrote: "unexpected"
        case .failed(let code, let refusal, _): refusal ?? code
        }
    }

    private static var operationUnavailable: ActionFailure {
        ActionFailure(message: String(localized: "cloud.operationUnavailable",
            defaultValue: "This action is unavailable for this Cloud machine.", bundle: .module))
    }

    /// A machine action's `action.run` result: the machine's id and the `--target` that names it
    /// in the next command, plus `extra`.
    static func machineFields(_ machineID: String, _ extra: [String: ActionResultValue] = [:]) -> [String: ActionResultValue] {
        CloudHandlerRules().machineFields(machineID, extra)
    }

    /// How long a CLI or agent fork, restore, resize or kill waits for the
    /// server before it answers `pending`: inside `action.run`'s 40 s result
    /// deadline. The work finishes either way.
    static let machineAnswerWait: Duration = .seconds(30)

    /// How long a CLI or agent snapshot waits for its id before it answers
    /// `pending` (a snapshot may take minutes): inside `action.run`'s 40 s
    /// result deadline. The snapshot finishes either way.
    static let snapshotAnswerWait: Duration = .seconds(30)

    static func filePath(_ invocation: ActionInvocation) throws -> String {
        try CloudHandlerRules().text("filePath", invocation)
    }

    /// `cloud set-idle-pause --target machine:<id> --minutes off|15|30|60|120`. A CLI, agent or
    /// script run gets `machine_id` and `idle_pause_minutes` back as its result (#23155); a
    /// person's run reports a failure in a sheet. `set` stores it (`CloudService.setIdlePause`).
    static func setIdlePause(_ invocation: ActionInvocation, _ context: AppActionContext,
                             set: @escaping @MainActor (String, Int) async throws -> Void) throws {
        let session = try machine(invocation, context)
        let minutes = try CloudHandlerRules().arg("idlePause", invocation, extra: ["choices": CloudMachine.idlePauseChoices]) as? Int ?? 0
        let machineID = session.machineID
        guard origin(of: invocation) == .user else {
            return result("set idle pause", context) {
                try await set(machineID, minutes)
                return ["machine_id": .string(machineID), "idle_pause_minutes": .int(minutes)]
            }
        }
        runTracked("set idle pause", context) { try await set(machineID, minutes) }
    }
}

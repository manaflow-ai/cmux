import AppKit
import CmuxNextActions
import CmuxNextCloud
import CmuxNextDaemon

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
            // only for the user's own gesture.
            if session.appLink != nil { session.connect(origin: connectOrigin(for: invocation)) }
            run("open machine", context) { show(try await firstWorkspace(on: session, context), context) }
        }
        bind("cloudSSH", registry, reason: reason) { invocation in
            let session = try machine(invocation, context)
            guard session.daemon.connection != nil else { throw ActionFailure(message: CloudStrings.notConnected) }
            runTracked("open Cloud SSH terminal", context) {
                let anchor = try await terminalAnchor(on: session, context)
                guard let connection = session.daemon.connection else { throw ActionFailure(message: CloudStrings.notConnected) }
                let created = try await connection.newTab(in: anchor.pane.handle, options: SpawnOptions(workspace: anchor.key))
                if invocation.allowsViewChange { reveal(created.surface, in: anchor.pane, workspaceID: anchor.id, context) }
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
                guard session.machine.allows(.exec) else { throw ActionFailure(message: CloudStrings.execUnavailable) }
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
            guard session.daemon.connection != nil else { throw ActionFailure(message: CloudStrings.notConnected) }
            // A CLI or agent run gets the new workspace's id, and the window keeps what it shows
            // unless the run asked for focus.
            guard origin(of: invocation) == .user else {
                return result("new terminal on machine", context) {
                    guard let id = await context.services.windows.createWorkspace(on: session.daemon) else {
                        throw ActionFailure(message: CloudStrings.notConnected)
                    }
                    if invocation.allowsViewChange { show(id, context) }
                    return ["machine_id": .string(session.machineID), "workspace_id": .string(id)]
                }
            }
            run("new terminal on machine", context) {
                guard let id = await context.services.windows.createWorkspace(on: session.daemon) else {
                    throw ActionFailure(message: CloudStrings.notConnected)
                }
                show(id, context)
            }
        }
        bind("cloudRenameMachine", registry, reason: reason) { invocation in
            let session = try machine(invocation, context)
            let rename = { (name: String) in run("rename machine", context) { try await cloud.renameMachine(session.machineID, to: name) } }
            if let name = invocation["name"]?.stringValue { return rename(name) }
            context.services.registry.ask("cloudRenameMachine", invocation,
                                          ActionArgumentAsk(argument: "name", initialText: session.machine.displayName ?? ""))
        }
        // Destructive: the registry confirmed it (sheet, or `confirm: true`).
        bind("cloudKillMachine", registry, reason: reason) { invocation in
            let session = try machine(invocation, context)
            run("kill machine", context) { try await cloud.deleteMachine(session.machineID) }
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
            run("resize machine", context) { try await cloud.api.resize(session.machineID, cpu: cpu, memoryMb: memory) }
        }
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
            run("restore machine", context) {
                _ = try await cloud.api.restore(snapshotID: snapshot)
                await cloud.refresh()
            }
        }
        bind("palette.cloud.fork", registry, reason: reason) { invocation in
            let session = try machine(invocation, context); guard session.machine.allows(.fork) else { throw operationUnavailable }
            run("fork machine", context) {
                _ = try await cloud.api.fork(session.machineID, name: nil)
                await cloud.refresh()
            }
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

    /// The handoff text, with the old app's fields and the cmux-next CLI verbs
    /// for Open Machine and Machine Tools.
    static func handoff(_ machine: CloudMachine) -> String {
        let target = "--target machine:\(machine.id)"
        return ["\(machine.title) (\(machine.id))", "provider: \(machine.provider.isEmpty ? "?" : machine.provider)", "status: \(machine.status.rawValue)",
                "attach: cmux cloud open-machine \(target)", "inspect: cmux cloud machine-tools \(target)"].joined(separator: "\n")
    }

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

    static func port(_ invocation: ActionInvocation) throws -> Int {
        guard let port = invocation["port"]?.intValue, (1...65535).contains(port) else { throw ActionFailure(message: CloudStrings.invalidPort) }
        return port
    }

    /// `describe`'s facts as `action.run` result fields.
    static func statusFields(_ session: CloudMachineSession, _ stats: CloudMachineStats) -> [String: ActionResultValue] {
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
        return fields
    }

    static func describe(_ session: CloudMachineSession, _ stats: CloudMachineStats) -> String {
        var lines = ["\(session.machine.title) (\(session.machineID))", "state: \(stats.state), status: \(session.effectiveStatus.rawValue)"]
        if let cpus = stats.cpus { lines.append("cpus: \(cpus)" + (stats.cpuPercent.map { String(format: ", %.0f%%", $0) } ?? "")) }
        if let used = stats.memoryUsedMb, let total = stats.memoryTotalMb { lines.append(String(format: "memory: %.0f / %.0f MB", used, total)) }
        if let used = stats.diskUsedMb, let total = stats.diskTotalMb { lines.append(String(format: "disk: %.0f / %.0f MB", used, total)) }
        if let address = session.machine.address?.ipv4 { lines.append("address: \(address)") }
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

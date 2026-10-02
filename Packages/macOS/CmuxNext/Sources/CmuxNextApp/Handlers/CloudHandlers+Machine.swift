import AppKit
import CmuxNextActions
import CmuxNextCloud
import CmuxNextDaemon

// Per-machine actions: open, terminal, rename, kill, pause/resume, copy,
// resize, status, ports, tools, handoff, snapshot, promote to template,
// restore, fork, and snapshot deletion.
extension CloudHandlers {
    static func bindMachineActions(into registry: ActionRegistry, context: AppActionContext, reason: @escaping @MainActor () -> String?) {
        let cloud = context.services.cloud!
        bind("cloudOpenMachine", registry, reason: reason) { invocation in
            let session = try machine(invocation, context)
            run("open machine", context) { show(try await firstWorkspace(on: session, context), context) }
        }
        bind("cloudNewTerminal", registry, reason: reason) { invocation in
            let session = try machine(invocation, context)
            guard session.daemon.connection != nil else { throw ActionFailure(message: CloudStrings.notConnected) }
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
            CloudPresenter.askText(CloudStrings.renameMachineTitle, initial: session.machine.displayName ?? "", button: CloudStrings.rename,
                                   in: window(context)) { name in if let name { rename(name) } }
        }
        // Destructive: the registry confirmed it (sheet, or `confirm: true`).
        bind("cloudKillMachine", registry, reason: reason) { invocation in
            let session = try machine(invocation, context)
            run("kill machine", context) { try await cloud.deleteMachine(session.machineID) }
        }
        bind("cloudPauseMachine", registry, reason: reason) { invocation in
            let session = try machine(invocation, context)
            run("pause machine", context) {
                try await cloud.pauseMachine(session.machineID)
            }
        }
        bind("cloudResumeMachine", registry, reason: reason) { invocation in
            let session = try machine(invocation, context)
            run("resume machine", context) {
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
            let session = try machine(invocation, context), port = try port(invocation)
            run("copy machine link", context) { CloudPresenter.copy(try await cloud.api.openPort(session.machineID, port: port).url) }
        }
        bind("cloudResizeMachine", registry, reason: reason) { invocation in
            let session = try machine(invocation, context)
            guard let size = invocation["size"]?.stringValue, let (cpu, memory) = sizes[size] else {
                throw ActionFailure(message: CloudStrings.sizeMustBeOneOf(sizes.keys.sorted().joined(separator: ", ")))
            }
            run("resize machine", context) { try await cloud.api.resize(session.machineID, cpu: cpu, memoryMb: memory) }
        }
        bind("palette.cloud.status", registry, reason: reason) { invocation in
            let session = try machine(invocation, context)
            run("machine status", context) {
                let stats = try await cloud.api.stats(session.machineID)
                CloudPresenter.show(CloudStrings.statusTitle, describe(session, stats), copyable: true, in: window(context))
            }
        }
        bind("palette.cloud.ports", registry, reason: reason) { invocation in
            let session = try machine(invocation, context)
            guard let connection = session.daemon.connection else { throw ActionFailure(message: CloudStrings.notConnected) }
            run("machine ports", context) {
                let table = try await connection.request(MachineListeningTCPRequest()).stdout
                let ports = MachineListeningTCPRequest.ports(in: table)
                let body = ports.isEmpty ? CloudStrings.noPorts : ports.map(String.init).joined(separator: "\n")
                CloudPresenter.show(CloudStrings.portsTitle, body, copyable: !ports.isEmpty, in: window(context))
            }
        }
        bind("palette.cloud.tools", registry, reason: reason) { invocation in
            let session = try machine(invocation, context)
            run("machine tools", context) {
                let result = try await cloud.api.exec(session.machineID, command: toolsProbe)
                CloudPresenter.show(CloudStrings.toolsTitle, result.stdout, copyable: true, in: window(context))
            }
        }
        // `cmux vm handoff`: the live status plus the commands that attach to
        // and inspect the machine, for pasting to another person or agent.
        bind("palette.cloud.handoff", registry, reason: reason) { invocation in
            let session = try machine(invocation, context)
            run("hand off machine", context) {
                let live = try await cloud.api.machine(session.machineID)
                CloudPresenter.show(CloudStrings.handoffTitle, handoff(live), copyable: true, in: window(context))
            }
        }
        bind("palette.cloud.snapshot", registry, reason: reason) { invocation in
            let session = try machine(invocation, context)
            run("snapshot machine", context) {
                let snapshot = try await cloud.api.snapshot(session.machineID, name: nil)
                CloudPresenter.show(CloudStrings.snapshotTitle, CloudStrings.snapshotBody(snapshot.id), copyable: true, in: window(context))
            }
        }
        bind("palette.cloud.deleteSnapshot", registry, reason: reason) { invocation in
            let session = try machine(invocation, context)
            guard let snapshot = invocation["snapshot"]?.stringValue, !snapshot.isEmpty else {
                throw ActionFailure(message: CloudStrings.snapshotRequired)
            }
            run("delete snapshot", context) {
                try await cloud.api.deleteSnapshot(session.machineID, snapshotID: snapshot)
                await cloud.refresh()
            }
        }
        // The old app's `cmux vm promote-template`: a snapshot named after the
        // machine, which Restore Cloud Machine then starts new machines from.
        bind("palette.cloud.promoteTemplate", registry, reason: reason) { invocation in
            let session = try machine(invocation, context)
            run("promote machine to template", context) {
                let snapshot = try await cloud.api.snapshot(session.machineID, name: templateName(session.machineID, at: Date()))
                CloudPresenter.show(CloudStrings.templateTitle, CloudStrings.templateBody(snapshot.id), copyable: true, in: window(context))
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
            let session = try machine(invocation, context)
            run("fork machine", context) {
                _ = try await cloud.api.fork(session.machineID, name: nil)
                await cloud.refresh()
            }
        }
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

    /// `template-<first 12 of the id>-<unix seconds>`, the old CLI's name.
    static func templateName(_ machineID: String, at date: Date) -> String {
        "template-\(machineID.prefix(12))-\(Int(date.timeIntervalSince1970))"
    }

    /// `size` choices -> (vCPUs, MiB). Pro allows up to 24 GiB.
    static let sizes: [String: (Int, Int)] = ["small": (2, 4096), "medium": (4, 8192), "large": (8, 16384), "xlarge": (16, 24576)]

    static func port(_ invocation: ActionInvocation) throws -> Int {
        guard let port = invocation["port"]?.intValue, (1...65535).contains(port) else { throw ActionFailure(message: CloudStrings.invalidPort) }
        return port
    }

    static func describe(_ session: CloudMachineSession, _ stats: CloudMachineStats) -> String {
        var lines = ["\(session.machine.title) (\(session.machineID))", "state: \(stats.state), status: \(session.machine.status.rawValue)"]
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

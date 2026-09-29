import AppKit
import CmuxNextActions
import CmuxNextCloud
import CmuxNextDaemon

// Per-machine actions: open, terminal, rename, kill, copy, resize, status,
// ports, snapshot, restore, fork.
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
        bind("cloudKillMachine", registry, reason: reason) { invocation in
            let session = try machine(invocation, context)
            let kill = { run("kill machine", context) { try await cloud.deleteMachine(session.machineID) } }
            // A scripted run (control socket) cannot answer a sheet; its
            // explicit command is the confirmation.
            if registry.isCapturingRefusal { return kill() }
            CloudPresenter.confirm(CloudStrings.killMachineTitle, CloudStrings.killMachineBody, button: CloudStrings.kill,
                                   in: window(context)) { confirmed in if confirmed { kill() } }
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
        bind("palette.cloud.snapshot", registry, reason: reason) { invocation in
            let session = try machine(invocation, context)
            run("snapshot machine", context) {
                let snapshot = try await cloud.api.snapshot(session.machineID, name: nil)
                CloudPresenter.show(CloudStrings.snapshotTitle, CloudStrings.snapshotBody(snapshot.id), copyable: true, in: window(context))
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

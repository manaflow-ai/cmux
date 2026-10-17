import CmuxFoundation
import CmuxSurfaceCatalogModel
import Foundation

// MARK: - cmux vm ports / the vm open port preflight

extension CMUXCLI {
    /// The listener inventory `cmux vm ports` and the `vm open` preflight run inside the
    /// machine. `-p` adds owners; `exec` runs as the work user, which sees only its own
    /// processes, so a non-interactive `sudo -n` is tried first to name root-owned system
    /// listeners too. The classifier shows a listener whose owner stays hidden instead
    /// of dropping it.
    static let vmPortsInventoryCommand =
        "if command -v ss >/dev/null 2>&1; then sudo -n ss -ltnp 2>/dev/null || ss -ltnp; "
        + "elif command -v netstat >/dev/null 2>&1; then sudo -n netstat -ltnp 2>/dev/null || netstat -ltnp; "
        + "else echo 'No port inspector found'; fi"

    /// One row of `cmux vm ports`: a classified listener plus what the CLI could
    /// learn about reaching it.
    struct VMPortRow {
        let listener: CloudListeningPort
        let privateURL: String?
        let sharing: CloudPortSharing?

        var jsonObject: [String: Any] {
            [
                "port": listener.port,
                "processes": listener.processes,
                "pids": listener.pids,
                "addresses": listener.addresses,
                "kind": listener.kind.rawValue,
                "system": listener.isSystem,
                "loopback_only": listener.isLoopbackOnly,
                "private_url": privateURL.map { $0 as Any } ?? NSNull(),
                "shared": sharing.map { $0.rawValue as Any } ?? NSNull(),
            ]
        }
    }

    /// `cmux vm ports <machine> [--all] [--json]`.
    func runVMPortsCommand(rest: [String], client: SocketClient, jsonOutput: Bool) throws {
        if rest.contains("--help") || rest.contains("-h") {
            print(Self.vmPortsUsage)
            return
        }
        let showAll = rest.contains("--all")
        let positional = rest.filter { $0 != "--all" && $0 != "--json" }
        guard positional.count == 1, let vmId = positional.first, !vmId.hasPrefix("-") else {
            throw CLIError(message: Self.vmPortsUsage)
        }
        let response = try client.sendV2(
            method: "vm.exec",
            params: ["id": vmId, "command": Self.vmPortsInventoryCommand, "timeout_ms": 30_000],
            responseTimeout: 35
        )
        let stdout = (response["stdout"] as? String) ?? ""
        let inventory = CloudListeningPort.inventory(socketListing: stdout)
        let privateAddress = vmPrivateAddress(vmId: vmId, client: client)
        let sharing = vmPortSharing(vmId: vmId, client: client)
        let rows = (inventory ?? []).map { listener in
            VMPortRow(
                listener: listener,
                privateURL: privateAddress.map { CmuxInternalHostnames().directPortURL(privateAddress: $0, port: listener.port) },
                sharing: sharing.map { $0[listener.port] ?? CloudPortSharing.unshared }
            )
        }
        if jsonOutput {
            var payload = response
            payload["machine"] = vmId
            payload["ports"] = rows.map(\.jsonObject)
            payload["inventory_available"] = inventory != nil
            print(jsonString(payload))
            return
        }
        guard inventory != nil else {
            // The guest has neither `ss` nor `netstat`, or the inventory failed:
            // show what it said rather than an empty table.
            let detail = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            throw CLIError(message: String(
                format: String(
                    localized: "cli.vm.ports.inventoryUnavailable",
                    defaultValue: "Could not list the ports listening inside %1$@: %2$@"
                ),
                Self.vmMachineDisplayName(vmId),
                detail.isEmpty ? ((response["stderr"] as? String) ?? "") : detail
            ))
        }
        for line in Self.vmPortsTableLines(vmId: Self.vmMachineDisplayName(vmId), rows: rows, showAll: showAll) {
            print(line)
        }
    }

    /// Renders the human table. Pure so the layout is unit-testable.
    static func vmPortsTableLines(vmId: String, rows: [VMPortRow], showAll: Bool) -> [String] {
        let visible = showAll ? rows : rows.filter { !$0.listener.isSystem }
        let hiddenCount = rows.count - visible.count
        var lines: [String] = []
        if visible.isEmpty {
            lines.append(String(
                format: String(
                    localized: "cli.vm.ports.empty",
                    defaultValue: "Nothing of yours is listening inside %@ yet. Start a server (for example on port 3000), then run this again."
                ),
                vmId
            ))
        } else {
            var header = [
                String(localized: "cli.vm.ports.column.port", defaultValue: "PORT"),
                String(localized: "cli.vm.ports.column.process", defaultValue: "PROCESS"),
                String(localized: "cli.vm.ports.column.privateURL", defaultValue: "PRIVATE URL"),
                String(localized: "cli.vm.ports.column.shared", defaultValue: "SHARED"),
            ]
            if showAll { header.append(String(localized: "cli.vm.ports.column.kind", defaultValue: "KIND")) }
            var table: [[String]] = [header]
            for row in visible {
                var cells = [
                    String(row.listener.port),
                    row.listener.processes.isEmpty ? "-" : row.listener.processes.joined(separator: ","),
                    row.privateURL.map { row.listener.isLoopbackOnly ? $0 + " *" : $0 } ?? "-",
                    row.listener.isSystem ? "-" : vmPortSharingLabel(row.sharing),
                ]
                if showAll { cells.append(row.listener.isSystem ? row.listener.kind.rawValue : "app") }
                table.append(cells)
            }
            let widths = (0..<header.count).map { column in table.map { $0[column].count }.max() ?? 0 }
            for cells in table {
                let padded = cells.enumerated().map { index, cell in
                    index == cells.count - 1 ? cell : cell.padding(toLength: widths[index], withPad: " ", startingAt: 0)
                }
                lines.append(padded.joined(separator: "  "))
            }
            lines.append("")
            if visible.contains(where: { $0.listener.isLoopbackOnly && $0.privateURL != nil }) {
                lines.append(String(
                    localized: "cli.vm.ports.loopbackNote",
                    defaultValue: "* listens on 127.0.0.1 only: it opens in cmux (`cmux vm open`), not from other apps."
                ))
            }
            lines.append(String(
                localized: "cli.vm.ports.privateNote",
                defaultValue: "Private URLs work only through your cmux VPN (`cmux vpn up`). Nothing here is public unless SHARED says so."
            ))
            lines.append(String(
                format: String(
                    localized: "cli.vm.ports.nextSteps.share",
                    defaultValue: "Open one: cmux vm open %1$@ <port>   Share one: cmux vm share %1$@ <port> --team"
                ),
                vmId
            ))
        }
        if hiddenCount > 0 {
            lines.append(String(
                format: String(
                    localized: "cli.vm.ports.hiddenSystem",
                    defaultValue: "System ports hidden: %ld (SSH, DNS, cmux, Desktop). --all shows them."
                ),
                hiddenCount
            ))
        }
        return lines
    }

    static func vmPortSharingLabel(_ sharing: CloudPortSharing?) -> String {
        switch sharing {
        case nil: return "?"
        case .unshared?: return String(localized: "cli.vm.ports.shared.none", defaultValue: "none")
        case .personal?: return String(localized: "cli.vm.ports.shared.personal", defaultValue: "you")
        case .team?: return String(localized: "cli.vm.ports.shared.team", defaultValue: "team")
        case .public?: return String(localized: "cli.vm.ports.shared.public", defaultValue: "PUBLIC")
        }
    }

    /// The machine's private VPC address, or nil when the app cannot say.
    /// A missing address only blanks the PRIVATE URL column.
    func vmPrivateAddress(vmId: String, client: SocketClient) -> String? {
        guard let status = try? client.sendV2(method: "vm.status", params: ["id": vmId], responseTimeout: 30),
              let address = status["privateAddress"] as? String, !address.isEmpty else { return nil }
        return address
    }

    /// Published audience per port of this machine, or nil when publications
    /// could not be read (the SHARED column then shows `?`, never a guess).
    func vmPortSharing(vmId: String, client: SocketClient) -> [Int: CloudPortSharing]? {
        guard let response = try? client.sendV2(method: "vm.publication_list", responseTimeout: 30) else { return nil }
        let publications = (response["publications"] as? [[String: Any]]) ?? []
        var byPort: [Int: [CloudPortSharing]] = [:]
        for publication in publications where (publication["vmId"] as? String) == vmId {
            guard let port = (publication["port"] as? Int) ?? (publication["targetPort"] as? Int) else { continue }
            byPort[port, default: []].append(CloudPortSharing(accessMode: publication["accessMode"] as? String))
        }
        return byPort.mapValues(CloudPortSharing.widest)
    }

    /// `vm open <machine> <port>` refuses a port nothing listens on, naming the
    /// ports that do listen. An unavailable inventory never blocks the open; a
    /// not-found machine is rethrown so a label can still be resolved.
    func vmPortOpenPreflight(vmId: String, port: Int, client: SocketClient) throws {
        // The inventory is a `vm.exec`, which would wake a parked machine just to look.
        // A paused or sleeping machine skips the check; the open itself decides.
        if let status = (try? client.sendV2(method: "vm.status", params: ["id": vmId], responseTimeout: 30))?["status"] as? String,
           Self.vmPortPreflightSkipsStatus(status) {
            return
        }
        let response: [String: Any]
        do {
            response = try client.sendV2(
                method: "vm.exec",
                params: ["id": vmId, "command": Self.vmPortsInventoryCommand, "timeout_ms": 15_000],
                responseTimeout: 20
            )
        } catch {
            if Self.isVMMachineNotFoundError(error) { throw error }
            return
        }
        guard (response["exit_code"] as? Int ?? 0) == 0,
              let inventory = CloudListeningPort.inventory(socketListing: (response["stdout"] as? String) ?? "")
        else { return }
        if let message = Self.vmPortNotListeningMessage(vmId: Self.vmMachineDisplayName(vmId), port: port, inventory: inventory) {
            throw CLIError(message: message)
        }
    }

    /// Machine states the port preflight leaves alone rather than wake.
    static func vmPortPreflightSkipsStatus(_ status: String) -> Bool {
        ["paused", "standby", "asleep", "sleeping", "stopped", "suspended"].contains(status.lowercased())
    }

    /// nil when `port` is listening; otherwise the refusal naming the person's ports.
    static func vmPortNotListeningMessage(vmId: String, port: Int, inventory: [CloudListeningPort]) -> String? {
        guard !inventory.contains(where: { $0.port == port }) else { return nil }
        let apps = inventory.filter { !$0.isSystem }
        let headline = String(
            format: String(
                localized: "cli.vm.open.portNotListening",
                defaultValue: "Nothing is listening on port %1$@ inside %2$@."
            ),
            String(port),
            vmId
        )
        let suggestion: String
        if apps.isEmpty {
            suggestion = String(
                localized: "cli.vm.open.portNotListening.none",
                defaultValue: "No server of yours is listening yet. Start it, then open the port."
            )
        } else {
            let listed = apps.map { listener in
                listener.processes.isEmpty ? String(listener.port) : "\(listener.port) (\(listener.processes.joined(separator: ",")))"
            }.joined(separator: ", ")
            suggestion = String(
                format: String(
                    localized: "cli.vm.open.portNotListening.suggest",
                    defaultValue: "Listening: %1$@. Try: cmux vm open %2$@ %3$@"
                ),
                listed,
                vmId,
                String(apps[0].port)
            )
        }
        let force = String(
            localized: "cli.vm.open.portNotListening.force",
            defaultValue: "Pass --force to open it anyway (for a server that is still starting)."
        )
        return [headline, suggestion, force].joined(separator: "\n")
    }
}

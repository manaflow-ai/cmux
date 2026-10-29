import Foundation

/// `cmux vm snapshot ls|rm` — the two snapshot verbs beside `cmux vm snapshot <id>`
/// (create) and `cmux vm restore <snapshot-id>`. Listing and deleting are per machine
/// (`GET|DELETE /api/vm/<id>/snapshots[/<snapshot-id>]` through the app's session), so
/// a snapshot can only be removed by naming the machine it belongs to.
extension CMUXCLI {
    static let vmSnapshotUsage = """
        Usage: cmux vm snapshot <machine> [--name <name>]        Create a snapshot; prints its id. Alias: `checkpoint`.
               cmux vm snapshot ls <machine> [--json]             List the machine's snapshots, newest first:
                                                                  <id>  <created ISO-8601>  <name|->
               cmux vm snapshot rm <machine> <snapshot-id> [--json]
                                                                  Delete one snapshot of the machine. Permanent.
               cmux vm restore <snapshot-id>                      Start a new machine from a snapshot.

        Snapshots are provider checkpoints of the whole machine (files, installed tools,
        ~/.config/cmux/env — `cmux vm env rm` secrets before you promote one). Forks and
        `vm restore` start from them. A provider without list/delete support says so.

        Examples:
          cmux vm snapshot brave-otter --name before-upgrade
          cmux vm snapshot ls brave-otter
          cmux vm snapshot rm brave-otter snap_01H…
        """

    /// `cmux vm snapshot ls <machine> [--json]`.
    func runVMSnapshotListCommand(rest: [String], client: SocketClient, jsonOutput: Bool) throws {
        let args = rest.filter { $0 != "--json" }
        if let unknown = args.first(where: { $0.hasPrefix("-") }) {
            throw CLIError(message: "Unknown option \(unknown)\n\n\(Self.vmSnapshotUsage)")
        }
        guard args.count == 1, let machine = args.first else {
            throw CLIError(message: Self.vmSnapshotUsage)
        }
        let response: [String: Any]
        do {
            response = try client.sendV2(method: "vm.snapshot_list", params: ["id": machine], responseTimeout: 70)
        } catch let error as CLIError {
            throw Self.vmSnapshotWordedError(error, machine: machine, snapshotID: nil, action: "list snapshots")
        }
        guard let snapshots = response["snapshots"] as? [[String: Any]],
              snapshots.allSatisfy({ ($0["id"] as? String)?.isEmpty == false }) else {
            throw CLIError(message: String(localized: "cli.vm.snapshot.invalidList", defaultValue: "The machine returned an invalid snapshot list. Reconnect and retry."))
        }
        if jsonOutput {
            print(jsonString(response))
            return
        }
        guard !snapshots.isEmpty else {
            print("no snapshots")
            return
        }
        for snapshot in snapshots {
            let id = (snapshot["id"] as? String) ?? "?"
            let created = (snapshot["created_at"] as? String) ?? (snapshot["createdAt"] as? String) ?? "-"
            let name = (snapshot["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "-"
            print("\(id)\t\(created)\t\(name)")
        }
    }

    /// `cmux vm snapshot rm <machine> <snapshot-id> [--json]`.
    func runVMSnapshotDeleteCommand(rest: [String], client: SocketClient, jsonOutput: Bool) throws {
        let args = rest.filter { $0 != "--json" }
        if let unknown = args.first(where: { $0.hasPrefix("-") }) {
            throw CLIError(message: "Unknown option \(unknown)\n\n\(Self.vmSnapshotUsage)")
        }
        guard args.count == 2 else {
            throw CLIError(message: Self.vmSnapshotUsage)
        }
        let machine = args[0]
        let snapshotID = args[1]
        let response: [String: Any]
        do {
            response = try client.sendV2(
                method: "vm.snapshot_delete",
                params: ["id": machine, "snapshot_id": snapshotID],
                responseTimeout: 130
            )
        } catch let error as CLIError {
            throw Self.vmSnapshotWordedError(error, machine: machine, snapshotID: snapshotID, action: "delete snapshots")
        }
        if jsonOutput {
            print(jsonString(response))
            return
        }
        print("OK deleted \(snapshotID) from \(machine)")
    }

    /// The backend's two structured refusals, worded for the terminal; anything else is
    /// the error as the socket reported it. The codes travel in the v2 error's `data`
    /// (`backend_code`, `http_status`), not in display text, so this stays exact.
    static func vmSnapshotWordedError(_ error: CLIError, machine: String, snapshotID: String?, action: String) -> CLIError {
        if error.vmBackendCode == "vm_operation_unsupported" || error.vmBackendHTTPStatus == 501 {
            return CLIError(
                message: "\(machine)'s provider cannot \(action). Snapshots there are created with `cmux vm snapshot \(machine)` and used by `cmux vm restore`; nothing else is offered.",
                exitCode: error.exitCode,
                v2Code: error.v2Code,
                isStructuredProtocolResponse: error.isStructuredProtocolResponse,
                vmBackendCode: error.vmBackendCode,
                vmBackendHTTPStatus: error.vmBackendHTTPStatus
            )
        }
        if let snapshotID, error.vmBackendCode == "vm_snapshot_not_found" {
            return CLIError(
                message: "no snapshot \(snapshotID) on \(machine) (it may belong to another machine or be gone already): `cmux vm snapshot ls \(machine)` shows this machine's.",
                exitCode: error.exitCode,
                v2Code: error.v2Code,
                isStructuredProtocolResponse: error.isStructuredProtocolResponse,
                vmBackendCode: error.vmBackendCode,
                vmBackendHTTPStatus: error.vmBackendHTTPStatus
            )
        }
        return error
    }
}

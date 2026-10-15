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
               cmux vm snapshot warm [ls] [--json]                List this Mac's warm starts, one per repository:
                                                                  <repo>  <snapshot id>  <saved>  <machine>
               cmux vm snapshot warm rm <repo> [--keep-snapshot]  Forget a repository's warm start and delete its
                                                                  snapshot (--keep-snapshot keeps it).

        Snapshots are provider checkpoints of the whole machine (files, installed tools,
        ~/.config/cmux/env — `cmux vm env rm` secrets before you promote one). Forks and
        `vm restore` start from them. A provider without list/delete support says so.

        A warm start is a snapshot `cmux vm clone --save-warm` (or `"warm": true` in the
        repository's .cmux/cloud.json) takes after setup; a later `vm clone` of the same
        repository that needs a new machine starts from it instead of cloning and setting
        up again (`--cold` opts out), and falls back to a fresh machine when it cannot.

        Examples:
          cmux vm snapshot brave-otter --name before-upgrade
          cmux vm snapshot ls brave-otter
          cmux vm snapshot rm brave-otter snap_01H…
          cmux vm snapshot warm
          cmux vm snapshot warm rm acme/api
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

    // MARK: - Warm starts

    /// A repository's warm start: the snapshot `vm clone` restores instead of provisioning a
    /// fresh machine and cloning and setting the repository up again. Kept per Mac, beside the
    /// router's bindings and pool, keyed by the repository's project key (the normalized
    /// remote, so `.` and `owner/repo` share one). The snapshot itself lives with the provider
    /// and is restorable by its owner after the machine it came from is gone.
    struct VMWarmStart: Codable, Equatable {
        let snapshotID: String
        /// The machine the snapshot was taken from (`vm snapshot rm` needs it).
        let machine: String
        let createdAtUnix: Int
        let name: String?

        enum CodingKeys: String, CodingKey {
            case snapshotID = "snapshot_id"
            case machine
            case createdAtUnix = "created_at_unix"
            case name
        }
    }

    static func vmWarmStartStoreURL() -> URL {
        URL(fileURLWithPath: vmRunStateHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".cmuxterm", isDirectory: true)
            .appendingPathComponent("vm-warm-starts.json", isDirectory: false)
    }

    static func loadVMWarmStarts(from url: URL? = nil) -> [String: VMWarmStart] {
        guard let data = try? Data(contentsOf: url ?? vmWarmStartStoreURL()),
              let store = try? JSONDecoder().decode([String: VMWarmStart].self, from: data) else { return [:] }
        return store.filter { !$0.value.snapshotID.isEmpty }
    }

    /// Records (or, with nil, forgets) the warm start of `project`.
    static func saveVMWarmStart(project: String, _ warmStart: VMWarmStart?, to url: URL? = nil) {
        let storeURL = url ?? vmWarmStartStoreURL()
        var store = loadVMWarmStarts(from: storeURL)
        store[project] = warmStart
        guard let data = try? JSONEncoder().encode(store) else { return }
        try? FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: storeURL, options: [.atomic])
    }

    /// The display name a warm-start snapshot carries in `vm snapshot ls`.
    static func vmWarmStartSnapshotName(projectKey: String) -> String {
        "cmux warm start \(projectKey)"
    }

    /// "3 days ago", in the person's language.
    static func vmWarmStartAge(createdAtUnix: Int, now: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let created = Date(timeIntervalSince1970: TimeInterval(createdAtUnix))
        return formatter.localizedString(for: min(created, now), relativeTo: now)
    }

    /// `.cmux/cloud.json`'s `"warm": true`: save a warm start after the first successful setup.
    static func vmCloneWarmRequested(cloudJSON text: String?) -> Bool {
        guard let text,
              let data = vmCloneStrictJSON(text).data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        return (object["warm"] as? Bool) == true
    }

    /// `cmux vm snapshot warm [ls|rm <repo> [--keep-snapshot]] [--json]`.
    func runVMSnapshotWarmCommand(rest: [String], client: SocketClient, jsonOutput: Bool) throws {
        var args = rest.filter { $0 != "--json" }
        let keepSnapshot = args.contains("--keep-snapshot")
        args.removeAll { $0 == "--keep-snapshot" }
        if let unknown = args.first(where: { $0.hasPrefix("-") }) {
            throw CLIError(message: "Unknown option \(unknown)\n\n\(Self.vmSnapshotUsage)")
        }
        let verb = args.first?.lowercased() ?? "ls"
        switch verb {
        case "ls", "list":
            guard args.count <= 1 else { throw CLIError(message: Self.vmSnapshotUsage) }
            let store = Self.loadVMWarmStarts()
            if jsonOutput {
                let rows: [[String: Any]] = store.keys.sorted().compactMap { project in
                    guard let warm = store[project] else { return nil }
                    return [
                        "project": project,
                        "snapshot_id": warm.snapshotID,
                        "machine": warm.machine,
                        "created_at": ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(warm.createdAtUnix))),
                    ]
                }
                print(jsonString(["warm_starts": rows]))
                return
            }
            guard !store.isEmpty else {
                print(String(localized: "cli.vm.snapshot.warm.none", defaultValue: "no warm starts (save one with `cmux vm clone <repo> --save-warm`)"))
                return
            }
            for project in store.keys.sorted() {
                guard let warm = store[project] else { continue }
                print("\(project)\t\(warm.snapshotID)\t\(Self.vmWarmStartAge(createdAtUnix: warm.createdAtUnix))\t\(warm.machine)")
            }
        case "rm", "delete", "forget":
            guard args.count == 2 else { throw CLIError(message: Self.vmSnapshotUsage) }
            let typed = args[1]
            let project: String
            if typed == "." {
                project = try resolveVMCloneDotRepo(directory: FileManager.default.currentDirectoryPath, branchOverride: nil).projectKey
            } else {
                project = (try? Self.parseVMCloneRepoSpec(typed).projectKey) ?? typed
            }
            guard let warm = Self.loadVMWarmStarts()[project] else {
                throw CLIError(message: String(
                    format: String(localized: "cli.vm.snapshot.warm.unknown", defaultValue: "no warm start for %@: `cmux vm snapshot warm` lists them."),
                    project
                ))
            }
            Self.saveVMWarmStart(project: project, nil)
            var deleted = false
            if !keepSnapshot {
                deleted = (try? client.sendV2(
                    method: "vm.snapshot_delete",
                    params: ["id": warm.machine, "snapshot_id": warm.snapshotID],
                    responseTimeout: 130
                )) != nil
            }
            if jsonOutput {
                print(jsonString(["project": project, "snapshot_id": warm.snapshotID, "forgotten": true, "snapshot_deleted": deleted]))
                return
            }
            if keepSnapshot {
                print("OK forgot the warm start of \(project); snapshot \(warm.snapshotID) kept")
            } else if deleted {
                print("OK forgot the warm start of \(project) and deleted snapshot \(warm.snapshotID)")
            } else {
                print("OK forgot the warm start of \(project); snapshot \(warm.snapshotID) could not be deleted (`cmux vm snapshot rm \(warm.machine) \(warm.snapshotID)` retries)")
            }
        default:
            throw CLIError(message: Self.vmSnapshotUsage)
        }
    }
}

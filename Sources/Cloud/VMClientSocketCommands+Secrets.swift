import CmuxCloud
import Foundation

/// A Cloud Secrets socket request the app refused, with a stable code and copy that
/// carries names at most, never a value.
struct CloudSecretsSocketFailure: Error, Equatable, LocalizedError {
    let code: String
    let message: String

    var errorDescription: String? { message }

    static func invalidParams(_ message: String) -> CloudSecretsSocketFailure {
        CloudSecretsSocketFailure(code: "invalid_params", message: message)
    }
}

/// Pure parsing for the `vm.secrets_*` methods, shared by the handlers and their tests.
enum CloudSecretsSocketParams {
    /// A scope from `scope` (`all`, `project:<key>`, `machine:<id>`, or bare `project` /
    /// `machine` resolved from `project`, `project_remote_url`, `project_dir_name`, or
    /// `machine`). `nil` `scope` yields `defaultScope`.
    static func scope(
        _ params: [String: Any],
        method: String,
        defaultScope: CloudSecretScope? = .all
    ) throws -> CloudSecretScope? {
        guard let raw = string(params["scope"]) else { return defaultScope }
        switch raw.lowercased() {
        case "all":
            return .all
        case "project":
            guard let key = projectKey(params) else {
                throw CloudSecretsSocketFailure.invalidParams(String(
                    format: String(localized: "cloudSecrets.socket.projectRequired", defaultValue: "%@: a project scope needs `project` (a key such as github.com/owner/repo) or `project_remote_url`."),
                    method
                ))
            }
            return .project(key)
        case "machine":
            guard let machine = string(params["machine"]) else {
                throw CloudSecretsSocketFailure.invalidParams(String(
                    format: String(localized: "cloudSecrets.socket.machineRequired", defaultValue: "%@: a machine scope needs `machine`."),
                    method
                ))
            }
            return .machine(machine)
        default:
            guard let scope = CloudSecretScope(wireValue: raw) else {
                throw CloudSecretsSocketFailure.invalidParams(String(
                    format: String(localized: "cloudSecrets.socket.invalidScope", defaultValue: "%1$@: unknown scope '%2$@' (use all, project:<key>, or machine:<id>)."),
                    method, raw
                ))
            }
            if case .project(let key) = scope {
                let normalized = normalizedProjectKey(key)
                guard !normalized.isEmpty else {
                    throw CloudSecretsSocketFailure.invalidParams(String(
                        format: String(localized: "cloudSecrets.socket.invalidScope", defaultValue: "%1$@: unknown scope '%2$@' (use all, project:<key>, or machine:<id>)."),
                        method, raw
                    ))
                }
                return .project(normalized)
            }
            return scope
        }
    }

    /// The project key from `project` (a key or a remote URL), else `project_remote_url`
    /// normalized, else `local/<project_dir_name>`.
    static func projectKey(_ params: [String: Any]) -> String? {
        if let explicit = string(params["project"]), explicit != "." {
            let key = normalizedProjectKey(explicit)
            return key.isEmpty ? nil : key
        }
        if let remote = string(params["project_remote_url"]),
           let key = CloudSecretProjectKey.normalize(remoteURL: remote) {
            return key
        }
        if let directory = string(params["project_dir_name"]) {
            return CloudSecretProjectKey.fallback(directoryName: directory)
        }
        return nil
    }

    /// A remote URL becomes its key; a bare key is normalized the same way
    /// (``CloudSecretProjectKey/normalize(key:)``), so `GitHub.com/Owner/Repo.git`
    /// names the scope a checkout of that repository resolves to.
    static func normalizedProjectKey(_ raw: String) -> String {
        CloudSecretProjectKey.normalize(key: raw)
    }

    /// `entries: [{key, value}]`, validated (names, single-line, size) before any write.
    static func entries(_ params: [String: Any], method: String) throws -> [CloudSecretInput] {
        guard let rawEntries = params["entries"] as? [[String: Any]], !rawEntries.isEmpty else {
            throw CloudSecretsSocketFailure.invalidParams(String(
                format: String(localized: "cloudSecrets.socket.entriesRequired", defaultValue: "%@ requires `entries`: a non-empty array of {key, value}."),
                method
            ))
        }
        var inputs: [CloudSecretInput] = []
        for raw in rawEntries {
            // Raw strings: whitespace inside a value is part of the value.
            guard let key = raw["key"] as? String, let value = raw["value"] as? String else {
                throw CloudSecretsSocketFailure.invalidParams(String(
                    format: String(localized: "cloudSecrets.socket.entryShape", defaultValue: "%@: every entry needs a string `key` and a string `value`."),
                    method
                ))
            }
            let input = CloudSecretInput(name: key, value: value)
            do {
                try input.validate()
            } catch let error as CloudSecretValidationError {
                throw CloudSecretsSocketFailure.invalidParams(error.errorDescription ?? method)
            }
            inputs.append(input)
        }
        return inputs
    }

    /// `names: [String]`, each a well-formed variable name (reserved names included, for removal).
    static func names(_ params: [String: Any], method: String) throws -> [String] {
        let names = (params["names"] as? [Any] ?? []).compactMap { string($0) }
        guard !names.isEmpty else {
            throw CloudSecretsSocketFailure.invalidParams(String(
                format: String(localized: "cloudSecrets.socket.namesRequired", defaultValue: "%@ requires `names`: a non-empty array of variable names."),
                method
            ))
        }
        for name in names {
            do {
                // Shape only: a name stored before it became reserved must stay removable.
                try CloudSecretInput.validateNameSyntax(name)
            } catch let error as CloudSecretValidationError {
                throw CloudSecretsSocketFailure.invalidParams(error.errorDescription ?? method)
            }
        }
        return names
    }

    /// `id`: the machine.
    static func machineID(_ params: [String: Any], method: String) throws -> String {
        guard let id = string(params["id"]) else {
            throw CloudSecretsSocketFailure.invalidParams(String(
                format: String(localized: "cloudSecrets.socket.idRequired", defaultValue: "%@ requires `id`. Run `cmux vm ls` to find one."),
                method
            ))
        }
        return id
    }

    /// `files: {path: text}` for `vm.secrets_check`, limited to the declaring paths and
    /// their size cap; nil when absent or holding none of them.
    static func declaringFiles(_ raw: Any?) -> [String: String]? {
        guard let object = raw as? [String: Any] else { return nil }
        var files: [String: String] = [:]
        for path in CloudSecretRequirements.declaringPaths {
            guard let text = object[path] as? String, text.utf8.count <= CloudSecretRequirements.maxFileBytes else { continue }
            files[path] = text
        }
        return files.isEmpty && object.isEmpty ? nil : files
    }

    static func source(_ params: [String: Any]) -> CloudSecretSource {
        string(params["source"]).flatMap(CloudSecretSource.init(wireValue:)) ?? .manual
    }

    static func bool(_ raw: Any?) -> Bool? {
        if let bool = raw as? Bool { return bool }
        if let number = raw as? NSNumber { return number.boolValue }
        if let string = raw as? String {
            switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "yes", "on": return true
            case "0", "false", "no", "off": return false
            default: return nil
            }
        }
        return nil
    }

    static func string(_ raw: Any?) -> String? {
        guard let string = raw as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Payloads (names, scopes, fingerprints; never values)

    static func payload(_ record: CloudSecretRecord) -> [String: Any] {
        [
            "name": record.name,
            "scope": record.scope.wireValue,
            "fingerprint": record.fingerprint,
            "created_at": iso8601(record.createdAt),
            "updated_at": iso8601(record.updatedAt),
            "source": record.source.wireValue,
        ]
    }

    static func payload(_ delivery: CloudSecretDelivery, syncing: Bool) -> [String: Any] {
        [
            "id": delivery.machineID,
            "project_keys": delivery.projectKeys,
            "delivered": delivery.delivered.keys.sorted(),
            "delivered_at": delivery.deliveredAt.map { iso8601($0) as Any } ?? NSNull(),
            "last_error": delivery.lastError.map { $0 as Any } ?? NSNull(),
            "syncing": syncing,
        ]
    }

    static func payload(_ change: CloudSecretChange) -> [String: Any] {
        ["name": change.name, "scope": change.scope.wireValue, "kind": change.kind.rawValue]
    }

    static func payload(_ result: CloudSecretSyncResult) -> [String: Any] {
        [
            "machine": result.machineID,
            "sent": result.sent,
            "removed": result.removed,
            "noop": result.noop,
            "git_credentials": result.configuredGitCredentials,
            "error": result.error.map { $0 as Any } ?? NSNull(),
        ]
    }

    static func payload(_ row: CloudSecretMachineStatusRow) -> [String: Any] {
        [
            "name": row.name,
            "scope": row.scope.map { $0.wireValue as Any } ?? NSNull(),
            "state": row.state.rawValue,
            "fingerprint": row.fingerprint.map { $0 as Any } ?? NSNull(),
        ]
    }

    private static let iso8601Formatter = ISO8601DateFormatter()

    static func iso8601(_ date: Date) -> String {
        iso8601Formatter.string(from: date)
    }
}

/// Sendable snapshots carried out of the main actor.
private struct CloudSecretsListSnapshot: Sendable {
    let records: [CloudSecretRecord]
    let deliveries: [CloudSecretDelivery]
    let syncing: Set<String>
    let autoSync: Bool
    let loadError: String?
}

private final class CloudSecretsFailureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: CloudSecretsSocketFailure?

    var value: CloudSecretsSocketFailure? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ failure: CloudSecretsSocketFailure) {
        lock.lock()
        stored = failure
        lock.unlock()
    }
}

extension TerminalController {
    /// `vm.secrets_*`: the Cloud Secrets vault on this Mac and delivery to machines.
    /// Every response carries names, scopes, fingerprints and states, never a value;
    /// values only enter (`vm.secrets_set` entries) and leave through the machine's
    /// end-to-end env delivery.
    nonisolated func socketWorkerVMSecretsResponse(method: String, id: Any?, params: [String: Any]) -> String {
        do {
            switch method {
            case "vm.secrets_list":
                return try socketWorkerVMSecretsList(id: id, params: params)
            case "vm.secrets_set":
                return try socketWorkerVMSecretsSet(id: id, params: params)
            case "vm.secrets_rm":
                let scope = try CloudSecretsSocketParams.scope(params, method: method) ?? .all
                let names = try CloudSecretsSocketParams.names(params, method: method)
                let sync = CloudSecretsSocketParams.bool(params["sync"])
                return cloudSecretsCall(id: id, timeoutSeconds: 600) {
                    let service = await CloudSecretsService.shared
                    let autoSync = await service.isAutoSyncEnabled
                    let outcome = try await service.remove(names: names, scope: scope, sync: sync ?? autoSync)
                    return [
                        "changes": outcome.changes.map(CloudSecretsSocketParams.payload),
                        "synced": outcome.synced.map(CloudSecretsSocketParams.payload),
                    ]
                }
            case "vm.secrets_sync":
                let machine = try CloudSecretsSocketParams.machineID(params, method: method)
                let project = CloudSecretsSocketParams.projectKey(params)
                return cloudSecretsCall(id: id, timeoutSeconds: 240) {
                    let result = await CloudSecretsService.shared.sync(machineID: machine, projectKey: project)
                    return CloudSecretsSocketParams.payload(result)
                }
            case "vm.secrets_status":
                let machine = try CloudSecretsSocketParams.machineID(params, method: method)
                let verify = CloudSecretsSocketParams.bool(params["verify"]) ?? false
                return cloudSecretsCall(id: id, timeoutSeconds: 90) {
                    let service = await CloudSecretsService.shared
                    let rows = try await service.status(machineID: machine, verify: verify)
                    await service.reload()
                    let delivery = await service.delivery(for: machine)
                    return [
                        "machine": machine,
                        "verified": verify,
                        "rows": rows.map(CloudSecretsSocketParams.payload),
                        "project_keys": delivery?.projectKeys ?? [],
                        "delivered_at": delivery?.deliveredAt.map { CloudSecretsSocketParams.iso8601($0) as Any } ?? NSNull(),
                        "last_error": delivery?.lastError.map { $0 as Any } ?? NSNull(),
                    ]
                }
            case "vm.secrets_link", "vm.secrets_unlink":
                let machine = try CloudSecretsSocketParams.machineID(params, method: method)
                guard let project = CloudSecretsSocketParams.projectKey(params) else {
                    throw CloudSecretsSocketFailure.invalidParams(String(
                        format: String(localized: "cloudSecrets.socket.linkProjectRequired", defaultValue: "%@ requires `project` (a key such as github.com/owner/repo) or `project_remote_url`."),
                        method
                    ))
                }
                let linking = method == "vm.secrets_link"
                let sync = CloudSecretsSocketParams.bool(params["sync"])
                return cloudSecretsCall(id: id, timeoutSeconds: 240) {
                    let service = await CloudSecretsService.shared
                    if linking {
                        try await service.link(machineID: machine, projectKey: project)
                    } else {
                        try await service.unlink(machineID: machine, projectKey: project)
                    }
                    var payload: [String: Any] = ["machine": machine, "project": project, "linked": linking]
                    let autoSync = await service.isAutoSyncEnabled
                    if sync ?? autoSync {
                        payload["sync"] = CloudSecretsSocketParams.payload(await service.sync(machineID: machine))
                    }
                    return payload
                }
            case "vm.secrets_check":
                // Names only: `dir` is a checkout on this Mac; `files` carries the declaring
                // files' text fetched from a checkout elsewhere (a Cloud machine). With `id`
                // and/or a project, `missing` lists the declared names that machine's
                // effective set (all + its linked projects + that project + the machine)
                // would not have.
                let files = CloudSecretsSocketParams.declaringFiles(params["files"])
                let directory = CloudSecretsSocketParams.string(params["dir"])
                guard directory != nil || files != nil else {
                    throw CloudSecretsSocketFailure.invalidParams(String(
                        localized: "cloudSecrets.socket.dirRequired",
                        defaultValue: "vm.secrets_check requires `dir`: the project directory to read."
                    ))
                }
                let machine = CloudSecretsSocketParams.string(params["id"])
                let project = CloudSecretsSocketParams.projectKey(params)
                return cloudSecretsCall(id: id, timeoutSeconds: 30) {
                    let declared: [CloudSecretRequirement]
                    if let files {
                        declared = CloudSecretRequirements.declared(files: files)
                    } else {
                        declared = CloudSecretRequirements.declared(inDirectory: URL(fileURLWithPath: directory ?? "", isDirectory: true))
                    }
                    let service = await CloudSecretsService.shared
                    await service.reload()
                    // The sheet opened later from this project's machine lists
                    // the same names as ghost rows.
                    if let project {
                        await service.rememberDeclaredRequirements(declared, projectKey: project)
                    }
                    let records = await service.records
                    var projectKeys: [String] = []
                    if let machine {
                        projectKeys = await service.delivery(for: machine)?.projectKeys ?? []
                    }
                    if let project, !projectKeys.contains(project) { projectKeys.append(project) }
                    let missing = Set(CloudSecretRequirements.missing(
                        declared,
                        records: records,
                        projectKeys: projectKeys,
                        machineID: machine
                    ).map(\.name))
                    let targeted = machine != nil || project != nil
                    var payload: [String: Any] = [
                        "declared": declared.map { requirement -> [String: Any] in
                            let scopes = records.filter { $0.name == requirement.name }.map(\.scope.wireValue)
                            var item: [String: Any] = [
                                "name": requirement.name,
                                "description": requirement.description.map { $0 as Any } ?? NSNull(),
                                "source": requirement.source,
                                "stored": !scopes.isEmpty,
                                "scopes": scopes,
                            ]
                            if targeted { item["effective"] = !missing.contains(requirement.name) }
                            return item
                        },
                        "project": project.map { $0 as Any } ?? NSNull(),
                    ]
                    if let directory { payload["dir"] = directory }
                    if targeted {
                        payload["machine"] = machine.map { $0 as Any } ?? NSNull()
                        payload["missing"] = declared.filter { missing.contains($0.name) }.map(\.name)
                    }
                    return payload
                }
            default:
                return v2Error(id: id, code: "method_not_found", message: "Unknown method")
            }
        } catch let failure as CloudSecretsSocketFailure {
            return v2Error(id: id, code: failure.code, message: failure.message)
        } catch {
            return v2Error(id: id, code: "invalid_params", message: CloudSecretsService.redactedMessage(for: error, values: []))
        }
    }

    private nonisolated func socketWorkerVMSecretsList(id: Any?, params: [String: Any]) throws -> String {
        let filter = try CloudSecretsSocketParams.scope(params, method: "vm.secrets_list", defaultScope: nil)
        return cloudSecretsCall(id: id, timeoutSeconds: 30) {
            let service = await CloudSecretsService.shared
            await service.reload()
            let listed = await CloudSecretsListSnapshot(
                records: service.records,
                deliveries: service.deliveries,
                syncing: service.syncingMachineIDs,
                autoSync: service.isAutoSyncEnabled,
                loadError: service.loadError
            )
            if let loadError = listed.loadError {
                throw CloudSecretsSocketFailure(code: "cloud_secrets_unavailable", message: loadError)
            }
            let records = filter.map { scope in listed.records.filter { $0.scope == scope } } ?? listed.records
            return [
                "secrets": records.map(CloudSecretsSocketParams.payload),
                "machines": listed.deliveries.map { CloudSecretsSocketParams.payload($0, syncing: listed.syncing.contains($0.machineID)) },
                "auto_sync": listed.autoSync,
                "well_known": CloudSecretCatalog.wellKnownNames,
            ]
        }
    }

    private nonisolated func socketWorkerVMSecretsSet(id: Any?, params: [String: Any]) throws -> String {
        let method = "vm.secrets_set"
        let scope = try CloudSecretsSocketParams.scope(params, method: method) ?? .all
        let inputs = try CloudSecretsSocketParams.entries(params, method: method)
        let source = CloudSecretsSocketParams.source(params)
        let sync = CloudSecretsSocketParams.bool(params["sync"])
        let dryRun = CloudSecretsSocketParams.bool(params["dry_run"]) ?? false
        return cloudSecretsCall(id: id, timeoutSeconds: 600) {
            let service = await CloudSecretsService.shared
            if dryRun {
                let changes = try await service.preview(inputs, scope: scope)
                return ["changes": changes.map(CloudSecretsSocketParams.payload), "synced": [[String: Any]](), "dry_run": true]
            }
            let autoSync = await service.isAutoSyncEnabled
            let outcome = try await service.set(inputs, scope: scope, source: source, sync: sync ?? autoSync)
            return [
                "changes": outcome.changes.map(CloudSecretsSocketParams.payload),
                "synced": outcome.synced.map(CloudSecretsSocketParams.payload),
                "dry_run": false,
            ]
        }
    }

    /// `v2VmCall`, plus vault and validation failures answered with their own code and
    /// redacted copy instead of the generic Cloud VM line. Transport and auth errors
    /// keep `v2VmCall`'s mapping.
    private nonisolated func cloudSecretsCall(
        id: Any?,
        timeoutSeconds: TimeInterval,
        _ work: @escaping () async throws -> [String: Any]
    ) -> String {
        let box = CloudSecretsFailureBox()
        let response = v2VmCall(id: id, timeoutSeconds: timeoutSeconds) {
            do {
                return try await work()
            } catch let failure as CloudSecretsSocketFailure {
                box.set(failure)
                throw failure
            } catch let error as CloudSecretValidationError {
                let failure = CloudSecretsSocketFailure.invalidParams(CloudSecretsService.redactedMessage(for: error, values: []))
                box.set(failure)
                throw failure
            } catch let error as CloudSecretVaultError {
                let failure = CloudSecretsSocketFailure(code: "cloud_secrets_unavailable", message: CloudSecretsService.redactedMessage(for: error, values: []))
                box.set(failure)
                throw failure
            } catch let error as CloudSecretsService.ShimFailure {
                let failure = CloudSecretsSocketFailure(code: "vm_error", message: error.message)
                box.set(failure)
                throw failure
            } catch let error as CloudSecretVaultStorageError {
                let failure = CloudSecretsSocketFailure(code: "cloud_secrets_unavailable", message: CloudSecretsService.redactedMessage(for: error, values: []))
                box.set(failure)
                throw failure
            }
        }
        if let failure = box.value {
            return v2Error(id: id, code: failure.code, message: failure.message)
        }
        return response
    }
}

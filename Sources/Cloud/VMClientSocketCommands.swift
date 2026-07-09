import CmuxControlSocket
import Foundation

extension TerminalController {
    nonisolated func socketWorkerCloudVMResponse(
        method: String,
        id: Any?,
        params: [String: Any]
    ) -> String {
        switch method {
        case "vm.list":
            return v2VmCall(id: id) {
                let items = try await VMClient.shared.list()
                return [
                    "vms": items.map(Self.socketWorkerVMSummaryPayload),
                ]
            }
        case "vm.create":
            let image = Self.socketWorkerString(params["image"])
            let provider = Self.socketWorkerString(params["provider"])
            let idempotencyKey = Self.socketWorkerString(params["idempotency_key"])
            guard let idempotencyKey, !idempotencyKey.isEmpty else {
                return v2Error(
                    id: id,
                    code: "invalid_params",
                    message: "vm.create requires `idempotency_key`. Use `cmux vm new` instead of calling the socket method directly."
                )
            }
            return v2VmCall(id: id) {
                let vm = try await VMClient.shared.create(image: image, provider: provider, idempotencyKey: idempotencyKey)
                return Self.socketWorkerVMSummaryPayload(vm)
            }
        case "vm.base_open":
            let name = Self.socketWorkerString(params["name"])
            return v2VmCall(id: id) {
                let vm = try await VMClient.shared.openBase(name: name)
                return Self.socketWorkerVMSummaryPayload(vm)
            }
        case "vm.base_reset":
            let name = Self.socketWorkerString(params["name"])
            let reason = Self.socketWorkerString(params["reason"])
            return v2VmCall(id: id) {
                let vm = try await VMClient.shared.resetBase(name: name, reason: reason)
                return Self.socketWorkerVMSummaryPayload(vm)
            }
        case "vm.status":
            guard let vmId = Self.socketWorkerString(params["id"]), !vmId.isEmpty else {
                return v2Error(id: id, code: "invalid_params", message: "vm.status requires `id`. Run `cmux vm ls` to find one.")
            }
            return v2VmCall(id: id) {
                let vm = try await VMClient.shared.status(id: vmId)
                return Self.socketWorkerVMSummaryPayload(vm)
            }
        case "vm.snapshot":
            guard let vmId = Self.socketWorkerString(params["id"]), !vmId.isEmpty else {
                return v2Error(id: id, code: "invalid_params", message: "vm.snapshot requires `id`. Run `cmux vm ls` to find one.")
            }
            let name = Self.socketWorkerString(params["name"])
            return v2VmCall(id: id) {
                let snapshot = try await VMClient.shared.snapshot(id: vmId, name: name)
                return ["id": snapshot.id, "snapshot_id": snapshot.id, "name": snapshot.name ?? NSNull(), "created_at": snapshot.createdAt]
            }
        case "vm.fork":
            guard let vmId = Self.socketWorkerString(params["id"]), !vmId.isEmpty else {
                return v2Error(id: id, code: "invalid_params", message: "vm.fork requires `id`. Run `cmux vm ls` to find one.")
            }
            guard let idempotencyKey = Self.socketWorkerString(params["idempotency_key"]), !idempotencyKey.isEmpty else {
                return v2Error(id: id, code: "invalid_params", message: "vm.fork requires `idempotency_key`. Use `cmux vm fork` instead of calling the socket method directly.")
            }
            let name = Self.socketWorkerString(params["name"])
            return v2VmCall(id: id) {
                let result = try await VMClient.shared.fork(id: vmId, name: name, idempotencyKey: idempotencyKey)
                var payload = Self.socketWorkerVMSummaryPayload(result.vm)
                payload["snapshot_id"] = result.snapshot?.id ?? NSNull()
                return payload
            }
        case "vm.restore":
            guard let snapshotId = Self.socketWorkerString(params["snapshot_id"]) ?? Self.socketWorkerString(params["snapshotId"]),
                  !snapshotId.isEmpty else {
                return v2Error(id: id, code: "invalid_params", message: "vm.restore requires `snapshot_id`. Run `cmux vm snapshot <id>` first.")
            }
            guard let idempotencyKey = Self.socketWorkerString(params["idempotency_key"]), !idempotencyKey.isEmpty else {
                return v2Error(id: id, code: "invalid_params", message: "vm.restore requires `idempotency_key`. Use `cmux vm restore` instead of calling the socket method directly.")
            }
            let provider = Self.socketWorkerString(params["provider"])
            return v2VmCall(id: id) {
                let vm = try await VMClient.shared.restore(snapshotID: snapshotId, provider: provider, idempotencyKey: idempotencyKey)
                return Self.socketWorkerVMSummaryPayload(vm)
            }
        case "vm.destroy":
            guard let vmId = Self.socketWorkerString(params["id"]), !vmId.isEmpty else {
                return v2Error(id: id, code: "invalid_params", message: "vm.destroy requires `id`. Run `cmux vm ls` to find one, then `cmux vm rm <id>`.")
            }
            return v2VmCall(id: id) {
                try await VMClient.shared.destroy(id: vmId)
                return ["ok": true]
            }
        case "vm.exec":
            guard let vmId = Self.socketWorkerString(params["id"]), !vmId.isEmpty else {
                return v2Error(id: id, code: "invalid_params", message: "vm.exec requires `id`. Run `cmux vm ls` to find one.")
            }
            guard let command = Self.socketWorkerString(params["command"]), !command.isEmpty else {
                return v2Error(id: id, code: "invalid_params", message: "vm.exec requires `command`. From the CLI, use `cmux vm exec <id> -- <command>`.")
            }
            let timeoutMs = max(1, Self.socketWorkerInt(params["timeout_ms"]) ?? 30_000)
            return v2VmCall(id: id) {
                let result = try await VMClient.shared.exec(id: vmId, command: command, timeoutMs: timeoutMs)
                return ["exit_code": result.exitCode, "stdout": result.stdout, "stderr": result.stderr]
            }
        case "vm.ssh_info":
            guard let vmId = Self.socketWorkerString(params["id"]), !vmId.isEmpty else {
                return v2Error(id: id, code: "invalid_params", message: "vm.ssh_info requires `id`. Run `cmux vm ls` to find one.")
            }
            return v2VmCall(id: id) {
                let endpoint = try await VMClient.shared.openSSH(id: vmId)
                return Self.socketWorkerSSHInfoPayload(endpoint)
            }
        case "vm.attach_info":
            guard let vmId = Self.socketWorkerString(params["id"]), !vmId.isEmpty else {
                return v2Error(id: id, code: "invalid_params", message: "vm.attach_info requires `id`. Run `cmux vm ls` to find one, then `cmux vm ssh <id>`.")
            }
            let requireDaemon = Self.socketWorkerBool(params["require_daemon"])
                ?? Self.socketWorkerBool(params["requireDaemon"])
                ?? false
            return v2VmCall(id: id) {
                let endpoint = try await VMClient.shared.openAttach(id: vmId, requireDaemon: requireDaemon)
                return Self.socketWorkerAttachInfoPayload(endpoint)
            }
        case "vm.sessions":
            guard let vmId = Self.socketWorkerString(params["id"]), !vmId.isEmpty else {
                return v2Error(id: id, code: "invalid_params", message: "vm.sessions requires `id`. Run `cmux vm ls` to find one.")
            }
            return v2VmCall(id: id) {
                let sessions = try await VMClient.shared.listSessions(id: vmId)
                return ["sessions": sessions.map(Self.socketWorkerCloudSessionPayload)]
            }
        case "vm.env_resolve_layers":
            let provider = Self.socketWorkerString(params["provider"])
            // An empty chain_hashes list is a valid probe: the CLI uses it to learn
            // the provider + base image id before it can compute any hashes.
            let chainHashes = Self.socketWorkerStringArray(params["chain_hashes"])
            return v2VmCall(id: id) {
                let result = try await VMClient.shared.envResolveLayers(provider: provider, chainHashes: chainHashes)
                return [
                    "provider": result.provider,
                    "base_image_id": result.baseImageID,
                    "layer": result.layer.map(Self.socketWorkerEnvLayerPayload) ?? NSNull(),
                ]
            }
        case "vm.env_record_layer":
            let provider = Self.socketWorkerString(params["provider"])
            guard let baseImageID = Self.socketWorkerString(params["base_image_id"]),
                  let chainHash = Self.socketWorkerString(params["chain_hash"]),
                  let specDigest = Self.socketWorkerString(params["spec_digest"]),
                  let snapshotID = Self.socketWorkerString(params["snapshot_id"]),
                  let stepIndex = Self.socketWorkerInt(params["step_index"]),
                  stepIndex >= 0 else {
                return v2Error(id: id, code: "invalid_params", message: "vm.env_record_layer requires `base_image_id`, `chain_hash`, `spec_digest`, `snapshot_id`, and `step_index`. Use `cmux vm env build` instead of calling the socket method directly.")
            }
            let stepName = Self.socketWorkerString(params["step_name"])
            return v2VmCall(id: id) {
                let layer = try await VMClient.shared.envRecordLayer(
                    provider: provider,
                    baseImageID: baseImageID,
                    chainHash: chainHash,
                    stepIndex: stepIndex,
                    stepName: stepName,
                    specDigest: specDigest,
                    snapshotID: snapshotID
                )
                return Self.socketWorkerEnvLayerPayload(layer)
            }
        case "vm.env_list_layers":
            let provider = Self.socketWorkerString(params["provider"])
            let specDigest = Self.socketWorkerString(params["spec_digest"])
            return v2VmCall(id: id) {
                let layers = try await VMClient.shared.envListLayers(provider: provider, specDigest: specDigest)
                return ["layers": layers.map(Self.socketWorkerEnvLayerPayload)]
            }
        case "vm.session_attach_info":
            guard let vmId = Self.socketWorkerString(params["id"]), !vmId.isEmpty else {
                return v2Error(id: id, code: "invalid_params", message: "vm.session_attach_info requires `id`. Run `cmux vm ls` to find one.")
            }
            let sessionId = Self.socketWorkerString(params["session_id"]) ?? Self.socketWorkerString(params["sessionId"])
            let attachmentId = Self.socketWorkerString(params["attachment_id"]) ?? Self.socketWorkerString(params["attachmentId"])
            let title = Self.socketWorkerString(params["title"])
            return v2VmCall(id: id) {
                let result = try await VMClient.shared.openSession(
                    id: vmId,
                    sessionId: sessionId,
                    attachmentId: attachmentId,
                    title: title
                )
                return [
                    "endpoint": Self.socketWorkerAttachInfoPayload(result.endpoint),
                    "session": result.session.map(Self.socketWorkerCloudSessionPayload) ?? NSNull(),
                ]
            }
        default:
            return v2Error(id: id, code: "method_not_found", message: "Unknown method")
        }
    }

    /// Handles the `remotes.*` socket methods backing `cmux remotes`. Each maps
    /// to a single ``RemotesClient`` operation (the shared registry mutation
    /// path); the CLI does presentation only.
    nonisolated func socketWorkerRemotesResponse(
        method: String,
        id: Any?,
        params: [String: Any]
    ) -> String {
        switch method {
        case "remotes.list":
            return v2VmCall(id: id) {
                let remotes = try await RemotesClient.shared.list()
                return ["remotes": remotes.map(Self.socketWorkerRemotePayload)]
            }
        case "remotes.add":
            guard let name = Self.socketWorkerString(params["name"]), !name.isEmpty else {
                return v2Error(id: id, code: "invalid_params", message: "remotes.add requires `name`. Use `cmux remotes add <name> --route host:port`.")
            }
            let routes = Self.socketWorkerStringArray(params["routes"])
            guard !routes.isEmpty else {
                return v2Error(id: id, code: "invalid_params", message: "remotes.add requires at least one `--route host:port`.")
            }
            let tag = Self.socketWorkerString(params["tag"])
            return v2VmCall(id: id) {
                let deviceId = try await RemotesClient.shared.add(name: name, routes: routes, tag: tag)
                return ["ok": true, "deviceId": deviceId, "name": name]
            }
        case "remotes.remove":
            guard let target = Self.socketWorkerString(params["target"]), !target.isEmpty else {
                return v2Error(id: id, code: "invalid_params", message: "remotes.remove requires `target` (a remote name or deviceId). Run `cmux remotes list`.")
            }
            return v2VmCall(id: id) {
                let deviceId = try await RemotesClient.shared.remove(target: target)
                return ["ok": true, "deviceId": deviceId]
            }
        default:
            return v2Error(id: id, code: "method_not_found", message: "Unknown method")
        }
    }

    private nonisolated static func socketWorkerRemotePayload(_ remote: RemoteSummary) -> [String: Any] {
        [
            "deviceId": remote.deviceId,
            "displayName": remote.displayName ?? NSNull(),
            "platform": remote.platform,
            "tag": remote.tag ?? NSNull(),
            "lastSeen": remote.lastSeen ?? NSNull(),
            "routes": remote.routes.map { ["host": $0.host, "port": $0.port] as [String: Any] },
        ]
    }

    private nonisolated static func socketWorkerEnvLayerPayload(_ layer: VMEnvLayer) -> [String: Any] {
        [
            "provider": layer.provider ?? NSNull(),
            "chain_hash": layer.chainHash,
            "step_index": layer.stepIndex,
            "step_name": layer.stepName ?? NSNull(),
            "snapshot_id": layer.snapshotID,
            "spec_digest": layer.specDigest,
            "base_image_id": layer.baseImageID,
        ]
    }

    private nonisolated static func socketWorkerVMSummaryPayload(_ vm: VMSummary) -> [String: Any] {
        var payload: [String: Any] = [
            "id": vm.id,
            "provider": vm.provider,
            "image": vm.image,
            "status": vm.status,
            "createdAt": vm.createdAt,
        ]
        if let base = vm.base {
            payload["base"] = [
                "id": base.id,
                "name": base.name,
                "generation": base.generation,
                "retainedProviderVmId": base.retainedProviderVmId ?? NSNull(),
            ] as [String: Any]
        }
        return payload
    }

    private nonisolated static func socketWorkerStringArray(_ raw: Any?) -> [String] {
        guard let array = raw as? [Any] else { return [] }
        return array.compactMap { socketWorkerString($0) }
    }

    /// Handles `aiAccounts.*` socket methods backing `cmux ai-accounts`.
    /// OAuth credential files are read here in the app process so the CLI only
    /// sends provider/options; API-key providers may carry an explicit key.
    ///
    /// Trust model (conscious decision): the control socket is same-user
    /// trusted. A socket caller can already exfiltrate any user-readable file
    /// through existing verbs (`send` types arbitrary commands into a shell
    /// pane), and this upload only goes to the signed-in user's own team
    /// tenant using app-held auth. Reading the files app-side keeps secrets
    /// out of CLI argv and socket payloads; moving the reads to the caller
    /// would push credentials through more process boundaries, not fewer.
    nonisolated func socketWorkerAIAccountsResponse(
        method: String,
        id: Any?,
        params: [String: Any]
    ) -> String {
        switch method {
        case "aiAccounts.list":
            let teamID = Self.socketWorkerString(params["teamId"]) ?? Self.socketWorkerString(params["team_id"])
            return v2VmCall(id: id) {
                let accounts = try await AIAccountsClient.shared.list(teamID: teamID)
                return ["accounts": accounts.map(\.foundationObject)]
            }
        case "aiAccounts.upload":
            guard let rawProvider = Self.socketWorkerString(params["provider"]),
                  let provider = AIAccountProvider(rawValue: rawProvider) else {
                return v2Error(
                    id: id,
                    code: "invalid_params",
                    message: "aiAccounts.upload requires provider claude, codex, anthropic-key, or openai-key."
                )
            }
            let label = Self.socketWorkerString(params["label"])
            let explicitKey = Self.socketWorkerString(params["key"])
            let teamID = Self.socketWorkerString(params["teamId"]) ?? Self.socketWorkerString(params["team_id"])
            let validate = Self.socketWorkerBool(params["validate"]) ?? false
            return v2VmCall(id: id) {
                let sources = AIAccountCredentialSources()
                let payload = try sources.uploadPayload(provider: provider, label: label, explicitAPIKey: explicitKey)
                let result = try await AIAccountsClient.shared.upload(payload, teamID: teamID, validate: validate)
                return (result.foundationObject as? [String: Any]) ?? [:]
            }
        case "aiAccounts.remove":
            guard let accountID = Self.socketWorkerString(params["id"]), !accountID.isEmpty else {
                return v2Error(id: id, code: "invalid_params", message: "aiAccounts.remove requires `id`. Run `cmux ai-accounts list`.")
            }
            let teamID = Self.socketWorkerString(params["teamId"]) ?? Self.socketWorkerString(params["team_id"])
            return v2VmCall(id: id) {
                let result = try await AIAccountsClient.shared.remove(id: accountID, teamID: teamID)
                return (result.foundationObject as? [String: Any]) ?? [:]
            }
        default:
            return v2Error(id: id, code: "method_not_found", message: "Unknown method")
        }
    }

    private nonisolated static func socketWorkerSSHInfoPayload(_ endpoint: VMSSHEndpoint) -> [String: Any] {
        var payload: [String: Any] = [
            "transport": endpoint.transport,
            "host": endpoint.host,
            "port": endpoint.port,
            "username": endpoint.username,
            "credential": socketWorkerCredentialPayload(endpoint.credential),
            "public_key_fingerprint": endpoint.publicKeyFingerprint ?? NSNull(),
        ]
        if let daemon = endpoint.daemon {
            payload["daemon"] = [
                "url": daemon.url,
                "headers": daemon.headers,
                "token": daemon.token,
                "session_id": daemon.sessionId,
                "expires_at_unix": daemon.expiresAtUnix,
            ]
        }
        return payload
    }

    private nonisolated static func socketWorkerAttachInfoPayload(_ endpoint: VMAttachEndpoint) -> [String: Any] {
        switch endpoint {
        case .ssh(let ssh):
            return socketWorkerSSHInfoPayload(ssh)
        case .websocket(let websocket):
            var payload: [String: Any] = [
                "transport": "websocket",
                "url": websocket.url,
                "headers": websocket.headers,
                "token": websocket.token,
                "session_id": websocket.sessionId,
                "attachment_id": websocket.attachmentId,
                "expires_at_unix": websocket.expiresAtUnix,
            ]
            if let daemon = websocket.daemon {
                payload["daemon"] = [
                    "url": daemon.url,
                    "headers": daemon.headers,
                    "token": daemon.token,
                    "session_id": daemon.sessionId,
                    "expires_at_unix": daemon.expiresAtUnix,
                ]
            }
            return payload
        }
    }

    private nonisolated static func socketWorkerCloudSessionPayload(_ session: VMCloudSession) -> [String: Any] {
        [
            "id": session.id,
            "vm_id": session.vmId,
            "session_id": session.sessionId,
            "title": session.title ?? NSNull(),
            "kind": session.kind,
            "status": session.status,
            "attachment_count": session.attachmentCount,
            "effective_cols": session.effectiveCols ?? NSNull(),
            "effective_rows": session.effectiveRows ?? NSNull(),
            "last_known_cols": session.lastKnownCols ?? NSNull(),
            "last_known_rows": session.lastKnownRows ?? NSNull(),
            "scrollback_bytes": session.scrollbackBytes,
            "metadata": session.metadata,
            "created_at": session.createdAt,
            "updated_at": session.updatedAt,
            "last_attached_at": session.lastAttachedAt ?? NSNull(),
        ]
    }

    private nonisolated static func socketWorkerCredentialPayload(_ credential: VMSSHEndpoint.Credential) -> [String: Any] {
        switch credential {
        case .password(let value):
            return ["kind": "password", "value": value]
        case .authorizedKey(let pem):
            return ["kind": "authorizedKey", "private_key_pem": pem]
        }
    }

    private nonisolated static func socketWorkerBool(_ raw: Any?) -> Bool? {
        if let bool = raw as? Bool { return bool }
        if let number = raw as? NSNumber { return number.boolValue }
        if let string = raw as? String {
            switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "yes", "on":
                return true
            case "0", "false", "no", "off":
                return false
            default:
                return nil
            }
        }
        return nil
    }

    private nonisolated static func socketWorkerString(_ raw: Any?) -> String? {
        guard let string = raw as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private nonisolated static func socketWorkerInt(_ raw: Any?) -> Int? {
        if let int = raw as? Int { return int }
        if let number = raw as? NSNumber { return number.intValue }
        if let string = raw as? String { return Int(string) }
        return nil
    }
}

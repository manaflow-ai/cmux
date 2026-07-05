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
                    "vms": items.map { ["id": $0.id, "provider": $0.provider, "image": $0.image, "createdAt": $0.createdAt] as [String: Any] },
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
                return ["id": vm.id, "provider": vm.provider, "image": vm.image, "createdAt": vm.createdAt]
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

    private nonisolated static func socketWorkerStringArray(_ raw: Any?) -> [String] {
        guard let array = raw as? [Any] else { return [] }
        return array.compactMap { socketWorkerString($0) }
    }

    /// Handles `aiAccounts.*` socket methods backing `cmux ai-accounts`.
    /// OAuth credential files are read here in the app process so the CLI only
    /// sends provider/options; API-key providers may carry an explicit key.
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
                return ["accounts": accounts]
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
                return try await AIAccountsClient.shared.upload(payload, teamID: teamID, validate: validate)
            }
        case "aiAccounts.remove":
            guard let accountID = Self.socketWorkerString(params["id"]), !accountID.isEmpty else {
                return v2Error(id: id, code: "invalid_params", message: "aiAccounts.remove requires `id`. Run `cmux ai-accounts list`.")
            }
            let teamID = Self.socketWorkerString(params["teamId"]) ?? Self.socketWorkerString(params["team_id"])
            return v2VmCall(id: id) {
                try await AIAccountsClient.shared.remove(id: accountID, teamID: teamID)
            }
        default:
            return v2Error(id: id, code: "method_not_found", message: "Unknown method")
        }
    }

    private nonisolated static func socketWorkerSSHInfoPayload(_ endpoint: VMSSHEndpoint) -> [String: Any] {
        [
            "host": endpoint.host,
            "port": endpoint.port,
            "username": endpoint.username,
            "credential": socketWorkerCredentialPayload(endpoint.credential),
            "public_key_fingerprint": endpoint.publicKeyFingerprint ?? NSNull(),
        ]
    }

    private nonisolated static func socketWorkerAttachInfoPayload(_ endpoint: VMAttachEndpoint) -> [String: Any] {
        switch endpoint {
        case .ssh(let ssh):
            var payload = socketWorkerSSHInfoPayload(ssh)
            payload["transport"] = "ssh"
            return payload
        case .websocket(let websocket):
            var payload: [String: Any] = [
                "transport": "websocket",
                "url": websocket.url,
                "headers": websocket.headers,
                "token": websocket.token,
                "session_id": websocket.sessionId,
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

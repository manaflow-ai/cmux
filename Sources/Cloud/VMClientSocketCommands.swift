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

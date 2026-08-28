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
                let page = try await VMClient.shared.listPage()
                var payload: [String: Any] = [
                    "vms": page.vms.map(Self.socketWorkerVMSummaryPayload),
                ]
                if let limits = page.limits {
                    payload["limits"] = [
                        "maxActiveVms": limits.maxActiveVms,
                        "planId": limits.planId,
                        "freeAccessWindowDays": limits.freeAccessWindowDays,
                        "freeAccessExpiresAt": limits.freeAccessExpiresAt.map { $0 as Any } ?? NSNull(),
                        "imageKinds": limits.imageKinds.map { ["kind": $0.kind.rawValue, "image": $0.image] },
                    ]
                }
                return payload
            }
        case "vm.create":
            let image = Self.socketWorkerString(params["image"])
            let kind: VMMachineKind?
            switch Self.socketWorkerMachineKind(params["kind"], method: "vm.create") {
            case .success(let parsed):
                kind = parsed
            case .failure(let error):
                return v2Error(id: id, code: "invalid_params", message: error.message)
            }
            let provider = Self.socketWorkerString(params["provider"])
            let idempotencyKey = Self.socketWorkerString(params["idempotency_key"])
            guard let idempotencyKey, !idempotencyKey.isEmpty else {
                return v2Error(
                    id: id,
                    code: "invalid_params",
                    message: "vm.create requires `idempotency_key`. Use `cmux vm new` instead of calling the socket method directly."
                )
            }
            let persistentHome = Self.socketWorkerBool(params["persistent_home"]) ?? false
            let perMachineHome = Self.socketWorkerBool(params["per_machine_home"]) ?? false
            let memoryMb = Self.socketWorkerInt(params["memory_mb"])
            return v2VmCall(id: id) {
                let vm = try await VMClient.shared.create(image: image, kind: kind, provider: provider, persistentHome: persistentHome, perMachineHome: perMachineHome, memoryMb: memoryMb, idempotencyKey: idempotencyKey)
                return Self.socketWorkerVMSummaryPayload(vm)
            }
        case "vm.base_open":
            let name = Self.socketWorkerString(params["name"])
            let kind: VMMachineKind?
            switch Self.socketWorkerMachineKind(params["kind"], method: "vm.base_open") {
            case .success(let parsed):
                kind = parsed
            case .failure(let error):
                return v2Error(id: id, code: "invalid_params", message: error.message)
            }
            return v2VmCall(id: id) {
                let vm = try await VMClient.shared.openBase(name: name, kind: kind)
                return Self.socketWorkerVMSummaryPayload(vm)
            }
        case "vm.base_reset":
            let name = Self.socketWorkerString(params["name"])
            let reason = Self.socketWorkerString(params["reason"])
            let kind: VMMachineKind?
            switch Self.socketWorkerMachineKind(params["kind"], method: "vm.base_reset") {
            case .success(let parsed):
                kind = parsed
            case .failure(let error):
                return v2Error(id: id, code: "invalid_params", message: error.message)
            }
            return v2VmCall(id: id) {
                let vm = try await VMClient.shared.resetBase(name: name, kind: kind, reason: reason)
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
        case "vm.stats":
            guard let vmId = Self.socketWorkerString(params["id"]), !vmId.isEmpty else {
                return v2Error(id: id, code: "invalid_params", message: "vm.stats requires `id`. Run `cmux vm ls` to find one.")
            }
            return v2VmCall(id: id) {
                let stats = try await VMClient.shared.stats(id: vmId)
                var payload: [String: Any] = [
                    "id": vmId,
                    "state": stats.state.rawValue,
                    "sampled_at_unix": Int(stats.sampledAt.timeIntervalSince1970),
                ]
                payload["cpus"] = stats.cpus
                payload["cpu_percent"] = stats.cpuPercent
                payload["load_average_1m"] = stats.loadAverage1m
                payload["memory_total_mb"] = stats.memoryTotalMb
                payload["memory_used_mb"] = stats.memoryUsedMb
                payload["disk_total_mb"] = stats.diskTotalMb
                payload["disk_used_mb"] = stats.diskUsedMb
                return payload.compactMapValues { $0 }
            }
        case "vm.rename":
            guard let vmId = Self.socketWorkerString(params["id"]), !vmId.isEmpty else {
                return v2Error(id: id, code: "invalid_params", message: "vm.rename requires `id`. Run `cmux vm ls` to find one.")
            }
            let displayName = Self.socketWorkerString(params["display_name"])
            return v2VmCall(id: id) {
                let stored = try await VMClient.shared.rename(
                    id: vmId,
                    displayName: displayName?.isEmpty == false ? displayName : nil
                )
                return [
                    "id": vmId,
                    "displayName": stored ?? NSNull(),
                ]
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
                // Same cleanup as the Machines panel's delete confirm. Every
                // entrypoint (panel, tree, CLI, socket) funnels through this
                // handler, so this is the one place the app learns a machine
                // died before the next 45 s list poll: close its workspaces
                // and its URL-backed panes now, not up to 45 s later.
                await MainActor.run {
                    AppDelegate.shared?.closeWorkspaces(forManagedCloudVMID: vmId)
                }
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
        case "vm.open_port":
            guard let vmId = Self.socketWorkerString(params["id"]), !vmId.isEmpty else {
                return v2Error(id: id, code: "invalid_params", message: "vm.open_port requires `id`. Run `cmux vm ls` to find one.")
            }
            guard let port = Self.socketWorkerInt(params["port"]), (1...65535).contains(port) else {
                return v2Error(id: id, code: "invalid_params", message: "vm.open_port requires `port` between 1 and 65535. From the CLI, use `cmux vm open <id> <port>`.")
            }
            return v2VmCall(id: id) {
                let endpoint = try await VMClient.shared.openPort(id: vmId, port: port)
                return ["url": endpoint.url, "token": endpoint.token, "open_url": endpoint.openUrl]
            }
        case "vm.cloud_agent_open":
            // Shared entrypoint with the Machines panel's cloud-agent menu:
            // both call CloudAgentSkillLauncher.openAgent, which installs the
            // bundled skill file and opens a local terminal running the agent.
            guard let agentRaw = Self.socketWorkerString(params["agent"]),
                  let agent = CloudAgentSkillLauncher.CodingAgent(rawValue: agentRaw.lowercased())
            else {
                let names = CloudAgentSkillLauncher.CodingAgent.allCases.map(\.rawValue).joined(separator: "|")
                return v2Error(id: id, code: "invalid_params", message: "vm.cloud_agent_open requires `agent` (\(names)).")
            }
            return v2VmCall(id: id, timeoutSeconds: 60) {
                try await CloudAgentSkillLauncher.openAgent(agent)
            }
        case "vm.cloud_prompt":
            return v2VmCall(id: id) {
                let payload = try CloudAgentSkillLauncher.promptPayload()
                return ["prompt": payload.prompt, "skill_path": payload.skillPath]
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
        case "vm.cmux_remote_info":
            guard let vmId = Self.socketWorkerString(params["id"]), !vmId.isEmpty else {
                return v2Error(id: id, code: "invalid_params", message: "vm.cmux_remote_info requires `id`. Run `cmux vm ls` to find one, then `cmux vm tui <id>`.")
            }
            let deviceFingerprint = Self.socketWorkerString(params["device_fingerprint"])
                ?? Self.socketWorkerString(params["deviceFingerprint"])
            // What the local cmux-tui client can do (`remote-probe --json` capabilities);
            // VMClient validates the tokens before they reach the control plane.
            let clientCapabilities = Self.socketWorkerStringArray(
                params["client_capabilities"] ?? params["clientCapabilities"]
            )
            return v2VmCall(id: id) {
                let endpoint = try await VMClient.shared.openCmuxRemote(
                    id: vmId,
                    deviceFingerprint: deviceFingerprint,
                    clientCapabilities: clientCapabilities
                )
                var payload: [String: Any] = [
                    "transport": "cmux-remote",
                    "route": endpoint.route,
                    "token": endpoint.token,
                    "expires_at_unix": endpoint.expiresAtUnix,
                    "session": endpoint.session,
                ]
                if let build = endpoint.daemonBuild {
                    var raw: [String: Any] = [:]
                    if let commit = build.commit { raw["commit"] = commit }
                    if let remoteProtocol = build.remoteProtocol { raw["remote_protocol"] = remoteProtocol }
                    if let version = build.version { raw["version"] = version }
                    payload["daemon_build"] = raw
                }
                if let invitation = endpoint.invitation {
                    payload["invitation"] = [
                        "uri": invitation.uri,
                        "invitation_id": invitation.invitationId,
                        "expires_at_unix": invitation.expiresAtUnix,
                    ]
                }
                return payload
            }
        case "vm.cmux_remote_approve":
            guard let vmId = Self.socketWorkerString(params["id"]), !vmId.isEmpty,
                  let invitationId = Self.socketWorkerString(params["invitation_id"]) ?? Self.socketWorkerString(params["invitationId"]),
                  !invitationId.isEmpty else {
                return v2Error(id: id, code: "invalid_params", message: "vm.cmux_remote_approve requires `id` and `invitation_id`.")
            }
            return v2VmCall(id: id) {
                let approval = try await VMClient.shared.approveCmuxRemoteEnrollment(id: vmId, invitationId: invitationId)
                var payload: [String: Any] = ["approved": approval.approved, "state": approval.state]
                if let fingerprint = approval.deviceFingerprint {
                    payload["device_fingerprint"] = fingerprint
                }
                return payload
            }
        case "vm.sessions":
            guard let vmId = Self.socketWorkerString(params["id"]), !vmId.isEmpty else {
                return v2Error(id: id, code: "invalid_params", message: "vm.sessions requires `id`. Run `cmux vm ls` to find one.")
            }
            return v2VmCall(id: id) {
                let sessions = try await VMClient.shared.listSessions(id: vmId)
                return ["sessions": sessions.map(Self.socketWorkerCloudSessionPayload)]
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
        // The cloud tree verbs (`cmux vm tree|open|agent`, the sidebar) are thin wrappers
        // over the surface catalog now; see SurfaceSocketCommands.swift. They stay on the
        // socket worker like every other vm verb and await the main-actor catalog.
        case "vm.tree":
            return socketWorkerVMTreeResponse(id: id, params: params)
        case "vm.terminal_open":
            return socketWorkerVMTerminalOpenResponse(id: id, params: params)
        case "vm.terminal_new":
            return socketWorkerVMTerminalNewResponse(id: id, params: params)
        case "vm.workspace_new":
            return socketWorkerVMWorkspaceNewResponse(id: id, params: params)
        case "vm.desktop_open":
            return socketWorkerVMDesktopOpenResponse(id: id, params: params)
        case "vm.port_open":
            return socketWorkerVMPortOpenResponse(id: id, params: params)
        case "vm.link_socket":
            return socketWorkerVMLinkSocketResponse(id: id, params: params)
        case "vm.workspace_open":
            return socketWorkerVMWorkspaceOpenResponse(id: id, params: params)
        case "vm.workspace_close":
            return socketWorkerVMWorkspaceCloseResponse(id: id, params: params)
        case "vm.terminal_close":
            return socketWorkerVMTerminalCloseResponse(id: id, params: params)
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

    /// `kind` is optional; when present it must be a known machine kind.
    private nonisolated static func socketWorkerMachineKind(_ raw: Any?, method: String) -> Result<VMMachineKind?, SocketWorkerKindError> {
        guard let rawKind = socketWorkerString(raw), !rawKind.isEmpty else { return .success(nil) }
        guard let kind = VMMachineKind(rawValue: rawKind.lowercased()) else {
            let known = VMMachineKind.allCases.map(\.rawValue).joined(separator: "|")
            return .failure(SocketWorkerKindError(message: "\(method): `kind` must be one of \(known), got `\(rawKind)`."))
        }
        return .success(kind)
    }

    private nonisolated static func socketWorkerVMSummaryPayload(_ vm: VMSummary) -> [String: Any] {
        var payload: [String: Any] = [
            "id": vm.id,
            "provider": vm.provider,
            "image": vm.image,
            "kind": vm.resolvedKind.rawValue,
            // What the provider can honor; agents skip Checkpoint/Fork the way the menus do.
            "capabilities": ["snapshot": vm.capabilities.snapshot, "restore": vm.capabilities.restore, "fork": vm.capabilities.fork],
            "status": vm.status,
            "createdAt": vm.createdAt,
        ]
        if let displayName = vm.displayName, !displayName.isEmpty {
            payload["displayName"] = displayName
        }
        if let freeAccessExpiresAt = vm.freeAccessExpiresAt {
            payload["freeAccessExpiresAt"] = freeAccessExpiresAt
        }
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

/// A rejected `kind` parameter on a machine-creating socket command.
private struct SocketWorkerKindError: Error {
    let message: String
}

import CmuxNextActions
import CmuxNextCloud
import Foundation
import CmuxNextControl
import CmuxNextSettings

// Account and Cloud machine state for the iOS dogfood launcher and agents:
// `auth.status` (signed in, email) and `cloud.machines`. Short main-actor
// reads of observable state; no network.
extension AppControl {
    func registerCloudMethods(_ services: AppServices) {
        service?.router.register([
            .mainActor("auth.status") { _ in
                let cloud = services.cloud
                let user = cloud.auth.user
                return .value(.object([
                    "signed_in": .bool(cloud.isSignedIn),
                    "restoring": .bool(cloud.auth.isRestoring),
                    "email": user?.primaryEmail.map(JSONValue.string) ?? .null,
                    // The old app's shape, read by the iOS dogfood launcher.
                    "user": user.map { .object(["id": .string($0.id), "email": $0.primaryEmail.map(JSONValue.string) ?? .null]) } ?? .null,
                    "user_id": user.map { .string($0.id) } ?? .null,
                    "team_id": cloud.auth.teamID.map(JSONValue.string) ?? .null,
                    "backend": .string(cloud.configuration.apiBaseURL.absoluteString),
                    "cloud_unavailable": cloud.unavailableReason.map(JSONValue.string) ?? .null,
                ]))
            },
            .mainActor("cloud.machines") { _ in
                if let refusal = ControlError.policyRefusal("cloud.machines", disabled: services.registry.disabledFeatures) { throw refusal }
                let rows: [JSONValue] = services.machines.cloud.map { .object(Self.cloudMachineRow($0, services.machines)) }
                return .value(.object(["machines": .array(rows), "loaded": .bool(services.cloud.hasLoadedCurrentMachines),
                                       "creations": .array(services.cloud.creations.controlRows),
                                       "last_error": services.cloud.lastError.map(JSONValue.string) ?? .null]))
            },
            // `cmux automation --target cloud`: one Cloud automation op as the signed-in user (CloudAutomationRelay).
            .async("cloud.automation") { [relay = CloudAutomationRelay.signedIn(services.cloud.auth), registry = services.registry] call in
                if let refusal = await MainActor.run(body: { ControlError.policyRefusal("cloud.automation", disabled: registry.disabledFeatures) }) { throw refusal }
                let reply = await relay.forward(try JSONSerialization.data(withJSONObject: JSONValue.object(call.params).foundationObject))
                return JSONValue(foundation: try JSONSerialization.jsonObject(with: reply)) ?? .null
            }.withDeadline(.fixed(.seconds(30))),
        ])
        registerRunMethods(services)
        registerVMAgentKeyMethods(services)
        let turnClient = CloudTurnRewindClient(origin: services.cloud.configuration.turnAPIBaseURL()) {
            try await services.cloud.installIdentity.accessToken(team: try await services.cloud.auth.accessTokenTeam(requested: nil)).accessToken
        }
        service?.router.register(CloudTurnCommands(
            state: { try await turnClient.state(workspace: $0) },
            connection: { try await turnClient.connection(workspace: $0) },
            rewind: { try await turnClient.rewind(workspace: $0.workspace, session: $0.session, turn: $0.turn,
                                                  machine: $0.machine, generation: $0.generation, key: $0.key) }
        ) { workspace in
            let (machine, account) = try await MainActor.run {
                if let refusal = ControlError.policyRefusal("cloud.turn.rewind", disabled: services.registry.disabledFeatures) { throw refusal }
                guard let account = services.cloud.workspaceBindingScope else { throw ControlError(code: "cloud.turn.scope", message: "Sign in to Cloud first.") }
                let known = try services.cloud.workspaceBindings.bindings(in: account).first { $0.workspace == workspace }
                guard let machine = services.machines.cloud.first(where: { $0.appLink != nil && ($0.machineID == known?.machine || $0.daemon.store.workspaces.contains(where: { $0.resourceID?.rawValue == workspace })) })
                else { throw ControlError(code: "cloud.turn.scope", message: "Open the Cloud workspace in this app first.") }
                return (machine, account)
            }
            // The platform authenticates the workspace creator. A previous rewind may already
            // have ended the old owner link, so same-key recovery must not require that link.
            return CloudTurnCommands.Scope(machine: await machine.machineID, confirmed: {
                try await services.cloud.rememberTurnWorkspace(workspace: workspace, machine: machine.machineID, scope: account)
            }) { try await machine.reconnectAfterRewind(connectionMachine: $0, generation: $1) }
        }.methods)
        // `cmux auth token` (cmux-platform#111): the method lives in CmuxNextControl, the mint in CmuxNextCloud.
        let identity = services.cloud.installIdentity, origin = services.cloud.configuration.ownerAPIBaseURL(), auth = services.cloud.auth
        service?.router.register([.authToken(
            disabledFeatures: { services.registry.disabledFeatures }, isSignedIn: { services.cloud.isSignedIn },
            mint: { asked in
                do {
                    let token = try await identity.accessToken(team: try await auth.accessTokenTeam(requested: asked))
                    return AuthTokenGrant(accessToken: token.accessToken, team: token.team, user: token.user, expiresAt: token.expiresAt, apiOrigin: origin)
                } catch let failure as CloudAccessToken.Failure { throw AuthTokenRefusal(code: failure.code, detail: failure.detail) }
            }),
        ])
        // Tagged DEV builds only (debug.* methods; a release build registers
        // none, and ControlRouter drops them too).
        #if DEBUG || CMUX_BENCH_HOOKS
        service?.router.register([
            // Starts this Mac's cmux link the way a connect does and reports
            // the ensure and the apps-link-changed answer (cx-rtipa S3).
            .async("debug.cloud.link_ensure") { [weak services] _ in
                let found = await MainActor.run { () -> (CloudService?, ControlError?) in
                    guard let services else { return (nil, nil) }
                    return (services.cloud, ControlError.policyRefusal("debug.cloud.link_ensure", disabled: services.registry.disabledFeatures))
                }
                if let refusal = found.1 { throw refusal }
                guard let cloud = found.0 else { return .null }
                // The daemon wire value, as this socket's JSON value.
                let report = await cloud.ensureLinkReport()
                guard let data = try? JSONEncoder().encode(report),
                      let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return .null }
                return CmuxNextSettings.JSONValue(foundation: object) ?? .null
            },
            // Ends the Cloud session here without the app's sign-out (as an
            // expired or remote sign-out does), for the link's GUI proof.
            .async("debug.cloud.end_session") { [weak services] _ in
                guard let cloud = await MainActor.run(body: { services?.cloud }) else { return .null }
                await cloud.auth.signOut()
                return .object(["ended": .bool(true)])
            },
        ])
        #endif
    }

    /// One Cloud machine's row of `cloud.machines` (and of the Cloud
    /// diagnostics' details): its record, stage, daemon link state and the
    /// capability negotiation of its daemon.
    /// The daemon capability that serves file ops over a Cloud machine's home (cmux-tui `FS_CAPABILITY`).
    static let cloudFileOpsCapability = "fs-v1"

    static func cloudMachineRow(_ session: CloudMachineSession, _ machines: MachineRegistry) -> [String: JSONValue] {
        let store = session.daemon.store
        let state: String = switch store.connectionState {
        case .connected: "connected"
        case .connecting: "connecting"
        case .disconnected: "disconnected"
        case .failed(let reason): "failed: \(reason)"
        }
        var compat = machines.compatibility(of: session.daemon)
        // File ops (`fs-v1`) are what Move to Cloud and a Cloud chat's first send copy the folder
        // with. A Cloud machine's daemon serves them only when it knows its model plane identity,
        // so their absence is not an optional extra there: say so here, before a sync fails on it.
        // Nil before the daemon answers.
        let fileOps = session.daemon.identity.map { _ in session.daemon.supports(Self.cloudFileOpsCapability) }
        if fileOps == false, var known = compat, known.level != .incompatible {
            if !known.missingOptional.contains(Self.cloudFileOpsCapability) { known.missingOptional.append(Self.cloudFileOpsCapability) }
            known.level = .limited
            compat = known
        }
        return [
            "id": .string(session.machineID),
            // The id its daemon has in the machine catalog (`machine list --catalog`),
            // so `cmux machine list` lists a connected machine once.
            "machine_id": session.daemon.identity?.machineResourceID.map { .string($0.rawValue) } ?? .null,
            "title": .string(session.machine.title),
            // The record's status, except a connected daemon is running (cx-lu8f).
            "status": .string(session.effectiveStatus.rawValue),
            "api_status": .string(session.machine.status.rawValue),
            "stage": .string(session.stage.name),
            "stage_detail": session.stage.failure.map(JSONValue.string) ?? .null,
            // Why a paused machine is paused (`idle` or `user`), and its idle auto-pause (0: Off).
            "pause_reason": session.machine.pauseReason.map { .string($0.rawValue) } ?? .null,
            "idle_pause_minutes": session.machine.idlePauseMinutes.map { .number(Double($0)) } ?? .null,
            "daemon": .string(state),
            // Capability negotiation per machine (DaemonCompatibility).
            "session_id": compat?.sessionID.map(JSONValue.string) ?? .null,
            "session": compat?.sessionName.map(JSONValue.string) ?? .null,
            "protocol": compat?.protocolVersion.map { .number(Double($0)) } ?? .null,
            "daemon_version": compat.map { .string($0.version) } ?? .null,
            "daemon_commit": compat?.buildCommit.map(JSONValue.string) ?? .null,
            "compatibility": compat.map { .string($0.level.rawValue) } ?? .null,
            "missing_required": .array((compat?.missingRequired ?? []).map(JSONValue.string)),
            "missing_features": .array((compat?.missingOptional ?? []).map(JSONValue.string)),
            "file_ops": fileOps.map(JSONValue.bool) ?? .null,
            "workspaces": .array(store.workspaces.map { .object(["id": .string($0.id), "name": .string($0.displayName)]) }),
        ]
    }
}

// `runs.sandbox.create|runs.wait|runs.cancel`: the methods `cmux run --sandboxed` sends
// (hq#3367). The app holds the Stack session, so the CLI never sees a token: it asks the
// app, the app asks cmux.com's Run API (messages in Resources/Runs.xcstrings), and the answer (the Run's view and its receipt,
// which hold no secrets or provider handles) passes through as JSON. Not behind Labs
// (Leo, 2026-10-30): signed in and Cloud allowed by policy.
extension AppControl {
    private func registerRunMethods(_ services: AppServices) {
        service?.router.register([
            ControlMethod.async("runs.sandbox.create") { call in
                let params = call.params
                guard let task = params["task"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !task.isEmpty else {
                    throw ControlError.invalidParams(String(localized: "runs.error.taskRequired", defaultValue: "A sandboxed run needs a task.", table: "Runs", bundle: .module))
                }
                let key = params["idempotencyKey"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString
                let api = try await Self.runsAPI(services, newRun: true)
                return try await Self.runJSON {
                    try await api.createSandboxRun(task: task, agent: params["agent"]?.stringValue, image: params["image"]?.stringValue,
                                                   timeoutMs: params["timeoutMs"]?.intValue, idempotencyKey: key)
                }
            }.withDeadline(.fixed(.seconds(25))),
            ControlMethod.async("runs.wait") { call in
                let id = try Self.runID(call.params)
                let wait = call.params["timeoutMs"]?.intValue ?? 10_000
                let api = try await Self.runsAPI(services, newRun: false)
                return try await Self.runJSON { try await api.waitRun(id, timeoutMs: wait) }
            }.withDeadline(.fixed(.seconds(25))),
            ControlMethod.async("runs.cancel") { call in
                let id = try Self.runID(call.params)
                // The person's own cancel: the Run's end tells nothing (SandboxRunNotices).
                await MainActor.run { services.agentTabs.pageChats.runNotices?.follower.noteCancel(id) }
                let api = try await Self.runsAPI(services, newRun: false)
                return try await Self.runJSON { try await api.cancelRun(id) }
            }.withDeadline(.fixed(.seconds(65))),
        ])
    }

    nonisolated private static func runID(_ params: [String: JSONValue]) throws -> String {
        guard let id = params["id"]?.stringValue, !id.isEmpty else { throw ControlError.invalidParams(String(localized: "runs.error.idRequired", defaultValue: "Name the run with `id`.", table: "Runs", bundle: .module)) }
        return id
    }

    /// The signed-in Cloud client. The Cloud policy gates only a new sandboxed run (`newRun`):
    /// waiting on or cancelling one that exists stays open, so turning it off mid-run never strands
    /// a billable VM without its receipt or its cancel. Not behind Labs (Leo, 2026-10-30): the CLI's
    /// `cmux run --sandboxed` is the person's explicit ask for the run.
    nonisolated private static func runsAPI(_ services: AppServices, newRun: Bool) async throws -> CloudAPIClient {
        try await MainActor.run {
            if newRun, let refusal = ControlError.policyRefusal("runs.sandbox.create", disabled: services.registry.disabledFeatures) { throw refusal }
            // A managed team missing or a local-only backend: no new run asks the server (mayCallCloud).
            guard !newRun || services.cloud.mayCallCloud else { throw ControlError(code: "cloud_disabled", message: String(localized: "runs.error.cloudUnavailable", defaultValue: "cmux Cloud is not available for this account or team.", table: "Runs", bundle: .module)) }
            guard services.cloud.isSignedIn else { throw ControlError(code: "not_signed_in", message: String(localized: "runs.error.notSignedIn", defaultValue: "Sign in to cmux in the cmux app first.", table: "Runs", bundle: .module)) }
            return services.cloud.api
        }
    }

    /// One Run API call as JSON; the server's error code (`run_task_required`, …) passes through.
    nonisolated private static func runJSON(_ call: @Sendable () async throws -> Data) async throws -> JSONValue {
        let data: Data
        do {
            data = try await call()
        } catch let error as CloudAPIError {
            throw runError(error)
        }
        // Every Run answer is a JSON object. A 2xx that isn't one (empty, unreadable, anything
        // else) says nothing about the run: `bad_response`, which the CLI treats as "the run may
        // exist" on a create, waits through on a wait, and as no answer on a cancel.
        guard let answer = try? JSONValue.parse(data), case .object = answer else {
            throw ControlError(code: "bad_response", message: String(localized: "runs.error.badResponse", defaultValue: "cmux.com sent an answer the app couldn't read.", table: "Runs", bundle: .module))
        }
        return answer
    }

    /// The control error a Run API failure answers with (internal for its tests).
    nonisolated static func runError(_ error: CloudAPIError) -> ControlError {
        let notSignedIn = String(localized: "runs.error.notSignedIn", defaultValue: "Sign in to cmux in the cmux app first.", table: "Runs", bundle: .module)
        switch error {
        case .notSignedIn: return ControlError(code: "not_signed_in", message: notSignedIn)
        case .timedOut: return ControlError(code: "timeout", message: String(localized: "runs.error.timeout", defaultValue: "cmux.com didn't answer in time.", table: "Runs", bundle: .module))
        // An expired or revoked session: sign in again (the CLI's exit 3), not a failed run.
        case .http(401, _, _, _, _): return ControlError(code: "not_signed_in", message: notSignedIn)
        case .http(_, "run_sandbox_unavailable", _, _, _): return ControlError(code: "run_sandbox_unavailable", message: String(localized: "runs.error.sandboxUnavailable", defaultValue: "Sandboxed runs are not enabled for this cmux Cloud account yet.", table: "Runs", bundle: .module))
        case .http(_, "run_image_invalid", _, _, _): return ControlError(code: "run_image_invalid", message: String(localized: "runs.error.imageInvalid", defaultValue: "That image isn't a cmux Cloud VM image. Leave out --image to use the base image.", table: "Runs", bundle: .module))
        case .http(_, "run_agent_invalid", _, _, _): return ControlError(code: "run_agent_invalid", message: String(localized: "runs.error.agentInvalid", defaultValue: "Unknown agent. Use claude, codex, opencode or pi.", table: "Runs", bundle: .module))
        case .http(_, "run_task_required", _, _, _): return ControlError(code: "run_task_required", message: String(localized: "runs.error.taskInvalid", defaultValue: "A sandboxed run needs a task of at most 16,000 characters.", table: "Runs", bundle: .module))
        case .http(_, "run_timeout_invalid", _, _, _): return ControlError(code: "run_timeout_invalid", message: String(localized: "runs.error.timeoutInvalid", defaultValue: "The timeout must be 30 to 720 seconds.", table: "Runs", bundle: .module))
        // The rate limit answers before anything is stored: a definite refusal, not "may have started".
        case .http(429, let code, _, _, _): return ControlError(code: "rate_limited", message: error.description, data: .object(["status": .number(429), "code": code.map(JSONValue.string) ?? .null]))
        // A server failure says nothing about the run: the caller may wait again.
        case .http(let status, let code, _, _, _) where status >= 500:
            return ControlError(code: "unavailable", message: error.description, data: .object(["status": .number(Double(status)), "code": code.map(JSONValue.string) ?? .null]))
        case .http(let status, let code, _, _, _): return ControlError(code: code ?? "http_\(status)", message: error.description)
        // No backend configured: nothing was sent.
        case .noBackend: return ControlError(code: "no_backend", message: error.description)
        case .transport: return ControlError(code: "unavailable", message: error.description)
        case .decoding: return ControlError(code: "bad_response", message: error.description)
        // A refusal a paid plan lifts: the CLI tells the person which plan, nothing ran.
        case let .planRequired(_, _, plan): return ControlError(code: "plan_required", message: CloudStrings.apiErrorText(error), data: .object(["plan": .string(plan)]))
        }
    }
}

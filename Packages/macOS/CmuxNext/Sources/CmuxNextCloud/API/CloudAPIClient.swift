public import Foundation
import CmuxNextCompat

/// The app's Cloud API calls as a person: classic cmux.com's `/api/vm` routes that have no NEXT route
/// yet (tunnel, firewall, snapshots, restore, fork, resize, SCP, domains, publications), its sandboxed
/// Runs (`/api/runs`), and a Worker machine's exec, file and preview routes
/// (``workerMachines(baseURL:accessToken:teamID:appVersion:cli:sessions:)``). Every request, deadline,
/// retry and refusal's reading is cmux-tui Rust's (`cmux cloud api`, `cmux cloud machine-io`; cmux-tui
/// `cli/cloud_api.rs`): this type reads the caller's tokens per call, hands them to the bundled cmux on
/// its stdin (``BundledCmux``), and decodes the answer. Tokens are never stored here.
public struct CloudAPIClient: Sendable {
    public typealias Tokens = @Sendable () async throws -> (access: String, refresh: String)
    public typealias TeamID = @Sendable () async -> String?

    public let baseURL: URL
    let backendIsLocalOnly: Bool
    private(set) var tokens: Tokens
    private(set) var teamID: TeamID
    let appVersion: String
    /// Classic cmux.com's client (the Stack session, `X-Cmux-Team-Id`), or a Worker machines client's
    /// (the Stack access token, the cmux team in `x-cmux-team`, never the refresh token).
    let sendsStackSession: Bool
    /// The bundled cmux every call runs through; nil: a build without it, whose calls all fail.
    public let cli: BundledCmux?
    /// Where `cmux cloud machine-io` keeps a Worker machine's client sessions (0700; one 0600 file per
    /// machine and person); nil for the classic client.
    let sessions: URL?

    /// Requests that carry the account's bearer token from the lanes that still send their own (the
    /// feed, automations): ephemeral, no URL cache, no cookies, so no answer (or the request headers
    /// stored with it) lands in `~/Library/Caches/<bundle id>/Cache.db`.
    public static let noStoreTransport: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        return URLSession(configuration: configuration)
    }()

    /// The team requests go to now (`X-Cmux-Team-Id`).
    public func currentTeam() async -> String? { await teamID() }

    /// This client with its team fixed to `team`: every request of a create and its retries
    /// goes to the same team whatever the app switches to meanwhile.
    /// A Worker machines client keeps its cmux team: `team` is the app's (Stack) team id.
    public func pinningTeam(_ team: String?) -> CloudAPIClient {
        guard sendsStackSession else { return self }
        var copy = self
        copy.teamID = { team }
        return copy
    }

    /// Classic cmux.com's client at `configuration.apiBaseURL`.
    public init(configuration: CloudConfiguration, tokens: @escaping Tokens, teamID: @escaping TeamID,
                appVersion: String = "cmux-next", cli: BundledCmux?) {
        baseURL = configuration.apiBaseURL
        if case .localOnly = configuration.backend { backendIsLocalOnly = true } else { backendIsLocalOnly = false }
        self.tokens = tokens
        self.teamID = teamID
        self.appVersion = appVersion
        self.cli = cli
        sendsStackSession = true
        sessions = nil
    }

    /// A Worker machines client (``workerMachines(baseURL:accessToken:teamID:appVersion:cli:sessions:)``).
    init(baseURL: URL, tokens: @escaping Tokens, teamID: @escaping TeamID, appVersion: String, cli: BundledCmux?, sessions: URL?) {
        self.baseURL = baseURL
        backendIsLocalOnly = false
        self.tokens = tokens
        self.teamID = teamID
        self.appVersion = appVersion
        self.cli = cli
        self.sessions = sessions
        sendsStackSession = false
    }

    // MARK: Machines (classic)

    /// `POST /api/vm/{id}/resize`: cpu 1-32, memory 4096-65536 MiB in whole GiB, storage in 4 GiB
    /// steps up to 256 GiB (grow-only). Only the given dimensions are sent; the server checks them.
    public func resize(_ id: String, cpu: Int? = nil, memoryMb: Int? = nil, storageMb: Int? = nil) async throws {
        var args: [String: any Sendable] = ["id": id]
        if let cpu { args["cpu"] = cpu }
        if let memoryMb { args["memoryMb"] = memoryMb }
        if let storageMb { args["storageMb"] = storageMb }
        _ = try await call("vm.resize", args, timeout: .seconds(120))
    }

    public func snapshot(_ id: String, name: String?, idempotencyKey: String = UUID().uuidString) async throws -> CloudSnapshot {
        var args: [String: any Sendable] = ["id": id, "idempotencyKey": idempotencyKey]
        if let name { args["name"] = name }
        return try await call("vm.snapshot", args, timeout: .seconds(300), as: CloudSnapshot.self)
    }

    public func snapshots(_ id: String) async throws -> [CloudSnapshot] {
        try await call("vm.snapshots", ["id": id], as: [CloudSnapshot].self)
    }

    /// Deletes a snapshot scoped to the machine that owns it.
    public func deleteSnapshot(_ id: String, snapshotID: String) async throws {
        _ = try await call("vm.delete_snapshot", ["id": id, "snapshotId": snapshotID], timeout: .seconds(960))
    }

    public func restore(snapshotID: String, idempotencyKey: String = UUID().uuidString) async throws -> CloudMachine {
        try await call("vm.restore", ["snapshotId": snapshotID, "idempotencyKey": idempotencyKey], timeout: .seconds(620),
                       as: CloudMachine.self)
    }

    public func fork(_ id: String, name: String?, idempotencyKey: String = UUID().uuidString) async throws -> CloudMachine {
        var args: [String: any Sendable] = ["id": id, "idempotencyKey": idempotencyKey]
        if let name { args["name"] = name }
        return try await call("vm.fork", args, timeout: .seconds(620), as: CloudMachine.self)
    }

    /// Mints a short-lived private SCP route (port 22, user `cmux`, an ed25519 host key, not expired;
    /// anything else is refused as unsafe). The public key is the only key material sent; the caller
    /// owns the corresponding secret.
    public func prepareSCP(_ id: String, publicKey: String) async throws -> CloudSCPEndpoint {
        try await call("vm.scp_endpoint", ["id": id, "publicKey": publicKey], timeout: .seconds(100), as: CloudSCPEndpoint.self)
    }

    // MARK: Tunnel and firewall (classic)

    /// `POST /api/vm/tunnel`: enrolls this Mac's WireGuard public key. The private key never leaves the Mac.
    public func enrollTunnel(_ request: CloudTunnelEnrollment.Request) async throws -> CloudTunnelEnrollment {
        try await call("vm.tunnel_enroll", ["body": request.body], timeout: .seconds(60), as: CloudTunnelEnrollment.self)
    }

    /// `DELETE /api/vm/tunnel?deviceId=…`: revokes this Mac's peer.
    public func revokeTunnel(deviceID: String) async throws {
        _ = try await call("vm.tunnel_revoke", ["deviceId": deviceID])
    }

    public func attachTunnelNetwork(deviceFingerprint: String, networkID: String, tunnelPurpose: String = "browser") async throws -> CloudTunnelNetworkMutation {
        try await call("vm.tunnel_attach", ["deviceFingerprint": deviceFingerprint, "networkId": networkID, "tunnelPurpose": tunnelPurpose],
                       timeout: .seconds(60), as: CloudTunnelNetworkMutation.self)
    }

    public func detachTunnelNetwork(deviceFingerprint: String, networkID: String, tunnelPurpose: String = "browser") async throws -> CloudTunnelNetworkMutation {
        try await call("vm.tunnel_detach", ["deviceFingerprint": deviceFingerprint, "networkId": networkID, "tunnelPurpose": tunnelPurpose],
                       timeout: .seconds(60), as: CloudTunnelNetworkMutation.self)
    }

    public func rotateTunnelKey(deviceFingerprint: String, publicKey: String, tunnelPurpose: String = "browser") async throws -> CloudTunnelNetworkMutation {
        try await call("vm.tunnel_rotate_key", ["deviceFingerprint": deviceFingerprint, "clientPublicKey": publicKey, "tunnelPurpose": tunnelPurpose],
                       timeout: .seconds(60), as: CloudTunnelNetworkMutation.self)
    }

    public func listFirewallRules(vpcID: String? = nil, vmID: String? = nil, tunnelID: String? = nil) async throws -> [CloudFirewallRule] {
        var args: [String: any Sendable] = [:]
        if let vpcID { args["vpcId"] = vpcID }
        if let vmID { args["vmId"] = vmID }
        if let tunnelID { args["tunnelId"] = tunnelID }
        return try await call("vm.firewall_list", args, as: [CloudFirewallRule].self)
    }

    public func listNetworks() async throws -> [CloudNetwork] {
        try await call("vm.networks", [:], as: [CloudNetwork].self)
    }

    public func getFirewallRule(_ ruleID: String) async throws -> CloudFirewallRule {
        try await call("vm.firewall_get", ["ruleId": ruleID], as: CloudFirewallRule.self)
    }

    public func createFirewallRule(source: CloudFirewallEndpoint, destination: CloudFirewallEndpoint, description: String? = nil) async throws -> CloudFirewallRule {
        var args: [String: any Sendable] = ["source": Self.endpointBody(source), "destination": Self.endpointBody(destination)]
        if let description { args["description"] = description }
        return try await call("vm.firewall_create", args, timeout: .seconds(60), as: CloudFirewallRule.self)
    }

    private static func endpointBody(_ endpoint: CloudFirewallEndpoint) -> [String: any Sendable] {
        var body: [String: any Sendable] = [:]
        if let value = endpoint.vmId { body["vmId"] = value }
        if let value = endpoint.vpcId { body["vpcId"] = value }
        if let value = endpoint.tunnelId { body["tunnelId"] = value }
        if let value = endpoint.cidr { body["cidr"] = value }
        if let value = endpoint.isPublic { body["public"] = value }
        if let value = endpoint.port { body["port"] = value }
        if let value = endpoint.protocolName { body["protocol"] = value }
        return body
    }

    public func deleteFirewallRule(_ ruleID: String) async throws {
        _ = try await call("vm.firewall_delete", ["ruleId": ruleID], timeout: .seconds(60))
    }

    // MARK: Domains and publications (classic)

    /// Lists custom domains owned by the signed-in account. Provider credentials and certificate
    /// material are never returned by this route.
    public func listDomains() async throws -> [CloudDomain] {
        try await call("vm.domains", [:], as: [CloudDomain].self)
    }

    /// Lists redacted VM publications owned by the signed-in account.
    public func listPublications() async throws -> [CloudPublication] {
        try await call("vm.publications", [:], as: [CloudPublication].self)
    }

    /// `POST /api/vm/apis`: publishes `port` of the machine behind cmux sign-in and mints an API key
    /// for it in one call. Calling it again for the same port reuses the publication and mints another key.
    public func provisionAPI(machineID: String, port: Int, accessMode: String? = nil, keyName: String? = nil) async throws -> CloudProvisionedAPI {
        var args: [String: any Sendable] = ["vmId": machineID, "port": port]
        if let accessMode { args["accessMode"] = accessMode }
        if let keyName { args["keyName"] = keyName }
        return try await call("vm.provision_api", args, timeout: .seconds(120), as: CloudProvisionedAPI.self)
    }

    /// The live API keys of a publication, named by its id or hostname.
    public func listPublicationAPIKeys(_ publication: String) async throws -> [CloudPublicationAPIKey] {
        try await call("vm.publication_api_keys", ["publication": publication], as: [CloudPublicationAPIKey].self)
    }

    /// Revokes one key; its next request is refused at the edge.
    public func revokePublicationAPIKey(_ publication: String, keyID: String) async throws -> CloudPublicationAPIKey {
        try await call("vm.revoke_publication_api_key", ["publication": publication, "keyId": keyID], as: CloudPublicationAPIKey.self)
    }

    // MARK: Runs (classic)

    /// `POST /api/runs` for a sandboxed Run (hq#3367): one task on a throwaway VM from a pinned
    /// image. The key makes a retry after a lost response return the same Run. Answers the server's
    /// JSON as is; the Run API's views already hold no secrets.
    public func createSandboxRun(task: String, agent: String? = nil, image: String? = nil, timeoutMs: Int? = nil,
                                 idempotencyKey: String = UUID().uuidString) async throws -> Data {
        try await call("runs.create", Self.runArgs(task: task, agent: agent, image: image, timeoutMs: timeoutMs, key: idempotencyKey))
    }

    /// `GET /api/runs/:id/wait`: the snapshot once the Run is terminal or after `timeoutMs` (capped at
    /// 10 s), with its receipt when it has one.
    public func waitRun(_ id: String, timeoutMs: Int) async throws -> Data {
        try await call("runs.wait", ["id": id, "timeoutMs": timeoutMs], timeout: .milliseconds(max(0, min(timeoutMs, 10_000)) + 10_000))
    }

    /// One sandboxed Run to its end (cmux-tui `cloud_api/runs.rs`): its create, sent once more under
    /// `idempotencyKey` when the first answer was lost (with the first's own credentials: they are read
    /// once here; pin the team with ``pinningTeam(_:)``), then waits of 10 s until the snapshot carries
    /// its receipt. Everything, the sign-in token read included, runs under one bound: the task's
    /// timeout plus `teardown` (boot, the last output and the VM destroy) plus `callsMargin` for the
    /// calls, so the caller always gets an answer. `follow` (``SandboxRunFollower``) waits in place of
    /// the poll. Answers the final snapshot (`{run, attempts, artifacts, receipt}`).
    public func runSandbox(task: String, agent: String? = nil, timeoutMs: Int = 600_000, idempotencyKey: String = UUID().uuidString,
                           teardown: Duration = .seconds(180), callsMargin: Duration = .seconds(60),
                           follow: (@Sendable (_ id: String) async throws -> Data)? = nil) async throws -> [String: Any] {
        let bound = Duration.milliseconds(timeoutMs) + teardown + callsMargin
        let data = try await SandboxDeadline.race(bound) {
            // The create and its retry go with one account's credentials, read once.
            let credentials: (access: String, refresh: String)
            do { credentials = try await self.tokens() } catch { throw CloudAPIError.notSignedIn }
            var pinned = self
            pinned.tokens = { credentials }
            var args = Self.runArgs(task: task, agent: agent, image: nil, timeoutMs: timeoutMs, key: idempotencyKey)
            guard let follow else {
                args["teardownMs"] = Int(teardown / .milliseconds(1))
                args["callsMarginMs"] = Int(callsMargin / .milliseconds(1))
                return try await pinned.call("runs.sandbox", args, timeout: bound)
            }
            let created = try await pinned.call("runs.start", args, timeout: .seconds(60))
            guard let id = ((try? JSONSerialization.jsonObject(with: created)) as? [String: Any])?["id"] as? String, !id.isEmpty else {
                throw CloudAPIError.decoding("/api/runs: no run id")
            }
            return try await follow(id)
        }
        guard let snapshot = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudAPIError.decoding("/api/runs: no snapshot")
        }
        return snapshot
    }

    /// `POST /api/runs/:id/cancel`; a sandbox's VM is destroyed before it answers.
    public func cancelRun(_ id: String) async throws -> Data {
        try await call("runs.cancel", ["id": id], timeout: .seconds(60))
    }

    private static func runArgs(task: String, agent: String?, image: String?, timeoutMs: Int?, key: String) -> [String: any Sendable] {
        var args: [String: any Sendable] = ["task": task, "idempotencyKey": key]
        if let agent { args["agent"] = agent }
        if let image { args["image"] = image }
        if let timeoutMs { args["timeoutMs"] = timeoutMs }
        return args
    }

    // MARK: The call

    /// One `cmux cloud api` call: `call` with `args`, as this client's person and team. Answers the
    /// answer's body as JSON. `timeout` is the route's own deadline; the child is given 30 s more.
    func call(_ call: String, _ args: [String: any Sendable], timeout: Duration = .seconds(20)) async throws -> Data {
        let (access, refresh): (String, String)
        do { (access, refresh) = try await tokens() } catch { throw CloudAPIError.notSignedIn }
        var request: [String: any Sendable] = [
            "call": call, "api": baseURL.absoluteString, "auth": sendsStackSession ? "stack" : "worker",
            "credential": access, "app_version": appVersion, "local_only": backendIsLocalOnly, "args": args,
        ]
        if sendsStackSession { request["refresh"] = refresh }
        if let team = await teamID() { request["team"] = team }
        return try await CloudAPIAnswer.send(request, on: cli, timeout: timeout, baseURL: baseURL)
    }

    /// ``call(_:_:timeout:)`` decoded as `T`.
    func call<T: Decodable>(_ name: String, _ args: [String: any Sendable], timeout: Duration = .seconds(20), as type: T.Type) async throws -> T {
        let data = try await call(name, args, timeout: timeout)
        do { return try JSONDecoder().decode(T.self, from: data) } catch { throw CloudAPIError.decoding("\(name): \(error)") }
    }
}

/// `cmux cloud api`'s answer line (cmux-tui `cli/cloud_api.rs`): `{ok: true, body}`, or `{ok: false,
/// error}` whose `kind` is one ``CloudAPIError`` case.
struct CloudAPIAnswer {
    /// Runs `request` (and, after its line, `tail`'s bytes) and answers the body as JSON.
    static func send(_ request: [String: any Sendable], tail: Data? = nil, on cli: BundledCmux?, timeout: Duration,
                     baseURL: URL) async throws -> Data {
        let call = request["call"] as? String ?? "cloud api"
        guard let cli else { throw CloudAPIError.transport("this build has no bundled cmux") }
        var input = try JSONSerialization.data(withJSONObject: request)
        if let tail {
            input.append(UInt8(ascii: "\n"))
            input.append(tail)
        }
        let line: Data
        do {
            line = try await cli.line(["cloud", "api"], stdin: input, timeout: timeout + .seconds(30))
        } catch let noAnswer as BundledCmux.NoAnswer {
            // A call that may have run is never reported as refused: the caller must not take it for "nothing happened".
            if noAnswer.dispatched { throw CloudAPIError.timedOut(call) }
            throw CloudAPIError.transport("the bundled cmux did not start")
        }
        return try read(line, call: call, baseURL: baseURL)
    }

    /// The body of an `ok` line, or the error it names.
    static func read(_ line: Data, call: String, baseURL: URL) throws -> Data {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            throw CloudAPIError.timedOut(call)
        }
        if object["ok"] as? Bool == true {
            return try JSONSerialization.data(withJSONObject: object["body"] ?? NSNull(), options: .fragmentsAllowed)
        }
        throw error(object["error"] as? [String: Any] ?? [:], call: call, baseURL: baseURL)
    }

    static func error(_ error: [String: Any], call: String, baseURL: URL) -> CloudAPIError {
        let text = { (name: String) in error[name] as? String }
        switch text("kind") {
        case "timed_out": return .timedOut(text("path") ?? call)
        case "no_backend": return .noBackend(baseURL)
        case "http":
            return .http(status: error["status"] as? Int ?? 0, code: text("code"), message: text("message"),
                         action: text("action"), traceId: text("trace_id"))
        case "plan_required":
            return .planRequired(message: text("message"), upgradeURL: text("upgrade_url").flatMap(URL.init(string:)),
                                 plan: text("plan") ?? "pro")
        case "decoding": return .decoding(text("message") ?? call)
        default: return .transport(text("message") ?? "cmux cloud api gave no answer")
        }
    }
}

/// A deadline that holds even when the work ignores cancellation (a sign-in token read that never
/// returns): the caller is answered at the bound and the work is cancelled, never awaited. A task
/// group would wait for its cancelled child, so ``withDeadline`` can't promise that.
nonisolated final class SandboxDeadline<T: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<T, any Error>?
        var cancels: [@Sendable () -> Void] = []
        /// The caller was cancelled, possibly before the continuation was registered: no work starts.
        var cancelled = false
    }
    private let state = Mutex(State())

    static func race(_ bound: Duration, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await race(bound, timeout: { CloudAPIError.timedOut("/api/runs") }, work)
    }

    /// ``race(_:_:)`` with the error the bound throws (`timeout`): a Cloud link step names itself.
    static func race(_ bound: Duration, timeout: @escaping @Sendable () -> any Error,
                     _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let gate = SandboxDeadline<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let cancelled = gate.state.withLock { state -> Bool in
                    if !state.cancelled { state.continuation = continuation }
                    return state.cancelled
                }
                // Cancelled first: answered now, and no Run is created.
                guard !cancelled else { return continuation.resume(throwing: CancellationError()) }
                // concurrency-allow: the race answers at the bound without awaiting this task; it is cancelled then.
                let job = Task { do { gate.finish(.success(try await work())) } catch { gate.finish(.failure(error)) } }
                // concurrency-allow: one-shot timer, cancelled when the work answers first.
                let timer = Task {
                    // wakeup-allow: one-shot deadline for a sandbox run (stops at the bound or the answer)
                    try? await Task.sleep(for: bound)
                    gate.finish(.failure(timeout()))
                }
                gate.onFinish { job.cancel(); timer.cancel() }
            }
        } onCancel: {
            gate.state.withLock { $0.cancelled = true }
            gate.finish(.failure(CancellationError()))
        }
    }

    private func onFinish(_ cancel: @escaping @Sendable () -> Void) {
        let finished = state.withLock { state -> Bool in
            if state.continuation == nil { return true }
            state.cancels.append(cancel)
            return false
        }
        if finished { cancel() }
    }

    /// The first answer wins; later ones are dropped.
    private func finish(_ result: Result<T, any Error>) {
        let taken = state.withLock { state -> (CheckedContinuation<T, any Error>, [@Sendable () -> Void])? in
            guard let continuation = state.continuation else { return nil }
            state.continuation = nil
            defer { state.cancels = [] }
            return (continuation, state.cancels)
        }
        guard let (continuation, cancels) = taken else { return }
        continuation.resume(with: result)
        for cancel in cancels { cancel() }
    }
}

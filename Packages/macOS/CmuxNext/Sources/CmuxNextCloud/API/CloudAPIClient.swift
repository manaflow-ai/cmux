public import Foundation
import CmuxNextCompat
import CmuxNextDaemon

/// The Cloud API client: classic's `/api/vm` and `/api/runs`, or a Worker machines client's routes
/// (CloudAPIClient+MachineRoutes.swift). Each call is the local daemon's `cloud.<call>` operation
/// (``CloudAPICaller``; cmux-tui's `cmux-cloud-api` sends the request, holds its deadline and reads
/// its refusal as ``CloudAPIError``). Tokens come from the caller per call and are never stored here.
public struct CloudAPIClient: Sendable {
    public typealias Tokens = @Sendable () async throws -> (access: String, refresh: String)
    public typealias TeamID = @Sendable () async -> String?

    public let baseURL: URL
    let backendIsLocalOnly: Bool
    private(set) var tokens: Tokens
    private(set) var teamID: TeamID
    let caller: CloudAPICaller
    let appVersion: String
    /// Classic (`stack`: the refresh token and `X-Cmux-Team-Id` go too), or a Worker machines client.
    let sendsStackSession: Bool
    /// A Worker machines client's exec and file routes through cmux-tui (direct to the provider
    /// with a client session); nil: through the daemon's `cloud.machine.io` (CloudAPIClient+MachineRoutes.swift).
    var machineIO: CloudMachineIO?
    /// A write too large for one daemon request goes to the route over this (CloudAPIClient+MachineRoutes.swift).
    var fileRoute: URLSession = CloudAPIClient.noStoreTransport
    /// The Run calls' transport (MARK: Runs).
    let session: URLSession

    /// Requests that carry the account's bearer token: ephemeral, no URL
    /// cache, no cookies, so no answer (or the request headers stored with
    /// it) lands in `~/Library/Caches/<bundle id>/Cache.db`.
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

    public init(configuration: CloudConfiguration, tokens: @escaping Tokens, teamID: @escaping TeamID,
                caller: CloudAPICaller, session: URLSession = CloudAPIClient.noStoreTransport, appVersion: String = "cmux-next") {
        baseURL = configuration.apiBaseURL
        if case .localOnly = configuration.backend { backendIsLocalOnly = true } else { backendIsLocalOnly = false }
        self.tokens = tokens
        self.teamID = teamID
        self.caller = caller
        self.session = session
        self.appVersion = appVersion
        sendsStackSession = true
    }

    /// A Worker machines client (CloudAPIClient+MachineRoutes.swift).
    init(baseURL: URL, tokens: @escaping Tokens, teamID: @escaping TeamID, caller: CloudAPICaller, appVersion: String) {
        self.baseURL = baseURL
        backendIsLocalOnly = false
        self.tokens = tokens
        self.teamID = teamID
        self.caller = caller
        session = CloudAPIClient.noStoreTransport
        self.appVersion = appVersion
        sendsStackSession = false
    }

    // MARK: Files and SCP

    /// Mints a short-lived private SCP route: cmux-platform's `POST /v1/cloud/machines/{id}/ssh-endpoint` on a
    /// Worker machines client (``workerMachines(baseURL:accessToken:teamID:caller:appVersion:machineIO:)``). The
    /// public key is the only key material sent; the caller owns the secret.
    public func prepareSCP(_ id: String, publicKey: String) async throws -> CloudSCPEndpoint {
        // cmux-cloud-machine reads only a safe route (port 22, user cmux, an ed25519 host key, not
        // expired); any other answer throws ``CloudAPIError/decoding(_:)``. The daemon's
        // `vm.scp_endpoint` is classic's route, so this goes to the Worker's route itself.
        let body = try JSONSerialization.data(withJSONObject: ["publicKey": publicKey])
        let data = try await machineRouteRequest("POST", id, "ssh-endpoint", query: [], body: body, timeout: .seconds(100))
        return try CloudMachineRules().answer(data, as: CloudSCPEndpoint.self, context: "ssh-endpoint")
    }

    // MARK: Tunnel

    public func attachTunnelNetwork(deviceFingerprint: String, networkID: String, tunnelPurpose: String = "browser") async throws -> CloudTunnelNetworkMutation {
        try await tunnel("vm.tunnel_attach", ["deviceFingerprint": deviceFingerprint, "networkId": networkID, "tunnelPurpose": tunnelPurpose])
    }

    public func detachTunnelNetwork(deviceFingerprint: String, networkID: String, tunnelPurpose: String = "browser") async throws -> CloudTunnelNetworkMutation {
        try await tunnel("vm.tunnel_detach", ["deviceFingerprint": deviceFingerprint, "networkId": networkID, "tunnelPurpose": tunnelPurpose])
    }

    public func rotateTunnelKey(deviceFingerprint: String, publicKey: String, tunnelPurpose: String = "browser") async throws -> CloudTunnelNetworkMutation {
        try await tunnel("vm.tunnel_rotate_key", ["deviceFingerprint": deviceFingerprint, "clientPublicKey": publicKey, "tunnelPurpose": tunnelPurpose])
    }

    private func tunnel(_ name: String, _ args: [String: String]) async throws -> CloudTunnelNetworkMutation {
        try await call(name, args.mapValues(JSONValue.string), timeout: .seconds(60), as: CloudTunnelNetworkMutation.self)
    }

    public func listFirewallRules(vpcID: String? = nil, vmID: String? = nil, tunnelID: String? = nil) async throws -> [CloudFirewallRule] {
        var args: [String: JSONValue] = [:]
        if let vpcID { args["vpcId"] = .string(vpcID) }
        if let vmID { args["vmId"] = .string(vmID) }
        if let tunnelID { args["tunnelId"] = .string(tunnelID) }
        return try await call("vm.firewall_list", args, as: [CloudFirewallRule].self)
    }

    public func listNetworks() async throws -> [CloudNetwork] {
        try await call("vm.networks", [:], as: [CloudNetwork].self)
    }

    public func getFirewallRule(_ ruleID: String) async throws -> CloudFirewallRule {
        try await call("vm.firewall_get", ["ruleId": .string(ruleID)], as: CloudFirewallRule.self)
    }

    public func createFirewallRule(source: CloudFirewallEndpoint, destination: CloudFirewallEndpoint, description: String? = nil) async throws -> CloudFirewallRule {
        var args: [String: JSONValue] = ["source": endpointBody(source), "destination": endpointBody(destination)]
        if let description { args["description"] = .string(description) }
        return try await call("vm.firewall_create", args, timeout: .seconds(60), as: CloudFirewallRule.self)
    }

    private func endpointBody(_ endpoint: CloudFirewallEndpoint) -> JSONValue {
        var body: [String: JSONValue] = [:]
        if let value = endpoint.vmId { body["vmId"] = .string(value) }
        if let value = endpoint.vpcId { body["vpcId"] = .string(value) }
        if let value = endpoint.tunnelId { body["tunnelId"] = .string(value) }
        if let value = endpoint.cidr { body["cidr"] = .string(value) }
        if let value = endpoint.isPublic { body["public"] = .bool(value) }
        if let value = endpoint.port { body["port"] = .number(Double(value)) }
        if let value = endpoint.protocolName { body["protocol"] = .string(value) }
        return .object(body)
    }

    public func deleteFirewallRule(_ ruleID: String) async throws {
        _ = try await call("vm.firewall_delete", ["ruleId": .string(ruleID)], timeout: .seconds(60))
    }

    // MARK: Domains and publications

    /// Lists custom domains owned by the signed-in account. Provider
    /// credentials and certificate material are never returned by this route.
    public func listDomains() async throws -> [CloudDomain] {
        try await call("vm.domains", [:], as: [CloudDomain].self)
    }

    /// Lists redacted VM publications owned by the signed-in account.
    public func listPublications() async throws -> [CloudPublication] {
        try await call("vm.publications", [:], as: [CloudPublication].self)
    }

    /// `vm.provision_api`: publishes `port` of the machine behind cmux sign-in and mints an
    /// API key for it in one call. Calling it again for the same port reuses the publication
    /// and mints another key.
    public func provisionAPI(machineID: String, port: Int, accessMode: String? = nil, keyName: String? = nil) async throws -> CloudProvisionedAPI {
        var args: [String: JSONValue] = ["vmId": .string(machineID), "port": .number(Double(port))]
        if let accessMode { args["accessMode"] = .string(accessMode) }
        if let keyName { args["keyName"] = .string(keyName) }
        return try await call("vm.provision_api", args, timeout: .seconds(120), as: CloudProvisionedAPI.self)
    }

    /// The live API keys of a publication, named by its id or hostname.
    public func listPublicationAPIKeys(_ publication: String) async throws -> [CloudPublicationAPIKey] {
        try await call("vm.publication_api_keys", ["publication": .string(publication)], as: [CloudPublicationAPIKey].self)
    }

    /// Revokes one key; its next request is refused at the edge.
    public func revokePublicationAPIKey(_ publication: String, keyID: String) async throws -> CloudPublicationAPIKey {
        try await call("vm.revoke_publication_api_key", ["publication": .string(publication), "keyId": .string(keyID)],
                       as: CloudPublicationAPIKey.self)
    }

    // MARK: Runs

    // RULE (cmux#38435): the create, wait and sandbox calls stay on HTTP. A wait holds its answer up to
    // 10 s, a sandboxed Run for its whole task; on the daemon socket they would hold the terminal
    // connection's update drain (`quietHandoff`) behind them. Moving them needs a daemon connection of
    // their own or a drain exemption.

    /// `POST /api/runs` for a sandboxed Run (hq#3367): one task on a throwaway VM from a
    /// pinned image. The key makes a retry after a lost response return the same Run.
    /// Answers the server's JSON as is; the Run API's views already hold no secrets.
    public func createSandboxRun(task: String, agent: String? = nil, image: String? = nil, timeoutMs: Int? = nil,
                                 idempotencyKey: String = UUID().uuidString) async throws -> Data {
        var body: [String: any Sendable] = ["environment": "sandboxed", "task": task]
        if let agent, !agent.isEmpty { body["agent"] = agent }
        if let image, !image.isEmpty { body["image"] = image }
        if let timeoutMs { body["timeoutMs"] = timeoutMs }
        return try await sendData("POST", "/api/runs", body: body, idempotencyKey: idempotencyKey)
    }

    /// `GET /api/runs/:id/wait`: the snapshot once the Run is terminal or after
    /// `timeoutMs` (the server caps it at 10 s), with its receipt when it has one.
    public func waitRun(_ id: String, timeoutMs: Int) async throws -> Data {
        let wait = max(0, min(timeoutMs, 10_000))
        return try await sendData("GET", "/api/runs/\(queryComponent(id))/wait?timeoutMs=\(wait)", timeout: .milliseconds(wait + 10_000))
    }

    /// One sandboxed Run to its end: create it, then long-poll ``waitRun(_:timeoutMs:)`` (10 s a
    /// call) until the snapshot carries its receipt. Everything (sign-in tokens included) runs under
    /// one deadline, the task's timeout plus `teardown` (boot, the last output and the VM destroy)
    /// plus a minute for the calls themselves, so the caller always gets an answer. The poll stops
    /// at the receipt, at the first error, or at that deadline (`timedOut`); the server destroys
    /// the VM either way. `idempotencyKey` names this one send: a create whose answer was lost is
    /// sent once more under it, with the first's own credentials (the server scopes the key per
    /// account, so a switch of account between the two can't make a second Run; pin the team with
    /// ``pinningTeam(_:)``), which returns the same Run, never a second paid one. Answers the final
    /// snapshot (`{run, attempts, artifacts, receipt}`) as JSON. `follow` (``SandboxRunFollower``) waits in place of the poll here.
    public func runSandbox(task: String, agent: String? = nil, timeoutMs: Int = 600_000, idempotencyKey: String = UUID().uuidString,
                           teardown: Duration = .seconds(180), callsMargin: Duration = .seconds(60),
                           now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }, follow: (@Sendable (_ id: String) async throws -> Data)? = nil) async throws -> [String: Any] {
        let bound = Duration.milliseconds(timeoutMs) + teardown + callsMargin
        let data = try await SandboxDeadline.race(bound) {
            try await self.sandboxSnapshot(task: task, agent: agent, timeoutMs: timeoutMs, key: idempotencyKey,
                                           deadline: now() + .milliseconds(timeoutMs) + teardown, now: now, follow: follow)
        }
        guard let snapshot = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudAPIError.decoding("/api/runs: no snapshot")
        }
        return snapshot
    }

    private func sandboxSnapshot(task: String, agent: String?, timeoutMs: Int, key: String, deadline: ContinuousClock.Instant,
                                 now: @Sendable () -> ContinuousClock.Instant, follow: (@Sendable (String) async throws -> Data)?) async throws -> Data {
        // The create and its retry go with one account's credentials, read once.
        let credentials: (access: String, refresh: String)
        do { credentials = try await tokens() } catch { throw CloudAPIError.notSignedIn }
        var pinned = self
        pinned.tokens = { credentials }
        let create = { try await pinned.createSandboxRun(task: task, agent: agent, timeoutMs: timeoutMs, idempotencyKey: key) }
        let createdData: Data
        do {
            createdData = try await create()
        } catch CloudAPIError.transport, CloudAPIError.timedOut {
            // The first create may have made the Run: whatever the retry says, the outcome stays
            // uncertain (`timedOut`, never a refusal the caller could take as "nothing runs").
            do { createdData = try await create() } catch { throw CloudAPIError.timedOut("/api/runs") }
        }
        let created = try JSONSerialization.jsonObject(with: createdData) as? [String: Any]
        guard let id = created?["id"] as? String, !id.isEmpty else { throw CloudAPIError.decoding("/api/runs: no run id") }
        if let follow { return try await follow(id) }
        while now() < deadline {
            let data: Data
            do {
                data = try await waitRun(id, timeoutMs: 10_000)
            } catch { // The Run exists: losing sight of it is "no receipt in time", never a refusal to retry past.
                throw CloudAPIError.timedOut("/api/runs/\(id)")
            }
            // A 200 that is no Run snapshot (an array, an error body) won't turn into one: stop now.
            guard let snapshot = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  snapshot["run"] is [String: Any] else { throw CloudAPIError.timedOut("/api/runs/\(id)") }
            if snapshot["receipt"] is [String: Any] { return data }
            try Task.checkCancellation()
        }
        throw CloudAPIError.timedOut("/api/runs/\(id)")
    }

    /// `runs.cancel`; a sandbox's VM is destroyed before it answers.
    public func cancelRun(_ id: String) async throws -> Data {
        try await callData("runs.cancel", ["id": .string(id)], timeout: .seconds(60))
    }

    // MARK: Transport

    // The Run calls' HTTP (see RULE in MARK: Runs).
    /// One request whose JSON body the caller reads itself.
    func sendData(_ method: String, _ path: String, body: [String: any Sendable]? = nil, idempotencyKey: String? = nil,
                  timeout: Duration = .seconds(20)) async throws -> Data {
        try await send(method, path, body: body, idempotencyKey: idempotencyKey, timeout: timeout, as: RawBody.self).data
    }

    /// The undecoded body; ``send(_:_:body:bodyStream:idempotencyKey:timeout:onSent:as:)`` hands it over as is.
    struct RawBody: Decodable {
        let data: Data
        init(data: Data) { self.data = data }
        init(from decoder: any Decoder) throws {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "RawBody is not decoded"))
        }
    }

    func send<T: Decodable>(_ method: String, _ path: String, body: [String: any Sendable]? = nil,
                            bodyStream: (stream: InputStream, length: Int, contentType: String)? = nil, idempotencyKey: String? = nil,
                            timeout: Duration = .seconds(20), onSent: (@Sendable () async -> Void)? = nil,
                            as type: T.Type) async throws -> T {
        let (access, refresh): (String, String)
        do { (access, refresh) = try await tokens() } catch { throw CloudAPIError.notSignedIn }
        guard let url = URL(string: baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path) else {
            throw CloudAPIError.transport("bad path \(path)")
        }
        var request = URLRequest(url: url, timeoutInterval: TimeInterval(timeout.components.seconds))
        request.httpMethod = method
        request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        request.setValue("cmux-mac", forHTTPHeaderField: "X-Cmux-Client")
        request.setValue(appVersion, forHTTPHeaderField: "X-Cmux-App-Version")
        if sendsStackSession {
            request.setValue(refresh, forHTTPHeaderField: "X-Stack-Refresh-Token")
            if let team = await teamID() { request.setValue(team, forHTTPHeaderField: "X-Cmux-Team-Id") }
        } else if let team = await teamID() {
            request.setValue(team, forHTTPHeaderField: "x-cmux-team")
        }
        if let idempotencyKey { request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } else if let bodyStream {
            request.setValue(bodyStream.contentType, forHTTPHeaderField: "Content-Type")
            request.setValue(String(bodyStream.length), forHTTPHeaderField: "Content-Length")
            request.httpBodyStream = bodyStream.stream
        }
        let data: Data
        let response: URLResponse
        await onSent?()
        do {
            let session = session, prepared = request
            (data, response) = try await withDeadline(timeout, label: "\(method) \(path)") { try await session.data(for: prepared) }
        } catch is DeadlineExceeded {
            throw CloudAPIError.timedOut(path)
        } catch let error as URLError where error.code == .timedOut {
            throw CloudAPIError.timedOut(path)
        } catch let error as URLError where backendIsLocalOnly && error.code == .cannotConnectToHost {
            throw CloudAPIError.noBackend(baseURL)
        } catch {
            throw CloudAPIError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw CloudAPIError.transport("no HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            throw CloudAPIError.from(status: http.statusCode, data: data, headerCode: http.value(forHTTPHeaderField: "x-cmux-vm-error"))
        }
        if T.self == Ignored.self, let ignored = Ignored() as? T { return ignored }
        if T.self == RawBody.self, let raw = RawBody(data: data) as? T { return raw }
        return try CloudMachineRules().answer(data, as: T.self, context: path)
    }

    private func queryComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(.init(charactersIn: "/?&=#"))) ?? value
    }


    /// Who this client's calls go as, its tokens read now (once per call).
    func credentials() async throws -> CloudAPICaller.Credentials {
        let (access, refresh): (String, String)
        do { (access, refresh) = try await tokens() } catch { throw CloudAPIError.notSignedIn }
        return CloudAPICaller.Credentials(auth: sendsStackSession ? "stack" : "worker", api: baseURL, access: access,
                                          refresh: sendsStackSession ? refresh : nil, team: await teamID(),
                                          appVersion: appVersion, localOnly: backendIsLocalOnly)
    }

    /// One call; its answer as the daemon sent it.
    func call(_ name: String, _ args: [String: JSONValue], timeout: Duration = .seconds(20)) async throws -> JSONValue {
        try await caller.call(name, as: try await credentials(), args: args, timeout: timeout)
    }

    /// One call read as `T`.
    func call<T: Decodable>(_ name: String, _ args: [String: JSONValue], timeout: Duration = .seconds(20),
                            as type: T.Type) async throws -> T {
        try await caller.call(name, as: try await credentials(), args: args, timeout: timeout, decoding: T.self)
    }

    /// One call whose JSON the caller reads itself.
    func callData(_ name: String, _ args: [String: JSONValue], timeout: Duration = .seconds(20)) async throws -> Data {
        let answer = try await call(name, args, timeout: timeout)
        do { return try JSONEncoder().encode(answer) } catch { throw CloudAPIError.decoding("\(name): \(error)") }
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

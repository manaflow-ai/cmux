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
                caller: CloudAPICaller, appVersion: String = "cmux-next") {
        baseURL = configuration.apiBaseURL
        if case .localOnly = configuration.backend { backendIsLocalOnly = true } else { backendIsLocalOnly = false }
        self.tokens = tokens
        self.teamID = teamID
        self.caller = caller
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
        self.appVersion = appVersion
        sendsStackSession = false
    }

    // MARK: Machines

    /// `vm.resize`: cpu 1-32, memory 4096-65536 MiB in whole GiB, storage in 4 GiB steps up to
    /// 256 GiB (grow-only). Only the given dimensions are sent; the server checks them.
    public func resize(_ id: String, cpu: Int? = nil, memoryMb: Int? = nil, storageMb: Int? = nil) async throws {
        var args: [String: JSONValue] = ["id": .string(id)]
        if let cpu { args["cpu"] = .number(Double(cpu)) }
        if let memoryMb { args["memoryMb"] = .number(Double(memoryMb)) }
        if let storageMb { args["storageMb"] = .number(Double(storageMb)) }
        _ = try await call("vm.resize", args, timeout: .seconds(120))
    }

    public func snapshot(_ id: String, name: String?, idempotencyKey: String = UUID().uuidString) async throws -> CloudSnapshot {
        var args: [String: JSONValue] = ["id": .string(id), "idempotencyKey": .string(idempotencyKey)]
        if let name { args["name"] = .string(name) }
        return try await call("vm.snapshot", args, timeout: .seconds(300), as: CloudSnapshot.self)
    }

    public func snapshots(_ id: String) async throws -> [CloudSnapshot] {
        struct List: CloudServerModel {
            static var cloudModelKind: String { "snapshots" }
            var snapshots: [CloudSnapshot]
            init(from decoder: any Decoder) throws { snapshots = try [CloudSnapshot](from: decoder) }
        }
        return try await call("vm.snapshots", ["id": .string(id)], as: List.self).snapshots
    }

    /// Deletes a snapshot scoped to the machine that owns it.
    public func deleteSnapshot(_ id: String, snapshotID: String) async throws {
        _ = try await call("vm.delete_snapshot", ["id": .string(id), "snapshotId": .string(snapshotID)], timeout: .seconds(960))
    }

    public func restore(snapshotID: String, idempotencyKey: String = UUID().uuidString) async throws -> CloudMachine {
        try await call("vm.restore", ["snapshotId": .string(snapshotID), "idempotencyKey": .string(idempotencyKey)],
                       timeout: .seconds(620), as: CloudMachine.self)
    }

    public func fork(_ id: String, name: String?, idempotencyKey: String = UUID().uuidString) async throws -> CloudMachine {
        var args: [String: JSONValue] = ["id": .string(id), "idempotencyKey": .string(idempotencyKey)]
        if let name { args["name"] = .string(name) }
        return try await call("vm.fork", args, timeout: .seconds(620), as: CloudMachine.self)
    }

    // MARK: Files and SCP

    /// Mints a short-lived private SCP route. The public key is the only key
    /// material sent to the backend; the caller owns the corresponding secret.
    public func prepareSCP(_ id: String, publicKey: String) async throws -> CloudSCPEndpoint {
        // cmux-cloud-api refuses an unsafe route (port 22, user cmux, an ed25519 host key, not
        // expired), and cmux-cloud-machine reads it again; any other answer throws ``CloudAPIError/decoding(_:)``.
        try await call("vm.scp_endpoint", ["id": .string(id), "publicKey": .string(publicKey)], timeout: .seconds(100),
                       as: CloudSCPEndpoint.self)
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

    /// `runs.create` for a sandboxed Run (hq#3367): one task on a throwaway VM from a pinned
    /// image. The key makes a retry after a lost response return the same Run.
    /// Answers the server's JSON as is; the Run API's views already hold no secrets.
    public func createSandboxRun(task: String, agent: String? = nil, image: String? = nil, timeoutMs: Int? = nil,
                                 idempotencyKey: String = UUID().uuidString) async throws -> Data {
        try await callData("runs.create", runArgs(task: task, agent: agent, image: image, timeoutMs: timeoutMs, key: idempotencyKey))
    }

    /// `runs.wait`: the snapshot once the Run is terminal or after `timeoutMs` (the server caps it
    /// at 10 s), with its receipt when it has one.
    public func waitRun(_ id: String, timeoutMs: Int) async throws -> Data {
        let wait = max(0, min(timeoutMs, 10_000))
        return try await callData("runs.wait", ["id": .string(id), "timeoutMs": .number(Double(wait))], timeout: .milliseconds(wait + 10_000))
    }

    /// One sandboxed Run to its end (`runs.sandbox`: create it, then long-poll it until the snapshot
    /// carries its receipt, a create whose answer was lost sent once more under `idempotencyKey`).
    /// Everything (sign-in tokens included) runs under one deadline, the task's timeout plus
    /// `teardown` plus `callsMargin`, so the caller always gets an answer. Pin the team with
    /// ``pinningTeam(_:)``. With `follow` (``SandboxRunFollower``), `runs.start` creates the Run
    /// and `follow` waits in place of the poll. Answers the final snapshot
    /// (`{run, attempts, artifacts, receipt}`) as JSON.
    public func runSandbox(task: String, agent: String? = nil, timeoutMs: Int = 600_000, idempotencyKey: String = UUID().uuidString,
                           teardown: Duration = .seconds(180), callsMargin: Duration = .seconds(60),
                           follow: (@Sendable (_ id: String) async throws -> Data)? = nil) async throws -> [String: Any] {
        let bound = Duration.milliseconds(timeoutMs) + teardown + callsMargin
        let args = runArgs(task: task, agent: agent, image: nil, timeoutMs: timeoutMs, key: idempotencyKey)
        let whole = args.merging(["teardownMs": .number(Double(Self.millis(teardown))),
                                  "callsMarginMs": .number(Double(Self.millis(callsMargin)))]) { _, new in new }
        let data = try await SandboxDeadline.race(bound) {
            guard let follow else { return try await self.callData("runs.sandbox", whole, timeout: bound) }
            let created = try JSONSerialization.jsonObject(with: try await self.callData("runs.start", args, timeout: .seconds(45)))
            guard let id = (created as? [String: Any])?["id"] as? String, !id.isEmpty else {
                throw CloudAPIError.decoding("/api/runs: no run id")
            }
            return try await follow(id)
        }
        guard let snapshot = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudAPIError.decoding("/api/runs: no snapshot")
        }
        return snapshot
    }

    private func runArgs(task: String, agent: String?, image: String?, timeoutMs: Int?, key: String) -> [String: JSONValue] {
        var args: [String: JSONValue] = ["task": .string(task), "idempotencyKey": .string(key)]
        if let agent, !agent.isEmpty { args["agent"] = .string(agent) }
        if let image, !image.isEmpty { args["image"] = .string(image) }
        if let timeoutMs { args["timeoutMs"] = .number(Double(timeoutMs)) }
        return args
    }

    private static func millis(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)
    }

    /// `runs.cancel`; a sandbox's VM is destroyed before it answers.
    public func cancelRun(_ id: String) async throws -> Data {
        try await callData("runs.cancel", ["id": .string(id)], timeout: .seconds(60))
    }

    // MARK: Transport

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

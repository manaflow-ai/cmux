public import Foundation
import CmuxNextCompat
import CmuxNextWakeups

/// NEXT's Cloud API client: each call is one of the cmux daemon's `cloud.*` operations
/// (``CloudDaemon``; crate `cmux-cloud-api`), which sends the request, holds its deadline, retries
/// a lost Run create and reads every refusal. A Worker machines client
/// (CloudAPIClient+MachineRoutes.swift) goes as `worker` to cmux-platform: a machine's exec, file,
/// SCP and preview calls, the network and the publications. The sign-in client
/// (``init(configuration:tokens:teamID:daemon:appVersion:)``) keeps only the sandboxed-Run calls, as
/// `stack` (the Stack access and refresh tokens and the team); a machine call on it answers 501 at
/// once and sends nothing. Tokens come from the caller per call and are never stored here.
public struct CloudAPIClient: Sendable {
    public typealias Tokens = @Sendable () async throws -> (access: String, refresh: String)
    public typealias TeamID = @Sendable () async -> String?

    public let baseURL: URL
    let backendIsLocalOnly: Bool
    private(set) var tokens: Tokens
    private(set) var teamID: TeamID
    let daemon: CloudDaemon
    let appVersion: String
    /// The sign-in client: Stack refresh token and its team, sandboxed Runs only.
    let sendsStackSession: Bool
    /// The bundled cmux the sealed secret delivery runs (CloudAPIClient+SealedDelivery.swift).
    var machineIO: CloudMachineIO?
    /// A Worker machines client's install token, for the routes that take an install, not a session (``listNetworks()``).
    var installToken: (@Sendable () async throws -> String)?
    /// A Worker machines client's blocking-work lanes: its transfer files' disk work runs there.
    var work: BackgroundWork?

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

    /// The team requests go to now.
    public func currentTeam() async -> String? { await teamID() }

    /// This client with its team fixed to `team`: every call of a create and its retries
    /// goes to the same team whatever the app switches to meanwhile.
    /// A Worker machines client keeps its cmux team: `team` is the app's (Stack) team id.
    public func pinningTeam(_ team: String?) -> CloudAPIClient {
        guard sendsStackSession else { return self }
        var copy = self
        copy.teamID = { team }
        return copy
    }

    public init(configuration: CloudConfiguration, tokens: @escaping Tokens, teamID: @escaping TeamID, daemon: CloudDaemon,
                appVersion: String = "cmux-next") {
        baseURL = configuration.apiBaseURL
        if case .localOnly = configuration.backend { backendIsLocalOnly = true } else { backendIsLocalOnly = false }
        self.tokens = tokens
        self.teamID = teamID
        self.daemon = daemon
        self.appVersion = appVersion
        sendsStackSession = true
    }

    /// A Worker machines client (CloudAPIClient+MachineRoutes.swift).
    init(baseURL: URL, tokens: @escaping Tokens, teamID: @escaping TeamID, daemon: CloudDaemon, appVersion: String) {
        self.baseURL = baseURL
        backendIsLocalOnly = false
        self.tokens = tokens
        self.teamID = teamID
        self.daemon = daemon
        self.appVersion = appVersion
        sendsStackSession = false
    }

    // MARK: Files and SCP

    /// Mints a short-lived private SCP route (`cloud.vm.scp_endpoint`: cmux-platform's
    /// `POST /v1/cloud/machines/{id}/ssh-endpoint`, answered only when the route is safe) on a Worker
    /// machines client. The public key is the only key material sent; the caller owns the secret.
    public func prepareSCP(_ id: String, publicKey: String) async throws -> CloudSCPEndpoint {
        try requireWorker()
        return try await call("vm.scp_endpoint", ["id": id, "publicKey": publicKey], wait: .seconds(100), as: CloudSCPEndpoint.self)
    }

    /// The team's Cloud network (`cloud.vm.networks`: cmux-platform's `GET /v1/host/network/target`), sent
    /// as this Mac's install (the route refuses a Stack session). A team has one network, named by its
    /// team id, with its provider mesh as `meshId`; a team with no mesh yet has none.
    public func listNetworks() async throws -> [CloudNetwork] {
        guard !sendsStackSession, let installToken else { throw CloudAPIError.transport("the Cloud network list is a cmux API Worker route") }
        var install = self
        install.tokens = { (try await installToken(), "") }
        return try await install.call("vm.networks", wait: .seconds(20), as: [CloudNetwork].self)
    }

    // MARK: Domains and publications

    // cmux-platform's previews (docs/cloud-previews.md) on a preview client (``previewClient(baseURL:)``): a
    // publication is one machine port's preview, `vm_…:port`. The sign-in client answers 501 and sends nothing.

    /// The domains Cloud publications are served on (the platform's managed one).
    public func listDomains() async throws -> [CloudDomain] {
        try requireWorker(code: "machine.previews_unsupported")
        return try await call("vm.domains", wait: .seconds(30), as: [CloudDomain].self)
    }

    /// The signed-in person's publications in the current team.
    public func listPublications() async throws -> [CloudPublication] {
        try requireWorker(code: "machine.previews_unsupported")
        return try await call("vm.publications", wait: .seconds(30), as: [CloudPublication].self)
    }

    /// Publishes `port` of the machine behind cmux sign-in (a refresh, when it has no preview yet) and
    /// mints an API key for it in one call. Calling it again for the same port reuses the publication
    /// and mints another key.
    public func provisionAPI(machineID: String, port: Int, keyName: String? = nil) async throws -> CloudProvisionedAPI {
        try requireWorker(code: "machine.previews_unsupported")
        var args: [String: any Sendable] = ["machine": machineID, "port": port]
        if let keyName { args["keyName"] = keyName }
        return try await call("vm.provision_api", args, wait: .seconds(120), as: CloudProvisionedAPI.self)
    }

    /// The live API keys of a publication, named by its id or hostname.
    public func listPublicationAPIKeys(_ publication: String) async throws -> [CloudPublicationAPIKey] {
        try requireWorker(code: "machine.previews_unsupported")
        return try await call("vm.publication_api_keys", ["publication": publication], wait: .seconds(60), as: [CloudPublicationAPIKey].self)
    }

    /// Revokes one key; its next request is refused at the edge.
    public func revokePublicationAPIKey(_ publication: String, keyID: String) async throws -> CloudPublicationAPIKey {
        try requireWorker(code: "machine.previews_unsupported")
        return try await call("vm.revoke_publication_api_key", ["publication": publication, "keyId": keyID], wait: .seconds(60),
                              as: CloudPublicationAPIKey.self)
    }

    /// Machine, file, SCP and preview calls are cmux-platform's: the sign-in client refuses them with a
    /// 501 before any call, never a wait on a route NEXT does not serve.
    func requireWorker(code: String = "machine.unsupported") throws {
        guard !sendsStackSession else { throw CloudAPIError.http(status: 501, code: code, message: nil) }
    }

    // MARK: Runs

    /// A sandboxed Run (hq#3367, `cloud.runs.create`): one task on a throwaway VM from a pinned
    /// image. The key makes a retry after a lost answer return the same Run.
    /// Answers the server's JSON as is; the Run API's views already hold no secrets.
    public func createSandboxRun(task: String, agent: String? = nil, image: String? = nil, timeoutMs: Int? = nil,
                                 idempotencyKey: String = UUID().uuidString) async throws -> Data {
        var args: [String: any Sendable] = ["task": task, "idempotencyKey": idempotencyKey]
        if let agent, !agent.isEmpty { args["agent"] = agent }
        if let image, !image.isEmpty { args["image"] = image }
        if let timeoutMs { args["timeoutMs"] = timeoutMs }
        return try await call("runs.create", args, wait: .seconds(20))
    }

    /// The Run's snapshot once it is terminal or after `timeoutMs` (the server caps it at 10 s),
    /// with its receipt when it has one (`cloud.runs.wait`).
    public func waitRun(_ id: String, timeoutMs: Int) async throws -> Data {
        let wait = max(0, min(timeoutMs, 10_000))
        return try await call("runs.wait", ["id": id, "timeoutMs": wait], wait: .milliseconds(wait + 10_000) + CloudDaemon.lineAllowance)
    }

    /// One sandboxed Run to its end: `cloud.runs.start` (the create, sent once more under
    /// `idempotencyKey` with the same credentials when its answer was lost, so never a second paid
    /// Run; pin the team with ``pinningTeam(_:)``), then `follow` (``SandboxRunFollower``) until the
    /// Run's receipt. Everything runs under one deadline, the task's timeout plus `teardown` (boot,
    /// the last output and the VM destroy) plus `callsMargin` for the calls themselves, so the
    /// caller always gets an answer (`timedOut` past it). Answers the final snapshot
    /// (`{run, attempts, artifacts, receipt}`).
    public func runSandbox(task: String, agent: String? = nil, timeoutMs: Int = 600_000, idempotencyKey: String = UUID().uuidString,
                           teardown: Duration = .seconds(180), callsMargin: Duration = .seconds(60),
                           follow: @escaping @Sendable (_ id: String) async throws -> Data) async throws -> [String: Any] {
        let bound = Duration.milliseconds(timeoutMs) + teardown + callsMargin
        let data = try await SandboxDeadline.race(bound) {
            var args: [String: any Sendable] = ["task": task, "idempotencyKey": idempotencyKey, "timeoutMs": timeoutMs]
            if let agent, !agent.isEmpty { args["agent"] = agent }
            let created = try await self.call("runs.start", args, wait: .seconds(50))
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

    /// Cancels a Run (`cloud.runs.cancel`); a sandbox's VM is destroyed before it answers.
    public func cancelRun(_ id: String) async throws -> Data {
        try await call("runs.cancel", ["id": id], wait: .seconds(60))
    }

    // MARK: The daemon call

    /// Who this client's calls go as: the Stack session (`stack`) or the person's session at cmux-platform (`worker`).
    func route() async throws -> CloudDaemon.Route {
        let credentials: (access: String, refresh: String)
        do { credentials = try await tokens() } catch { throw CloudAPIError.notSignedIn }
        return CloudDaemon.Route(api: baseURL, auth: sendsStackSession ? .stack : .worker, credential: credentials.access,
                                 refresh: sendsStackSession ? credentials.refresh : nil, team: await teamID(),
                                 appVersion: appVersion, localOnly: backendIsLocalOnly)
    }

    /// One `cloud.<name>` call as this client; its body as JSON.
    func call(_ name: String, _ args: [String: any Sendable] = [:], wait: Duration,
              ended: (@Sendable () -> Void)? = nil) async throws -> Data {
        let route: CloudDaemon.Route
        do { route = try await self.route() } catch {
            ended?()
            throw error
        }
        return try await daemon.call(name, args, as: route, wait: wait, ended: ended)
    }

    /// ``call(_:_:wait:)`` read as `T`.
    func call<T: Decodable>(_ name: String, _ args: [String: any Sendable] = [:], wait: Duration, as type: T.Type) async throws -> T {
        try CloudMachineRules().answer(try await call(name, args, wait: wait), as: T.self, context: "cloud.\(name)")
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

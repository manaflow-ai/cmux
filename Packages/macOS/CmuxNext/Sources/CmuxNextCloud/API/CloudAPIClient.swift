public import Foundation
import CmuxNextCompat

/// The Cloud REST client. A Worker machines client (CloudAPIClient+MachineRoutes.swift) sends a
/// machine's exec, file, SCP and preview calls to cmux-platform's `/v1/cloud/machines`, the only
/// machine path. The sign-in client (``init(configuration:tokens:teamID:session:appVersion:)``)
/// keeps only the sandboxed-Run calls (`Authorization: Bearer <access>`, `X-Stack-Refresh-Token`,
/// `X-Cmux-Team-Id`); a machine call on it answers 501 at once and sends nothing. Every call has a
/// deadline; a miss is `CloudAPIError.timedOut`, never a hang. Tokens come from the caller per
/// request and are never stored here.
public struct CloudAPIClient: Sendable {
    public typealias Tokens = @Sendable () async throws -> (access: String, refresh: String)
    public typealias TeamID = @Sendable () async -> String?

    public let baseURL: URL
    let backendIsLocalOnly: Bool
    private(set) var tokens: Tokens
    private(set) var teamID: TeamID
    let session: URLSession
    let appVersion: String
    /// cmux-platform's machine routes (CloudAPIClient+MachineRoutes.swift, which says what each sends).
    let machinePath = "/v1/cloud/machines"
    /// The sign-in client: Stack refresh token and `X-Cmux-Team-Id`, sandboxed Runs only.
    let sendsStackSession: Bool
    /// A Worker machines client's exec and file routes through cmux-tui (direct to the provider
    /// with a client session); nil: straight to the cmux API (CloudAPIClient+MachineRoutes.swift).
    /// Its binary also runs the daemon's sandboxed Run ops (CloudAPIClient+DaemonCall.swift).
    var machineIO: CloudMachineIO?
    /// The `cmux cloud api` child's run (request on stdin, stdout back); nil: ``machineIO``'s. A test passes its own.
    var daemonCall: (@Sendable (_ input: Data, _ timeout: Duration) async throws -> Data)?
    /// The account a sandboxed Run's create is sent under (``runningAs(_:)``); nil: no create is sent.
    private(set) var runAccount: RunAccount?
    /// A Worker machines client's install token, for the routes that take an install, not a session (``listNetworks()``).
    var installToken: (@Sendable () async throws -> String)?
    /// Classic Cloud's Run API and Stack session (``drainingClassic(_:)``): where a Run the daemon never made drains; nil: none does.
    private(set) var classicRuns: (@Sendable () async throws -> (api: URL, access: String, refresh: String, team: String?))?

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
        var copy = self
        // A classic Run drains in the Stack team it was sent in.
        if let classic = classicRuns { copy.classicRuns = { let session = try await classic(); return (session.api, session.access, session.refresh, team) } }
        guard sendsStackSession else { return copy }
        copy.teamID = { team }
        return copy
    }

    /// This client with `classic` (the sign-in client) as where a wait or cancel of a Run the daemon never made goes:
    /// a Run the app followed from before the daemon ran Runs drains on classic Cloud's `/api/runs` to its end
    /// (cmux-cloud-api `classic_runs`), so an upgrade never drops its result. New Runs are the daemon's alone.
    public func drainingClassic(_ classic: CloudAPIClient) -> CloudAPIClient {
        var copy = self
        copy.classicRuns = {
            let session = try await classic.tokens()
            return (classic.baseURL, session.access, session.refresh, await classic.teamID())
        }
        return copy
    }

    public init(configuration: CloudConfiguration, tokens: @escaping Tokens, teamID: @escaping TeamID,
                session: URLSession = CloudAPIClient.noStoreTransport, appVersion: String = "cmux-next") {
        baseURL = configuration.apiBaseURL
        if case .localOnly = configuration.backend { backendIsLocalOnly = true } else { backendIsLocalOnly = false }
        self.tokens = tokens
        self.teamID = teamID
        self.session = session
        self.appVersion = appVersion
        sendsStackSession = true
    }

    /// A Worker machines client (CloudAPIClient+MachineRoutes.swift).
    init(baseURL: URL, tokens: @escaping Tokens, teamID: @escaping TeamID, session: URLSession, appVersion: String) {
        self.baseURL = baseURL
        backendIsLocalOnly = false
        self.tokens = tokens
        self.teamID = teamID
        self.session = session
        self.appVersion = appVersion
        sendsStackSession = false
    }

    // MARK: Files and SCP

    /// Mints a short-lived private SCP route: cmux-platform's `POST /v1/cloud/machines/{id}/ssh-endpoint` on a
    /// Worker machines client (``workerMachines(baseURL:accessToken:teamID:session:appVersion:machineIO:)``). The
    /// public key is the only key material sent; the caller owns the secret.
    public func prepareSCP(_ id: String, publicKey: String) async throws -> CloudSCPEndpoint {
        // cmux-cloud-machine reads only a safe route (port 22, user cmux, an ed25519 host key, not
        // expired); any other answer throws ``CloudAPIError/decoding(_:)``.
        try requireWorker()
        return try await send("POST", "\(machinePath)/\(id)/ssh-endpoint", body: ["publicKey": publicKey],
                       timeout: .seconds(100), as: CloudSCPEndpoint.self)
    }

    /// The team's Cloud network: cmux-platform's `GET /v1/host/network/target` on a Worker machines
    /// client, sent as this Mac's install (`installToken`; the route refuses a Stack session), never
    /// classic Cloud. A team has one network, named by its team id (what tunnel attach takes), with
    /// its provider mesh as `meshId`; a team with no mesh yet (404) has none.
    public func listNetworks() async throws -> [CloudNetwork] {
        guard !sendsStackSession, let installToken else { throw CloudAPIError.transport("the Cloud network list is a cmux API Worker route") }
        struct Target: Decodable { var team: String; var mesh: String; var ipv4_cidr: String }
        var install = self
        install.tokens = { (try await installToken(), "") }
        do {
            let target = try await install.send("GET", "/v1/host/network/target", as: Target.self)
            return [CloudNetwork(id: target.team, meshId: target.mesh, cidr: target.ipv4_cidr, cidrV6: nil, scope: "team")]
        } catch CloudAPIError.http(status: 404, code: _, message: _, action: _, traceId: _) {
            return []
        }
    }

    // MARK: Domains and publications

    // cmux-platform's previews (docs/cloud-previews.md) on a preview client (``previewClient(baseURL:)``): a
    // publication is one machine port's preview, `vm_…:port`. The sign-in client answers 501 and sends nothing.

    /// `GET /v1/cloud/domains`: the domains Cloud publications are served on (the platform's managed one).
    public func listDomains() async throws -> [CloudDomain] {
        struct List: Decodable { var domains: [CloudDomain] }
        return try await sendPreviews("GET", "/v1/cloud/domains", as: List.self).domains
    }

    /// `GET /v1/cloud/previews`: the signed-in person's publications in the current team.
    public func listPublications() async throws -> [CloudPublication] {
        struct List: Decodable { var previews: [CloudPublication] }
        return try await sendPreviews("GET", "/v1/cloud/previews", as: List.self).previews
    }

    /// `POST /v1/cloud/machines/{id}/previews/{port}/api-keys`: publishes `port` of the machine behind
    /// cmux sign-in (a refresh, when it has no preview yet) and mints an API key for it in one call.
    /// Calling it again for the same port reuses the publication and mints another key.
    public func provisionAPI(machineID: String, port: Int, keyName: String? = nil) async throws -> CloudProvisionedAPI {
        let body: [String: any Sendable] = keyName.map { ["name": $0] } ?? [:]
        return try await sendPreviews("POST", "\(machinePath)/\(queryComponent(machineID))/previews/\(port)/api-keys", body: body,
                                      timeout: .seconds(120), as: CloudProvisionedAPI.self)
    }

    /// The live API keys of a publication, named by its id or hostname.
    public func listPublicationAPIKeys(_ publication: String) async throws -> [CloudPublicationAPIKey] {
        struct List: Decodable { var apiKeys: [CloudPublicationAPIKey] }
        return try await sendPreviews("GET", "\(try await publicationPath(publication))/api-keys", as: List.self).apiKeys
    }

    /// Revokes one key; its next request is refused at the edge.
    public func revokePublicationAPIKey(_ publication: String, keyID: String) async throws -> CloudPublicationAPIKey {
        struct Revoked: Decodable { var apiKey: CloudPublicationAPIKey }
        let path = "\(try await publicationPath(publication))/api-keys/\(queryComponent(keyID))"
        return try await sendPreviews("DELETE", path, as: Revoked.self).apiKey
    }

    /// `/v1/cloud/machines/{id}/previews/{port}` of the publication whose id or hostname is `publication`.
    private func publicationPath(_ publication: String) async throws -> String {
        guard let found = try await listPublications().first(where: { $0.id == publication || $0.hostname == publication }),
              let machine = found.vmId, let port = found.port else {
            throw CloudAPIError.http(status: 404, code: "cloud.preview.not_found", message: "no such publication: \(publication)")
        }
        return "\(machinePath)/\(queryComponent(machine))/previews/\(port)"
    }

    private func sendPreviews<T: Decodable>(_ method: String, _ path: String, body: [String: any Sendable]? = nil,
                                            timeout: Duration = .seconds(20), as type: T.Type) async throws -> T {
        try requireWorker(code: "machine.previews_unsupported")
        return try await send(method, path, body: body, timeout: timeout, as: type)
    }

    /// Machine, file, SCP and preview calls are cmux-platform's: the sign-in client refuses them with a
    /// 501 before any request, never a wait on a route NEXT does not serve.
    func requireWorker(code: String = "machine.unsupported") throws {
        guard !sendsStackSession else { throw CloudAPIError.http(status: 501, code: code, message: nil) }
    }

    func query(_ value: String) -> String {
        // Keep guest path separators readable, but never let a path inject a
        // second query item or fragment into the request URL.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~/"))
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func queryComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(.init(charactersIn: "/?&=#"))) ?? value
    }

    // MARK: Runs

    /// The daemon's `cloud.runs.create` for a sandboxed Run (hq#3367): one task in a Cloud chat on a new
    /// small machine, deleted after (cmux-tui `cloud.runs.*`). The key makes a retry after a lost answer return the
    /// same Run. Answers the Run's view as JSON; it holds no secrets. A non-empty `image` is refused (`run_image_invalid`).
    /// This client with the account the person is sending a Run under, read as they send it
    /// (``CloudAuth/runAccount``). Every sandboxed Run's create needs one: without it none is sent.
    public func runningAs(_ account: RunAccount?) -> CloudAPIClient {
        var copy = self
        copy.runAccount = account
        return copy
    }

    /// The app's Cloud account a send was made under (its user id and its team id, nil: personal).
    public struct RunAccount: Sendable, Equatable {
        public var user: String
        public var team: String?
        public init(user: String, team: String?) {
            self.user = user
            self.team = team
        }
    }

    /// It goes under ``runningAs(_:)``'s account, the one the person sent under (none: `notSignedIn`, nothing sent);
    /// the daemon refuses the create (`run_account_changed`) when the app is on another one by then, so a switch
    /// never sends the task elsewhere. An `incognito` Run's reply and error are never written to the daemon's store.
    public func createSandboxRun(task: String, agent: String? = nil, image: String? = nil, timeoutMs: Int? = nil,
                                 idempotencyKey: String = UUID().uuidString, incognito: Bool = false) async throws -> Data {
        guard let runAccount else { throw CloudAPIError.notSignedIn }
        var args: [String: any Sendable] = ["task": task, "idempotencyKey": idempotencyKey,
                                            "expectedAccount": ["user_id": runAccount.user, "team_id": runAccount.team ?? ""] as [String: any Sendable]]
        if incognito { args["incognito"] = true }
        if let agent, !agent.isEmpty { args["agent"] = agent }
        if let image, !image.isEmpty { args["image"] = image }
        if let timeoutMs { args["timeoutMs"] = timeoutMs }
        return try await daemon("runs.create", args, timeout: .seconds(20))
    }

    /// The daemon's `cloud.runs.wait`: the snapshot once the Run is terminal or after
    /// `timeoutMs` (held at most 10 s), with its receipt when it has one.
    public func waitRun(_ id: String, timeoutMs: Int) async throws -> Data {
        let wait = max(0, min(timeoutMs, 10_000))
        return try await daemon("runs.wait", ["id": id, "timeoutMs": wait], timeout: .milliseconds(wait + 10_000))
    }

    /// One sandboxed Run to its end: create it, then long-poll ``waitRun(_:timeoutMs:)`` (10 s a
    /// call) until the snapshot carries its receipt. Everything (sign-in tokens included) runs under
    /// one deadline, the task's timeout plus `teardown` (boot, the last output and the VM destroy)
    /// plus a minute for the calls themselves, so the caller always gets an answer. The poll stops
    /// at the receipt, at the first error, or at that deadline (`timedOut`); the daemon deletes
    /// the machine either way. `idempotencyKey` names this one send: a create whose answer was lost is
    /// sent once more under it, which returns the same Run, never a second paid one; after a switch of
    /// account the daemon refuses it (`run_account_changed`) rather than start one under the new account, as it
    /// refuses any create once the app is off ``runningAs(_:)``'s account. Answers the final
    /// snapshot (`{run, attempts, artifacts, receipt}`) as JSON. `follow` (``SandboxRunFollower``) waits in place of the poll here.
    public func runSandbox(task: String, agent: String? = nil, timeoutMs: Int = 600_000, idempotencyKey: String = UUID().uuidString,
                           incognito: Bool = false,
                           teardown: Duration = .seconds(180), callsMargin: Duration = .seconds(60),
                           now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }, follow: (@Sendable (_ id: String) async throws -> Data)? = nil) async throws -> [String: Any] {
        let bound = Duration.milliseconds(timeoutMs) + teardown + callsMargin
        let data = try await SandboxDeadline.race(bound) {
            try await self.sandboxSnapshot(task: task, agent: agent, timeoutMs: timeoutMs, key: idempotencyKey, incognito: incognito,
                                           deadline: now() + .milliseconds(timeoutMs) + teardown, now: now, follow: follow)
        }
        guard let snapshot = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudAPIError.decoding("cloud.runs: no snapshot")
        }
        return snapshot
    }

    private func sandboxSnapshot(task: String, agent: String?, timeoutMs: Int, key: String, incognito: Bool, deadline: ContinuousClock.Instant,
                                 now: @Sendable () -> ContinuousClock.Instant, follow: (@Sendable (String) async throws -> Data)?) async throws -> Data {
        // The create and its retry go with one account's credentials, read once.
        let credentials: (access: String, refresh: String)
        do { credentials = try await tokens() } catch { throw CloudAPIError.notSignedIn }
        var pinned = self
        pinned.tokens = { credentials }
        // An incognito create goes to classic Cloud with the session read here, once, as the daemon's credentials are.
        if incognito, let classicRuns, let classic = try? await classicRuns() { pinned.classicRuns = { classic } }
        let create = { try await pinned.createSandboxRun(task: task, agent: agent, timeoutMs: timeoutMs, idempotencyKey: key,
                                                                   incognito: incognito) }
        let createdData: Data
        do {
            createdData = try await create()
        } catch CloudAPIError.transport, CloudAPIError.timedOut {
            // The first create may have made the Run: whatever the retry says, the outcome stays
            // uncertain (`timedOut`, never a refusal the caller could take as "nothing runs").
            do { createdData = try await create() } catch { throw CloudAPIError.timedOut("cloud.runs") }
        }
        let created = try JSONSerialization.jsonObject(with: createdData) as? [String: Any]
        guard let id = created?["id"] as? String, !id.isEmpty else { throw CloudAPIError.decoding("cloud.runs: no run id") }
        if let follow { return try await follow(id) }
        while now() < deadline {
            let data: Data
            do {
                data = try await waitRun(id, timeoutMs: 10_000)
            } catch { // The Run exists: losing sight of it is "no receipt in time", never a refusal to retry past.
                throw CloudAPIError.timedOut("cloud.runs/\(id)")
            }
            // A 200 that is no Run snapshot (an array, an error body) won't turn into one: stop now.
            guard let snapshot = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  snapshot["run"] is [String: Any] else { throw CloudAPIError.timedOut("cloud.runs/\(id)") }
            if snapshot["receipt"] is [String: Any] { return data }
            try Task.checkCancellation()
        }
        throw CloudAPIError.timedOut("cloud.runs/\(id)")
    }

    /// The daemon's `cloud.runs.cancel`; the Run's machine is deleted before it answers.
    public func cancelRun(_ id: String) async throws -> Data {
        try await daemon("runs.cancel", ["id": id], timeout: .seconds(60))
    }

    // MARK: Transport

    struct Ignored: Decodable {}

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
        try await race(bound, timeout: { CloudAPIError.timedOut("cloud.runs") }, work)
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

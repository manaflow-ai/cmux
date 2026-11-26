import CmuxEgress
public import CMUXAuthCore
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
    /// A tagged dev build's cloud data space, sent on every request (``CloudConfiguration/buildSpace``); none for nightly; a misconfigured dev build's requests throw.
    let buildSpace: CMUXBuildSpaceState
    /// cmux-platform's machine routes (CloudAPIClient+MachineRoutes.swift, which says what each sends).
    let machinePath = "/v1/cloud/machines"
    /// The sign-in client: Stack refresh token and `X-Cmux-Team-Id`, sandboxed Runs only.
    let sendsStackSession: Bool
    /// The daemon's calls (CloudDaemon.swift): Runs and sealed secrets. It holds the bundled cmux (`machineIO`) and the
    /// Run account and classic session; this client's team pin and machine reach carry through.
    public internal(set) var daemon: CloudDaemon
    /// A Worker machines client's exec and file routes through cmux-tui (direct to the provider
    /// with a client session); nil: straight to the cmux API (CloudAPIClient+MachineRoutes.swift).
    var machineIO: CloudMachineIO? {
        get { daemon.machineIO }
        set { daemon.machineIO = newValue }
    }
    /// A Worker machines client's install token, for the routes that take an install, not a session (``listNetworks()``).
    var installToken: (@Sendable () async throws -> String)?

    /// Requests that carry the account's bearer token: ephemeral, no URL
    /// cache, no cookies, so no answer (or the request headers stored with
    /// it) lands in `~/Library/Caches/<bundle id>/Cache.db`.
    public static let noStoreTransport: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        return CmuxEgress.session(site: "CmuxNextCloud.CloudAPIClient", configuration: configuration)
    }()

    /// The team requests go to now (`X-Cmux-Team-Id`).
    public func currentTeam() async -> String? { await teamID() }

    /// This client with its team fixed to `team`: every request of a create and its retries
    /// goes to the same team whatever the app switches to meanwhile.
    /// A Worker machines client keeps its cmux team: `team` is the app's (Stack) team id.
    public func pinningTeam(_ team: String?) -> CloudAPIClient {
        var copy = self
        copy.daemon = daemon.pinningTeam(team)
        guard sendsStackSession else { return copy }
        copy.teamID = { team }
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
        buildSpace = configuration.buildSpace
        sendsStackSession = true
        daemon = CloudDaemon(baseURL: baseURL, tokens: tokens, teamID: teamID, appVersion: appVersion, sendsStackSession: true)
    }

    /// A Worker machines client (CloudAPIClient+MachineRoutes.swift).
    init(baseURL: URL, tokens: @escaping Tokens, teamID: @escaping TeamID, session: URLSession, appVersion: String,
         buildSpace: CMUXBuildSpaceState = .nightly) {
        self.baseURL = baseURL
        backendIsLocalOnly = false
        self.tokens = tokens
        self.teamID = teamID
        self.session = session
        self.appVersion = appVersion
        self.buildSpace = buildSpace
        sendsStackSession = false
        daemon = CloudDaemon(baseURL: baseURL, tokens: tokens, teamID: teamID, appVersion: appVersion, sendsStackSession: false)
    }

    // MARK: Files and SCP

    /// Mints a short-lived private SCP route: the daemon's `vm.scp_endpoint` (cmux-platform's
    /// `POST /v1/cloud/machines/{id}/ssh-endpoint`) on a Worker machines client
    /// (``workerMachines(baseURL:accessToken:teamID:session:appVersion:machineIO:)``). The public key is the only
    /// key material sent; the caller owns the secret.
    public func prepareSCP(_ id: String, publicKey: String) async throws -> CloudSCPEndpoint {
        // Rust answers only a safe route (port 22, user cmux, an ed25519 host key, not expired) and
        // cmux-cloud-machine reads it again; any other answer throws ``CloudAPIError/decoding(_:)``.
        try requireWorker()
        // The route's own deadline is 100 s in Rust; this one only bounds a child that hangs.
        let body = try await cloudCall("vm.scp_endpoint", ["id": id, "publicKey": publicKey], timeout: .seconds(130))
        return try CloudMachineRules().answer(body, as: CloudSCPEndpoint.self, context: "\(machinePath)/\(id)/ssh-endpoint")
    }

    /// The team's Cloud network: the daemon's `vm.networks` (cmux-platform's `GET /v1/host/network/target`)
    /// on a Worker machines client, sent as this Mac's install (`installToken`, auth `worker`; the route
    /// refuses a Stack session), never classic Cloud. A team has one network, named by its team id (what
    /// tunnel attach takes), with its provider mesh as `meshId`; a team with no mesh yet (404) has none.
    public func listNetworks() async throws -> [CloudNetwork] {
        guard !sendsStackSession, let installToken else { throw CloudAPIError.transport("the Cloud network list is a cmux API Worker route") }
        try buildSpace.check()
        var install = daemon
        install.tokens = { (try await installToken(), "") }
        let body = try await install.daemon("vm.networks", [:], timeout: .seconds(50), auth: "worker")
        do {
            return try JSONDecoder().decode([CloudNetwork].self, from: body)
        } catch {
            throw CloudAPIError.decoding("cloud.vm.networks: \(error)")
        }
    }

    // MARK: Domains and publications

    // cmux-platform's previews (docs/cloud-previews.md) on a preview client (``previewClient(baseURL:)``), sent by the
    // daemon (cmux-cloud-api `previews.rs`): a publication is one machine port's preview, `vm_…:port`. The sign-in
    // client answers 501 and sends nothing.

    /// The daemon's `cloud.vm.domains`: the domains Cloud publications are served on (the platform's managed one).
    public func listDomains() async throws -> [CloudDomain] {
        try await previewCall("vm.domains", [:], as: [CloudDomain].self)
    }

    /// The daemon's `cloud.vm.publications`: the signed-in person's publications in the current team.
    public func listPublications() async throws -> [CloudPublication] {
        try await previewCall("vm.publications", [:], as: [CloudPublication].self)
    }

    /// The daemon's `cloud.vm.provision_api`: publishes `port` of the machine behind cmux sign-in (a refresh,
    /// when it has no preview yet) and mints an API key for it in one call. Calling it again for the same
    /// port reuses the publication and mints another key.
    public func provisionAPI(machineID: String, port: Int, keyName: String? = nil) async throws -> CloudProvisionedAPI {
        var args: [String: any Sendable] = ["machine": machineID, "port": port]
        if let keyName { args["keyName"] = keyName }
        return try await previewCall("vm.provision_api", args, timeout: .seconds(125), as: CloudProvisionedAPI.self)
    }

    /// The daemon's `cloud.vm.publication_api_keys`: the live API keys of a publication, named by its id or
    /// hostname (the daemon resolves it from the publication list, so two bounded requests).
    public func listPublicationAPIKeys(_ publication: String) async throws -> [CloudPublicationAPIKey] {
        try await previewCall("vm.publication_api_keys", ["publication": publication], timeout: .seconds(65),
                              as: [CloudPublicationAPIKey].self)
    }

    /// The daemon's `cloud.vm.revoke_publication_api_key`: revokes one key; its next request is refused at the edge.
    public func revokePublicationAPIKey(_ publication: String, keyID: String) async throws -> CloudPublicationAPIKey {
        try await previewCall("vm.revoke_publication_api_key", ["publication": publication, "keyId": keyID],
                              timeout: .seconds(65), as: CloudPublicationAPIKey.self)
    }

    /// One preview or publication call through the daemon, its body decoded as `type`. The daemon bounds
    /// each request at 30 s (120 s for a key's create); `timeout` bounds the child a little past that.
    func previewCall<T: Decodable>(_ call: String, _ args: [String: any Sendable], timeout: Duration = .seconds(35),
                                   as type: T.Type) async throws -> T {
        try requireWorker(code: "machine.previews_unsupported")
        try buildSpace.check()
        let data = try await daemon.daemon(call, args, timeout: timeout)
        return try CloudMachineRules().answer(data, as: T.self, context: "cloud.\(call)")
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

    // MARK: Transport

    struct Ignored: Decodable {}

    /// One request whose JSON body the caller reads itself.
    public func sendData(_ method: String, _ path: String, body: [String: any Sendable]? = nil, idempotencyKey: String? = nil,
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
        try buildSpace.apply(to: &request)
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

/// The machine routes' daemon calls: ``daemon``'s one transport (CloudMachineIO.swift), after the build space check
/// ``send`` makes (a misconfigured dev build refuses before anything runs).
extension CloudAPIClient {
    func cloudCall(_ call: String, _ args: [String: any Sendable], timeout: Duration, auth: String = "owner") async throws -> Data {
        try buildSpace.check()
        return try await daemon.daemon(call, args, timeout: timeout, auth: auth)
    }
}

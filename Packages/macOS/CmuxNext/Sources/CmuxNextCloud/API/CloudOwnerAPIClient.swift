import CmuxEgress
public import CMUXAuthCore
public import Foundation

/// The person's own calls on the cmux-next API Worker (`ownerAPIBaseURL`; cx-kvmz), outside the op path: the keyed
/// acpmux start and its person_holds check on a Cloud machine of the app server link, a fork run, the person's
/// hand-offs and their turns (CloudHandoffs.swift, CloudHandoffTurns.swift) and the GitHub App routes.
///
/// Every call but the keyed start is the daemon's `cloud.owner.*` (cmux-cloud-api `owner.rs`, through the bundled
/// cmux's `cmux cloud api`; ``daemon(_:_:timeout:)``): the requests, their deadlines and every refusal's reading are
/// Rust's, and this type only forwards.
///
/// The keyed start stays here on purpose: the person key never goes through `apps-run`, the local daemon or a Cloud
/// op. Here it lives in one zeroed buffer and goes straight into one request body stream, never a `Data` or `String`
/// copy (cx-kvmz, #13742 D16); through the daemon it would be copied into the child's stdin, the daemon's JSON
/// params and its connection reader, none of which is wiped (#37350 says so). The person_holds check carries no key
/// (the proof is checked here against the key the daemon never sees), so it is the daemon's.
///
/// The keyed start sets only `Authorization` (the Stack session, which the Worker's logs mask), `Content-Type`,
/// `Content-Length`, `x-cmux-team` and, on a tagged dev build, `X-Cmux-Build-Space` (`dev:<slug>`, the build's
/// public tag); URLSession adds `User-Agent`, `Accept`, `Accept-Language`, `Accept-Encoding` and `Host`, none of
/// which holds a credential. The Worker's invocation logs (on in development) record the URL and every header but
/// Authorization, so nothing outside the body may hold a key. No cache, no cookies, no redirect is followed, and
/// nothing is retried.
public struct CloudOwnerAPIClient: Sendable {
    public struct ForkRunChild: Sendable, Equatable, Decodable {
        public var id: String
        public var harness: String
        public var state: String
        public var machineId: String?
        public var error: String?

        public init(id: String, harness: String, state: String, machineId: String?, error: String?) {
            self.id = id
            self.harness = harness
            self.state = state
            self.machineId = machineId
            self.error = error
        }
    }
    public typealias AccessToken = @Sendable () async throws -> String
    /// The cmux team (`team_…`) whose machine this is: the install token's team claim.
    public typealias TeamID = @Sendable () async -> String?

    public let baseURL: URL
    let accessToken: AccessToken
    let teamID: TeamID
    let session: URLSession
    /// A tagged dev build's cloud data space (``CloudConfiguration/buildSpace``); none for nightly; a misconfigured dev build's requests throw.
    let buildSpace: CMUXBuildSpaceState

    /// The bundled cmux that runs the daemon's calls (``CloudAuth/machineIO``); nil: they answer "cmux is not available".
    let machineIO: CloudMachineIO?
    /// The `cmux cloud api` child's run (request on stdin, stdout back); nil: ``machineIO``'s. A test passes its own.
    var daemonCall: (@Sendable (_ input: Data, _ timeout: Duration) async throws -> Data)?

    public init(baseURL: URL, accessToken: @escaping AccessToken, teamID: @escaping TeamID, buildSpace: CMUXBuildSpaceState,
                machineIO: CloudMachineIO? = nil) {
        self.baseURL = baseURL
        self.accessToken = accessToken
        self.teamID = teamID
        self.buildSpace = buildSpace
        self.machineIO = machineIO
        session = Self.transport
    }

    /// `cloud.<call>` with `args` on the daemon, as this person (`auth: owner`) in ``teamID``'s team: its body as JSON,
    /// or its failure as a ``CloudAPIError`` (``CloudDaemon/daemon(_:_:timeout:)``). `timeout` bounds the child; a
    /// misconfigured dev build refuses before anything runs.
    func daemon(_ call: String, _ args: [String: any Sendable], timeout: Duration) async throws -> Data {
        try buildSpace.check()
        let accessToken = accessToken
        var client = CloudDaemon.workerMachines(baseURL: baseURL, accessToken: { try await accessToken() }, teamID: teamID,
                                                   machineIO: machineIO, buildSpace: buildSpace)
        client.daemonCall = daemonCall
        return try await client.daemon(call, args, timeout: timeout)
    }

    /// The daemon's bound for a call whose own deadline (Rust's) is `deadline`: its answer comes back before the child is killed.
    static func bound(_ deadline: Duration) -> Duration { deadline + .seconds(10) }

    /// `request` with the person's session (`access`), the cmux team and the build space: every header this
    /// client sets besides the body's `Content-Type` and `Content-Length`.
    func authorized(_ request: URLRequest, access: String) async throws -> URLRequest {
        var request = request
        request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        if let team = await teamID() { request.setValue(team, forHTTPHeaderField: "x-cmux-team") }
        try buildSpace.apply(to: &request)
        return request
    }

    /// `POST /v1/cloud/machines/{machine}/acpmux/keyed-start`: restarts the machine's acpmux with
    /// this app's person key. `writeKey` writes the key line (`keyLineLength` bytes) into the body
    /// stream from the caller's own zeroed buffer: no `Data` or `String` copy here, and a stream
    /// body is never resent. Answers the new
    /// daemon run (`personInstance`).
    public func acpmuxKeyedStart(_ machine: String, keyLineLength: Int, writeKey: (OutputStream) -> Bool) async throws -> String {
        var input: InputStream?
        var output: OutputStream?
        Stream.getBoundStreams(withBufferSize: keyLineLength * 2, inputStream: &input, outputStream: &output)
        guard let input, let output else { throw CloudAPIError.transport("no request body stream") }
        output.open()
        let wrote = writeKey(output)
        output.close()
        guard wrote else { throw CloudAPIError.transport("the key did not reach the request body") }
        struct Started: Decodable { var personInstance: String }
        return try await post(machine, "keyed-start", body: .stream(input, keyLineLength, "application/octet-stream"),
                              timeout: .seconds(100), as: Started.self).personInstance
    }

    /// `cloud.owner.acpmux_person_holds` (`POST /v1/cloud/machines/{machine}/acpmux/person-holds {nonce}`, 40 s): what
    /// the machine's acpmux answers to `_acpmux/person_holds`. The caller checks the proof against its own key.
    public func acpmuxPersonHolds(_ machine: String, nonce: String) async throws -> (instance: String, proof: String) {
        struct Holds: Decodable { var instance: String; var proof: String }
        let data = try await daemon("owner.acpmux_person_holds", ["machine": machine, "nonce": nonce], timeout: Self.bound(.seconds(40)))
        let holds = try CloudMachineRules().answer(data, as: Holds.self, context: "cloud.owner.acpmux_person_holds")
        return (holds.instance, holds.proof)
    }

    /// `cloud.owner.fork_run` (`POST /v1/workspaces/{workspace}/fork-runs`, 180 s): snapshots the source machine now and
    /// creates one durable child for each requested harness. The platform intentionally has no checkpoint argument;
    /// transcript cut is performed by the child acpmux after it is ready.
    public func forkRun(workspace: String, clientKey: String, sourceMachine: String, session: String,
                        harnesses: [String]) async throws -> [ForkRunChild] {
        struct Run: Decodable { var children: [ForkRunChild] }
        let args: [String: any Sendable] = ["verb": "start", "workspace": workspace, "clientKey": clientKey,
                                            "sourceMachine": sourceMachine, "session": session, "harnesses": harnesses]
        let data = try await daemon("owner.fork_run", args, timeout: Self.bound(.seconds(180)))
        return try CloudMachineRules().answer(data, as: Run.self, context: "cloud.owner.fork_run").children
    }

    enum Body {
        case stream(InputStream, Int, String)
    }

    func post<T: Decodable>(_ machine: String, _ action: String, body: Body, timeout: Duration, as type: T.Type) async throws -> T {
        // The machine id is the only path part that varies; anything else is refused before a request.
        guard machine.range(of: #"^vm_[a-z0-9]{20}$"#, options: .regularExpression) != nil else {
            throw CloudAPIError.transport("not a Cloud machine id")
        }
        let path = "/v1/cloud/machines/\(machine)/acpmux/\(action)"
        let access: String
        do { access = try await accessToken() } catch { throw CloudAPIError.notSignedIn }
        guard let url = URL(string: baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path) else {
            throw CloudAPIError.transport("bad path \(path)")
        }
        var request = URLRequest(url: url, timeoutInterval: TimeInterval(timeout.components.seconds))
        request.httpMethod = "POST"
        // RULE (cx-kvmz, hq-84): this client sets only these headers: Authorization (the
        // Worker's invocation log masks it), Content-Type, Content-Length, x-cmux-team and the
        // build space (the build's public tag). The log records every other header and the URL, so
        // no other header, no query and no path part that could hold a key may ever be added here.
        request = try await authorized(request, access: access)
        switch body {
        case let .stream(stream, length, contentType):
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            request.setValue(String(length), forHTTPHeaderField: "Content-Length")
            request.httpBodyStream = stream
        }
        let data: Data
        let response: URLResponse
        do {
            let session = session, prepared = request
            (data, response) = try await withDeadline(timeout, label: "POST \(path)") { try await session.data(for: prepared) }
        } catch is DeadlineExceeded {
            throw CloudAPIError.timedOut(path)
        } catch let error as URLError where error.code == .timedOut {
            throw CloudAPIError.timedOut(path)
        } catch {
            throw CloudAPIError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw CloudAPIError.transport("no HTTP response") }
        // The Worker's shape: {ok: true, value} or {ok: false, error: {code, message}}.
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(http.statusCode), object?["ok"] as? Bool == true, let value = object?["value"] else {
            let error = object?["error"] as? [String: Any]
            throw CloudAPIError.http(status: http.statusCode, code: error?["code"] as? String, message: error?["message"] as? String)
        }
        guard let reply = try? JSONSerialization.data(withJSONObject: value) else { throw CloudAPIError.decoding("\(path): not JSON") }
        return try CloudMachineRules().answer(reply, as: T.self, context: path)
    }

    /// No cache, no cookies, and redirects refused: the Stack bearer never follows one.
    public static let transport: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        return CmuxEgress.session(site: "CmuxNextCloud.CloudOwnerAPIClient", configuration: configuration, delegate: RefuseRedirects(), delegateQueue: nil)
    }()

    private final class RefuseRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}

/// The Slack integration's calls (Settings' Slack page): cmux-cloud-api's `owner.slack` and `owner.slack_awake`
/// (`slack.rs`) send them, wait 20 s and check the answers; the app only names the call.
extension CloudDaemon {
    /// One of the three fixed Slack routes by its HTTP method (`GET` the connection, `POST` an install link,
    /// `DELETE` the connection, answered `{}`), or "use your own bot name" (`ownBot`: `POST /v1/slack/apps`).
    /// Sent with this Mac's install token (auth `worker`). The configuration token goes to the daemon on stdin, in this
    /// one request; nothing here stores, caches or logs it, and a refusal of it carries no text the service wrote.
    public func slackRequest(method: String, ownBot: (configToken: String, name: String?)? = nil) async throws -> Data {
        var args: [String: any Sendable]
        if let ownBot {
            args = ["route": "create_app", "configToken": ownBot.configToken]
            if let name = ownBot.name { args["name"] = name }
        } else {
            switch method {
            case "GET": args = ["route": "connection"]
            case "POST": args = ["route": "install_link"]
            case "DELETE": args = ["route": "disconnect"]
            default: throw CloudAPIError.transport("unsupported Slack request method")
            }
        }
        return try await daemon("owner.slack", args, timeout: CloudOwnerAPIClient.bound(.seconds(20)), auth: "worker")
    }

    /// RFD 0123's owner setting: `GET /v1/chiefs/<chief>/slack-awake?days=7` when `allowance` is nil, else `PUT`
    /// `{allowance_seconds}` (`.some(nil)`: back to the 2 h default), with the person's own Stack session (auth `owner`).
    /// `chief` is an `agent_` id; anything else never leaves the app. Answers the reply's `value`.
    public func slackAwake(chief: String, allowance: Int?? = nil) async throws -> Data {
        guard Self.isChiefID(chief) else { throw CloudAPIError.transport("not a Chief id") }
        var args: [String: any Sendable] = ["chief": chief]
        if case .some(let seconds) = allowance { args["allowance"] = seconds.map { $0 as any Sendable } ?? NSNull() }
        return try await daemon("owner.slack_awake", args, timeout: CloudOwnerAPIClient.bound(.seconds(20)), auth: "owner")
    }

    /// A Chief id: `agent_` and 26 Crockford base32 digits (cmux-cloud-api checks it again).
    static func isChiefID(_ id: String) -> Bool {
        id.range(of: #"^agent_[0-9A-HJKMNP-TV-Z]{26}$"#, options: .regularExpression) != nil
    }
}

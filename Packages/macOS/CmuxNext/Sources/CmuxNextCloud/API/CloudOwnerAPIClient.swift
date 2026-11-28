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
/// The keyed start carries the person key as the call's stdin tail, never an argv, JSON or env value (``acpmuxKeyedStart``).
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
    }

    /// `cloud.<call>` with `args` on the daemon, as this person (`auth: owner`) in ``teamID``'s team: its body as JSON,
    /// or its failure as a ``CloudAPIError`` (``CloudDaemon/daemon(_:_:timeout:)``). `timeout` bounds the child; a
    /// misconfigured dev build refuses before anything runs.
    func daemon(_ call: String, _ args: [String: any Sendable], timeout: Duration, tail: Data? = nil) async throws -> Data {
        try buildSpace.check()
        let accessToken = accessToken
        var client = CloudDaemon.workerMachines(baseURL: baseURL, accessToken: { try await accessToken() }, teamID: teamID,
                                                   machineIO: machineIO, buildSpace: buildSpace)
        client.daemonCall = daemonCall
        return try await client.daemon(call, args, timeout: timeout, tail: tail)
    }

    /// The daemon's bound for a call whose own deadline (Rust's) is `deadline`: its answer comes back before the child is killed.
    static func bound(_ deadline: Duration) -> Duration { deadline + .seconds(10) }

    /// `cloud.owner.acpmux_keyed_start` (`POST /v1/cloud/machines/{machine}/acpmux/keyed-start`, 100 s): restarts the
    /// machine's acpmux with this app's person key. `writeKey` writes the key line (`keyLineLength` bytes) from the
    /// caller's own zeroed buffer; the bytes go to the `cmux cloud api` child as the call's stdin tail (never argv or
    /// JSON) and Rust sends them as the request body only, wiping them after (`owner.rs`); this copy is zeroed once the
    /// child has them. Answers the new daemon run (`personInstance`). The call is never retried.
    public func acpmuxKeyedStart(_ machine: String, keyLineLength: Int, writeKey: (OutputStream) -> Bool) async throws -> String {
        let stream = OutputStream.toMemory()
        stream.open()
        let wrote = writeKey(stream)
        stream.close()
        guard wrote, var key = stream.property(forKey: .dataWrittenToMemoryStreamKey) as? Data, key.count == keyLineLength else {
            throw CloudAPIError.transport("the key did not reach the request body")
        }
        defer { key.resetBytes(in: 0..<key.count) }
        struct Started: Decodable { var personInstance: String }
        let data = try await daemon("owner.acpmux_keyed_start", ["machine": machine, "key_length": keyLineLength],
                                    timeout: Self.bound(.seconds(100)), tail: key)
        return try CloudMachineRules().answer(data, as: Started.self, context: "cloud.owner.acpmux_keyed_start").personInstance
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

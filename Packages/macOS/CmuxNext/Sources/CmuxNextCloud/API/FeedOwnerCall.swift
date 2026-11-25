public import CMUXAuthCore
public import Foundation

/// The feed's own calls on the cmux API Worker (`POST /v1/ops` and `/v1/read`, `ownerAPIBaseURL`): the
/// daemon's `cloud.owner.op` (cmux-cloud-api `owner.rs`, through the bundled cmux's `cmux cloud api`), as the
/// person's session (`FeedService.call`) or this Mac's install token (`FeedInstallPrincipal.call`). The request,
/// its headers and its deadline are Rust's; this only forwards the body and reads the reply.
public struct FeedOwnerCall: Sendable {
    public typealias Credential = @Sendable () async throws -> String
    public typealias TeamID = @Sendable () async -> String?

    /// The route: `ops` (`POST /v1/ops`) or `read` (`POST /v1/read`).
    public enum Route: String, Sendable {
        case ops
        case read

        /// `v1/ops` or `v1/read`, the paths the feed's callers name.
        public init?(path: String) {
            switch path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) {
            case "v1/ops": self = .ops
            case "v1/read": self = .read
            default: return nil
            }
        }
    }

    /// The Worker's reply: its HTTP status and its body when that is a JSON object.
    public struct Reply: Sendable {
        public var status: Int
        /// The body as JSON text (a Sendable value); nil when the Worker's body was not a JSON object.
        var bodyJSON: Data?

        /// The body, parsed: nil when it was not a JSON object.
        public var body: [String: Any]? {
            bodyJSON.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
        }
    }

    let baseURL: URL
    let credential: Credential
    let teamID: TeamID
    let buildSpace: CMUXBuildSpaceState
    let machineIO: CloudMachineIO?
    let clientVersion: String?
    /// The `cmux cloud api` child's run (request on stdin, stdout back); nil: ``machineIO``'s. A test passes its own.
    var daemonCall: (@Sendable (_ input: Data, _ timeout: Duration) async throws -> Data)?

    /// `credential` is the bearer (the Stack session or an install token); `teamID` the `x-cmux-team` (nil:
    /// none); `clientVersion` goes as `x-cmux-client-version` (the app's version, no secret).
    public init(baseURL: URL, credential: @escaping Credential, teamID: @escaping TeamID = { nil },
                buildSpace: CMUXBuildSpaceState, machineIO: CloudMachineIO?, clientVersion: String? = nil) {
        self.baseURL = baseURL
        self.credential = credential
        self.teamID = teamID
        self.buildSpace = buildSpace
        self.machineIO = machineIO
        self.clientVersion = clientVersion
    }

    /// Rust's deadline for the request is 15 s; the child gets 10 s more to answer.
    static let bound: Duration = .seconds(25)

    /// Sends `body` (`{op, params, ...}`) to `route`: the reply's status and body for every HTTP status. A
    /// credential that cannot be read is ``FeedServiceError/signedOut``; a request that never got an answer
    /// throws its ``CloudAPIError``.
    public func send(_ route: Route, _ body: [String: Any]) async throws -> Reply {
        try buildSpace.check()
        // The body goes as the JSON text the app serialized, so every number and flag reaches the Worker as written.
        let text = String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
        var args: [String: any Sendable] = ["route": route.rawValue, "body_json": text]
        if let clientVersion, !clientVersion.isEmpty { args["client_version"] = clientVersion }
        let credential = credential
        var daemon = CloudDaemon(baseURL: baseURL, tokens: { (try await credential(), "") }, teamID: teamID,
                                 appVersion: "cmux-next", sendsStackSession: false)
        daemon.machineIO = machineIO
        daemon.daemonCall = daemonCall
        let data: Data
        do {
            data = try await daemon.daemon("owner.op", args, timeout: Self.bound)
        } catch CloudAPIError.notSignedIn {
            throw FeedServiceError.signedOut
        }
        guard let answer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let status = answer["status"] as? Int else { throw FeedServiceError.badReply }
        let body = (answer["reply"] as? [String: Any]).flatMap { try? JSONSerialization.data(withJSONObject: $0) }
        return Reply(status: status, bodyJSON: body)
    }

    /// ``send(_:_:)``'s reply as the feed reads it: the body, or ``FeedServiceError/owner(code:message:)`` for
    /// the Worker's `{error: {code, message}}`, or ``FeedServiceError/badReply`` when it is not a JSON object.
    public static func read(_ reply: Reply) throws -> [String: Any] {
        guard let body = reply.body else { throw FeedServiceError.badReply }
        if let error = body["error"] as? [String: Any] {
            throw FeedServiceError.owner(code: error["code"] as? String ?? "error", message: error["message"] as? String ?? "")
        }
        return body
    }
}

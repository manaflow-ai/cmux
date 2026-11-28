package import CmuxNextCloud
package import Foundation

/// The feed's own calls on the cmux API Worker (`POST /v1/ops` and `/v1/read`): the daemon's `cloud.owner.op`
/// (cmux-cloud-api `owner.rs`), as the person's session (`FeedService.call`) or this Mac's install token
/// (`FeedInstallPrincipal.call`). The request, its headers and its deadline are Rust's; this only forwards the
/// body and reads the reply.
package nonisolated struct FeedOwnerCall: Sendable {
    package typealias Credential = @Sendable () async throws -> String
    package typealias Run = @Sendable (_ input: Data, _ timeout: Duration) async throws -> Data

    /// The route: `ops` (`POST /v1/ops`) or `read` (`POST /v1/read`).
    package nonisolated enum Route: String, Sendable {
        case ops
        case read

        /// `v1/ops` or `v1/read`, the paths the feed's callers name.
        package init?(path: String) {
            switch path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) {
            case "v1/ops": self = .ops
            case "v1/read": self = .read
            default: return nil
            }
        }
    }

    /// The Worker's reply: its HTTP status and its body as JSON text (nil when it was not a JSON object).
    package nonisolated struct Reply: Sendable {
        package var status: Int
        package var bodyJSON: Data?

        package var body: [String: Any]? {
            bodyJSON.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
        }
    }

    let daemon: CloudDaemon
    let configuration: CloudConfiguration
    let clientVersion: String?

    /// `credential` is the bearer (the Stack session or an install token); `team` the `x-cmux-team` (nil: none);
    /// `clientVersion` goes as `x-cmux-client-version` (the app's version, no secret). `run`: a test's child.
    package init(baseURL: URL, credential: @escaping Credential, team: String? = nil, configuration: CloudConfiguration,
         machineIO: CloudMachineIO?, clientVersion: String? = nil, run: Run? = nil) {
        daemon = .owner(baseURL: baseURL, credential: credential, teamID: { team }, machineIO: machineIO, run: run)
        self.configuration = configuration
        self.clientVersion = clientVersion
    }

    /// Rust's deadline for the request is 15 s; the child gets 10 s more to answer.
    static let bound: Duration = .seconds(25)

    /// Sends `body` (`{op, params, ...}`) to `route`: the reply's status and body for every HTTP status. A
    /// credential that cannot be read is ``FeedServiceError/signedOut``; a request that never got an answer
    /// throws its ``CloudAPIError``.
    package func send(_ route: Route, _ body: [String: Any]) async throws -> Reply {
        try configuration.buildSpace.check()
        // The body goes as the JSON text the app serialized, so every number and flag reaches the Worker as written.
        let text = String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
        var args: [String: any Sendable] = ["route": route.rawValue, "body_json": text]
        if let clientVersion, !clientVersion.isEmpty { args["client_version"] = clientVersion }
        let data: Data
        do {
            data = try await daemon.daemon("owner.op", args, timeout: Self.bound)
        } catch CloudAPIError.notSignedIn {
            throw FeedServiceError.signedOut
        }
        guard let answer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let status = answer["status"] as? Int else { throw FeedServiceError.badReply }
        let reply = (answer["reply"] as? [String: Any]).flatMap { try? JSONSerialization.data(withJSONObject: $0) }
        return Reply(status: status, bodyJSON: reply)
    }

    /// ``send(_:_:)``'s reply as the feed reads it: the body, or ``FeedServiceError/owner(code:message:)`` for
    /// the Worker's `{error: {code, message}}`, or ``FeedServiceError/badReply`` when it is not a JSON object.
    package static func read(_ reply: Reply) throws -> [String: Any] {
        guard let body = reply.body else { throw FeedServiceError.badReply }
        if let error = body["error"] as? [String: Any] {
            throw FeedServiceError.owner(code: error["code"] as? String ?? "error", message: error["message"] as? String ?? "")
        }
        return body
    }
}

public import CmuxNextDaemon
public import Foundation

/// How the app sends a Cloud API call: as the local daemon's `cloud.<call>` operation (cmux-tui
/// `server/cloud_api.rs`, over the `cmux-cloud-api` crate). The request, its deadline, the headers
/// each auth sends, the retry of a lost Run create and the reading of every refusal are Rust's;
/// Swift reads the person's tokens, sends them with the call, and decodes the answer. The daemon
/// keeps no credential, and takes these calls only from a local socket client.
public struct CloudAPICaller: Sendable {
    /// Sends one operation (`cloud.vm.networks`, …) with its fields; `mutation` calls carry an
    /// idempotency key and answer under `value`. `timeout` bounds the wait for the daemon's answer.
    public typealias Send = @Sendable (_ operation: String, _ fields: [String: JSONValue], _ mutation: Bool,
                                       _ timeout: Duration) async throws -> JSONValue

    let send: Send

    public init(send: @escaping Send) { self.send = send }

    /// Sends over `connection` (the app's local daemon, read per call).
    public static func daemon(_ connection: @escaping @Sendable () async -> DaemonConnection?) -> CloudAPICaller {
        CloudAPICaller { operation, fields, mutation, timeout in
            guard let connection = await connection() else { throw CloudAPIError.transport("cmux is not connected") }
            // A caller that gave up while its tokens or connection were read starts nothing (a Run costs).
            try Task.checkCancellation()
            return try await ResourceRelayClient(connection: connection).send(
                operation: operation, params: fields, idempotencyKey: mutation ? UUID().uuidString : nil, timeout: timeout)
        }
    }

    /// The calls the daemon serves as reads (cmux-tui `resource/class.rs`); every other is a mutation.
    static let reads: Set<String> = [
        "vm.snapshots", "vm.firewall_list", "vm.firewall_get", "vm.networks", "vm.domains", "vm.publications",
        "vm.publication_api_keys", "runs.wait", "owner.handoff_wait", "owner.handoffs", "owner.harness_login_copy",
        "owner.github_app",
    ]

    /// Who a call goes as: `auth` is `stack` (classic `/api/vm`, `/api/runs`), `owner` (the cmux API
    /// Worker's person routes) or `worker` (the platform's machine routes).
    struct Credentials: Sendable {
        var auth: String
        var api: URL
        var access: String
        var refresh: String?
        var team: String?
        var appVersion: String?
        var localOnly = false
    }

    /// One call: its answer, or the refusal as ``CloudAPIError``. The daemon's own deadlines answer
    /// first; `timeout` (the call's longest) plus a margin only bounds a daemon that never answers.
    func call(_ call: String, as credentials: Credentials, args: [String: JSONValue] = [:],
              timeout: Duration = .seconds(20)) async throws -> JSONValue {
        var fields: [String: JSONValue] = [
            "api": .string(credentials.api.absoluteString), "auth": .string(credentials.auth),
            "access_token": .string(credentials.access), "args": .object(args),
        ]
        if let refresh = credentials.refresh, !refresh.isEmpty { fields["refresh_token"] = .string(refresh) }
        if let team = credentials.team, !team.isEmpty { fields["team"] = .string(team) }
        if let version = credentials.appVersion { fields["app_version"] = .string(version) }
        if credentials.localOnly { fields["local_only"] = .bool(true) }
        let mutation = !Self.reads.contains(call)
        // The credentials were read across a suspension: a caller cancelled meanwhile sends nothing.
        try Task.checkCancellation()
        let answer: JSONValue
        do {
            answer = try await send("cloud.\(call)", fields, mutation, timeout + .seconds(15))
        } catch let error as DaemonError {
            throw Self.failure(error, call: call, api: credentials.api)
        }
        return mutation ? answer["value"] ?? .null : answer
    }

    /// ``call(_:as:args:timeout:)`` read as `T` (a ``CloudServerModel`` through the crate's rules).
    func call<T: Decodable>(_ call: String, as credentials: Credentials, args: [String: JSONValue] = [:],
                            timeout: Duration = .seconds(20), decoding: T.Type) async throws -> T {
        let answer = try await self.call(call, as: credentials, args: args, timeout: timeout)
        let data: Data
        do { data = try JSONEncoder().encode(answer) } catch { throw CloudAPIError.decoding("\(call): \(error)") }
        return try CloudMachineRules().answer(data, as: T.self, context: call)
    }

    /// The refusal the daemon sent (`operation.failed`, its `extra.failure` the crate's failure
    /// object: `timed_out`, `transport`, `no_backend`, `http`, `plan_required` or `decoding`).
    static func failure(_ error: DaemonError, call: String, api: URL) -> CloudAPIError {
        guard case let .command(_, message, _, details, _) = error else {
            if case .timedOut = error { return .timedOut(call) }
            return .transport(error.description)
        }
        // A refusal before the call ran (the daemon's own validation) says why in its message.
        guard case let .object(failure)? = details?["extra"]?["failure"] else { return .transport(message) }
        let text = { (name: String) in failure[name]?.stringValue }
        switch text("kind") {
        case "timed_out": return .timedOut(text("path") ?? call)
        case "no_backend": return .noBackend(api)
        case "http":
            return .http(status: failure["status"]?.doubleValue.flatMap { Int(exactly: $0) } ?? 0, code: text("code"), message: text("message"),
                         action: text("action"), traceId: text("trace_id"))
        case "plan_required":
            return .planRequired(message: text("message"), upgradeURL: text("upgrade_url").flatMap(URL.init(string:)),
                                 plan: text("plan") ?? "pro")
        case "decoding": return .decoding(text("message") ?? message)
        default: return .transport(text("message") ?? message)
        }
    }
}

import CCmuxSdkFFI
public import Foundation
public import CmuxNextCompat
import CmuxNextWakeups

/// The app's Cloud API calls, run by this Mac's cmux daemon: its `cloud.*` operations
/// (`cmux.protocol/2`, capability `cloud-api-v1`; cmux-tui-core `server/cloud_api.rs`). Each
/// request, its deadline, a lost Run create's retry, the long-polls and every refusal's reading
/// are the `cmux-cloud-api` crate's, with their tests; the app sends one call on the daemon's
/// local socket through the cmux SDK's C ABI (`cmux_sdk_ffi.h`, in CCmuxAppFFI) and reads the
/// answer. The caller's credential goes in that one call's params and is never kept.
public struct CloudDaemon: Sendable {
    /// Which credentials and headers a call sends (the crate's `Auth`).
    public enum Auth: String, Sendable {
        /// Classic cmux.com's Stack session: sandboxed Runs.
        case stack
        /// The API Worker's person routes.
        case owner
        /// cmux-platform's machine, preview and publication routes.
        case worker
    }

    /// Who a call goes as and where.
    public struct Route: Sendable {
        public var api: URL
        public var auth: Auth
        public var credential: String
        public var refresh: String?
        public var team: String?
        public var appVersion: String?
        /// The build points at a loopback backend: a refused connection is ``CloudAPIError/noBackend(_:)``.
        public var localOnly: Bool

        public init(api: URL, auth: Auth, credential: String, refresh: String? = nil, team: String? = nil,
                    appVersion: String? = nil, localOnly: Bool = false) {
            (self.api, self.auth, self.credential, self.refresh, self.team) = (api, auth, credential, refresh, team)
            (self.appVersion, self.localOnly) = (appVersion, localOnly)
        }
    }

    /// One operation sent as is: its wire name, whether it is a mutation, its params (JSON, wiped
    /// after the send) and how long to wait; answers the SDK's envelope. `ended` runs once, when the
    /// call has really ended: after the answer, or, for a cancelled call, once the call itself is
    /// over (later than the caller's cancel), or at once when nothing was sent.
    public typealias Send = @Sendable (_ operation: String, _ mutation: Bool, _ params: CloudSecretBytes,
                                       _ wait: Duration, _ ended: @escaping @Sendable () -> Void) async throws -> Data

    let send: Send

    /// The daemon at `socketPath` (the app's local daemon; nil while it has none: still starting,
    /// or handing off to an upgraded daemon). `changes` yields at each change that may bring one (the
    /// connection appearing or being replaced): a call made before then waits for it, at most
    /// `readyWithin`, instead of failing at once, so a call at launch or auth restore reaches the
    /// daemon once it is up.
    public init<Change: Sendable>(socketPath: @escaping @Sendable () async -> String?,
                                  changes: @escaping @Sendable () -> ObservationStream<Change>,
                                  readyWithin: Duration = .seconds(30)) {
        send = { operation, mutation, params, wait, ended in
            let socket: String
            do { socket = try await Self.socket(socketPath, changes: changes, within: readyWithin) } catch { ended(); throw error }
            return try await Self.sdkCall(socket: socket, operation: operation, mutation: mutation, params: params, wait: wait, ended: ended)
        }
    }

    /// The daemon at `socketPath`, with no wait (``none``, a caller with no daemon to wait for).
    public init(socketPath: @escaping @Sendable () async -> String?) {
        send = { operation, mutation, params, wait, ended in
            guard let socket = await socketPath() else {
                ended()
                throw CloudAPIError.transport("the cmux daemon is not running")
            }
            return try await Self.sdkCall(socket: socket, operation: operation, mutation: mutation, params: params, wait: wait, ended: ended)
        }
    }

    /// The daemon's socket now, or once a change of `changes` brings one, within `within`; woken by
    /// those changes, never by polling. Past `within`, the daemon is not running.
    static func socket<Change: Sendable>(_ socketPath: @escaping @Sendable () async -> String?,
                                         changes: @escaping @Sendable () -> ObservationStream<Change>,
                                         within: Duration) async throws -> String {
        if let socket = await socketPath() { return socket }
        do {
            return try await withDeadline(within, label: "the cmux daemon") {
                // The stream's first value is read when iteration starts, so a socket that came
                // between the check above and here is seen at once.
                for await _ in changes() {
                    if let socket = await socketPath() { return socket }
                }
                throw CancellationError()
            }
        } catch is DeadlineExceeded {
            throw CloudAPIError.transport("the cmux daemon is not running")
        }
    }

    /// A daemon that answers `send` (tests).
    public init(send: @escaping Send) { self.send = send }

    /// No daemon: every call is refused before anything is sent.
    public static let none = CloudDaemon(socketPath: { nil })

    /// The daemon's mutations (spec/resource-operations-v2.json); every other call is a read.
    static let reads: Set<String> = [
        "vm.firewall_get", "vm.firewall_list", "vm.networks", "vm.domains", "vm.publications", "vm.publication_api_keys",
        "runs.wait", "owner.github_app", "owner.handoff_wait", "owner.handoffs", "owner.harness_login_copy",
    ]

    /// Runs `call` (one of `cmux_cloud_api::CALLS`) with `args` as `route`; answers its body as JSON.
    /// `wait` is the call's deadline, sent as `args.deadline_ms`: the daemon ends the whole call by
    /// then (time waiting for a slot included; a staged write out of time is aborted, never
    /// committed), and this side gives up 30 s later, so nothing of it outlives this answer. `ended`
    /// runs once the call has really ended (see ``Send``), for what must outlive a cancelled caller.
    public func call(_ call: String, _ args: [String: any Sendable] = [:], as route: Route, wait: Duration,
                     ended: (@Sendable () -> Void)? = nil) async throws -> Data {
        let ended = ended ?? {}
        var args = args
        args["deadline_ms"] = Int(clamping: wait.components.seconds * 1000 + wait.components.attoseconds / 1_000_000_000_000_000)
        var fields: [String: Any] = [
            "machine": "current", "session": "current", "api": route.api.absoluteString, "auth": route.auth.rawValue,
            "access_token": route.credential, "local_only": route.localOnly, "args": args,
        ]
        if let refresh = route.refresh, !refresh.isEmpty { fields["refresh_token"] = refresh }
        if let team = route.team, !team.isEmpty { fields["team"] = team }
        if let version = route.appVersion, !version.isEmpty { fields["app_version"] = version }
        let params: CloudSecretBytes
        do {
            params = CloudSecretBytes(Array(try JSONSerialization.data(withJSONObject: fields)))
        } catch {
            ended()
            throw CloudAPIError.transport("the call is not JSON")
        }
        let mutation = !Self.reads.contains(call)
        let envelope = try await send("cloud.\(call)", mutation, params, wait + .seconds(30), ended)
        return try Self.answer(envelope, mutation: mutation, api: route.api)
    }

    /// The body of the SDK's envelope (`{ok: true, result}`; a mutation's under `result.value`), or its refusal as
    /// a ``CloudAPIError``: the library's own failure (`details.extra.failure`) when the daemon ran the call, else
    /// a transport failure with the daemon's message.
    static func answer(_ envelope: Data, mutation: Bool, api: URL) throws -> Data {
        guard let object = (try? JSONSerialization.jsonObject(with: envelope)) as? [String: Any] else {
            throw CloudAPIError.transport("the cmux daemon's answer is not JSON")
        }
        if object["ok"] as? Bool == true {
            let result = object["result"]
            let body = mutation ? (result as? [String: Any])?["value"] : result
            return try JSONSerialization.data(withJSONObject: body ?? NSNull(), options: .fragmentsAllowed)
        }
        let error = object["error"] as? [String: Any]
        let details = error?["details"] as? [String: Any]
        let failure = (details?["extra"] as? [String: Any])?["failure"] as? [String: Any]
        if failure == nil, details?["reason"] as? String == "busy" { throw Self.busy }
        throw failure.flatMap { Self.failure($0, api: api) }
            ?? CloudAPIError.transport(error?["message"] as? String ?? "the cmux daemon refused the call")
    }

    /// The daemon ran nothing because its call slots (or its long polls') are all taken: worth
    /// trying again after a backoff.
    /// What a long poll's `wait` adds for its time waiting for one of the daemon's long-poll slots
    /// (more than one hand-off wait's 25 s, so a full batch of them frees one first).
    public static let lineAllowance: Duration = .seconds(30)

    public static var busy: CloudAPIError { .transport("the cmux daemon is busy") }

    /// `body`'s answer, asked again after a backoff while the daemon answers ``busy``: a caller
    /// that must not give up (the hand-off list at sign-in) is never dropped for a full daemon.
    /// Any other failure, and a cancel, end it.
    public static func retryingBusy<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        var backoff = Backoff(initial: .seconds(1), maximum: .seconds(30))
        // wakeup-allow: each pass after the first waits a Backoff delay that a busy answer started
        while true {
            do {
                return try await body()
            } catch let error as CloudAPIError where error == busy {
                // concurrency-allow: Backoff.wait is an async sleep after a busy answer, not a blocking wait.
                try await backoff.wait(owner: "cloud.daemon.busy")
            }
        }
    }

    /// `cmux_cloud_api::Failure::json` read back.
    static func failure(_ value: [String: Any], api: URL) -> CloudAPIError? {
        let text = { (name: String) in value[name] as? String }
        switch text("kind") {
        case "timed_out": return .timedOut(text("path") ?? "")
        case "transport": return .transport(text("message") ?? "")
        case "no_backend": return .noBackend(api)
        case "http":
            guard let status = value["status"] as? Int else { return nil }
            return .http(status: status, code: text("code"), message: text("message"), action: text("action"), traceId: text("trace_id"))
        case "plan_required":
            guard let plan = text("plan") else { return nil }
            return .planRequired(message: text("message"), upgradeURL: text("upgrade_url").flatMap(URL.init(string:)), plan: plan)
        case "decoding": return .decoding(text("message") ?? "")
        default: return nil
        }
    }

    // MARK: The SDK call

    /// One call on its own connection, on a thread of its own (the SDK's calls block, for minutes for a sandboxed
    /// Run). A cancel answers at once; the call then ends on the daemon by its own deadlines and its answer is dropped.
    /// `ended` runs on the call's thread when the call is over (at once when it never started).
    static func sdkCall(socket: String, operation: String, mutation: Bool, params: CloudSecretBytes, wait: Duration,
                        ended: @escaping @Sendable () -> Void = {}) async throws -> Data {
        if Task.isCancelled {
            ended()
            throw CancellationError()
        }
        let gate = OneAnswer()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard gate.hold(continuation) else {
                    ended()
                    return continuation.resume(throwing: CancellationError())
                }
                let thread = Thread {
                    gate.finish(Result { try blockingCall(socket: socket, operation: operation, mutation: mutation, params: params, wait: wait) })
                    ended()
                }
                thread.name = "cmux.cloud.daemon-call"
                thread.start()
            }
        } onCancel: {
            gate.finish(.failure(CancellationError()))
        }
    }

    private static func blockingCall(socket: String, operation: String, mutation: Bool, params: CloudSecretBytes,
                                     wait: Duration) throws -> Data {
        let ms = UInt32(clamping: wait.components.seconds * 1000 + wait.components.attoseconds / 1_000_000_000_000_000)
        var client: OpaquePointer?
        var out = CmuxSdkBytes(ptr: nil, len: 0)
        let connected = socket.withCString { cmux_sdk_connect($0, max(ms, 1), &client, &out) }
        guard connected == CMUX_SDK_OK, let client else {
            let reply = take(&out)
            let message = ((try? JSONSerialization.jsonObject(with: reply)) as? [String: Any]).flatMap { ($0["error"] as? [String: Any])?["message"] as? String }
            throw CloudAPIError.transport("the cmux daemon could not be reached: \(message ?? "error \(connected)")")
        }
        defer { cmux_sdk_close(client) }
        let key = mutation ? UUID().uuidString.lowercased() : nil
        let kind = mutation ? CMUX_SDK_KIND_MUTATION : CMUX_SDK_KIND_READ
        let rc = params.withBytes { bytes in
            operation.withCString { op in
                if let key {
                    return key.withCString { cmux_sdk_call(client, op, kind, $0, bytes.baseAddress, bytes.count, &out) }
                }
                return cmux_sdk_call(client, op, kind, nil, bytes.baseAddress, bytes.count, &out)
            }
        }
        let reply = take(&out)
        guard rc == CMUX_SDK_OK else {
            throw CloudAPIError.transport(rc == CMUX_SDK_ERR_IO ? "the cmux daemon closed the connection" : "the cmux daemon call failed (\(rc))")
        }
        return reply
    }

    /// The bytes of `out`, which is freed.
    private static func take(_ out: inout CmuxSdkBytes) -> Data {
        defer {
            cmux_sdk_bytes_free(out)
            out = CmuxSdkBytes(ptr: nil, len: 0)
        }
        guard let pointer = out.ptr, out.len > 0 else { return Data() }
        return Data(bytes: pointer, count: out.len)
    }
}

/// Bytes that hold a credential: wiped when the last reference goes.
public final class CloudSecretBytes: Sendable {
    private let bytes: Mutex<[UInt8]>

    public init(_ bytes: [UInt8]) { self.bytes = Mutex(bytes) }

    deinit {
        bytes.withLock { bytes in
            bytes.withUnsafeMutableBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                _ = memset_s(base, buffer.count, 0, buffer.count)
            }
        }
    }

    func withBytes<R: Sendable>(_ body: (UnsafeBufferPointer<UInt8>) -> R) -> R {
        bytes.withLock { $0.withUnsafeBufferPointer(body) }
    }

    /// The JSON text, for a test to read.
    public var text: String { withBytes { String(decoding: $0, as: UTF8.self) } }
}

/// The first answer of an SDK call wins: its thread's, or a cancel's.
private final class OneAnswer: Sendable {
    private struct State {
        var continuation: CheckedContinuation<Data, any Error>?
        var done = false
    }
    private let state = Mutex(State())

    /// Keeps `continuation` unless the call was already cancelled; false then.
    func hold(_ continuation: CheckedContinuation<Data, any Error>) -> Bool {
        state.withLock { state in
            guard !state.done else { return false }
            state.continuation = continuation
            return true
        }
    }

    func finish(_ result: Result<Data, any Error>) {
        let continuation = state.withLock { state -> CheckedContinuation<Data, any Error>? in
            state.done = true
            defer { state.continuation = nil }
            return state.continuation
        }
        continuation?.resume(with: result)
    }
}

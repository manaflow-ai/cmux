import CCmuxSdkFFI
public import Foundation
import CmuxNextCompat

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
    /// after the send) and how long to wait; answers the SDK's envelope.
    public typealias Send = @Sendable (_ operation: String, _ mutation: Bool, _ params: SecretBytes,
                                       _ wait: Duration) async throws -> Data

    let send: Send

    /// The daemon at `socketPath` (the app's local daemon; nil while it has none).
    public init(socketPath: @escaping @Sendable () async -> String?) {
        send = { operation, mutation, params, wait in
            guard let socket = await socketPath() else { throw CloudAPIError.transport("the cmux daemon is not running") }
            return try await Self.sdkCall(socket: socket, operation: operation, mutation: mutation, params: params, wait: wait)
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
    /// `key` is a keyed start's person key: it goes base64 in the params and every copy is wiped.
    /// `wait` bounds a daemon that does not answer; the call's own deadlines end first.
    public func call(_ call: String, _ args: [String: any Sendable] = [:], as route: Route, key: SecretBytes? = nil,
                     wait: Duration) async throws -> Data {
        var fields: [String: Any] = [
            "machine": "current", "session": "current", "api": route.api.absoluteString, "auth": route.auth.rawValue,
            "access_token": route.credential, "local_only": route.localOnly, "args": args,
        ]
        if let refresh = route.refresh, !refresh.isEmpty { fields["refresh_token"] = refresh }
        if let team = route.team, !team.isEmpty { fields["team"] = team }
        if let version = route.appVersion, !version.isEmpty { fields["app_version"] = version }
        let params: SecretBytes
        do {
            params = SecretBytes(Array(try JSONSerialization.data(withJSONObject: fields)))
        } catch {
            throw CloudAPIError.transport("the call is not JSON")
        }
        if let key { params.appendField("key_base64", base64Of: key) }
        let mutation = !Self.reads.contains(call)
        let envelope = try await send("cloud.\(call)", mutation, params, wait + .seconds(30))
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
        let failure = ((error?["details"] as? [String: Any])?["extra"] as? [String: Any])?["failure"] as? [String: Any]
        throw failure.flatMap { Self.failure($0, api: api) }
            ?? CloudAPIError.transport(error?["message"] as? String ?? "the cmux daemon refused the call")
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
    static func sdkCall(socket: String, operation: String, mutation: Bool, params: SecretBytes, wait: Duration) async throws -> Data {
        try Task.checkCancellation()
        let gate = OneAnswer()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard gate.hold(continuation) else { return continuation.resume(throwing: CancellationError()) }
                let thread = Thread {
                    gate.finish(Result { try blockingCall(socket: socket, operation: operation, mutation: mutation, params: params, wait: wait) })
                }
                thread.name = "cmux.cloud.daemon-call"
                thread.start()
            }
        } onCancel: {
            gate.finish(.failure(CancellationError()))
        }
    }

    private static func blockingCall(socket: String, operation: String, mutation: Bool, params: SecretBytes,
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
public final class SecretBytes: @unchecked Sendable {
    // Unchecked: written only while one owner builds it, before it is shared; read after.
    private var bytes: [UInt8]

    public init(_ bytes: [UInt8]) { self.bytes = bytes }

    deinit { wipe() }

    func withBytes<R>(_ body: (UnsafeBufferPointer<UInt8>) throws -> R) rethrows -> R {
        try bytes.withUnsafeBufferPointer(body)
    }

    func withMutableBytes<R>(_ body: (UnsafeMutableBufferPointer<UInt8>) throws -> R) rethrows -> R {
        try bytes.withUnsafeMutableBufferPointer { try body($0) }
    }

    /// The JSON text, for a test to read.
    public var text: String { String(decoding: bytes, as: UTF8.self) }

    /// Adds `"name":"<base64 of key>"` to this JSON object in place: no `String` or `Data` copy of the key.
    func appendField(_ name: String, base64Of key: SecretBytes) {
        guard bytes.last == UInt8(ascii: "}") else { return }
        bytes.removeLast()
        if bytes.count > 1 { bytes.append(UInt8(ascii: ",")) }
        bytes.append(contentsOf: Array("\"\(name)\":\"".utf8))
        key.withBytes { Self.base64(into: &bytes, $0) }
        bytes.append(contentsOf: Array("\"}".utf8))
    }

    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)

    private static func base64(into out: inout [UInt8], _ input: UnsafeBufferPointer<UInt8>) {
        var index = 0
        while index < input.count {
            let a = UInt32(input[index])
            let b = index + 1 < input.count ? UInt32(input[index + 1]) : 0
            let c = index + 2 < input.count ? UInt32(input[index + 2]) : 0
            let triple = a << 16 | b << 8 | c
            out.append(alphabet[Int(triple >> 18 & 63)])
            out.append(alphabet[Int(triple >> 12 & 63)])
            out.append(index + 1 < input.count ? alphabet[Int(triple >> 6 & 63)] : UInt8(ascii: "="))
            out.append(index + 2 < input.count ? alphabet[Int(triple & 63)] : UInt8(ascii: "="))
            index += 3
        }
    }

    private func wipe() {
        bytes.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            memset_s(base, buffer.count, 0, buffer.count)
        }
    }
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

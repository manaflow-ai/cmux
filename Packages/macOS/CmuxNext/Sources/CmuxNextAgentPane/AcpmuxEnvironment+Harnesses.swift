public import Foundation
import Network

/// A refusal from the acpmux daemon with its JSON-RPC code and, when the daemon names one, its
/// reason id from `data.reason` (`harness.exists`, `harness.not_removable`, `harness.secret_inline`,
/// `harness.not_found`).
public nonisolated struct AcpmuxRPCError: Error, Sendable, Equatable, LocalizedError {
    public var code: Int?
    public var name: String?
    public var message: String
    /// The folder named by a trust refusal, retained for the pane's Trust route.
    public var cwd: String?

    public init(code: Int? = nil, name: String? = nil, message: String, cwd: String? = nil) {
        self.code = code
        self.name = name
        self.message = message
        self.cwd = cwd
    }

    init(_ error: [String: Any]) {
        let data = error["data"] as? [String: Any]
        code = (error["code"] as? NSNumber)?.intValue
        name = data?["reason"] as? String ?? data?["code"] as? String
        message = error["message"] as? String ?? "acpmux request failed"
        cwd = data?["cwd"] as? String
    }

    /// The daemon does not serve the method (an older acpmux): callers fall back to the CLI.
    public var isMethodMissing: Bool { code == -32601 }
    /// No daemon answered on the socket.
    public var isUnreachable: Bool { name == Self.unreachable }
    static let unreachable = "acpmux.unreachable"
    public var errorDescription: String? { message }
}

/// The harness operations of BRING-YOUR-OWN-HARNESS (H1, H2) on the local daemon's unix socket:
/// list, add, remove (with a restorable backup), restore, doctor and the ACP Registry. Each
/// answers the result object as JSON bytes, so callers in other modules parse it with their own
/// JSON type.
public nonisolated enum AcpmuxHarnessMethod: String, Sendable, CaseIterable {
    case list = "_acpmux/harnesses"
    case add = "_acpmux/harness/add"
    case remove = "_acpmux/harness/remove"
    case restore = "_acpmux/harness/restore"
    case doctor = "_acpmux/harness/doctor"
    case registry = "_acpmux/registry"
    /// Agent CLI health (cx-ny85): version, install channel, newest version, sign-in, update command.
    case health = "_acpmux/harness/health"
    /// acpmux reads its profiles and looks on PATH again (cx-apoko: a harness the Harnesses page
    /// just installed). Running chats stay; idle pooled sessions are dropped.
    case reload = "_acpmux/reload_config"
    /// One cheap completion through the user's own harness login (hq#1957, auto-naming):
    /// `{prompt, harness?, model?, maxTokens?, timeoutMs?}` answers `{text, harness, model}`. The
    /// unix socket only; the harness CLI runs headless with no tools, MCP, hooks or session.
    case complete = "_acpmux/complete"
    /// The probed models of every harness, with each model's efforts (the Chief editor's picker).
    case models = "_acpmux/models"
    /// Stores one secret in the Keychain (`cmux harness secret set ID KEY`): `{id, key, value}`
    /// answers `{item}` (`cmux-harness/<id>/<KEY>`), the name a profile reads as `keychain:NAME`.
    case secretSet = "_acpmux/harness/secret/set"
    /// Sets the icon of a profile in the user's harness folder (user 12922): `{id, icon}` (an
    /// emoji, an SF Symbol name or an agent mark id), `{id, data, ext}` (base64 png or svg bytes,
    /// copied next to the profile) or `{id, clear: true}`. Answers `{id, path, icon}`.
    case icon = "_acpmux/harness/icon"

    /// Doctor starts the harness and sends one prompt; a registry refresh fetches over HTTPS; a
    /// health check runs each harness's `--version` and may ask npm and Homebrew for the newest.
    var deadline: Duration {
        switch self {
        case .doctor: .seconds(150)
        // The daemon's own limit is at most 60 s (`timeoutMs`).
        case .complete: .seconds(65)
        case .registry, .health, .models: .seconds(40)
        case .list, .add, .remove, .restore, .reload, .secretSet, .icon: .seconds(10)
        }
    }
}

extension AcpmuxEnvironment {
    /// One harness operation. Throws ``AcpmuxRPCError``: a daemon refusal (an older daemon
    /// answers `isMethodMissing`), or `isUnreachable` when no daemon runs.
    public nonisolated func harness(_ method: AcpmuxHarnessMethod, params: [String: any Sendable] = [:]) async throws -> Data {
        do {
            let result = try await AcpmuxStatusClient.call(socketPath: socketPath, method: method.rawValue, params: params,
                                                           deadline: method.deadline, detailed: true)
            return try JSONSerialization.data(withJSONObject: result)
        } catch AcpmuxStatusClient.Failure.unreachable(let detail) {
            throw AcpmuxRPCError(name: AcpmuxRPCError.unreachable, message: detail)
        }
    }

    /// One `_acpmux/complete` (`params`: `prompt`, `harness`, `model`, `maxTokens`, `timeoutMs`): its
    /// `text`, empty when the reply has none. When the named harness cannot answer here (no profile
    /// by that id, no headless mode, its CLI not installed), `fallback` is asked instead: a profile id
    /// differs per machine (`claude-cr`, a wrapper), so a caller names its preference and a fallback.
    public nonisolated func completionText(params: [String: any Sendable],
                                           fallback: [String: any Sendable]? = nil) async throws -> String {
        let data: Data
        do {
            data = try await harness(.complete, params: params)
        } catch let error as AcpmuxRPCError where fallback != nil && Self.harnessUnavailable.contains(error.name ?? "") {
            data = try await harness(.complete, params: fallback ?? [:])
        }
        let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return reply?["text"] as? String ?? ""
    }

    /// `_acpmux/complete` refusals that name the harness, not the request: another harness may answer.
    nonisolated static let harnessUnavailable: Set<String> = [
        "complete.unknown_harness", "complete.unsupported_harness", "complete.not_installed",
    ]

    /// `_acpmux/harness/health` (`refresh`: the daemon checks again). Named so a caller can default
    /// to it without an async closure literal default argument (crash_ratchet, cx-bsue).
    public nonisolated static func harnessHealth(_ environment: AcpmuxEnvironment, refresh: Bool) async throws -> Data {
        try await environment.harness(.health, params: ["refresh": refresh])
    }

    /// Calls `onChange` for each `_acpmux/harnesses_changed` the daemon sends (a profile file
    /// written, removed or reloaded), until the task is cancelled or the daemon closes the
    /// connection. Event-driven: one `_acpmux/watch` connection, no polling.
    public nonisolated func watchHarnesses(_ onChange: @escaping @Sendable () -> Void) -> Task<Void, Never> {
        let socketPath = socketPath
        return Task.detached {
            guard let endpoint = try? AcpmuxStatusClient.unixEndpoint(socketPath) else { return }
            let connection = NWConnection(to: endpoint, using: .tcp)
            defer { connection.cancel() }
            await withTaskCancellationHandler {
                try? await Self.readHarnessChanges(on: connection, onChange: onChange)
            } onCancel: {
                connection.cancel()
            }
        }
    }

    private nonisolated static func readHarnessChanges(on connection: NWConnection,
                                                      onChange: @escaping @Sendable () -> Void) async throws {
        try await AcpmuxStatusClient.start(connection)
        let initialize: [String: Any] = [
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": 1, "clientInfo": ["name": "cmux-next-harness-settings", "version": "1"],
                       "clientCapabilities": [:]],
        ]
        // We only consume harness-change notifications. Keep the initial
        // session snapshot to one row; sending the whole watch page makes a
        // large daemon's first reply needlessly multi-megabyte.
        let watch: [String: Any] = ["jsonrpc": "2.0", "id": 2, "method": "_acpmux/watch", "params": ["enabled": true, "limit": 1]]
        var payload = Data()
        for request in [initialize, watch] {
            payload += try JSONSerialization.data(withJSONObject: request)
            payload.append(0x0A)
        }
        try await AcpmuxStatusClient.send(payload, on: connection)
        var buffer = Data()
        // wakeup-allow: each pass awaits socket data; EOF, an error or cancellation ends it
        while !Task.isCancelled {
            guard let chunk = try await AcpmuxStatusClient.receive(on: connection) else { return }
            buffer += chunk
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                if Self.isHarnessChange(line) { onChange() }
            }
            // A session event larger than this is not one this reader needs whole.
            if buffer.count > 4 << 20 { buffer.removeAll(keepingCapacity: true) }
        }
    }

    /// Whether `line` is a `_acpmux/harnesses_changed` notification.
    nonisolated static func isHarnessChange(_ line: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return false }
        return object["method"] as? String == "_acpmux/harnesses_changed"
    }
}

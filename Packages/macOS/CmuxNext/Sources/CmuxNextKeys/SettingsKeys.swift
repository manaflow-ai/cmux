package import CmuxNextPages
package import CmuxNextSettings
package import Foundation

/// Settings > Keys (design/settings-keys.md): the page's `cmux.settings.keys.*` ops and its
/// `cmux.settings.keys.changed` stream. The list is `cmux keys ls --json` (records, never a value)
/// plus the requests waiting in ``KeyRequests``. An answer pipes the typed value to `cmux keys put`
/// on stdin (``KeysCLI``) and only then ends the agent's waiting request as stored; a refusal leaves
/// the request waiting and says why. The value is never kept, logged or put in an error. Revoke is
/// `cmux keys revoke`. The App routes the ops and the stream here.
@MainActor
package final class SettingsKeys: PageProvider {
    package static let ops: Set<String> = ["cmux.settings.keys.list", "cmux.settings.keys.answer", "cmux.settings.keys.decline",
                                           "cmux.settings.keys.revoke"]
    package static let changedStream = "cmux.settings.keys.changed"

    private let requests: KeyRequests
    /// The bundled `cmux` as a ``KeysCLI``; nil when this build carries none.
    private let cli: () async -> KeysCLI?
    /// Requests whose answer runs now: a second Store on the same one waits for the first.
    private var answering: Set<String> = []

    init(requests: KeyRequests, cli: @escaping () async -> KeysCLI?) {
        self.requests = requests
        self.cli = cli
    }

    /// The bundled `cmux` at the URL `binary` answers, as the CLI.
    package convenience init(requests: KeyRequests, binary: @escaping () async -> URL?) {
        self.init(requests: requests, cli: { await binary().map { KeysCLI(binary: $0) } })
    }

    package func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        switch op {
        case "cmux.settings.keys.list": return await list()
        case "cmux.settings.keys.answer":
            guard let id = params["request_id"]?.stringValue, !id.isEmpty, let value = params["value"]?.stringValue, !value.isEmpty else {
                throw PageError.invalidParams("request_id and value are required")
            }
            return try await answer(id, value: value)
        case "cmux.settings.keys.decline":
            guard let id = params["request_id"]?.stringValue, !id.isEmpty else { throw PageError.invalidParams("request_id") }
            return try decline(id)
        case "cmux.settings.keys.revoke":
            guard let id = params["id"]?.stringValue, !id.isEmpty else { throw PageError.invalidParams("id") }
            return try await revoke(id)
        default: throw PageError.unknownOp(op)
        }
    }

    /// `cmux.settings.keys.changed`: `{revision}` after every change to the requests (no request
    /// text in the event); the page reads the list again.
    package func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                           onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
        guard stream == Self.changedStream else { throw PageError.unknownOp(stream) }
        let stop = requests.watch { revision in onEvent(.object(["revision": .number(Double(revision))])) }
        return PageSubscription(onCancel: stop)
    }

    /// `cmux.settings.keys.list`: `{available, requests, keys}`. `available` is false when the CLI is
    /// missing or its list failed; the waiting requests show either way.
    package func list() async -> JSONValue {
        let waiting: [JSONValue] = requests.requests.map(Self.json)
        var keys: JSONValue = .array([])
        var available = false
        if let cli = await cli(), let listed = try? await cli.list() {
            keys = listed["keys"] ?? .array([])
            available = true
        }
        return .object(["available": .bool(available), "requests": .array(waiting), "keys": keys])
    }

    /// `cmux.settings.keys.answer`: stores `value` for request `id`, then answers its agent.
    package func answer(_ id: String, value: String) async throws -> JSONValue {
        guard let request = requests.request(id) else { throw PageError(code: "cmux.keys.request_ended", message: Self.ended) }
        guard !value.isEmpty else { throw PageError.invalidParams("value is required") }
        guard !answering.contains(id) else { throw PageError(code: "cmux.keys.busy", message: Self.busy) }
        guard let cli = await cli() else { throw PageError(code: "cmux.page.unavailable", message: Self.noCLI) }
        answering.insert(id)
        defer { answering.remove(id) }
        do {
            _ = try await cli.put(KeysCLI.Put(name: request.name, purpose: request.purpose, hosts: request.hosts, ttl: request.ttl,
                                              askedBy: request.requester), value: value)
        } catch let failure as KeysCLI.Failure {
            throw PageError(code: Self.code(failure), message: failure.message)
        } catch {
            throw PageError(code: "cmux.keys.failed", message: Self.failed)
        }
        requests.finish(id, .stored(name: request.name))
        return .object(["stored": .bool(true), "name": .string(request.name)])
    }

    /// `cmux.settings.keys.decline`: the agent's request ends as declined.
    package func decline(_ id: String) throws -> JSONValue {
        guard requests.finish(id, .declined) else { throw PageError(code: "cmux.keys.request_ended", message: Self.ended) }
        return .object([:])
    }

    /// `cmux.settings.keys.revoke`.
    package func revoke(_ id: String) async throws -> JSONValue {
        guard let cli = await cli() else { throw PageError(code: "cmux.page.unavailable", message: Self.noCLI) }
        do {
            return try await cli.revoke(id: id)
        } catch let failure as KeysCLI.Failure {
            throw PageError(code: Self.code(failure), message: failure.message)
        }
    }

    /// The page's error code for a CLI failure (`keys.failed` → `cmux.keys.failed`).
    static func code(_ failure: KeysCLI.Failure) -> String {
        failure.code.hasPrefix("keys.") ? "cmux.\(failure.code)" : "cmux.keys.\(failure.code)"
    }

    /// A request as the page reads it (``KeyRequestWire`` in ops.ts).
    package static func json(_ request: KeyRequests.Request) -> JSONValue {
        .object([
            "id": .string(request.id), "name": .string(request.name), "purpose": .string(request.purpose),
            "hosts": .array(request.hosts.map(JSONValue.string)), "requester": .string(request.requester),
            "asked_at": .string(request.askedAt.formatted(.iso8601)),
        ])
    }

    private static let ended = "This request ended: the agent stopped waiting or asked again."
    private static let busy = "This key is being stored."
    private static let noCLI = "This build has no cmux command to store keys with."
    private static let failed = "The key wasn’t stored."
}

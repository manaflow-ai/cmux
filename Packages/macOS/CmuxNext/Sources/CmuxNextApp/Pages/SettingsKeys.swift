import CmuxNextPages
import CmuxNextSettings
import Foundation

/// Settings > Keys (design/settings-keys.md): the page's `cmux.settings.keys.*` ops. The list is
/// `cmux keys ls --json` (records, never a value) plus the requests waiting in ``KeyRequests``. An
/// answer pipes the typed value to `cmux keys put` on stdin (``KeysCLI``) and only then ends the
/// agent's waiting request as stored; a refusal leaves the request waiting and says why. The value
/// is never kept, logged or put in an error. Revoke is `cmux keys revoke`.
@MainActor
final class SettingsKeys {
    private let requests: KeyRequests
    /// The bundled `cmux` as a ``KeysCLI``; nil when this build carries none.
    private let cli: @MainActor () async -> KeysCLI?
    /// Requests whose answer runs now: a second Store on the same one waits for the first.
    private var answering: Set<String> = []

    init(requests: KeyRequests, cli: @escaping @MainActor () async -> KeysCLI?) {
        self.requests = requests
        self.cli = cli
    }

    /// `cmux.settings.keys.list`: `{available, requests, keys}`. `available` is false when the CLI is
    /// missing or its list failed; the waiting requests show either way.
    func list() async -> JSONValue {
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
    func answer(_ id: String, value: String) async throws -> JSONValue {
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
    func decline(_ id: String) throws -> JSONValue {
        guard requests.finish(id, .declined) else { throw PageError(code: "cmux.keys.request_ended", message: Self.ended) }
        return .object([:])
    }

    /// `cmux.settings.keys.revoke`.
    func revoke(_ id: String) async throws -> JSONValue {
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
    static func json(_ request: KeyRequests.Request) -> JSONValue {
        .object([
            "id": .string(request.id), "name": .string(request.name), "purpose": .string(request.purpose),
            "hosts": .array(request.hosts.map(JSONValue.string)), "requester": .string(request.requester),
            "asked_at": .string(rfc3339.string(from: request.askedAt)),
        ])
    }

    private static let rfc3339: ISO8601DateFormatter = {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime]
        return format
    }()

    private static let ended = "This request ended: the agent stopped waiting or asked again."
    private static let busy = "This key is being stored."
    private static let noCLI = "This build has no cmux command to store keys with."
    private static let failed = "The key wasn’t stored."
}

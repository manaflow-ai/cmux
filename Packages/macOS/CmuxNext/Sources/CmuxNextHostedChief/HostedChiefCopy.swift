import CmuxNextDaemon
import CmuxNextHomeEngine
import Foundation

/// A refusal of the API Worker (`code` is the owner's error code) or a reply that does not parse.
public enum HostedChiefError: Error, Equatable {
    case owner(code: String, message: String)
    case badReply
}

/// The one-time copy of this Mac's Chief into the Hosted Chief (Lawrence
/// 2026-10-19: Cloud Chief is the default). Copy only: the local Chief home
/// is read through the memory tool's read-only export and the owner's
/// history reads; nothing local is moved or deleted. Every step can run again:
/// the memory copy resumes from the brain's count, the history import from
/// the conversation's `last_seq`, and each step skips when its target is not empty.
@MainActor
final class HostedChiefCopy {
    /// One request to the API Worker as the signed-in user.
    struct HTTP {
        let base: URL
        let token: @MainActor () async throws -> String

        /// The status and the decoded JSON object (empty when the body is not one).
        func send(_ method: String, _ path: String, query: [URLQueryItem] = [], body: [String: Any]? = nil) async throws -> (status: Int, json: [String: Any]) {
            // The memory batches are measured in this form (no escaped slashes).
            let data = try body.map { try JSONSerialization.data(withJSONObject: $0, options: [.withoutEscapingSlashes]) }
            let reply = try await send(method, path, query: query, data: data)
            return (reply.status, await Self.decode(reply.body))
        }

        /// The status and the body of one request whose body is already encoded.
        func send(_ method: String, _ path: String, query: [URLQueryItem] = [], data: Data?) async throws -> (status: Int, body: Data) {
            var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)
            if !query.isEmpty { components?.queryItems = query }
            guard let url = components?.url else { throw HostedChiefError.badReply }
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.timeoutInterval = 60
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.setValue("Bearer \(try await token())", forHTTPHeaderField: "authorization")
            request.httpBody = data
            let (reply, response) = try await URLSession.shared.data(for: request)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, reply)
        }

        /// The reply's JSON object off the main actor (a history page can be large).
        @concurrent nonisolated static func decode(_ data: Data) async -> sending [String: Any] {
            (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        }

        nonisolated static func errorCode(_ json: [String: Any]) -> String? { (json["error"] as? [String: Any])?["code"] as? String }
    }

    let http: HTTP
    /// `v1/ops` as the signed-in user (FeedService.call).
    let ops: @MainActor (_ body: [String: Any]) async throws -> [String: Any]
    let chief: String
    let conversation: String
    /// This run turned the brain off for the memory copy (it turns it on again at the end or on a failure).
    private(set) var brainTurnedOff = false
    /// One id per run: every import key holds it, so a later run never replays an earlier run's
    /// keys with other content (idempotency.conflict); a run resumes from the conversation's `last_seq`.
    private let run = UUID().uuidString.lowercased()

    init(http: HTTP, ops: @escaping @MainActor (_ body: [String: Any]) async throws -> [String: Any], chief: String, conversation: String) {
        self.http = http
        self.ops = ops
        self.chief = chief
        self.conversation = conversation
    }

    // MARK: Brain

    /// A well-formed agent id no account owns: the brain route answers it 403
    /// where Chief brains run and 404 where they do not (cmux-next-ios lookUp).
    nonisolated static let probeAgent = "agent_00000000000000000000000000"

    /// Whether this service runs Cloud Chief brains (nil: unknown, the probe failed).
    static func brainsAvailable(_ http: HTTP) async -> Bool? {
        guard let reply = try? await http.send("GET", "v1/chiefs/\(probeAgent)/brain") else { return nil }
        switch reply.status {
        case 403: return true
        case 404: return false
        default: return nil
        }
    }

    /// The brain's `enabled` setting.
    func brainEnabled() async throws -> Bool {
        let reply = try await http.send("GET", "v1/chiefs/\(chief)/brain")
        guard reply.status == 200 else { throw HostedChiefError.owner(code: HTTP.errorCode(reply.json) ?? "http_\(reply.status)", message: "brain status") }
        let value = reply.json["value"] as? [String: Any]
        return (value?["config"] as? [String: Any])?["enabled"] as? Bool ?? false
    }

    func setBrain(enabled: Bool) async throws {
        // Only `enabled`: the user's model and effort stay as they are.
        let body: [String: Any] = ["enabled": enabled]
        let reply = try await http.send("PUT", "v1/chiefs/\(chief)/brain", body: body)
        guard reply.status == 200 else { throw HostedChiefError.owner(code: HTTP.errorCode(reply.json) ?? "http_\(reply.status)", message: "brain update") }
        if !enabled { brainTurnedOff = true } else { brainTurnedOff = false }
    }

    // MARK: Memory

    /// Lines of the memory export (`memory export --text`): main/ and tree/ day files, in file name and line order.
    @concurrent static func exportLines(_ directory: URL) async throws -> (main: [String], tree: [String]) {
        func lines(_ sub: String) throws -> [String] {
            let folder = directory.appendingPathComponent(sub, isDirectory: true)
            guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
            let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".jsonl") }.sorted()
            return try files.flatMap { name in
                // concurrency-allow: @concurrent: runs on the global executor, never the main actor
                try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
                    .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            }
        }
        return (try lines("main"), try lines("tree"))
    }

    enum MemoryOutcome: Equatable, Sendable { case copied(Int), skipped(String) }

    /// PUTs the export into the brain's empty memory in batches whose JSON body
    /// stays under `maxBytes`: the main lines (by `i`) after the brain's count
    /// first, then the tree lines (by `l`, `i`), the last batch `done` (also
    /// for an empty export). A memory the brain already has is not touched; a
    /// memory another copy started (`importing`) is continued only when
    /// `mayContinue` (this Mac started it). `started` runs before the first write.
    func copyMemory(main: [String], tree: [String], mayContinue: Bool, started: () -> Void, maxBytes: Int = 900_000) async throws -> MemoryOutcome {
        let path = "v1/chiefs/\(chief)/memory"
        let query = [URLQueryItem(name: "conversation", value: conversation)]
        let main = Self.sorted(main, by: ["i"])
        let tree = Self.sorted(tree, by: ["l", "i"])
        var brainOnRetries = 0
        var orderRetries = 0
        // At most 5 attempts: the first, 2 after brain_on, 2 after out_of_order.
        attempt: for _ in 0..<5 {
            let status = try await http.send("GET", path, query: query)
            guard status.status == 200, let value = status.json["value"] as? [String: Any], let state = value["state"] as? String else {
                let code = HTTP.errorCode(status.json) ?? "http_\(status.status)"
                if code == "brain_impl" { return .skipped(code) }
                throw HostedChiefError.owner(code: code, message: "memory status")
            }
            if state == "done" || state == "live" { return .skipped(state) }
            if state == "importing", !mayContinue { return .skipped("importing_elsewhere") }
            var count = (value["count"] as? NSNumber)?.intValue ?? 0
            started()
            // Tree lines go after every main line (each covers stored messages); a resumed copy sends them again (upserts).
            var queue: [(main: Bool, line: String, size: Int)] = main.dropFirst(min(count, main.count)).map { (main: true, line: $0, size: Self.encodedSize($0)) }
                + tree.map { (main: false, line: $0, size: Self.encodedSize($0)) }
            let room = maxBytes - 256
            var sent = false
            while !sent || !queue.isEmpty {
                sent = true
                var batchMain: [String] = []
                var batchTree: [String] = []
                var bytes = 0
                while let next = queue.first, (batchMain.isEmpty && batchTree.isEmpty) || bytes + next.size <= room {
                    queue.removeFirst()
                    bytes += next.size
                    if next.main { batchMain.append(next.line) } else { batchTree.append(next.line) }
                }
                let body: [String: Any] = ["after": count, "main": batchMain, "tree": batchTree, "done": queue.isEmpty]
                let reply = try await http.send("PUT", path, query: query, body: body)
                if reply.status == 200 {
                    count = ((reply.json["value"] as? [String: Any])?["count"] as? NSNumber)?.intValue ?? count + batchMain.count
                    continue
                }
                let code = HTTP.errorCode(reply.json) ?? "http_\(reply.status)"
                switch code {
                case "memory_not_empty", "memory_import_done", "brain_impl": return .skipped(code)
                case "brain_on" where brainOnRetries < 2:
                    // A brain that is on would answer while the memory is half copied: off, copy, on (the caller).
                    brainOnRetries += 1
                    try await setBrain(enabled: false)
                    continue attempt
                case "out_of_order" where orderRetries < 2:
                    // Another copy got further: start again from the brain's count.
                    orderRetries += 1
                    continue attempt
                default: throw HostedChiefError.owner(code: code, message: "memory copy")
                }
            }
            return .copied(count)
        }
        throw HostedChiefError.owner(code: "memory_retries", message: "memory copy")
    }

    /// One line's size in the request body: its JSON string form plus a comma.
    nonisolated static func encodedSize(_ line: String) -> Int {
        ((try? JSONSerialization.data(withJSONObject: [line], options: [.withoutEscapingSlashes]).count) ?? line.utf8.count * 6) - 1
    }

    /// Lines ordered by the integer fields `keys` of their JSON objects (a line
    /// without them keeps its place after the others), stable.
    nonisolated static func sorted(_ lines: [String], by keys: [String]) -> [String] {
        let keyed = lines.enumerated().map { offset, line -> (key: [Int], offset: Int, line: String) in
            let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
            let key = keys.map { (object?[$0] as? NSNumber)?.intValue ?? Int.max }
            return (key, offset, line)
        }
        return keyed.sorted { $0.key == $1.key ? $0.offset < $1.offset : $0.key.lexicographicallyPrecedes($1.key) }.map(\.line)
    }

    // MARK: History

    enum HistoryOutcome: Equatable, Sendable { case copied(UInt64), partial(UInt64, String), skipped(String) }

    /// Imports `messages` (the local Chief conversation, ascending, seq 1...n)
    /// into the Hosted Chief's empty main conversation (`conversation.import`
    /// with `fill`), then commits it. The first call of a run replays the
    /// conversation's `last_seq` when an earlier run began it, so the import
    /// resumes after it. A refusal in the middle commits what is in (partial,
    /// logged): the conversation never stays `importing`.
    func copyHistory(_ messages: [[String: Any]], host: String, localID: String) async throws -> HistoryOutcome {
        guard !messages.isEmpty else { return .skipped("empty") }
        let source: [String: Any] = ["kind": "mac", "host": host, "local_id": localID]
        var starts = 0
        func begin() async throws -> [String: Any] {
            starts += 1
            return try await op("conversation.import", key: "hosted-chief-import-\(run)-start-\(starts)",
                                params: ["id": conversation, "fill": true, "source": source, "messages": Self.batches(messages)[0]])
        }
        var reply: [String: Any]
        do {
            reply = try await begin()
        } catch let HostedChiefError.owner(code, _) where Self.skipCodes.contains(code) {
            // The main conversation has its own messages, or the owner refuses the copy: nothing to resume.
            // Any other error (rate limit, server failure) throws: the next run tries again.
            return .skipped(code)
        }
        if reply["state"] as? String == "active" { return .skipped("already_imported") }
        var last = (reply["last_seq"] as? NSNumber)?.uint64Value ?? 0
        let total = UInt64(messages.count)
        while last < total {
            let batch = Self.batches(Array(messages[Int(last)...]))[0]
            do {
                reply = try await op("conversation.import", key: "hosted-chief-import-\(run)-\(last)",
                                     params: ["id": conversation, "after_seq": last, "messages": batch])
            } catch let HostedChiefError.owner(code, _) {
                if code == "import_out_of_order", starts < 3 {
                    // Another run moved it: read where it stands (the first call replays its last_seq).
                    reply = try await begin()
                    if reply["state"] as? String == "active" { return .skipped("already_imported") }
                    last = (reply["last_seq"] as? NSNumber)?.uint64Value ?? last
                    continue
                }
                // Only a refusal of the content commits a partial copy; a transient error throws and
                // the next run resumes from the conversation's last_seq (the first call replays it).
                guard Self.partialCodes.contains(code) else { throw HostedChiefError.owner(code: code, message: "history import") }
                return try await commit(last, refused: code)
            }
            let moved = (reply["last_seq"] as? NSNumber)?.uint64Value ?? last + UInt64(batch.count)
            guard moved > last else { return try await commit(last, refused: "import_stalled") }
            last = moved
        }
        return try await commit(last, refused: nil)
    }

    /// First-call codes that end the history step for good (conversation.import).
    nonisolated static let skipCodes: Set<String> = ["conversation_exists", "forbidden"]
    /// Codes in the middle of an import that commit what is in.
    nonisolated static let partialCodes: Set<String> = ["invalid_import", "import_stalled"]

    private func commit(_ last: UInt64, refused: String?) async throws -> HistoryOutcome {
        _ = try await op("conversation.import.commit", key: "hosted-chief-import-commit-\(run)-\(last)", params: ["id": conversation, "last_seq": last])
        return refused.map { .partial(last, $0) } ?? .copied(last)
    }

    private func op(_ name: String, key: String, params: [String: Any]) async throws -> [String: Any] {
        let reply = try await ops(["op": name, "origin": "user", "idempotency_key": key, "params": params])
        // The ops envelope: a refusal carries `_tag` and `code`, a success its `value`.
        if reply["_tag"] != nil, let code = reply["code"] as? String { throw HostedChiefError.owner(code: code, message: reply["message"] as? String ?? code) }
        return reply["value"] as? [String: Any] ?? [:]
    }

    /// Import batches: at most 200 messages and about 700 KB each (the owner allows 500 and 1 MiB).
    nonisolated static func batches(_ messages: [[String: Any]]) -> [[[String: Any]]] {
        var out: [[[String: Any]]] = [[]]
        var bytes = 0
        for message in messages {
            let size = (try? JSONSerialization.data(withJSONObject: message).count) ?? 0
            if !out[out.count - 1].isEmpty, out[out.count - 1].count >= 200 || bytes + size > 700_000 {
                out.append([])
                bytes = 0
            }
            out[out.count - 1].append(message)
            bytes += size
        }
        return out
    }
}

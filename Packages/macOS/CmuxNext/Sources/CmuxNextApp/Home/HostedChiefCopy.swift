import CmuxNextDaemon
import CmuxNextHomeEngine
import Foundation

/// The one-time copy of this Mac's Chief into the Hosted Chief (Lawrence
/// 2026-10-19: Cloud Chief is the default). Copy only: the local Chief home
/// is read through the memory tool's read-only export and the owner's
/// history reads; nothing local is moved or deleted. Every step can run again:
/// the memory copy resumes from the brain's count, the history import from
/// the conversation's `last_seq`, and each step skips when its target is not empty.
@MainActor
struct HostedChiefCopy {
    /// One request to the API Worker as the signed-in user.
    struct HTTP {
        let base: URL
        let token: @MainActor () async throws -> String

        /// The status and the decoded JSON object (empty when the body is not one).
        func send(_ method: String, _ path: String, query: [URLQueryItem] = [], body: [String: Any]? = nil) async throws -> (status: Int, json: [String: Any]) {
            var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)
            if !query.isEmpty { components?.queryItems = query }
            guard let url = components?.url else { throw FeedServiceError.badReply }
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.timeoutInterval = 60
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.setValue("Bearer \(try await token())", forHTTPHeaderField: "authorization")
            if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return (status, (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:])
        }

        nonisolated static func errorCode(_ json: [String: Any]) -> String? { (json["error"] as? [String: Any])?["code"] as? String }
    }

    let http: HTTP
    /// `v1/ops` as the signed-in user (FeedService.call).
    let ops: @MainActor (_ body: [String: Any]) async throws -> [String: Any]
    let chief: String
    let conversation: String

    // MARK: Brain

    /// A well-formed agent id no account owns: the brain route answers it 403
    /// where Chief brains run and 404 where they do not (cnx-ios lookUp).
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
        guard reply.status == 200 else { throw FeedServiceError.owner(code: HTTP.errorCode(reply.json) ?? "http_\(reply.status)", message: "brain status") }
        let value = reply.json["value"] as? [String: Any]
        return (value?["config"] as? [String: Any])?["enabled"] as? Bool ?? false
    }

    func setBrain(enabled: Bool) async throws {
        let body: [String: Any] = enabled ? ["enabled": true, "model": "claude-opus-5-5", "effort": "low"] : ["enabled": false]
        let reply = try await http.send("PUT", "v1/chiefs/\(chief)/brain", body: body)
        guard reply.status == 200 else { throw FeedServiceError.owner(code: HTTP.errorCode(reply.json) ?? "http_\(reply.status)", message: "brain update") }
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

    /// PUTs the export into the brain's empty memory in batches of at most
    /// `maxBytes`: the main lines after the brain's count first, then the tree
    /// lines, the last batch `done`. A memory the brain already has is not touched.
    func copyMemory(main: [String], tree: [String], maxBytes: Int = 900_000) async throws -> MemoryOutcome {
        let path = "v1/chiefs/\(chief)/memory"
        let query = [URLQueryItem(name: "conversation", value: conversation)]
        let status = try await http.send("GET", path, query: query)
        guard status.status == 200, let value = status.json["value"] as? [String: Any], let state = value["state"] as? String else {
            if status.status == 409, let code = HTTP.errorCode(status.json), code == "brain_impl" { return .skipped(code) }
            throw FeedServiceError.owner(code: HTTP.errorCode(status.json) ?? "http_\(status.status)", message: "memory status")
        }
        if state == "done" || state == "live" { return .skipped(state) }
        var count = (value["count"] as? NSNumber)?.intValue ?? 0
        // Tree lines go after every main line (each covers stored messages); a resumed copy sends them again (upserts).
        var queue: [(main: Bool, line: String)] = main.dropFirst(min(count, main.count)).map { (main: true, line: $0) } + tree.map { (main: false, line: $0) }
        // At least one request: the last one says done, also for an empty export.
        var sent = false
        while !sent || !queue.isEmpty {
            sent = true
            var batchMain: [String] = []
            var batchTree: [String] = []
            var bytes = 0
            while let next = queue.first, (batchMain.isEmpty && batchTree.isEmpty) || bytes + next.line.utf8.count + 4 <= maxBytes {
                queue.removeFirst()
                bytes += next.line.utf8.count + 4
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
            case "brain_on":
                // A brain that is on would answer while the memory is half copied: off, copy, on (the caller).
                try await setBrain(enabled: false)
                return try await copyMemory(main: main, tree: tree, maxBytes: maxBytes)
            case "out_of_order":
                // Another copy got further: start again from the brain's count.
                return try await copyMemory(main: main, tree: tree, maxBytes: maxBytes)
            default: throw FeedServiceError.owner(code: code, message: "memory copy")
            }
        }
        return .copied(count)
    }

    // MARK: History

    enum HistoryOutcome: Equatable, Sendable { case copied(UInt64), skipped(String) }

    /// Imports `messages` (the local Chief conversation, ascending) into the
    /// Hosted Chief's empty main conversation (`conversation.import` with
    /// `fill`), then commits it. A repeated first call replays the
    /// conversation's `last_seq`, so the import resumes after it.
    func copyHistory(_ messages: [[String: Any]], host: String, localID: String) async throws -> HistoryOutcome {
        guard !messages.isEmpty else { return .skipped("empty") }
        let batches = Self.batches(messages)
        let source: [String: Any] = ["kind": "mac", "host": host, "local_id": localID]
        var reply: [String: Any]
        do {
            reply = try await op("conversation.import", key: "hosted-chief-import-\(conversation)-0",
                                 params: ["id": conversation, "fill": true, "source": source, "messages": batches[0]])
        } catch FeedServiceError.owner(code: "conversation_exists", message: _) {
            return .skipped("conversation_exists")
        }
        if reply["state"] as? String == "active" { return .skipped("already_imported") }
        var last = (reply["last_seq"] as? NSNumber)?.uint64Value ?? 0
        let total = UInt64(messages.count)
        while last < total {
            let rest = Array(messages[Int(last)...])
            let batch = Self.batches(rest)[0]
            reply = try await op("conversation.import", key: "hosted-chief-import-\(conversation)-\(last)",
                                 params: ["id": conversation, "after_seq": last, "messages": batch])
            let moved = (reply["last_seq"] as? NSNumber)?.uint64Value ?? last + UInt64(batch.count)
            // An owner that did not move on would loop here: stop with an error instead.
            guard moved > last else { throw FeedServiceError.owner(code: "import_stalled", message: "history import did not advance") }
            last = moved
        }
        _ = try await op("conversation.import.commit", key: "hosted-chief-import-commit-\(conversation)", params: ["id": conversation, "last_seq": last])
        return .copied(last)
    }

    private func op(_ name: String, key: String, params: [String: Any]) async throws -> [String: Any] {
        let reply = try await ops(["op": name, "origin": "user", "idempotency_key": key, "params": params])
        return try CloudPairingSource.okValue(reply) as? [String: Any] ?? [:]
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

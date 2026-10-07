@testable import CmuxNextApp
import Foundation
import Synchronization

/// Stands in for `cmux-diff-sidecar rpc --resource-scheme page` the way
/// Native/DiffSidecar/tests/support/test_host.rs stands in for bin/cmux: it
/// reads one `DiffRequest` and answers the `DiffResponse` the sidecar would,
/// with the sidecar's authorization against the grant files in `root`.
/// `sessionOpen` writes `diff-session-<id>.patch` and appends it to the
/// token's manifest, as the sidecar does.
nonisolated final class FakeDiffSidecar: DiffSidecarRunning {
    let root: URL
    private let log = Mutex<[Data]>([])
    /// Requests of this method wait until ``release()``.
    let holdMethod: String?
    private let held = Mutex<[CheckedContinuation<Void, Never>]>([])

    init(root: URL, hold: String? = nil) {
        self.root = root
        holdMethod = hold
    }

    /// Every request received, in order (`method`, `params`).
    var requests: [[String: Any]] {
        log.withLock { $0 }.compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    /// The methods received, in order.
    var methods: [String] { requests.map { $0["method"] as? String ?? "" } }

    func release() {
        let waiting = held.withLock { held -> [CheckedContinuation<Void, Never>] in
            defer { held.removeAll() }
            return held
        }
        for continuation in waiting { continuation.resume() }
    }

    var heldCount: Int { held.withLock { $0.count } }

    func run(_ request: Data) async throws -> Data {
        let object = try JSONSerialization.jsonObject(with: request) as? [String: Any] ?? [:]
        log.withLock { $0.append(request) }
        let method = object["method"] as? String ?? ""
        if method == holdMethod {
            await withCheckedContinuation { continuation in held.withLock { $0.append(continuation) } }
            try Task.checkCancellation()
        }
        let params = object["params"] as? [String: Any] ?? [:]
        let id = object["id"] as? String ?? "?"
        let result: Any
        do {
            result = try answer(method, params)
        } catch let failure as Failure {
            return try Self.encode(["id": id, "version": 1, "result": NSNull(), "error": ["code": failure.code, "message": "refused"]])
        }
        return try Self.encode(["id": id, "version": 1, "result": result, "error": NSNull()])
    }

    struct Failure: Error {
        let code: String
    }

    private func answer(_ method: String, _ params: [String: Any]) throws -> Any {
        switch method {
        case "protocolHandshake":
            return ["type": "handshake", "value": ["protocolVersion": 1, "capabilities": ["transport.page"]]]
        case "sessionOpen":
            let token = params["capabilityToken"] as? String ?? ""
            let source = params["source"] as? [String: Any] ?? [:]
            guard let repo = source["repoRoot"] as? String, allows(token: token, repo: repo) else { throw Failure(code: "notAllowed") }
            let session = params["sessionId"] as? String ?? UUID().uuidString.lowercased()
            return try openSession(session, token: token, source: source)
        case "sessionClose":
            let token = params["capabilityToken"] as? String ?? ""
            guard let session = params["sessionId"] as? String, grantExists(token: token) else { throw Failure(code: "notAllowed") }
            try mutateManifest(token) { files in files.removeAll { $0["request_path"] as? String == "/diff-session-\(session).patch" } }
            try? FileManager.default.removeItem(at: root.appending(path: "diff-session-\(session).patch"))
            return ["type": "sessionClosed"]
        case "branchList":
            return ["type": "branches", "value": ["groups": [["id": "suggested", "label": "Suggested", "rows": [["ref": "origin/main", "label": "origin/main"]]]]]]
        case "branchChange":
            let token = params["capabilityToken"] as? String ?? ""
            guard let group = params["groupId"] as? String, let session = branchSession(group: group), session["token"] as? String == token,
                  let repo = params["repoRoot"] as? String, allows(token: token, repo: repo) else { throw Failure(code: "branchChangeFailed") }
            return try openSession(UUID().uuidString.lowercased(), token: token,
                                   source: ["kind": "branch", "repoRoot": repo, "baseRef": params["baseRef"] ?? ""])
        default:
            throw Failure(code: "invalidRequest")
        }
    }

    private func openSession(_ session: String, token: String, source: [String: Any]) throws -> Any {
        let file = root.appending(path: "diff-session-\(session).patch")
        try Data("diff --git a/x b/x\n".utf8).write(to: file)
        try mutateManifest(token) { files in
            files.append(["request_path": "/diff-session-\(session).patch", "file_path": file.path, "mime_type": "text/x-diff",
                          "remote_url": NSNull()])
        }
        return ["type": "sessionOpened", "value": [
            "sessionId": session,
            "patch": ["id": "cmux-page://cmux.diff/__patch/\(token)/diff-session-\(session).patch", "mediaType": "text/x-diff",
                      "byteLength": 19, "revision": 1],
            "source": source, "generatedPaths": [String](),
        ]]
    }

    private func branchSession(group: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: root.appending(path: ".branch-session-\(group).json")) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func sessions() -> [[String: Any]] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.filter { $0.hasPrefix(".branch-session-") }.compactMap { name in
            let group = String(name.dropFirst(".branch-session-".count).dropLast(".json".count))
            return branchSession(group: group)
        }
    }

    private func grantExists(token: String) -> Bool { sessions().contains { $0["token"] as? String == token } }

    private func allows(token: String, repo: String) -> Bool {
        sessions().contains { $0["token"] as? String == token && ($0["allowedRepoRoots"] as? [String] ?? []).contains(repo) }
    }

    private func mutateManifest(_ token: String, _ update: (inout [[String: Any]]) -> Void) throws {
        let url = root.appending(path: ".manifest-\(token).json")
        var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
        var files = manifest["files"] as? [[String: Any]] ?? []
        update(&files)
        manifest["files"] = files
        try JSONSerialization.data(withJSONObject: manifest).write(to: url)
    }

    static func encode(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }
}

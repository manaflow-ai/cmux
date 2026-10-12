import CmuxNextDaemon
import Foundation

/// `cmux link access` (cmux-tui `link/access_cli.rs`, spec "Access requests"): a moved chat's file
/// requests for this Mac (``CloudAccessAsks``) and the folders it was granted. Each command prints a
/// last stdout line `{"ok":...,"error":...,"error_code":...}`; the app reads only that line.
nonisolated struct CloudAccessCLI: Sendable {
    /// One file the machine's agent asks for, as `triage` lists it with this Mac's view of it. Every
    /// field but ``session`` (which the app checks against its own ledger) is the CLI's report about
    /// a path the machine named.
    struct FileAsk: Sendable, Equatable {
        var requestID: String
        var session: String
        /// The path asked for, absolute on this Mac.
        var path: String
        var reason: String?
        var shareable: Bool
        /// Where the path leads (canonical); nil when it can't be shared.
        var target: String?
        /// Whether the item is a folder; nil when it can't be read.
        var folder: Bool?
        /// The folder "Always" would share; nil when none may be.
        var alwaysFolder: String?
    }

    /// The person's answer to one ask, naming again what the card showed.
    enum How: Sendable, Equatable {
        case allow(path: String, target: String)
        case always(path: String, target: String, folder: String)
        case deny
    }

    struct Answer: Sendable, Equatable {
        var ok: Bool
        var errorCode: String?
        var error: String?
        /// `triage`: the file asks left for the person.
        var asks: [FileAsk] = []
        /// `triage`'s per-request errors and `sync`'s failed copies.
        var failures = 0
    }

    let binary: URL
    var timeout: Duration = .seconds(120)

    /// `triage`: answers what needs no person and lists the rest, for the chats `sessions` only.
    func triage(socket: String, machine: String, sessions: [String]) async throws -> Answer {
        try await run(["link", "access", "triage", "--socket", socket, "--machine", machine] + sessions.flatMap { ["--session", $0] })
    }

    /// `answer`: the person's answer to request `request` of chat `session`.
    func answer(socket: String, machine: String, session: String, request: String, remoteRoot: String, how: How) async throws -> Answer {
        let flags: [String] = switch how {
        case .allow(let path, let target): ["--allow", path, "--target", target]
        case .always(let path, let target, let folder): ["--always", path, "--target", target, "--folder", folder]
        case .deny: ["--deny"]
        }
        return try await run(["link", "access", "answer", "--socket", socket, "--machine", machine, "--session", session,
                              "--request", request, "--remote-root", remoteRoot] + flags)
    }

    /// `sync`: copies the machine's granted folders again.
    func sync(socket: String, machine: String) async throws -> Answer {
        try await run(["link", "access", "sync", "--socket", socket, "--machine", machine])
    }

    /// `revoke --all`: ends chat `session`'s grants; with `socket`, also deletes their read-only copies there.
    func revoke(socket: String?, machine: String, session: String) async throws -> Answer {
        try await run(["link", "access", "revoke", "--machine", machine, "--session", session] + (socket.map { ["--socket", $0] } ?? []) + ["--all"])
    }

    private func run(_ arguments: [String]) async throws -> Answer {
        let result = try await ProcessRunner.run(executable: binary, arguments: arguments, environment: nil,
                                                 timeout: timeout, clock: ContinuousClock())
        let lines = String(decoding: result.stdout, as: UTF8.self).split(separator: "\n")
        guard let line = lines.last(where: { !$0.allSatisfy(\.isWhitespace) }),
              let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              let ok = object["ok"] as? Bool else {
            return Answer(ok: false, errorCode: CloudMoveCLI.badAnswer, error: "exit \(result.status)")
        }
        let asks = (object["ask"] as? [[String: Any]] ?? []).compactMap(Self.fileAsk)
        let failedSyncs = (object["synced"] as? [[String: Any]] ?? []).filter { $0["ok"] as? Bool != true }.count
        return Answer(ok: ok, errorCode: object["error_code"] as? String, error: object["error"] as? String, asks: asks,
                      failures: (object["errors"] as? [Any] ?? []).count + failedSyncs)
    }

    /// A file ask, nil for any other kind (a secret needs a text field, not this card) or one that
    /// breaks the contract: a request id that isn't 32 lowercase hex digits, a path that isn't absolute.
    private static func fileAsk(_ object: [String: Any]) -> FileAsk? {
        guard object["kind"] as? String == "file", let id = object["request_id"] as? String, id.utf8.count == 32,
              id.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              let session = object["session"] as? String, let path = object["path"] as? String, path.hasPrefix("/") else { return nil }
        let target = object["target"] as? String, always = object["always_folder"] as? String
        guard target?.hasPrefix("/") != false, always?.hasPrefix("/") != false else { return nil }
        return FileAsk(requestID: id, session: session, path: path, reason: object["reason"] as? String,
                       shareable: object["shareable"] as? Bool == true, target: target, folder: object["folder"] as? Bool, alwaysFolder: always)
    }
}

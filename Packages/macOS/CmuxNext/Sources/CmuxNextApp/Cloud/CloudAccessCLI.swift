import CmuxNextAgentPane
import CmuxNextDaemon
import Foundation

/// `cmux link access` (cmux-tui `link/access_cli.rs`, spec "Access requests"): a moved chat's file
/// and secret requests for this Mac (``CloudAccessAsks``) and the folders it was granted. Each command prints a
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

    /// One secret the machine's agent asks the person for, by name, as `triage` lists it. The name
    /// matches the machine daemon's rule (else it is dropped, never answered).
    struct SecretAsk: Sendable, Equatable {
        var requestID: String
        var session: String
        var name: String
        var reason: String?
    }

    /// The person's answer to one ask, naming again what the card showed.
    enum How: Sendable, Equatable {
        case allow(path: String, target: String)
        case always(path: String, target: String, folder: String)
        /// What the person typed for secret `name`: it goes to `answer` on stdin only. Swift can't
        /// wipe a `String`, so the copies here and in the stdin `Data` are freed, not zeroed.
        case shareSecret(name: String, value: AgentPaneToolCard.Entered)
        case deny
    }

    struct Answer: Sendable, Equatable {
        var ok: Bool
        var errorCode: String?
        var error: String?
        /// `triage`: the file and secret asks left for the person.
        var asks: [FileAsk] = []
        var secrets: [SecretAsk] = []
        /// `triage`'s per-request errors and `sync`'s failed copies.
        var failures = 0
        /// `upload`: where each file went on the machine, in the order given.
        var uploaded: [String] = []
        /// `upload`: each file's upload id, in the same order (``removeUploads(socket:remoteRoot:ids:)``).
        var uploadIDs: [String] = []
    }

    let binary: URL
    var timeout: Duration = .seconds(120)
    /// Upload replies contain paths/errors, never file bytes. Retain enough for the legacy
    /// multi-file reply as well as diagnostics, without reading all of a long transfer's heartbeats.
    static let uploadOutputTailBytes = 4 * 1024 * 1024
    /// An upload's stdout may stay silent this long: longer than the CLI's 60 s socket deadline.
    static let uploadIdle: Duration = .seconds(90)

    /// `triage`: answers what needs no person and lists the rest, for the chats `sessions` only.
    func triage(socket: String, machine: String, sessions: [String]) async throws -> Answer {
        try await run(["link", "access", "triage", "--socket", socket, "--machine", machine] + sessions.flatMap { ["--session", $0] })
    }

    /// `answer`: the person's answer to request `request` of chat `session`. A secret's value goes on
    /// stdin, never in the arguments, and no remote root goes with it (nothing is copied).
    func answer(socket: String, machine: String, session: String, request: String, remoteRoot: String, how: How) async throws -> Answer {
        let chat = ["link", "access", "answer", "--socket", socket, "--machine", machine, "--session", session, "--request", request]
        switch how {
        case .allow(let path, let target): return try await run(chat + ["--remote-root", remoteRoot, "--allow", path, "--target", target])
        case .always(let path, let target, let folder):
            return try await run(chat + ["--remote-root", remoteRoot, "--always", path, "--target", target, "--folder", folder])
        case .shareSecret(let name, let value): return try await run(chat + ["--share-secret", name], stdin: Data(value.text.utf8))
        case .deny: return try await run(chat + ["--remote-root", remoteRoot, "--deny"])
        }
    }

    /// `upload`: copies `files` (in this Mac's temporary `cmux-pastes`) to the machine, each under `remoteRoot`.
    /// Each file goes in its own call under an id of this app's (``Answer/uploadIDs``), so any count
    /// of files is taken, and a failure or a cancel removes every file of this upload from the
    /// machine, the partial one and those already sent, before it answers.
    func upload(socket: String, remoteRoot: String, files: [String]) async throws -> Answer {
        var sent = Answer(ok: true)
        for file in files {
            let answer: Answer
            do { answer = try await uploadOne(socket: socket, remoteRoot: remoteRoot, file: file) } catch {
                try await removeUploads(socket: socket, remoteRoot: remoteRoot, ids: sent.uploadIDs)
                throw error
            }
            guard answer.ok, answer.uploaded.count == 1 else {
                try await removeUploads(socket: socket, remoteRoot: remoteRoot, ids: sent.uploadIDs + answer.uploadIDs)
                return Answer(ok: false, errorCode: answer.errorCode, error: answer.error)
            }
            sent.uploaded += answer.uploaded
            sent.uploadIDs += answer.uploadIDs
        }
        return sent
    }

    /// One file under a fresh upload id; a failed or cancelled transfer removes its partial file.
    private func uploadOne(socket: String, remoteRoot: String, file: String) async throws -> Answer {
        // Upload emits a heartbeat as each slice of a part reaches the socket and as each part's
        // answer comes. Only a silent link times out, and the idle window outlasts the CLI's own
        // 60 s per-read/write socket deadline (sync_cli/remote.rs IO_DEADLINE), so a transfer the
        // transport still allows is never cut short; elapsed time never imposes a file-size ceiling.
        let id = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        var answer: Answer
        do {
            answer = try await run(["link", "access", "upload", "--socket", socket, "--remote-root", remoteRoot, "--upload-id", id, file],
                                   progressIdle: Self.uploadIdle, outputTailBytes: Self.uploadOutputTailBytes)
        } catch {
            try await removeUploads(socket: socket, remoteRoot: remoteRoot, ids: [id])
            throw error
        }
        if !answer.ok || Task.isCancelled {
            try await removeUploads(socket: socket, remoteRoot: remoteRoot, ids: [id])
            try Task.checkCancellation()
            return answer
        }
        answer.uploadIDs = [id]
        return answer
    }

    /// Removes uploads `ids` (each one's own folder) from the machine, trying every id and throwing
    /// after them all when any stayed. It runs outside a cancelled caller's task (ProcessRunner reaps
    /// a stopped child first), so the files are gone before a cancel answers.
    func removeUploads(socket: String, remoteRoot: String, ids: [String]) async throws {
        var removedAll = true
        for id in ids {
            let arguments = ["link", "access", "upload-cancel", "--socket", socket, "--remote-root", remoteRoot, "--upload-id", id]
            let cleanup = Task.detached(priority: .userInitiated) { try await run(arguments, outputTailBytes: Self.uploadOutputTailBytes) }
            if (try? await cleanup.value)?.ok != true { removedAll = false }
        }
        if !removedAll { throw CancellationError() }
    }

    /// `sync`: copies chat `session`'s granted folders on the machine again.
    func sync(socket: String, machine: String, session: String) async throws -> Answer {
        try await run(["link", "access", "sync", "--socket", socket, "--machine", machine, "--session", session])
    }

    /// `revoke --all`: ends chat `session`'s grants; with `socket`, also deletes their read-only copies there.
    func revoke(socket: String?, machine: String, session: String) async throws -> Answer {
        try await run(["link", "access", "revoke", "--machine", machine, "--session", session] + (socket.map { ["--socket", $0] } ?? []) + ["--all"])
    }

    private func run(_ arguments: [String], stdin: Data? = nil, timeout: Duration? = nil, progressIdle: Duration? = nil, outputTailBytes: Int? = nil) async throws -> Answer {
        let result = try await ProcessRunner.run(executable: binary, arguments: arguments, environment: nil, stdin: stdin,
                                                 timeout: progressIdle == nil ? (timeout ?? self.timeout) : timeout, progressIdle: progressIdle, outputTailBytes: outputTailBytes, clock: ContinuousClock())
        let lines = String(decoding: result.stdout, as: UTF8.self).split(separator: "\n")
        guard let line = lines.last(where: { !$0.allSatisfy(\.isWhitespace) }),
              let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              let ok = object["ok"] as? Bool else {
            return Answer(ok: false, errorCode: CloudMoveCLI.badAnswer, error: "exit \(result.status)")
        }
        let listed = object["ask"] as? [[String: Any]] ?? []
        let failedSyncs = (object["synced"] as? [[String: Any]] ?? []).filter { $0["ok"] as? Bool != true }.count
        let uploaded = (object["uploads"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
        return Answer(ok: ok, errorCode: object["error_code"] as? String, error: object["error"] as? String, asks: listed.compactMap(Self.fileAsk),
                      secrets: listed.compactMap(Self.secretAsk), failures: (object["errors"] as? [Any] ?? []).count + failedSyncs, uploaded: uploaded)
    }

    /// A request id as the machine daemon mints them: 32 lowercase hex digits.
    private static func requestID(_ object: [String: Any]) -> String? {
        guard let id = object["request_id"] as? String, id.utf8.count == 32,
              id.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        return id
    }

    /// A secret ask, nil for any other kind or a name outside the daemon's rule (`A-Za-z0-9._-`, 1 to 128 bytes).
    private static func secretAsk(_ object: [String: Any]) -> SecretAsk? {
        guard object["kind"] as? String == "secret", let id = requestID(object), let session = object["session"] as? String,
              let name = object["name"] as? String, (1...128).contains(name.utf8.count),
              name.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 46 || $0 == 95 || $0 == 45 })
        else { return nil }
        return SecretAsk(requestID: id, session: session, name: name, reason: object["reason"] as? String)
    }

    /// A file ask, nil for any other kind or one that breaks the contract: a request id that isn't
    /// 32 lowercase hex digits, a path that isn't absolute.
    private static func fileAsk(_ object: [String: Any]) -> FileAsk? {
        guard object["kind"] as? String == "file", let id = requestID(object),
              let session = object["session"] as? String, let path = object["path"] as? String, path.hasPrefix("/") else { return nil }
        let target = object["target"] as? String, always = object["always_folder"] as? String
        guard target?.hasPrefix("/") != false, always?.hasPrefix("/") != false else { return nil }
        return FileAsk(requestID: id, session: session, path: path, reason: object["reason"] as? String,
                       shareable: object["shareable"] as? Bool == true, target: target, folder: object["folder"] as? Bool, alwaysFolder: always)
    }
}

public import Foundation
import CmuxNextDaemon

/// Projected folders (cmux-tui `link/start_chat_cli/projected.rs` and `projected_serve.rs`): a Cloud chat starts on a
/// folder too big to copy without copying it. `project` sends the machine a list of the folder's files and mounts it
/// there; `project-serve` answers the machine's reads of each file from this Mac for as long as it runs
/// (``CloudProjectedFolders`` owns those children); `project-pull` brings the machine's edits back.
///
/// TRANSITIONAL until CCmuxAppFFI is repinned past a cmux-cloud-start-core that names these verbs: their arguments are
/// named here and their one JSON line is read here, where every other call's go through Rust (`cli_invocation`, `cli_read`).
extension CloudMoveCLI {
    /// `link start-chat project`'s answer: the folder is mounted on the machine. `machinePath` is the chat's folder
    /// there (the mounted `folder`, or the chat's subfolder in it); `mount` names the projection on this Mac.
    public nonisolated struct StartChatProjection: Sendable, Equatable, Decodable {
        public var mount: String
        public var machinePath: String
        public var folder: String
        /// The files and folders it lists, their bytes, and the files the copy's rules left out; nil when not answered.
        public var entries: Int64?, bytes: Int64?, skipped: Int64?

        public init(mount: String, machinePath: String, folder: String, entries: Int64? = nil, bytes: Int64? = nil, skipped: Int64? = nil) {
            (self.mount, self.machinePath, self.folder, self.entries, self.bytes, self.skipped) = (mount, machinePath, folder, entries, bytes, skipped)
        }

        enum CodingKeys: String, CodingKey { case mount, machinePath = "machine_path", folder, entries, bytes, skipped }

        /// The counts are read when they are numbers: a mount that answered is never lost to a count's shape.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            mount = try container.decode(String.self, forKey: .mount)
            machinePath = try container.decode(String.self, forKey: .machinePath)
            folder = try container.decode(String.self, forKey: .folder)
            entries = (try? container.decodeIfPresent(Int64.self, forKey: .entries)) ?? nil
            bytes = (try? container.decodeIfPresent(Int64.self, forKey: .bytes)) ?? nil
            skipped = (try? container.decodeIfPresent(Int64.self, forKey: .skipped)) ?? nil
        }
    }

    /// `link start-chat project`'s refusal (`fallback: copy`): nothing is mounted and no record is kept, so the start
    /// copies the folder as it would with projected folders off. `code` is cmux-tui's (``badAnswer`` for no answer line).
    public nonisolated struct StartChatProjectRefusal: Error, Sendable, Equatable {
        public var code: String
        /// cmux-tui's sentence; it may name files, so it is never logged.
        public var message: String

        public init(code: String, message: String) { (self.code, self.message) = (code, message) }
    }

    /// `link start-chat project-pull`'s answer: the machine's edits brought back into the folder on this Mac.
    public nonisolated struct StartChatProjectPull: Sendable, Equatable, Decodable {
        /// A file changed on both sides: one side `kept` at the path, the other written `beside` it.
        public struct Conflict: Sendable, Equatable, Decodable {
            public var path: String
            public var kept: String?, beside: String?
            public init(path: String, kept: String? = nil, beside: String? = nil) { (self.path, self.kept, self.beside) = (path, kept, beside) }
        }

        /// A file the pull would not write here, and why.
        public struct Refused: Sendable, Equatable, Decodable {
            public var path: String
            public var reason: String?
            public init(path: String, reason: String? = nil) { (self.path, self.reason) = (path, reason) }
        }

        public var ok: Bool
        public var code: String?, message: String?
        public var conflicts: [Conflict]
        public var refused: [Refused]

        public init(ok: Bool, code: String? = nil, message: String? = nil, conflicts: [Conflict] = [], refused: [Refused] = []) {
            (self.ok, self.code, self.message, self.conflicts, self.refused) = (ok, code, message, conflicts, refused)
        }

        enum CodingKeys: String, CodingKey { case ok, code, message, conflicts, refused }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            ok = try container.decode(Bool.self, forKey: .ok)
            code = try container.decodeIfPresent(String.self, forKey: .code)
            message = try container.decodeIfPresent(String.self, forKey: .message)
            conflicts = try container.decodeIfPresent([Conflict].self, forKey: .conflicts) ?? []
            refused = try container.decodeIfPresent([Refused].self, forKey: .refused) ?? []
        }

        /// The answer as Bring Back's own pull (`link seed pull`) gives it: a pull that kept both sides of a file is
        /// `sync_conflict` naming those files (the bring back stops there and the person's Retry goes on, the next
        /// pull naming none of them again); a failed pull is its code and sentence. `refused` paths (a secret, an
        /// ignored file, a kind this Mac cannot hold) are named on every pull, so they never fail one: they stay on
        /// the machine, as a copy's pull leaves them.
        public var answer: Answer {
            guard ok else { return Answer(ok: false, errorCode: code ?? CloudMoveCLI.badAnswer, error: message) }
            return conflicts.isEmpty ? Answer(ok: true) : Answer(ok: false, errorCode: "sync_conflict", conflicts: conflicts.map(\.path))
        }
    }

    /// `link start-chat project`'s arguments: `copy`'s own (`--subpath` and every `--work-root` mean the same).
    public static func startChatProjectArguments(key: String, account: String, machine: String, socket: String, local: String,
                                                 subpath: String, workRoots: [String]) -> [String] {
        ["link", "start-chat", "project", "--key", key, "--account", account, "--machine", machine, "--socket", socket,
         "--local", local, "--subpath", subpath] + workRoots.flatMap { ["--work-root", $0] }
    }

    /// `link start-chat project-serve`'s arguments: the record's socket unless `socket` names another.
    public static func startChatProjectServeArguments(mount: String, socket: String? = nil) -> [String] {
        ["link", "start-chat", "project-serve", "--mount", mount] + (socket.map { ["--socket", $0] } ?? [])
    }

    /// `link start-chat project-pull`'s arguments.
    public static func startChatProjectPullArguments(mount: String, socket: String? = nil) -> [String] {
        ["link", "start-chat", "project-pull", "--mount", mount] + (socket.map { ["--socket", $0] } ?? [])
    }

    /// `link start-chat project`: mounts `local` on the machine `socket` reaches as a projection, in a folder of the
    /// send's own under the first of `workRoots` it can write. Throws ``StartChatProjectRefusal`` for its refusal (and
    /// for no answer line); a run that did not finish in ``timeout`` throws the runner's error.
    public func startChatProject(key: String, account: String, machine: String, socket: String, local: String, subpath: String,
                                 workRoots: [String]) async throws -> StartChatProjection {
        struct Line: Decodable { var ok: Bool?; var code: String?; var message: String? }
        let data = try await projectedLine(Self.startChatProjectArguments(key: key, account: account, machine: machine, socket: socket,
                                                                          local: local, subpath: subpath, workRoots: workRoots), limit: timeout)
        let line = try? JSONDecoder().decode(Line.self, from: data)
        guard line?.ok == true else { throw StartChatProjectRefusal(code: line?.code ?? Self.badAnswer, message: line?.message ?? "") }
        guard let projection = try? JSONDecoder().decode(StartChatProjection.self, from: data) else {
            throw StartChatProjectRefusal(code: Self.badAnswer, message: "the answer names no mount")
        }
        return projection
    }

    /// `link start-chat project-pull`: the machine's edits to the projected folder `mount`, brought back to this Mac.
    /// An answer that is not a JSON line is a failed pull (``badAnswer``); a run that did not finish throws.
    public func startChatProjectPull(mount: String, socket: String?) async throws -> StartChatProjectPull {
        let data = try await projectedLine(Self.startChatProjectPullArguments(mount: mount, socket: socket), limit: timeout)
        return (try? JSONDecoder().decode(StartChatProjectPull.self, from: data)) ?? StartChatProjectPull(ok: false, code: Self.badAnswer)
    }

    /// `link start-chat preflight --local FOLDER` again (cmux-tui keeps a start's decision for two minutes, so this
    /// reads the one the start just made): whether `local` is past what a copy sends whole (``pastCopyLimits(_:)``).
    public func startChatPastCopyLimits(local: String) async -> Bool {
        guard let data = try? await projectedLine(["link", "start-chat", "preflight", "--local", local], limit: Self.preflightTimeout),
              let answer = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return Self.pastCopyLimits(answer)
    }

    /// cmux-cloud-start-core's `START_CHAT_PREFLIGHT_TIMEOUT_SECONDS`.
    static let preflightTimeout: Duration = .seconds(120)

    /// Whether a preflight answer is past the copy's limits, so a start with projected folders on projects the folder:
    /// a copy that sends a first pass and leaves the rest on this Mac (`estimate.mode` `first_pass`), a folder no Cloud
    /// machine's disk holds (`estimate_bytes` with no `needed_size`), or an older cmux-tui's `copy.too_large`. A whole
    /// copy, a seed (the machine clones the folder's git remote) that a machine holds, an estimate that could not be
    /// read and any other refusal are not: those start as they do with projected folders off.
    public static func pastCopyLimits(_ answer: [String: Any]) -> Bool {
        if StartChatPreflightRefusal(answer: answer) != nil { return true }
        guard answer["ok"] as? Bool == true, let estimate = answer["estimate"] as? [String: Any] else { return false }
        if estimate["mode"] as? String == "first_pass" { return true }
        return answer["estimate_bytes"] is NSNumber && (answer["needed_size"] == nil || answer["needed_size"] is NSNull)
    }

    /// One run's last JSON line (these verbs print one), whatever its exit status.
    private func projectedLine(_ arguments: [String], limit: Duration) async throws -> Data {
        let result = try await ProcessRunner.run(executable: binary, arguments: arguments, environment: nil, timeout: limit, clock: ContinuousClock())
        let stdout = String(decoding: result.stdout, as: UTF8.self)
        guard let line = stdout.split(whereSeparator: \.isNewline).last(where: { $0.hasPrefix("{") }) else {
            throw StartChatProjectRefusal(code: Self.badAnswer, message: "exit \(result.status)")
        }
        return Data(line.utf8)
    }
}

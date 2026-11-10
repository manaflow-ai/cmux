import CmuxNextDaemon
public import Foundation

/// The cmux-tui CLIs Move to Cloud, Bring Back Local and a chat start run (cmux-tui `link/sync_cli.rs`,
/// `link/agent_cli.rs`, `link/start_chat_cli.rs`). Rust names each call's arguments and reads its one
/// JSON answer line (cmux-cloud-start-core `moves::cli`, ops `cloud_move_cli_*`); this only runs the
/// process, with any credential on stdin, never in argv.
public nonisolated struct CloudMoveCLI: Sendable {
    /// One CLI's answer line, as Rust read it.
    public struct Answer: Sendable, Equatable, Codable {
        public var ok: Bool
        public var errorCode: String?
        public var error: String?
        /// `link agent move`: the chat's session on the machine, and the move's id.
        public var sessionID: String?
        public var transferID: String?
        /// `link sync pull`'s `sync_conflict`: the paths changed on both sides.
        public var conflicts: [String] = []
        /// `link agent move`'s `machine_outdated`: the daemon it is about, `source` or `target`.
        public var side: String?
        /// `link machine update`: whether the machine's cmux-tui changed, and the build it runs after it.
        public var updated = false
        public var build: String?
        /// `link machine update --if-older`: the machine runs a build not older than this app's.
        public var notOlder = false
        public var seedState: String?
        public var seedPhase: String?
        public var seedStartedAt: Double?
        public var seedFinishedAt: Double?

        public init(ok: Bool, errorCode: String? = nil, error: String? = nil, sessionID: String? = nil, transferID: String? = nil,
                    conflicts: [String] = [], side: String? = nil, updated: Bool = false, build: String? = nil, notOlder: Bool = false,
                    seedState: String? = nil, seedPhase: String? = nil, seedStartedAt: Double? = nil, seedFinishedAt: Double? = nil) {
            (self.ok, self.errorCode, self.error, self.sessionID, self.transferID) = (ok, errorCode, error, sessionID, transferID)
            (self.conflicts, self.side, self.updated, self.build, self.notOlder) = (conflicts, side, updated, build, notOlder)
            (self.seedState, self.seedPhase, self.seedStartedAt, self.seedFinishedAt) = (seedState, seedPhase, seedStartedAt, seedFinishedAt)
        }

        /// `link machine update`: whether the machine's daemon may have restarted in the run that gave this
        /// answer (an update, a rollback, an end the CLI lost track of). An FFI that does not answer says it may have.
        public var mayHaveRestartedDaemon: Bool {
            struct Reply: Decodable { var restarted: Bool }
            return CloudMoveCore().call("restarted_daemon", self, as: Reply.self)?.restarted ?? true
        }
    }

    /// The `cmux` binary (the bundled cmux-tui).
    public let binary: URL
    /// How long one run may take; past it the run is killed and throws.
    public var timeout: Duration = .seconds(30 * 60)
    /// The daemon's state root (`CMUX_TUI_STATE_DIR`; nil: cmux-tui's default): every run reads and writes the ledgers
    /// the daemon does, so a tagged or per-build app's Send sees the daemon's warm copies and login receipts.
    public var stateDirectory: URL?

    public init(binary: URL, timeout: Duration = .seconds(30 * 60), stateDirectory: URL? = nil) {
        self.binary = binary
        self.timeout = timeout
        self.stateDirectory = stateDirectory
    }

    /// A run's environment: this process's, on the daemon's state root; nil (inherited) without one.
    var environment: [String: String]? {
        stateDirectory.map { ProcessInfo.processInfo.environment.merging(["CMUX_TUI_STATE_DIR": $0.path]) { $1 } }
    }

    /// The error code of an answer that isn't a JSON line (a crash, a kill).
    public static let badAnswer = "bad_answer"
    /// Longer than `link machine update`'s own wait for the machine (25 minutes) plus a first download.
    public static let machineUpdateTimeout: Duration = .seconds(45 * 60)

    /// The folder copy a move makes once the chat is frozen (`--sync`).
    public struct FrozenSync: Sendable, Equatable, Encodable {
        /// Pull from the machine (Bring Back Local) rather than seed it (Move to Cloud).
        public var pull: Bool
        public var socket: String
        public var local: String
        public var remote: String
        /// Machine to machine: the source machine's link socket, and `local` is its folder there;
        /// `seedLocal` is this Mac's folder a Move to Cloud seeded it from, whose record follows.
        public var fromSocket: String?, seedLocal: String?

        public init(pull: Bool, socket: String, local: String, remote: String, fromSocket: String? = nil, seedLocal: String? = nil) {
            (self.pull, self.socket, self.local, self.remote, self.fromSocket, self.seedLocal) = (pull, socket, local, remote, fromSocket, seedLocal)
        }
    }

    /// `cmux link start-chat plan`'s answer: the machine a `cloud.startChat` send takes (nil: make
    /// one named `newName`), pinned to the send, and the send's keys.
    public struct StartChatPlan: Sendable, Equatable, Decodable {
        public var machine: String?
        public var newName: String?
        public var createKey: String
        public var tabKey: String
        public var targetPane: String?
        public var createTeam: String?
        public var createSent: Bool = false
        public var environmentId: String?
        public var setup: CloudStartSetup?

        public init(machine: String? = nil, newName: String? = nil, createKey: String, tabKey: String,
                    environmentId: String? = nil, setup: CloudStartSetup? = nil, targetPane: String? = nil,
                    createTeam: String? = nil, createSent: Bool = false) {
            (self.machine, self.newName, self.createKey, self.tabKey, self.targetPane) = (machine, newName, createKey, tabKey, targetPane)
            (self.createTeam, self.createSent, self.environmentId, self.setup) = (createTeam, createSent, environmentId, setup)
        }
    }

    /// `cmux link seed push`: seeds `local` at `remote` from its GitHub remote plus one bundle, else copies it.
    public func seedPush(socket: String, local: String, remote: String) async throws -> Answer {
        try await run(["verb": "seed-push", "socket": socket, "local": local, "remote": remote]).answer
    }

    /// `cmux link seed pull --or-copy` (Bring Back Local).
    public func bringBackPull(socket: String, local: String, remote: String) async throws -> Answer {
        try await run(["verb": "bring-back-pull", "socket": socket, "local": local, "remote": remote]).answer
    }

    /// `cmux link agent move`: moves the chat of tab `surface` of the daemon at `from` to the machine daemon at `to`,
    /// in `cwd`; a running turn stops for the move and goes on where the chat lands. `sync` copies the folder's last
    /// changes once the chat is frozen, then `thenSync` (Move to Another Machine: a pull from the machine the chat
    /// leaves, then a seed of the one it goes to); `askFirst` narrows it to an asking policy first; `vmKind` is the
    /// Cloud API's answer for this app on the link in use.
    public func agentMove(from: String, surface: UInt64, to: String, cwd: String, sync: FrozenSync? = nil, thenSync: FrozenSync? = nil,
                          askFirst: Bool = false, vmKind: String? = nil, toPID: Int32? = nil) async throws -> Answer {
        struct Call: Encodable {
            var verb = "agent-move"
            var from: String, surface: UInt64, to: String, cwd: String, sync: FrozenSync?, thenSync: FrozenSync?, askFirst: Bool, vmKind: String?
            var toPid: Int32?
        }
        return try await run(Call(from: from, surface: surface, to: to, cwd: cwd, sync: sync, thenSync: thenSync, askFirst: askFirst,
                                  vmKind: vmKind, toPid: toPID)).answer
    }

    /// `cmux link machine update`: updates the machine's cmux-tui to this app's own pinned build when it is outdated;
    /// `toBundled` whenever it runs another build, with `ifOlder` only when that build is older than this app's.
    public func machineUpdate(socket: String, toBundled: Bool = false, ifOlder: Bool = false) async throws -> Answer {
        struct Call: Encodable { var verb = "machine-update"; var socket: String, toBundled: Bool, ifOlder: Bool }
        return try await run(Call(socket: socket, toBundled: toBundled, ifOlder: ifOlder), reading: "machine-update").answer
    }

    /// `cmux link machine pin`: its output, the Linux build this client pins (``CloudLegacyPin/pin(answer:)``).
    public func machinePin() async -> Data? { try? await output(["verb": "machine-pin"]).stdout }

    /// The defaults key of ``copiesLoginOnClaim(_:)``.
    public static let copyLoginOnClaimKey = "cmux.cloud.copyLoginOnClaim"

    /// Whether a reserve's or a claim's machine starts the login copy onto that machine (cmux-platform#1084, item (a)).
    /// On unless `cmux.cloud.copyLoginOnClaim` is NO (Leo, 2026-11-09: "at least frontload the stuff that we can check earlier").
    public static func copiesLoginOnClaim(_ defaults: UserDefaults) -> Bool { defaults.object(forKey: copyLoginOnClaimKey) as? Bool ?? true }

    /// The machine a reservation answer (the daemon's `cloud-start-chat-reservation`, read as an object) reserved; nil for a refusal.
    public static func reservedMachine(_ reply: [String: Any]) -> String? {
        guard reply["ok"] as? Bool == true, let machine = reply["machine"] as? String, !machine.isEmpty else { return nil }
        return machine
    }

    /// A start's wait on a spare warm's login copy onto `machine` (Rust's `wait-copy`, at most 80 s): returns once no
    /// copy of `provider`'s login onto it is in flight, at once for a provider the warm does not copy.
    public func startChatWaitCopy(machine: String, provider: String) async {
        struct Call: Encodable { var verb = "start-chat-warm-spare"; var request: String }
        let wait: [String: Any] = ["account": "wait", "waitCopy": ["machine": machine, "provider": provider]]
        guard let payload = try? JSONSerialization.data(withJSONObject: wait, options: [.sortedKeys]) else { return }
        _ = try? await run(Call(request: String(decoding: payload, as: UTF8.self)), reading: "reservation", stdin: nil)
    }

    /// Whether a warm installed `account`'s `provider` login on `machine` recently and no newer copy onto it is in flight
    /// (Rust's `loginReceipt`): the start then checks and passes no login of its own. False on any failure.
    public func startChatLoginReceipt(machine: String, account: String, provider: String) async -> Bool {
        struct Call: Encodable { var verb = "start-chat-warm-spare"; var request: String }
        let ask: [String: Any] = ["account": account, "loginReceipt": ["machine": machine, "provider": provider]]
        guard let payload = try? JSONSerialization.data(withJSONObject: ask, options: [.sortedKeys]),
              let read = try? await run(Call(request: String(decoding: payload, as: UTF8.self)), reading: "reservation", stdin: nil),
              let object = read.object, let reply = try? JSONSerialization.jsonObject(with: object) as? [String: Any] else { return false }
        return reply["installed"] as? Bool == true
    }

    /// `cmux link start-chat plan --request JSON`, the cmux `access` token on stdin.
    /// `install`: a reserved send's install token, whose team Rust binds the reservation in (`install_team`).
    public func startChatPlan(request: String, access: String? = nil, install: String? = nil) async throws -> (Answer, StartChatPlan) {
        let read = try await run(["verb": "start-chat-plan", "request": request], reading: "start-chat-plan", stdin: access.map { Data(($0 + "\n" + (install.map { $0 + "\n" } ?? "")).utf8) })
        return (read.answer, read.plan ?? StartChatPlan(createKey: "", tabKey: ""))
    }

    /// `cmux link start-chat pin`: the send `key` of `account` runs on `machine`, one the App just made for it.
    public func startChatPin(key: String, account: String, machine: String, workspace: String?) async throws -> (Answer, Void) {
        var call = ["verb": "start-chat-pin", "key": key, "account": account, "machine": machine]
        call["workspace"] = workspace
        return (try await run(call).answer, ())
    }

    public func startChatCreateBegin(key: String, account: String, name: String, createKey: String) async throws -> (Answer, Void) {
        (try await run(["verb": "start-chat-create-begin", "key": key, "account": account, "name": name, "createKey": createKey]).answer, ())
    }

    public func startChatCreateSent(key: String, account: String, team: String, createKey: String) async throws -> (Answer, Void) {
        (try await run(["verb": "start-chat-create-sent", "key": key, "account": account, "team": team, "createKey": createKey]).answer, ())
    }

    public func startChatCreateRefused(key: String, account: String, createKey: String) async throws -> (Answer, Void) {
        (try await run(["verb": "start-chat-create-refused", "key": key, "account": account, "createKey": createKey]).answer, ())
    }

    public func startChatTargetPane(key: String, account: String, machine: String, pane: String) async throws -> (Answer, Void) {
        (try await run(["verb": "start-chat-target-pane", "key": key, "account": account, "machine": machine, "pane": pane]).answer, ())
    }

    /// `cmux link start-chat import`: hands cmux-tui the sends this App kept itself before (`entries`, their JSON).
    public func startChatImport(entries: String) async throws -> (Answer, Void) {
        (try await run(["verb": "start-chat-import", "entries": entries]).answer, ())
    }

    /// `cmux link start-chat copy`: copies `local` to a folder of the send's own on the machine `socket` reaches, under the
    /// first of `workRoots` it can write, unless this send's copy already finished there. With the cmux `access` token
    /// (on stdin) it goes through the content-addressed store. The chat's folder there, whether it copied now, and
    /// whether this Mac's acpmux (home `acpmuxHome`) trusts the chat's folder here.
    public func startChatCopy(key: String, account: String, machine: String, socket: String, local: String, subpath: String,
                              workRoots: [String], acpmuxHome: String?, access: String? = nil,
                              stderrLine: (@Sendable (String) -> Void)? = nil) async throws -> (Answer, (chat: String, folder: String, copied: Bool, sourceTrusted: Bool)) {
        struct Call: Encodable {
            var verb = "start-chat-copy"
            var key: String, account: String, machine: String, socket: String, local: String, subpath: String
            var workRoots: [String], acpmuxHome: String?, store: Bool
        }
        let call = Call(key: key, account: account, machine: machine, socket: socket, local: local, subpath: subpath, workRoots: workRoots,
                        acpmuxHome: acpmuxHome, store: access != nil)
        let read = try await run(call, reading: "start-chat-copy", stdin: access.map { Data(($0 + "\n").utf8) }, stderrLine: stderrLine)
        let copy = read.copy
        return (read.answer, (copy?.chat ?? "", copy?.folder ?? "", copy?.copied ?? false, copy?.sourceTrusted ?? false))
    }

    /// What Rust read of one run.
    private struct Read: Decodable {
        struct Copy: Decodable { var chat: String, folder: String, copied: Bool, sourceTrusted: Bool }
        var answer: Answer
        var plan: StartChatPlan?
        var copy: Copy?
        /// The reservation's answer object, as JSON.
        var object: Data?

        enum CodingKeys: String, CodingKey { case answer, plan, copy, object }
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            answer = try container.decode(Answer.self, forKey: .answer)
            plan = try container.decodeIfPresent(StartChatPlan.self, forKey: .plan)
            copy = try container.decodeIfPresent(Copy.self, forKey: .copy)
            object = try container.decodeIfPresent(JSONValue.self, forKey: .object).flatMap { try? JSONEncoder().encode($0) }
        }

        init(answer: Answer) { self.answer = answer }
    }

    /// One run's output, for Rust to read.
    private struct ReadRequest: Encodable { var reading: String, stdout: String, stderr: String, status: Int32 }

    /// How Rust says to run a call.
    private struct Invocation: Decodable { var args: [String], timeoutSeconds: Int?, minTimeoutSeconds: Int? }

    private func output<Call: Encodable>(_ call: Call, stdin: Data? = nil, stderrLine: (@Sendable (String) -> Void)? = nil) async throws -> ProcessResult {
        guard let invocation = CloudMoveCore().call("cli_invocation", call, as: Invocation.self) else { throw CloudMoveCLIUnanswered() }
        let limit = invocation.timeoutSeconds.map { Duration.seconds($0) } ?? max(timeout, .seconds(invocation.minTimeoutSeconds ?? 0))
        return try await ProcessRunner.run(executable: binary, arguments: invocation.args, environment: environment, stdin: stdin,
                                           timeout: limit, stderrLine: stderrLine, clock: ContinuousClock())
    }

    private func run<Call: Encodable>(_ call: Call, reading: String = "plain", stdin: Data? = nil,
                                      stderrLine: (@Sendable (String) -> Void)? = nil) async throws -> Read {
        let result = try await output(call, stdin: stdin, stderrLine: stderrLine)
        let request = ReadRequest(reading: reading, stdout: String(decoding: result.stdout, as: UTF8.self),
                              stderr: String(decoding: result.stderr, as: UTF8.self), status: result.status)
        return CloudMoveCore().call("cli_read", request, as: Read.self)
            ?? Read(answer: Answer(ok: false, errorCode: Self.badAnswer, error: "exit \(result.status)"))
    }
}

/// The app FFI did not name a CLI call's arguments.
struct CloudMoveCLIUnanswered: Error {}

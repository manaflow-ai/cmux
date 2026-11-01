import CmuxNextDaemon
import Foundation

/// The cmux-tui CLIs Move to Cloud and Bring Back Local run (cmux-tui `link/sync_cli.rs` and
/// `link/agent_cli.rs`). Each prints one JSON line on stdout:
/// `{"ok":true,...}` with exit 0, or `{"ok":false,"error":...,"error_code":...}`
/// with exit 1; bad usage exits 64. The app reads only that line.
nonisolated struct CloudMoveCLI: Sendable {
    /// One CLI's answer line.
    struct Answer: Sendable, Equatable {
        var ok: Bool
        var errorCode: String?
        var error: String?
        /// `link agent move`: the chat's session on the machine.
        var sessionID: String?
        /// `link agent move`: the move's id.
        var transferID: String?
        /// `link sync pull`'s `sync_conflict`: the paths changed on both sides.
        var conflicts: [String] = []
        /// `link agent move`'s `machine_outdated`: the daemon it is about, `source` or `target`.
        var side: String?
        /// `link machine update`: whether the machine's cmux-tui changed.
        var updated = false
        /// `link machine update`: the build the machine runs after it; with
        /// `machine_update_unsupported`, the build it was judged on (it still runs it).
        var build: String?
        /// `link machine update --if-older`: the machine runs another build that is not older than
        /// this app's (a newer one, or the same source tree), so it was left alone.
        var notOlder = false
    }

    /// The `cmux` binary (the bundled cmux-tui).
    let binary: URL
    /// How long one run may take (``CloudMoveSetup/timeout``); past it the run is killed and throws.
    var timeout: Duration = .seconds(30 * 60)
    /// The error code of an answer that isn't a JSON line (a crash, a kill).
    static let badAnswer = "bad_answer"

    /// `cmux link seed push`: seeds `local` at `remote` on the machine `socket` reaches from its
    /// GitHub remote plus one bundle, else copies it (`link sync push`), saying why.
    func seedPush(socket: String, local: String, remote: String) async throws -> Answer {
        try await run(["link", "seed", "push", "--socket", socket, local, remote])
    }

    /// `cmux link sync pull`: merges the machine's `remote` (what a push left there) back into
    /// `local`; a conflict changes nothing here and lists its paths.
    func syncPull(socket: String, local: String, remote: String) async throws -> Answer {
        try await run(["link", "sync", "pull", "--socket", socket, local, remote])
    }

    /// The folder copy a move makes once the chat is frozen (`--sync`): what changed since the
    /// caller's own sync, so a chat moved mid-turn takes the turn's last changes with it.
    struct FrozenSync: Sendable, Equatable {
        /// Pull from the machine (Bring Back Local) rather than seed it (Move to Cloud, `--since-last`).
        var pull: Bool
        /// The machine link socket `link sync` uses.
        var socket: String
        var local: String
        var remote: String
    }

    /// `cmux link agent move`: moves the chat of tab `surface` of the daemon at
    /// `from` to the machine daemon at `to`, where it runs in `cwd`. A rerun
    /// resolves a move an earlier run left unresolved. A running turn stops for the move
    /// (`--interrupt`) and goes on where the chat lands (acpmux queues its continuation), with
    /// `sync` copying the folder's last changes once the chat is frozen. `askFirst` has the source
    /// narrow the chat to an asking policy and mode before it moves (`--ask-first`). `vmKind`
    /// (`--vm-kind`): for a move onto a Cloud machine, the Cloud API's answer for this app on the
    /// link in use, which that machine's daemon takes the chat on (only `owner`), never its own record.
    func agentMove(from: String, surface: UInt64, to: String, cwd: String, sync: FrozenSync? = nil, askFirst: Bool = false,
                   vmKind: String? = nil, toPID: Int32? = nil) async throws -> Answer {
        try await run(["link", "agent", "move", "--from-socket", from, "--surface", String(surface), "--to-socket", to, "--cwd", cwd]
            + Self.agentMoveFlags(sync: sync, askFirst: askFirst, vmKind: vmKind, toPID: toPID))
    }

    /// `agentMove`'s flags after `--cwd`.
    static func agentMoveFlags(sync: FrozenSync?, askFirst: Bool, vmKind: String?, toPID: Int32?) -> [String] {
        let frozen = sync.map { ["--sync", $0.pull ? "pull" : "seed", "--sync-socket", $0.socket, "--sync-local", $0.local, "--sync-remote", $0.remote] } ?? []
        return ["--interrupt"] + frozen + (askFirst ? ["--ask-first"] : []) + (vmKind.map { ["--vm-kind", $0] } ?? [])
            + (toPID.map { ["--to-pid", String($0)] } ?? [])
    }

    /// `cmux link machine update`: updates the cmux-tui of the machine whose daemon `socket`
    /// reaches to this app's own pinned build, when that machine is outdated (cx-rppd.13).
    /// `toBundled` (`--to-bundled`): whenever it runs another build than this app's; with
    /// `ifOlder` (`--if-older`, the automatic update) only when that build is older than this
    /// app's, by the source commit time both report, so a machine on a newer build is never moved
    /// back. Either way the build is the one pinned beside this binary; nothing here picks it.
    func machineUpdate(socket: String, toBundled: Bool = false, ifOlder: Bool = false) async throws -> Answer {
        let flags = toBundled ? ["--to-bundled"] + (ifOlder ? ["--if-older"] : []) : []
        let run = try await parsed(["link", "machine", "update", "--socket", socket] + flags, timeout: max(timeout, Self.machineUpdateTimeout))
        return Self.machineUpdateAnswer(run.answer, object: run.object, status: run.status)
    }

    /// A `link machine update` success is exit 0 with `updated`, and with the `build` it reached
    /// when it updated. Any other `ok` line is no answer: an update that ran but said nothing of
    /// its outcome must not read as a machine that needed nothing.
    static func machineUpdateAnswer(_ answer: Answer, object: [String: Any]?, status: Int32) -> Answer {
        guard answer.ok else { return answer }
        guard status == 0, let object, let updated = object["updated"] as? Bool,
              !updated || (object["build"] as? String).map({ !$0.isEmpty }) == true else {
            return Answer(ok: false, errorCode: badAnswer, error: "link machine update answered ok without its outcome (exit \(status))")
        }
        return answer
    }

    /// `cmux link machine pin` (cmux-tui `link/machine_pin.rs`): its output, the Linux build this client pins (``CloudLegacyPin/pin(answer:)``).
    func machinePin() async -> Data? { try? await ProcessRunner.run(executable: binary, arguments: ["link", "machine", "pin"], environment: nil, timeout: .seconds(150), clock: ContinuousClock()).stdout }

    /// `cmux link start-chat plan`'s answer: the machine a `cloud.startChat` send takes (nil: make
    /// one named `newName`), pinned to the send, and the send's keys.
    struct StartChatPlan: Sendable, Equatable {
        var machine: String?
        var newName: String?
        var createKey: String
        var tabKey: String
    }

    /// `cmux link start-chat plan --request JSON` (cmux-tui `link/start_chat_cli.rs`), the cmux `access` token on stdin.
    func startChatPlan(request: String, access: String? = nil) async throws -> (Answer, StartChatPlan) {
        let run = try await parsed(["link", "start-chat", "plan", "--request", request], stdin: access.map { Data(($0 + "\n").utf8) })
        let object = run.object ?? [:]
        let plan = StartChatPlan(machine: object["machine"] as? String, newName: object["new_name"] as? String,
                                 createKey: object["create_key"] as? String ?? "", tabKey: object["tab_key"] as? String ?? "")
        // An ok answer without its keys is no answer: a create or open without them is not idempotent.
        guard !run.answer.ok || (!plan.createKey.isEmpty && !plan.tabKey.isEmpty) else {
            return (Answer(ok: false, errorCode: Self.badAnswer, error: "link start-chat plan answered ok without its keys"), plan)
        }
        return (run.answer, plan)
    }

    /// `cmux link start-chat pin`: the send `key` of `account` (``CloudStartChat/accountText(_:)``)
    /// runs on `machine`, one the App just made for it, and the Mac workspace `workspace` picks it from now on.
    func startChatPin(key: String, account: String, machine: String, workspace: String?) async throws -> (Answer, Void) {
        (try await run(["link", "start-chat", "pin", "--key", key, "--account", account, "--machine", machine] + (workspace.map { ["--workspace", $0] } ?? [])), ())
    }

    /// `cmux link start-chat import`: hands cmux-tui the sends this App kept itself before (`entries`, their JSON).
    func startChatImport(entries: String) async throws -> (Answer, Void) {
        (try await run(["link", "start-chat", "import", "--entries", entries]), ())
    }

    /// `cmux link start-chat copy`: copies `local` to a folder of the send's own on the machine whose
    /// daemon `socket` reaches, under the first of `workRoots` it can write, unless this send's copy
    /// already finished there. The chat's folder there, and whether it copied now.
    func startChatCopy(key: String, account: String, machine: String, socket: String, local: String, subpath: String,
                       workRoots: [String]) async throws -> (Answer, (chat: String, copied: Bool)) {
        let roots = workRoots.flatMap { ["--work-root", $0] }
        let run = try await parsed(["link", "start-chat", "copy", "--key", key, "--account", account, "--machine", machine,
                                    "--socket", socket, "--local", local, "--subpath", subpath] + roots)
        let chat = run.object?["chat"] as? String ?? ""
        guard !run.answer.ok || chat.hasPrefix("/") else {
            return (Answer(ok: false, errorCode: Self.badAnswer, error: "link start-chat copy answered ok without its folder"), (chat, false))
        }
        return (run.answer, (chat, run.object?["copied"] as? Bool ?? false))
    }

    /// Longer than `link machine update`'s own wait for the machine (25 minutes) plus a first download.
    static let machineUpdateTimeout: Duration = .seconds(45 * 60)

    private func run(_ arguments: [String], timeout: Duration? = nil) async throws -> Answer {
        try await parsed(arguments, timeout: timeout).answer
    }

    /// One run's answer, with its JSON line (nil when it printed none) and exit status.
    private func parsed(_ arguments: [String], stdin: Data? = nil, timeout: Duration? = nil) async throws -> (answer: Answer, object: [String: Any]?, status: Int32) {
        let result = try await ProcessRunner.run(executable: binary, arguments: arguments, environment: nil, stdin: stdin,
                                                 timeout: timeout ?? self.timeout, clock: ContinuousClock())
        let lines = String(decoding: result.stdout, as: UTF8.self).split(separator: "\n")
        guard let line = lines.last(where: { !$0.allSatisfy(\.isWhitespace) }),
              let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              let ok = object["ok"] as? Bool else {
            let detail = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return (Answer(ok: false, errorCode: Self.badAnswer, error: detail.isEmpty ? "exit \(result.status)" : detail), nil, result.status)
        }
        let answer = Answer(ok: ok, errorCode: object["error_code"] as? String, error: object["error"] as? String,
                            sessionID: object["session_id"] as? String, transferID: object["transfer_id"] as? String,
                            conflicts: object["conflicts"] as? [String] ?? [], side: object["side"] as? String,
                            updated: object["updated"] as? Bool ?? false, build: object["build"] as? String,
                            notOlder: object["not_older"] as? Bool ?? false)
        return (answer, object, result.status)
    }
}

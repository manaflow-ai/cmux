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
        /// `link machine update`: the build the machine runs after it.
        var build: String?
    }

    /// The `cmux` binary (the bundled cmux-tui).
    let binary: URL
    /// How long one run may take (``CloudMoveSetup/timeout``); past it the run is killed and throws.
    var timeout: Duration = .seconds(30 * 60)
    /// The error code of an answer that isn't a JSON line (a crash, a kill).
    static let badAnswer = "bad_answer"

    /// `cmux link sync push`: copies the working copy `local` to `remote` on
    /// the machine whose daemon `socket` reaches.
    func syncPush(socket: String, local: String, remote: String) async throws -> Answer {
        try await run(["link", "sync", "push", "--socket", socket, local, remote])
    }

    /// `cmux link sync pull`: merges the machine's `remote` (what a push left there) back into
    /// `local`; a conflict changes nothing here and lists its paths.
    func syncPull(socket: String, local: String, remote: String) async throws -> Answer {
        try await run(["link", "sync", "pull", "--socket", socket, local, remote])
    }

    /// `cmux link agent move`: moves the chat of tab `surface` of the daemon at
    /// `from` to the machine daemon at `to`, where it runs in `cwd`. A rerun
    /// resolves a move an earlier run left unresolved. `askFirst` has the source narrow the chat
    /// to an asking policy and mode before it moves (`--ask-first`).
    func agentMove(from: String, surface: UInt64, to: String, cwd: String, askFirst: Bool = false) async throws -> Answer {
        let flags = askFirst ? ["--ask-first"] : []
        return try await run(["link", "agent", "move", "--from-socket", from, "--surface", String(surface), "--to-socket", to, "--cwd", cwd] + flags)
    }

    /// `cmux link machine update`: updates the cmux-tui of the machine whose daemon `socket`
    /// reaches to this app's own pinned build, when that machine is outdated (cx-rppd.13).
    /// `toBundled` (`--to-bundled`, the automatic update): whenever it runs another build than
    /// this app's. Either way the build is the one pinned beside this binary; nothing here picks it.
    func machineUpdate(socket: String, toBundled: Bool = false) async throws -> Answer {
        let flags = toBundled ? ["--to-bundled"] : []
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

    /// Longer than `link machine update`'s own wait for the machine (25 minutes) plus a first download.
    static let machineUpdateTimeout: Duration = .seconds(45 * 60)

    private func run(_ arguments: [String], timeout: Duration? = nil) async throws -> Answer {
        try await parsed(arguments, timeout: timeout).answer
    }

    /// One run's answer, with its JSON line (nil when it printed none) and exit status.
    private func parsed(_ arguments: [String], timeout: Duration? = nil) async throws -> (answer: Answer, object: [String: Any]?, status: Int32) {
        let result = try await ProcessRunner.run(executable: binary, arguments: arguments, environment: nil,
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
                            updated: object["updated"] as? Bool ?? false, build: object["build"] as? String)
        return (answer, object, result.status)
    }
}

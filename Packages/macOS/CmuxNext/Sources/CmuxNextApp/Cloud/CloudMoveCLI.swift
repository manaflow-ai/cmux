import CmuxNextDaemon
import Foundation

/// The two cmux-tui CLIs Move to Cloud runs (cmux-tui `link/sync_cli.rs` and
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
    }

    /// The `cmux` binary (the bundled cmux-tui).
    let binary: URL
    /// A first sync of a big repository, or a long chat, can take minutes.
    static let timeout: Duration = .seconds(30 * 60)

    /// `cmux link sync push`: copies the working copy `local` to `remote` on
    /// the machine whose daemon `socket` reaches.
    func syncPush(socket: String, local: String, remote: String) async throws -> Answer {
        try await run(["link", "sync", "push", "--socket", socket, local, remote])
    }

    /// `cmux link agent move`: moves the chat of tab `surface` of the daemon at
    /// `from` to the machine daemon at `to`, where it runs in `cwd`. A rerun
    /// resolves a move an earlier run left unresolved.
    func agentMove(from: String, surface: UInt64, to: String, cwd: String) async throws -> Answer {
        try await run(["link", "agent", "move", "--from-socket", from, "--surface", String(surface), "--to-socket", to, "--cwd", cwd])
    }

    private func run(_ arguments: [String]) async throws -> Answer {
        let result = try await ProcessRunner.run(executable: binary, arguments: arguments, environment: nil,
                                                 timeout: Self.timeout, clock: ContinuousClock())
        let lines = String(decoding: result.stdout, as: UTF8.self).split(separator: "\n")
        guard let line = lines.last(where: { !$0.allSatisfy(\.isWhitespace) }),
              let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              let ok = object["ok"] as? Bool else {
            let detail = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return Answer(ok: false, errorCode: "bad_answer", error: detail.isEmpty ? "exit \(result.status)" : detail)
        }
        return Answer(ok: ok, errorCode: object["error_code"] as? String, error: object["error"] as? String,
                      sessionID: object["session_id"] as? String, transferID: object["transfer_id"] as? String)
    }
}

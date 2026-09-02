import Foundation

/// The exact argv the app hands the cmux-tui client for each cloud-tree operation.
/// Pure, so the lines can be checked without a machine. Grammar per
/// `cmux-tui/spec/cli.md`: `cmux [GLOBAL OPTIONS] <resource> <action> [OPTIONS]`, with
/// `--socket`/`--json`/`--jsonl` as global options, and `attach --terminal <id>` as the
/// single-terminal renderer (`spec/cli.md` §"attach").
struct CloudTuiCommandLine: Sendable {
    /// `remote connect <route> --device-name … --state-dir … --headless --json [--invite-file …]`:
    /// a headless link whose stdout carries `connection-snapshot` JSON lines with the
    /// local mux socket path (`remote_cli.rs` `connect_with_flags`).
    static func linkArguments(route: String, deviceName: String, stateDir: String, inviteFilePath: String?) -> [String] {
        var arguments = ["remote", "connect", route, "--device-name", deviceName, "--state-dir", stateDir, "--headless", "--json"]
        if let inviteFilePath, !inviteFilePath.isEmpty {
            arguments += ["--invite-file", inviteFilePath]
        }
        return arguments
    }

    /// Whole-session public snapshot (`session current snapshot`, `--json`).
    static func snapshotArguments(socketPath: String) -> [String] {
        ["--socket", socketPath, "--json", "session", "current", "snapshot"]
    }

    /// Live delta stream (`session current events`, `--jsonl`): one JSON line per
    /// session transaction. The app only uses it as a change signal and re-reads the
    /// snapshot, so the delta body is never interpreted.
    static func eventsArguments(socketPath: String) -> [String] {
        ["--socket", socketPath, "--jsonl", "session", "current", "events"]
    }

    /// `workspace <ws_id> run -- <argv…>`: a new terminal in that cmux-tui workspace
    /// running the exact argv. Result: `MutationResult<CreatedTerminalPath>`
    /// (`spec/resource-operations-v2.json` → `workspace.run`).
    static func runArguments(socketPath: String, workspaceID: String, command: [String]) -> [String] {
        ["--socket", socketPath, "--json", "workspace", workspaceID, "run", "--"] + command
    }

    /// `workspace create --name <name>`: a workspace with one terminal.
    static func createWorkspaceArguments(socketPath: String, name: String) -> [String] {
        ["--socket", socketPath, "--json", "workspace", "create", "--name", name]
    }

    /// `terminal <term_id> close`: end that remote terminal (spec `terminal.close`).
    static func closeTerminalArguments(socketPath: String, terminalID: String) -> [String] {
        ["--socket", socketPath, "--json", "terminal", terminalID, "close"]
    }

    /// `tab <tab_id> close`: drop the tab that held a terminal whose process already
    /// exited — cmux-tui no longer resolves such a terminal by its own selector.
    static func closeTabArguments(socketPath: String, tabID: String) -> [String] {
        ["--socket", socketPath, "--json", "tab", tabID, "close"]
    }

    /// `workspace <ws_id> close`: remove the workspace view. Its terminals detach
    /// (alive, zero views) rather than die (`spec/cli.md`) — close them first for
    /// a full delete.
    static func closeWorkspaceArguments(socketPath: String, workspaceID: String) -> [String] {
        ["--socket", socketPath, "--json", "workspace", workspaceID, "close"]
    }

    /// `terminal <term_id> project --workspace <ws> --screen <screen> --pane <pane> --index <n>`:
    /// creates a daemon tab view for a live terminal that currently has no placement. The
    /// operation is deliberately separate from the native pane destination: the remote view
    /// only makes the daemon's process-local surface attachable; local rendering remains in
    /// Ghostty.
    static func projectTerminalArguments(
        socketPath: String,
        terminalID: String,
        target: CloudTuiTerminalProjectionTarget,
        expectedRevision: String? = nil,
        idempotencyKey: String? = nil
    ) -> [String] {
        var arguments = [
            "--socket", socketPath, "--json", "terminal", terminalID, "project",
            "--workspace", target.workspaceID,
            "--screen", target.screenID,
            "--pane", target.paneID,
            "--index", String(target.index),
        ]
        if let expectedRevision, !expectedRevision.isEmpty {
            arguments += ["--expected-revision", expectedRevision]
        }
        if let idempotencyKey, !idempotencyKey.isEmpty {
            arguments += ["--idempotency-key", idempotencyKey]
        }
        return arguments
    }

    /// `workspace <ws_id> rename --name <name>` (verified live: the positional
    /// form is `usage.invalid`; the name rides the `--name` flag).
    static func renameWorkspaceArguments(socketPath: String, workspaceID: String, name: String) -> [String] {
        ["--socket", socketPath, "--json", "workspace", workspaceID, "rename", "--name", name]
    }

    /// `terminal <term_id> write --text <text>` (spec `terminal.input.write`): the bytes
    /// land on the PTY as typed; no newline is added, send `keys enter` for that.
    static func writeArguments(socketPath: String, terminalID: String, text: String) -> [String] {
        ["--socket", socketPath, "--json", "terminal", terminalID, "write", "--text", text]
    }

    /// `terminal <term_id> keys <key>…` (spec `terminal.input.keys`): named keys such as
    /// `enter`, `tab`, `escape`, `up`, and `+`-joined chords such as `ctrl+c` (verified
    /// live; `ctrl-c` is `validation.invalid`). The daemon rejects empty names.
    static func keysArguments(socketPath: String, terminalID: String, keys: [String]) -> [String] {
        ["--socket", socketPath, "--json", "terminal", terminalID, "keys"] + keys
    }

    /// `terminal <term_id> screen read` (spec `terminal.screen.read`): the visible grid as
    /// `{cols, rows, cursor_row, cursor_col, cursor_visible, text}`.
    static func screenReadArguments(socketPath: String, terminalID: String) -> [String] {
        ["--socket", socketPath, "--json", "terminal", terminalID, "screen", "read"]
    }

    /// `terminal <term_id> screen wait --pattern <regex> [--timeout-ms <n>]` (spec
    /// `terminal.wait`): blocks until the screen matches, `{matched, text}`.
    static func screenWaitArguments(socketPath: String, terminalID: String, pattern: String, timeoutMs: Int?) -> [String] {
        var arguments = ["--socket", socketPath, "--json", "terminal", terminalID, "screen", "wait", "--pattern", pattern]
        if let timeoutMs, timeoutMs > 0 {
            arguments += ["--timeout-ms", String(timeoutMs)]
        }
        return arguments
    }

    /// `attach --terminal <term_id>`: render exactly one remote terminal into this tty.
    static func attachArguments(socketPath: String, terminalID: String) -> [String] {
        ["--socket", socketPath, "attach", "--terminal", terminalID]
    }

    /// The compatibility tree used to translate a public `term_…` id to the
    /// numeric surface id required by `attach-surface` byte streams. Each tab
    /// in it carries `terminal_resource_id` (the public id the app holds) next
    /// to `surface`, which is the join the resolver needs.
    ///
    /// This rides the raw command bridge rather than a top-level
    /// `list-workspaces` subcommand: the resource CLI reads that leading word
    /// as a resource scope and rejects it with `unknown resource scope
    /// "list-workspaces"`, so the tree was unreachable from the CLI even though
    /// the daemon still serves the command over the wire.
    static func legacyListWorkspacesArguments(socketPath: String) -> [String] {
        // A fixed literal, so this cannot fail to encode and the request stays
        // byte-stable across runs.
        [
            "--socket", socketPath,
            "--json", "raw", "command",
            "--request-json", #"{"id":1,"cmd":"list-workspaces"}"#,
        ]
    }

    /// Resolves a stable terminal resource ID to the current generation's
    /// numeric surface handle. This is preferred over walking the legacy tree
    /// because it also works while a terminal has no visible tab placement.
    /// The private command accepts the 32-character payload without the
    /// public `term_` prefix.
    static func resolveTerminalArguments(socketPath: String, terminalID: String) -> [String]? {
        let payload = terminalID.hasPrefix("term_")
            ? String(terminalID.dropFirst("term_".count))
            : terminalID
        guard payload.count == 32,
              payload.unicodeScalars.allSatisfy({
                  (48...57).contains($0.value) || (97...102).contains($0.value)
              }) else {
            return nil
        }
        let request: [String: Any] = [
            "id": 1,
            "cmd": "resolve-terminal",
            "terminal_id": payload,
        ]
        return rawCommandArguments(socketPath: socketPath, request: request)
    }

    /// Returns the raw `identify` command used to negotiate the daemon protocol
    /// before selecting a compatibility-only resolver path.
    static func identifyArguments(socketPath: String) -> [String]? {
        rawCommandArguments(
            socketPath: socketPath,
            request: ["id": 1, "cmd": "identify"]
        )
    }

    /// Encodes one private JSON command through the CLI's raw command bridge.
    private static func rawCommandArguments(
        socketPath: String,
        request: [String: Any]
    ) -> [String]? {
        guard let data = try? JSONSerialization.data(withJSONObject: request),
              let encoded = String(data: data, encoding: .utf8) else {
            return nil
        }
        return [
            "--socket", socketPath,
            "--json", "raw", "command",
            "--request-json", encoded,
        ]
    }

    /// `session current terminal defaults set [--foreground #rrggbb] [--background #rrggbb]`
    /// (spec `session.terminal_defaults.update`): the session defaults every PTY surface
    /// renders with unless an application on the machine authored its own OSC 10/11.
    /// Pushing this Mac's resolved Ghostty colors makes remote panes match the local
    /// theme. (The flat `set-default-colors` verb in spec/commands.md is the protocol
    /// name; the v2 resource CLI rejects it — verified live against a machine.)
    static func setDefaultColorsArguments(socketPath: String, foreground: String?, background: String?) -> [String]? {
        var arguments = ["--socket", socketPath, "--json", "session", "current", "terminal", "defaults", "set"]
        if let foreground { arguments += ["--foreground", foreground] }
        if let background { arguments += ["--background", background] }
        return arguments.count > 8 ? arguments : nil
    }

    /// The argv `vm.terminal_new` runs in the machine when the caller gives none: a login
    /// shell in the persistent home.
    static let defaultTerminalCommand = ["bash", "-l"]

    /// A `cwd` wraps the command so it starts there; the remote shell does the `cd`.
    static func commandStartingIn(cwd: String?, command: [String]) -> [String] {
        guard let cwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines), !cwd.isEmpty else { return command }
        let quoted = command.map(shellQuote).joined(separator: " ")
        return ["sh", "-lc", "cd \(shellQuote(cwd)) && exec \(quoted)"]
    }

    /// The pane's initial command for a local terminal showing one remote terminal.
    static func attachShellCommand(clientPath: String, socketPath: String, terminalID: String) -> String {
        ([clientPath] + attachArguments(socketPath: socketPath, terminalID: terminalID))
            .map(shellQuote)
            .joined(separator: " ")
    }

    static func shellQuote(_ value: String) -> String {
        if value.isEmpty { return "''" }
        if value.range(of: "^[A-Za-z0-9_./:@%+=,-]+$", options: .regularExpression) != nil {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

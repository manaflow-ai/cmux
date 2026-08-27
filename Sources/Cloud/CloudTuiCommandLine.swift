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

    /// `terminal <term_id> close` / `browser <browser_id> close`: kill the resource.
    /// Only these kill content; pane/screen/workspace closes merely detach views
    /// (`spec/cli.md`), which is why the tree's "Kill" verbs route here.
    static func closeResourceArguments(socketPath: String, kind: SurfaceResourceKind, resourceID: String) -> [String]? {
        switch kind {
        case .terminal: return ["--socket", socketPath, "--json", "terminal", resourceID, "close"]
        case .browser: return ["--socket", socketPath, "--json", "browser", resourceID, "close"]
        default: return nil
        }
    }

    /// `workspace <ws_id> close`: remove the workspace view. Its terminals detach
    /// (alive, zero views) rather than die — kill them first for a full delete.
    static func closeWorkspaceArguments(socketPath: String, workspaceID: String) -> [String] {
        ["--socket", socketPath, "--json", "workspace", workspaceID, "close"]
    }

    /// `workspace <ws_id> rename <name>`.
    static func renameWorkspaceArguments(socketPath: String, workspaceID: String, name: String) -> [String] {
        ["--socket", socketPath, "--json", "workspace", workspaceID, "rename", name]
    }

    /// `attach --terminal <term_id>`: render exactly one remote terminal into this tty.
    static func attachArguments(socketPath: String, terminalID: String) -> [String] {
        ["--socket", socketPath, "attach", "--terminal", terminalID]
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

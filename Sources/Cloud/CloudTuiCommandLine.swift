import Foundation

/// The exact argv the app hands the cmux-tui client for each cloud-tree operation.
/// Pure, so the lines can be checked without a machine. Grammar per
/// `cmux-tui/spec/cli.md`: `cmux [GLOBAL OPTIONS] <resource> <action> [OPTIONS]`, with
/// `--socket`/`--json`/`--jsonl` as global options, and `attach --terminal <id>` as the
/// single-terminal renderer (`spec/cli.md` §"attach").
struct CloudTuiCommandLine: Sendable {
    /// `remote connect <route> --device-name … --state-dir … --local-socket …
    /// --headless --json [--invite-file …]`: a headless link whose stdout carries
    /// `connection-snapshot` JSON lines. The app chooses the socket path so child output
    /// cannot redirect later control operations to another local mux socket.
    static func linkArguments(
        route: String,
        deviceName: String,
        stateDir: String,
        localSocketPath: String,
        inviteFilePath: String?
    ) -> [String] {
        var arguments = [
            "remote", "connect", route,
            "--device-name", deviceName,
            "--state-dir", stateDir,
            "--local-socket", localSocketPath,
            "--headless", "--json",
        ]
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

    /// `workspace <ws_id> rename --name <name>` (verified live: the positional
    /// form is `usage.invalid`; the name rides the `--name` flag).
    static func renameWorkspaceArguments(socketPath: String, workspaceID: String, name: String) -> [String] {
        ["--socket", socketPath, "--json", "workspace", workspaceID, "rename", "--name", name]
    }

    /// `attach --terminal <term_id>`: render exactly one remote terminal into this tty.
    static func attachArguments(socketPath: String, terminalID: String) -> [String] {
        ["--socket", socketPath, "attach", "--terminal", terminalID]
    }

    /// `session current terminal defaults set [--foreground #rrggbb] [--background #rrggbb]`
    /// (spec `session.terminal_defaults.update`): the session defaults every PTY surface
    /// renders with unless an application on the machine authored its own OSC 10/11.
    /// Pushing this Mac's resolved Ghostty colors makes remote panes match the local
    /// theme. (The flat `set-default-colors` verb in spec/commands.md is the protocol
    /// name; the v2 resource CLI rejects it — verified live against a machine.)
    static func setDefaultColorsArguments(socketPath: String, foreground: String?, background: String?) -> [String]? {
        guard [foreground, background].compactMap({ $0 }).allSatisfy(validColor),
              foreground != nil || background != nil else { return nil }
        var arguments = ["--socket", socketPath, "--json", "session", "current", "terminal", "defaults", "set"]
        if let foreground { arguments += ["--foreground", foreground] }
        if let background { arguments += ["--background", background] }
        return arguments
    }

    private static func validColor(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return bytes.count == 7
            && bytes[0] == 0x23
            && bytes.dropFirst().allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x46) || ($0 >= 0x61 && $0 <= 0x66) }
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

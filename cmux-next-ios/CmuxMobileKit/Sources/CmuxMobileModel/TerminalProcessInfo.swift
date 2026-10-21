import Foundation

/// A terminal's `process-info` reply on the Mac (`pid`, `command`,
/// `foreground_executable`), as the cmux-next Mac app reads it
/// (`TerminalProcessInfoRequest.Response`).
public struct TerminalProcessInfo: Sendable, Equatable {
    /// The spawn command (`argv` joined), nil for the login shell.
    public var command: String?
    public var foregroundExecutable: String?

    public init(command: String? = nil, foregroundExecutable: String? = nil) {
        self.command = command
        self.foregroundExecutable = foregroundExecutable
    }

    /// The reply's data object (`{"ok":true,"data":{...}}` or the bare data).
    public init(reply: [String: Any]) {
        let data = reply["data"] as? [String: Any] ?? reply
        self.init(command: data["command"] as? String, foregroundExecutable: data["foreground_executable"] as? String)
    }

    /// The foreground program when it is not the terminal's own shell (an
    /// editor, a build, an agent, `sleep`), else nil.
    public var runningProgram: String? {
        guard let executable = foregroundExecutable.map(Self.basename), !executable.isEmpty else { return nil }
        if Self.shells.contains(executable) { return nil }
        if let command, let spawned = command.split(separator: " ").first.map({ Self.basename(String($0)) }),
           spawned == executable, Self.shells.contains(spawned) { return nil }
        return executable
    }

    /// Interactive shells a terminal idles in (the Mac's list).
    static let shells: Set<String> = ["zsh", "bash", "fish", "sh", "dash", "ksh", "tcsh", "csh", "nu", "xonsh", "elvish", "pwsh", "login"]

    static func basename(_ path: String) -> String {
        var name = (path as NSString).lastPathComponent
        if name.hasPrefix("-") { name.removeFirst() }  // login shells: `-zsh`
        return name
    }
}

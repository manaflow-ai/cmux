import Foundation

/// `process-info {surface}`: the PTY's child and its foreground process.
/// Used to ask before closing a workspace whose terminals run something.
public struct TerminalProcessInfoRequest: DaemonRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var pid: Int?
        /// The spawn command (`argv` joined), nil for the login shell.
        public var command: String?
        public var foregroundExecutable: String?

        public init(pid: Int? = nil, command: String? = nil, foregroundExecutable: String? = nil) {
            self.pid = pid
            self.command = command
            self.foregroundExecutable = foregroundExecutable
        }

        enum CodingKeys: String, CodingKey {
            case pid, command
            case foregroundExecutable = "foreground_executable"
        }

        /// The foreground program when it is not the terminal's own shell
        /// (an editor, a build, an agent), else nil.
        public var runningProgram: String? {
            guard let executable = foregroundExecutable.map(Self.programName), !executable.isEmpty else { return nil }
            if Self.shells.contains(executable) { return nil }
            if let command, let spawned = command.split(separator: " ").first.map({ Self.basename(String($0)) }),
               spawned == executable, Self.shells.contains(spawned) { return nil }
            return executable
        }

        /// Interactive shells a terminal idles in.
        static let shells: Set<String> = ["zsh", "bash", "fish", "sh", "dash", "ksh", "tcsh", "csh", "nu", "xonsh", "elvish", "pwsh", "login"]

        /// The program's name for a person: the executable's file name, except for a tool installed as one file per
        /// version (Claude Code runs `~/.local/share/claude/versions/2.1.323`), which is named by the folder that holds
        /// its versions ("claude"), never by its version number ("Still running: 2.1.323.").
        static func programName(_ path: String) -> String {
            let name = basename(path)
            guard isVersion(name) else { return name }
            var folders = (path as NSString).pathComponents.dropLast()
            while let last = folders.last, last == "versions" || isVersion(last) { folders.removeLast() }
            guard let tool = folders.last, tool != "/", !tool.isEmpty else { return name }
            return tool.hasPrefix(".") ? String(tool.dropFirst()) : tool
        }

        /// A version number as a file or folder name: `2.1.323`, `v1.4`, `20.11.0`.
        static func isVersion(_ name: String) -> Bool {
            let digits = name.hasPrefix("v") ? name.dropFirst() : Substring(name)
            let parts = digits.split(separator: ".", omittingEmptySubsequences: false)
            return parts.count >= 2 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }
        }

        static func basename(_ path: String) -> String {
            var name = (path as NSString).lastPathComponent
            if name.hasPrefix("-") { name.removeFirst() }  // login shells: `-zsh`
            return name
        }
    }

    public static let command = "process-info"
    public var surface: SurfaceID
    /// A person's action on `surface` (typing into its foreground program): a stand-in is refused at the request boundary
    /// and the refusal shows, as for every action (rule b).
    public init(surface: SurfaceID) { self.surface = surface }

    /// A read of `surface`'s process that the person did not ask for: nil for a stand-in tab (a Ctrl-` or split still
    /// opening), whose terminal has no process in the daemon yet, so the read is never sent and never shows "This pane is
    /// still opening". The boundary's own test (`DaemonRequestExecutor.standInReference`), so the two never disagree.
    public init?(reading surface: SurfaceID) {
        guard surface.rawValue < ProvisionalPane.firstHandle else { return nil }
        self.surface = surface
    }
}

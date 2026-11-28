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
            guard let executable = foregroundExecutable.map(Self.basename), !executable.isEmpty else { return nil }
            if Self.shells.contains(executable) { return nil }
            if let command, let spawned = command.split(separator: " ").first.map({ Self.basename(String($0)) }),
               spawned == executable, Self.shells.contains(spawned) { return nil }
            return executable
        }

        /// Interactive shells a terminal idles in.
        static let shells: Set<String> = ["zsh", "bash", "fish", "sh", "dash", "ksh", "tcsh", "csh", "nu", "xonsh", "elvish", "pwsh", "login"]

        static func basename(_ path: String) -> String {
            var name = (path as NSString).lastPathComponent
            if name.hasPrefix("-") { name.removeFirst() }  // login shells: `-zsh`
            return name
        }
    }

    public static let command = "process-info"
    public var surface: SurfaceID
    public init(surface: SurfaceID) { self.surface = surface }
}

import Foundation

/// One terminal's foreground program, as the daemon pushes it (`terminal-foreground-changed`,
/// `terminal-foreground-v1`) and lists it (``ListTerminalForegroundsRequest``). The whole state of
/// one PTY surface: the app keeps the newest per surface (``TerminalForegrounds``) and decides a
/// close's question from it in the key's turn, with no daemon round trip.
public struct TerminalForeground: Sendable, Hashable, Decodable {
    public var surface: SurfaceID
    /// Increases with every change of this surface's foreground; an older one changes nothing.
    public var seq: UInt64
    /// The foreground process-group leader, nil when the surface has no live child.
    public var foregroundPID: Int?
    /// As `process-info`'s `foreground_executable`.
    public var foregroundExecutable: String?
    /// The spawn command, as `process-info`'s `command` (nil for the login shell).
    public var command: String?

    public init(surface: SurfaceID, seq: UInt64, foregroundPID: Int? = nil, foregroundExecutable: String? = nil, command: String? = nil) {
        self.surface = surface
        self.seq = seq
        self.foregroundPID = foregroundPID
        self.foregroundExecutable = foregroundExecutable
        self.command = command
    }

    enum CodingKeys: String, CodingKey {
        case surface, seq, command
        case foregroundPID = "foreground_pid"
        case foregroundExecutable = "foreground_executable"
    }

    /// The foreground program when it is not the terminal's own shell, else nil: the same rule
    /// as `process-info` (``TerminalProcessInfoRequest/Response/runningProgram``).
    public var runningProgram: String? {
        TerminalProcessInfoRequest.Response(pid: foregroundPID, command: command, foregroundExecutable: foregroundExecutable).runningProgram
    }
}

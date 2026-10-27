import Foundation

/// `trace-status` (protocol 12, owner only): the trace recording state of the daemon and of every child it reaches,
/// the holder, each live terminal host and acpmux (cmux-tui/spec/commands.md, "trace-start, trace-stop,
/// trace-status"). The app reads only each process's role and pid from it: the daemon's own list of its children,
/// which task 121's resource samples use instead of scanning process names. One trace control call runs at a time in
/// the daemon, so a caller asks rarely (at a report) and keeps its last answer when the daemon is busy.
public struct TraceStatusRequest: DaemonRequest {
    /// One process of the reply.
    public struct Process: Decodable, Sendable, Equatable {
        /// `daemon`, `holder`, `terminal-host` or `acpmux`.
        public var role: String
        /// Its pid; nil when the daemon does not know it (the holder).
        public var pid: Int32?

        public init(role: String, pid: Int32?) {
            self.role = role
            self.pid = pid
        }
    }

    public struct Response: Decodable, Sendable, Equatable {
        public var processes: [Process]

        public init(processes: [Process]) {
            self.processes = processes
        }
    }

    public static let commandName: DaemonCommandName = "trace-status"

    public init() {}
}

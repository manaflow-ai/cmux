public import Foundation

/// RED STUB (R96 late endAgents): the lock-based proof that agents ended.
public nonisolated enum AcpmuxQuitProof {
    public enum LockState: Sendable, Equatable {
        case free, held, unknown
    }

    public struct Facts: Sendable, Equatable {
        public var daemon: LockState
        public var daemonPID: Int32?
        public var liveHostSessions: [String]
        public var unknownHostSessions: [String]

        public init(daemon: LockState, daemonPID: Int32? = nil, liveHostSessions: [String] = [], unknownHostSessions: [String] = []) {
            self.daemon = daemon
            self.daemonPID = daemonPID
            self.liveHostSessions = liveHostSessions
            self.unknownHostSessions = unknownHostSessions
        }
    }

    public static func read(home: URL) -> Facts { Facts(daemon: .free) }

    public static func decide(_ facts: Facts, chief: Set<String>, daemonExited: Bool) -> AcpmuxQuit.EndResult { .noDaemon }
}

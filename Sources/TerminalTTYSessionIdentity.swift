import Darwin
import Foundation

/// Identifies the process generation that owns one terminal session.
///
/// A PTY name can be reused after its session exits. Pairing the session-leader
/// PID with its process start time distinguishes the new terminal generation
/// from a stale report that happened to use the same device name.
nonisolated struct TerminalTTYSessionIdentity: Equatable, Sendable {
    let processIdentity: AgentPIDProcessIdentity

    init(processIdentity: AgentPIDProcessIdentity) {
        self.processIdentity = processIdentity
    }

    init?(ttyName: String) {
        let trimmedName = ttyName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, trimmedName != "not a tty" else { return nil }
        let deviceName = trimmedName.split(separator: "/").last.map(String.init) ?? trimmedName
        let descriptor = open("/dev/\(deviceName)", O_RDONLY | O_NONBLOCK | O_NOCTTY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }

        let sessionLeaderPID = tcgetsid(descriptor)
        guard let processIdentity = AgentPIDProcessIdentity(pid: sessionLeaderPID) else { return nil }
        self.processIdentity = processIdentity
    }
}

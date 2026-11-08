import Foundation

/// Identifies one session within one in-memory tmux server incarnation.
struct LocalTmuxSessionBinding: Codable, Equatable, Hashable, Sendable {
    let sessionID: LocalTmuxSessionIdentity
    let serverID: UUID
    let sessionCreated: UInt64

    init(
        sessionID: LocalTmuxSessionIdentity,
        serverID: UUID,
        sessionCreated: UInt64
    ) {
        self.sessionID = sessionID
        self.serverID = serverID
        self.sessionCreated = sessionCreated
    }
}

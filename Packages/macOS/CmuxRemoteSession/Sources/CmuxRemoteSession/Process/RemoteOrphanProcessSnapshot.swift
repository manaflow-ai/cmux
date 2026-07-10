/// A content-minimal process record used to identify stale cmux SSH transports.
struct RemoteOrphanProcessSnapshot: Sendable, Equatable {
    struct Identity: Sendable, Equatable {
        let startSeconds: UInt64
        let startMicroseconds: UInt64
    }

    let pid: Int
    let parentPID: Int
    let command: String
    let identity: Identity?

    init(
        pid: Int,
        parentPID: Int,
        command: String,
        identity: Identity? = nil
    ) {
        self.pid = pid
        self.parentPID = parentPID
        self.command = command
        self.identity = identity
    }
}

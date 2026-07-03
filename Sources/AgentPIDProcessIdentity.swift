import Darwin

struct AgentPIDProcessIdentity: Equatable, Sendable {
    let pid: pid_t
    let startSeconds: Int64
    let startMicroseconds: Int64
}

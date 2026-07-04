import Darwin

struct SocketCommandObservabilityCommand: Equatable, Sendable {
    let protocolName: SocketCommandProtocolName
    let method: String
    let peerPid: pid_t?
    let executionLane: SocketCommandExecutionLane
}

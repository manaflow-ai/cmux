import Foundation

/// Structured description of a completed CLI socket command.
///
/// Contains no command payload or user data; only sanitized protocol/method
/// identity, timing, routing facts, peer pid, and response size.
nonisolated public struct SocketCommandObservation: Sendable, Equatable {
    public let protocolName: String
    public let method: String
    public let durationMs: Double
    public let executedOnMain: Bool
    public let peerPid: pid_t?
    public let responseByteCount: Int

    public init(
        descriptor: SocketCommandDescriptor,
        durationMs: Double,
        responseByteCount: Int
    ) {
        self.protocolName = descriptor.protocolName
        self.method = descriptor.method
        self.durationMs = durationMs
        self.executedOnMain = descriptor.executedOnMain
        self.peerPid = descriptor.peerPid
        self.responseByteCount = responseByteCount
    }

    public init(
        protocolName: String,
        method: String,
        durationMs: Double,
        executedOnMain: Bool,
        peerPid: pid_t?,
        responseByteCount: Int
    ) {
        self.protocolName = protocolName
        self.method = method
        self.durationMs = durationMs
        self.executedOnMain = executedOnMain
        self.peerPid = peerPid
        self.responseByteCount = responseByteCount
    }
}

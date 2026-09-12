import Foundation

/// Sanitized identity and routing metadata for one CLI socket command.
nonisolated public struct SocketCommandDescriptor: Sendable, Equatable {
    public let protocolName: String
    public let method: String
    public let executedOnMain: Bool
    public let peerPid: pid_t?

    public init(protocolName: String, method: String, executedOnMain: Bool, peerPid: pid_t?) {
        self.protocolName = protocolName
        self.method = method
        self.executedOnMain = executedOnMain
        self.peerPid = peerPid
    }
}

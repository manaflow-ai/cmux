import Foundation

/// Filesystem and process identity required to classify a socket `EPERM` as
/// an expected sandbox policy denial.
public struct CLISocketPolicyDenialContext: Equatable, Sendable {
    public let stage: String
    public let errnoCode: Int32
    public let socketExists: Bool
    public let socketIsUnixDomainSocket: Bool
    public let socketOwnerUID: UInt32
    public let processUID: UInt32
    public let effectiveUID: UInt32

    public init(
        stage: String,
        errnoCode: Int32,
        socketExists: Bool,
        socketIsUnixDomainSocket: Bool,
        socketOwnerUID: UInt32,
        processUID: UInt32,
        effectiveUID: UInt32
    ) {
        self.stage = stage
        self.errnoCode = errnoCode
        self.socketExists = socketExists
        self.socketIsUnixDomainSocket = socketIsUnixDomainSocket
        self.socketOwnerUID = socketOwnerUID
        self.processUID = processUID
        self.effectiveUID = effectiveUID
    }
}

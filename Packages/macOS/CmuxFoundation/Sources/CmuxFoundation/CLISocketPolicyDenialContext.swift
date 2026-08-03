import Darwin
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

    /// Inspects the same resolved filesystem target that the socket client
    /// validates before connecting. Following a symlink here keeps policy
    /// classification consistent with the connection attempt.
    public static func inspecting(
        stage: String,
        error: CLISocketConnectError
    ) -> Self {
        var socketMetadata = stat()
        let socketExists = stat(error.path, &socketMetadata) == 0
        return Self(
            stage: stage,
            errnoCode: error.errnoCode,
            socketExists: socketExists,
            socketIsUnixDomainSocket: socketExists &&
                (socketMetadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK),
            socketOwnerUID: socketExists ? socketMetadata.st_uid : 0,
            processUID: getuid(),
            effectiveUID: geteuid()
        )
    }
}

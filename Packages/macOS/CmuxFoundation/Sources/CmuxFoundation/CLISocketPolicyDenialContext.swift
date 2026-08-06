import Darwin
import Foundation

/// Filesystem and process identity required to classify a socket `EPERM` as
/// an expected sandbox policy denial.
public struct CLISocketPolicyDenialContext: Equatable, Sendable {
    /// Socket operation stage that produced the denial.
    public let stage: String
    /// POSIX error code returned by the operation.
    public let errnoCode: Int32
    /// Whether the resolved socket path exists.
    public let socketExists: Bool
    /// Whether the resolved path identifies a Unix-domain socket.
    public let socketIsUnixDomainSocket: Bool
    /// User identifier that owns the socket inode.
    public let socketOwnerUID: UInt32
    /// Real user identifier of the CLI process.
    public let processUID: UInt32
    /// Effective user identifier of the CLI process.
    public let effectiveUID: UInt32

    /// Creates an explicit socket policy-denial context.
    ///
    /// - Parameters:
    ///   - stage: Socket operation stage that produced the denial.
    ///   - errnoCode: POSIX error code returned by the operation.
    ///   - socketExists: Whether the resolved socket path exists.
    ///   - socketIsUnixDomainSocket: Whether the path identifies a Unix socket.
    ///   - socketOwnerUID: User identifier that owns the socket inode.
    ///   - processUID: Real user identifier of the CLI process.
    ///   - effectiveUID: Effective user identifier of the CLI process.
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
    /// Creates a context by inspecting the path from a typed connection error.
    ///
    /// - Parameters:
    ///   - stage: Socket operation stage that produced the denial.
    ///   - error: Typed connection failure containing the path and POSIX code.
    public init(
        inspectingStage stage: String,
        error: CLISocketConnectError
    ) {
        var socketMetadata = stat()
        let socketExists = stat(error.path, &socketMetadata) == 0
        self.init(
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

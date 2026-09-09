import Foundation

struct CLIError: Error, CustomStringConvertible {
    enum SocketFailureKind: Equatable {
        case pathMissing
        case pathInspectionFailed
        case pathTypeConflict
        case pathOwnershipConflict
        case startupTimeout
    }

    let message: String
    let exitCode: Int32
    let shouldPrint: Bool
    /// Structured v2 protocol error code when the failure came from a v2 error response.
    let v2Code: String?
    /// Whether this error was decoded directly from a socket v2 error response.
    /// Local CLI sentinels may reuse ``v2Code`` for their own exit-status contract.
    let isStructuredProtocolResponse: Bool
    /// Cloud VM backend error code (e.g. "vm_create_failed") passed through the
    /// v2 error's data payload, so callers can make idempotency decisions
    /// structurally instead of parsing display text.
    let vmBackendCode: String?
    /// HTTP status from the Cloud VM backend, when the app forwarded an HTTP
    /// failure through the local v2 socket.
    let vmBackendHTTPStatus: Int?
    let socketFailureKind: SocketFailureKind?

    init(
        message: String,
        exitCode: Int32 = 1,
        shouldPrint: Bool = true,
        v2Code: String? = nil,
        isStructuredProtocolResponse: Bool = false,
        vmBackendCode: String? = nil,
        vmBackendHTTPStatus: Int? = nil,
        socketFailureKind: SocketFailureKind? = nil
    ) {
        self.message = message
        self.exitCode = exitCode
        self.shouldPrint = shouldPrint
        self.v2Code = v2Code
        self.isStructuredProtocolResponse = isStructuredProtocolResponse
        self.vmBackendCode = vmBackendCode
        self.vmBackendHTTPStatus = vmBackendHTTPStatus
        self.socketFailureKind = socketFailureKind
    }

    var description: String { message }
}

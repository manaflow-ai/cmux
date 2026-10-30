import Foundation

struct CLIError: Error, CustomStringConvertible {
    enum SocketFailureKind: Equatable {
        case pathMissing
        case pathInspectionFailed
        case pathTypeConflict
        case pathOwnershipConflict
        case startupTimeout
        /// SO_RCVTIMEO was rejected with EINVAL, which macOS returns once the
        /// peer has shut the socket down. Other setsockopt failures stay untyped.
        case receiveTimeoutConfiguration
    }

    let message: String
    let exitCode: Int32
    /// Structured v2 protocol error code when the failure came from a v2 error response.
    let v2Code: String?
    /// Whether this error was decoded directly from a socket v2 error response.
    /// Local CLI sentinels may reuse ``v2Code`` for their own exit-status contract.
    let isStructuredProtocolResponse: Bool
    /// Whether the v2 error's data marked the failure as retryable (for example a
    /// `busy` answer while the app's process scan settles), so callers can wait
    /// and retry structurally instead of parsing display text.
    let v2Retryable: Bool
    /// Cloud VM backend error code (e.g. "vm_create_failed") passed through the
    /// v2 error's data payload, so callers can make idempotency decisions
    /// structurally instead of parsing display text.
    let vmBackendCode: String?
    /// HTTP status from the Cloud VM backend, when the app forwarded an HTTP
    /// failure through the local v2 socket.
    let vmBackendHTTPStatus: Int?
    let socketFailureKind: SocketFailureKind?
    /// The v2 method whose response carried this error, so an uncaught
    /// `method_not_found` can name it (``CLIVersionSkew``).
    let v2Method: String?
    /// The page's open JavaScript dialog from a `dialog_pending` error's data.
    let browserDialog: BrowserDialog?

    /// A page's JavaScript dialog as a browser command reports it.
    struct BrowserDialog: Equatable {
        let type: String
        let message: String

        init?(_ value: Any?) {
            guard let dialog = value as? [String: Any],
                  let type = dialog["type"] as? String else { return nil }
            self.type = type
            self.message = (dialog["message"] as? String) ?? ""
        }
    }

    init(
        message: String,
        exitCode: Int32 = 1,
        v2Code: String? = nil,
        isStructuredProtocolResponse: Bool = false,
        v2Retryable: Bool = false,
        vmBackendCode: String? = nil,
        vmBackendHTTPStatus: Int? = nil,
        socketFailureKind: SocketFailureKind? = nil,
        v2Method: String? = nil,
        browserDialog: BrowserDialog? = nil
    ) {
        self.message = message
        self.exitCode = exitCode
        self.v2Code = v2Code
        self.isStructuredProtocolResponse = isStructuredProtocolResponse
        self.v2Retryable = v2Retryable
        self.vmBackendCode = vmBackendCode
        self.vmBackendHTTPStatus = vmBackendHTTPStatus
        self.socketFailureKind = socketFailureKind
        self.v2Method = v2Method
        self.browserDialog = browserDialog
    }

    /// This error with `line` added below its message.
    func appendingLine(_ line: String) -> CLIError {
        CLIError(
            message: "\(message)\n\(line)",
            exitCode: exitCode,
            v2Code: v2Code,
            isStructuredProtocolResponse: isStructuredProtocolResponse,
            v2Retryable: v2Retryable,
            vmBackendCode: vmBackendCode,
            vmBackendHTTPStatus: vmBackendHTTPStatus,
            socketFailureKind: socketFailureKind,
            v2Method: v2Method,
            browserDialog: browserDialog
        )
    }

    var description: String { message }
}

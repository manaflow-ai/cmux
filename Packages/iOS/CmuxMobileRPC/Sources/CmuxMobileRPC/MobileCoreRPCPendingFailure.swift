/// Preserves the exact underlying error carried by a pending RPC continuation.
struct MobileCoreRPCPendingFailure: Error {
    let underlying: any Error

    static var invalidResponse: Self {
        Self(underlying: MobileShellConnectionError.invalidResponse)
    }

    static var connectionClosed: Self {
        Self(underlying: MobileShellConnectionError.connectionClosed)
    }

    static var requestTimedOut: Self {
        Self(underlying: MobileShellConnectionError.requestTimedOut)
    }

    static var transportWriteTimedOut: Self {
        Self(underlying: MobileShellConnectionError.transportWriteTimedOut)
    }

    static func authorizationFailed(_ message: String) -> Self {
        Self(underlying: MobileShellConnectionError.authorizationFailed(message))
    }

    static func accountMismatch(_ message: String) -> Self {
        Self(underlying: MobileShellConnectionError.accountMismatch(message))
    }

    static func rpcError(_ code: String?, _ message: String) -> Self {
        Self(underlying: MobileShellConnectionError.rpcError(code, message))
    }
}

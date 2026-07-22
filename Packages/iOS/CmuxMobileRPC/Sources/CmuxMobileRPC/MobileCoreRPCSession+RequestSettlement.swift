import Foundation

extension MobileCoreRPCSession {
    static func resolvePendingSettlement(
        _ settlement: PendingRequestSettlement,
        isCancelled: Bool
    ) throws -> Data {
        switch settlement {
        case .cancelled:
            throw CancellationError()
        case .response(.success(let data)):
            // A decoded success followed by cancellation is still ambiguous:
            // the host may have created a non-idempotent workspace even though
            // the caller no longer owns the current session.
            if isCancelled { throw CancellationError() }
            return data
        case .response(.failure(let error)):
            // Preserve only failures decoded from a host response. Local
            // transport/protocol failures cannot prove whether a legacy,
            // non-idempotent workspace.create reached the host, so cancellation
            // must keep that outcome ambiguous upstream.
            if isCancelled, !error.isDefiniteHostResponseFailure {
                throw CancellationError()
            }
            throw error
        }
    }
}

private extension MobileShellConnectionError {
    var isDefiniteHostResponseFailure: Bool {
        switch self {
        case .authorizationFailed, .accountMismatch, .rpcError:
            true
        case .invalidResponse, .connectionClosed, .requestTimedOut, .transportWriteTimedOut,
             .insecureManualRoute, .attachTicketExpired:
            false
        }
    }
}

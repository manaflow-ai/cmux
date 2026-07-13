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
            // Once a response or transport failure settles, preserve it even if
            // ambient cancellation races this continuation. This prevents a
            // definite host rejection from becoming ambiguous success upstream.
            throw error
        }
    }
}

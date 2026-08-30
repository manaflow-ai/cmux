import Foundation

extension IrxBrokerService {
    /// Attributes an error to the broker operation that owns the call. The
    /// wrapper is the single boundary used by registration, discovery, mint,
    /// hint refresh, and grant/revocation requests, so callers cannot lose the
    /// operation while translating a low-level HTTP failure.
    func withBrokerOperation<Result: Sendable>(
        _ operation: IrxBrokerOperation,
        onError: ((any Error) -> Void)? = nil,
        _ body: () async throws -> Result
    ) async throws -> Result {
        do {
            return try await body()
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as IrxBrokerFailure {
            throw failure.with(operation: operation)
        } catch {
            onError?(error)
            throw IrxBrokerFailure(operation: operation, error: error)
        }
    }
}

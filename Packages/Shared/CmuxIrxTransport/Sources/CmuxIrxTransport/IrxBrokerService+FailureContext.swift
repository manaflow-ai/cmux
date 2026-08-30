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
            onError?(failure)
            throw failure.with(operation: operation)
        } catch {
            onError?(error)
            if let urlError = error as? URLError {
                if urlError.code == .cancelled {
                    throw CancellationError()
                }
                // URLSession exposes a few transport failures directly. They
                // are retryable unless the URL or certificate is itself
                // invalid; those terminal inputs must not become a retry loop.
                let fallbackKind: IrxBrokerFailureKind = switch urlError.code {
                case .badURL,
                     .unsupportedURL,
                     .serverCertificateHasBadDate,
                     .serverCertificateUntrusted,
                     .serverCertificateHasUnknownRoot,
                     .serverCertificateNotYetValid,
                     .clientCertificateRejected,
                     .clientCertificateRequired,
                     .appTransportSecurityRequiresSecureConnection:
                    .invalid
                default:
                    .transient
                }
                throw IrxBrokerFailure(
                    operation: operation,
                    error: error,
                    fallbackKind: fallbackKind
                )
            }
            // Every transport error that can be retried has a typed boundary
            // above (connectivity, rate limiting, or an HTTP response). An
            // unknown non-URL error is therefore a local/protocol failure and
            // must fail closed instead of creating an endless renewal loop.
            throw IrxBrokerFailure(
                operation: operation,
                error: error,
                fallbackKind: .invalid
            )
        }
    }
}

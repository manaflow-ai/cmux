import Foundation
import CmuxIrohTransport

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
        } catch let recovery as CmxIrohBrokerTokenRecoveryError {
            // Preserve the auth owner's one-refresh outcome instead of
            // collapsing it into an unclassified local error. This is the
            // fail-closed boundary used by register, discover, mint, and hint.
            let failure = IrxBrokerFailure(operation: operation, error: recovery)
            onError?(failure)
            throw failure
        } catch let broker as CmxIrohTrustBrokerClientError {
            // HTTP 429/5xx and connectivity retain their operation/status so
            // lifecycle backoff and diagnostics can choose the right policy.
            let failure = IrxBrokerFailure(operation: operation, error: broker)
            onError?(failure)
            throw failure
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

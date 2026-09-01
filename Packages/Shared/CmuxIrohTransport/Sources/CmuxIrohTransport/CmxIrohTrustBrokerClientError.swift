public import CMUXMobileCore
public import Foundation

/// Underlying URL-loading failure carried by connectivity-class broker
/// errors, so journals and caller retry policies can distinguish a dead
/// kept-alive connection (NSURLErrorNetworkConnectionLost) from DNS loss,
/// timeouts, or a token source that could not produce a coherent pair.
public struct CmxIrohBrokerConnectivityCause: Equatable, Sendable,
    CustomStringConvertible
{
    /// NSURLErrorDomain code, e.g. -1005.
    public let urlErrorCode: Int

    public init(urlErrorCode: Int) {
        self.urlErrorCode = urlErrorCode
    }

    public init(_ error: URLError) {
        self.init(urlErrorCode: error.code.rawValue)
    }

    /// Whether this is the connection-reuse failure class: a pooled
    /// keep-alive connection the server closed while it sat idle, surfaced
    /// only when the next request's first read fails. URLSession never
    /// transparently retries a request whose body bytes were already written
    /// (Apple QA1941), so idempotent callers retry once themselves; the
    /// failed attempt already purged the dead pooled connection.
    public var isConnectionReuseFailure: Bool {
        urlErrorCode == URLError.Code.networkConnectionLost.rawValue
    }

    public var description: String { "\(symbolicName)(\(urlErrorCode))" }

    private var symbolicName: String {
        switch URLError.Code(rawValue: urlErrorCode) {
        case .timedOut: "timedOut"
        case .cannotFindHost: "cannotFindHost"
        case .cannotConnectToHost: "cannotConnectToHost"
        case .networkConnectionLost: "networkConnectionLost"
        case .dnsLookupFailed: "dnsLookupFailed"
        case .notConnectedToInternet: "notConnectedToInternet"
        case .internationalRoamingOff: "internationalRoamingOff"
        case .callIsActive: "callIsActive"
        case .dataNotAllowed: "dataNotAllowed"
        case .cannotLoadFromNetwork: "cannotLoadFromNetwork"
        default: "urlError"
        }
    }
}

/// Failures at the authenticated HTTP trust-broker boundary.
public enum CmxIrohTrustBrokerClientError:
    CmxRetryAfterProviding,
    Equatable,
    Sendable
{
    /// The authenticated broker could not be reached through the current
    /// network. Carries the underlying URL-loading classification when one
    /// exists; a `nil` cause is a token source that could not read a
    /// coherent credential pair for a non-network reason.
    case connectivity(CmxIrohBrokerConnectivityCause?)
    case invalidBaseURL
    case missingAuthentication
    case invalidAuthentication
    case nonHTTPResponse
    /// The broker rejected a request and supplied a bounded retry floor.
    case rateLimited(code: String?, retryAfterSeconds: Int)
    case rejected(statusCode: Int, code: String?)
    case invalidResponse

    /// Whether an inconclusive refresh may preserve already-verified state.
    ///
    /// This never admits a new peer. Callers may retain only state whose own
    /// signed lease or policy expiry remains authoritative.
    static func preservesVerifiedStateDuringRefresh(_ error: any Error) -> Bool {
        if (error as? any CmxRetryAfterProviding)?.retryAfterSeconds != nil {
            return true
        }
        guard let brokerError = error as? Self else { return false }
        switch brokerError {
        case .connectivity:
            return true
        case .rateLimited:
            return true
        case let .rejected(statusCode, _):
            // A 401 here already survived the
            // broker client's single force-refresh retry, so it is a session
            // transition still settling (rotation race, locked token store) or
            // a server-side availability condition — not a trust change. The
            // existing state remains bounded by its signed expiry; tearing it
            // down buys nothing and turns a seconds-long auth blip into a full
            // endpoint or session rebuild. A genuinely dead session clears
            // auth state through the coordinator, which stops the runtime
            // through the lifecycle owner instead.
            return statusCode == 401
                || statusCode == 408
                || statusCode == 425
                || statusCode == 429
                || (500...599).contains(statusCode)
        case .invalidBaseURL,
             .missingAuthentication,
             .invalidAuthentication,
             .nonHTTPResponse,
             .invalidResponse:
            return false
        }
    }

    /// Accepts only failures that are safe to retry before any binding is trusted.
    static func retriesInitialActivation(_ error: any Error) -> Bool {
        if (error as? any CmxRetryAfterProviding)?.retryAfterSeconds != nil {
            return true
        }
        guard let brokerError = error as? Self else { return false }
        switch brokerError {
        case .connectivity, .rateLimited:
            return true
        case let .rejected(statusCode, _):
            // A server failure cannot establish trust, so retrying the request
            // is safe while the lifecycle-owned start task remains current.
            // An authentication rejection cannot establish initial trust. It
            // must return to the auth lifecycle instead of retrying forever.
            return statusCode == 408
                || statusCode == 425
                || statusCode == 429
                || (500...599).contains(statusCode)
        case .invalidBaseURL,
             .missingAuthentication,
             .invalidAuthentication,
             .nonHTTPResponse,
             .invalidResponse:
            return false
        }
    }

    /// The validated server retry floor, when present.
    public var retryAfterSeconds: Int? {
        guard case let .rateLimited(_, retryAfterSeconds) = self else { return nil }
        return retryAfterSeconds
    }

    /// Whether this is any connectivity-class failure, regardless of the
    /// underlying cause detail. Callers deciding retry or cached-state
    /// policy match on this instead of value equality, which would treat
    /// differently-attributed connectivity failures as distinct.
    public var isConnectivity: Bool {
        if case .connectivity = self { return true }
        return false
    }
}

extension CmxIrohTrustBrokerClientError: CustomStringConvertible {
    /// Journal-stable rendering: identical to the previously synthesized
    /// text for every case, except that an attributed connectivity failure
    /// appends its URL-loading cause, e.g.
    /// `connectivity(networkConnectionLost(-1005))`.
    public var description: String {
        switch self {
        case .connectivity(nil):
            "connectivity"
        case let .connectivity(cause?):
            "connectivity(\(cause))"
        case .invalidBaseURL:
            "invalidBaseURL"
        case .missingAuthentication:
            "missingAuthentication"
        case .invalidAuthentication:
            "invalidAuthentication"
        case .nonHTTPResponse:
            "nonHTTPResponse"
        case let .rateLimited(code, retryAfterSeconds):
            "rateLimited(code: \(String(describing: code)), "
                + "retryAfterSeconds: \(retryAfterSeconds))"
        case let .rejected(statusCode, code):
            "rejected(statusCode: \(statusCode), code: \(String(describing: code)))"
        case .invalidResponse:
            "invalidResponse"
        }
    }
}

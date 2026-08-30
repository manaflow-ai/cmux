public import CMUXMobileCore
import CmuxIrohTransport

/// The authenticated broker operation that produced a failure.
public enum IrxBrokerOperation: String, Codable, Equatable, Sendable {
    /// Endpoint binding registration or refresh.
    case register
    /// Account binding/trust discovery.
    case discover
    /// Relay credential minting.
    case mint
    /// Relay path-hint registration.
    case hintRefresh = "hint_refresh"
    /// Pair-grant minting.
    case pairGrant = "pair_grant"
    /// Binding revocation.
    case revoke
    /// Local endpoint binding or rebind work (not a broker HTTP operation).
    case endpoint
}

/// A privacy-safe classification of one irx broker failure.
public enum IrxBrokerFailureKind: String, Codable, Equatable, Sendable {
    /// The account must be authenticated again.
    case authenticationRequired = "authentication_required"
    /// The operation can be retried safely.
    case transient
    /// The broker rejected the request for a non-auth reason.
    case rejected
    /// The response or local inputs were invalid.
    case invalid
}

/// Broker failure context carried from the transport to the host lifecycle.
///
/// The wrapper retains only stable operation, status, and error-code fields;
/// raw response bodies and token material never cross into the journal or UI.
public struct IrxBrokerFailure: Error, Codable, Equatable, Sendable {
    public let operation: IrxBrokerOperation
    public let kind: IrxBrokerFailureKind
    public let statusCode: Int?
    public let errorCode: String?
    public let retryAfterSeconds: Int?

    /// Creates a classified failure, using `fallbackKind` only for errors that
    /// did not cross the shared broker error boundary.
    public init(
        operation: IrxBrokerOperation,
        error: any Error,
        fallbackKind: IrxBrokerFailureKind = .invalid
    ) {
        self.operation = operation
        switch error {
        case let recovery as CmxIrohBrokerTokenRecoveryError:
            switch recovery {
            case .authenticationRequired:
                kind = .authenticationRequired
                statusCode = 401
                errorCode = "unauthorized"
                retryAfterSeconds = nil
            case .transient:
                kind = .transient
                statusCode = nil
                errorCode = "auth_refresh_transient"
                retryAfterSeconds = nil
            }
        case let service as IrxBrokerServiceError:
            switch service {
            case .invalidIdentity:
                kind = .invalid
                errorCode = "invalid_identity"
            case .notRegistered:
                // A binding can disappear between registration and minting;
                // the next activation attempt must be allowed to restore it.
                kind = .transient
                errorCode = "not_registered"
            case .noCredentialsIssued:
                // Empty or malformed relay responses are recoverable broker
                // availability failures, not a reason to stop renewal.
                kind = .transient
                errorCode = "no_credentials_issued"
            case .unknownRelayURL:
                // The trust cache may lag a rotated fleet; retry after the
                // authoritative discovery path catches up. Never log the URL.
                kind = .transient
                errorCode = "unknown_relay_url"
            }
            statusCode = nil
            retryAfterSeconds = nil
        case let broker as CmxIrohTrustBrokerClientError:
            switch broker {
            case .missingAuthentication:
                // A nil account-pinned snapshot also represents a brief
                // account transition. The auth identity stream owns the
                // definitive sign-out signal, so keep this request retryable
                // instead of stranding a valid session on its first read.
                kind = .transient
                statusCode = nil
                errorCode = broker.code
                retryAfterSeconds = nil
            case .invalidAuthentication:
                kind = .authenticationRequired
                statusCode = nil
                errorCode = broker.code
                retryAfterSeconds = nil
            case .connectivity:
                kind = .transient
                statusCode = nil
                errorCode = "connectivity"
                retryAfterSeconds = nil
            case let .rateLimited(code, retryAfter):
                kind = .transient
                statusCode = 429
                errorCode = code ?? "rate_limited"
                retryAfterSeconds = retryAfter
            case let .rejected(status, code):
                kind = Self.kind(
                    forStatusCode: status,
                    code: code,
                    operation: operation
                )
                statusCode = status
                errorCode = code ?? "http_\(status)"
                retryAfterSeconds = nil
            case .invalidBaseURL, .nonHTTPResponse:
                kind = .invalid
                statusCode = nil
                errorCode = broker.code
                retryAfterSeconds = nil
            case .invalidResponse:
                // A malformed broker response is commonly a deploy/proxy
                // blip. Keep it retryable while preserving a stable code.
                kind = .transient
                statusCode = nil
                errorCode = broker.code
                retryAfterSeconds = nil
            }
        default:
            kind = fallbackKind
            statusCode = nil
            errorCode = "unclassified"
            retryAfterSeconds = nil
        }
    }

    /// Returns the same classified failure attributed to a higher-level
    /// operation (for example, `hintRefresh` calling the register endpoint).
    public func with(operation: IrxBrokerOperation) -> Self {
        Self(
            operation: operation,
            kind: kind,
            statusCode: statusCode,
            errorCode: errorCode,
            retryAfterSeconds: retryAfterSeconds
        )
    }

    private init(
        operation: IrxBrokerOperation,
        kind: IrxBrokerFailureKind,
        statusCode: Int?,
        errorCode: String?,
        retryAfterSeconds: Int?
    ) {
        self.operation = operation
        self.kind = kind
        self.statusCode = statusCode
        self.errorCode = errorCode
        self.retryAfterSeconds = retryAfterSeconds
    }

    /// Whether the auth lifecycle must ask the user to sign in again.
    public var requiresReauthentication: Bool {
        kind == .authenticationRequired
    }

    /// Whether the caller should retry with bounded backoff.
    public var isRetryable: Bool {
        kind == .transient
    }

    /// Attributes safe to attach to an irx journal event.
    public var journalAttributes: [String: String] {
        var values: [String: String] = [
            "operation": operation.rawValue,
            "failure_kind": kind.rawValue,
            "error_code": errorCode ?? "unknown",
        ]
        if let statusCode {
            values["status_code"] = String(statusCode)
        }
        if let retryAfterSeconds {
            values["retry_after_s"] = String(retryAfterSeconds)
        }
        return values
    }

    private static func kind(
        forStatusCode statusCode: Int,
        code: String?,
        operation: IrxBrokerOperation
    ) -> IrxBrokerFailureKind {
        switch statusCode {
        case 401:
            // The shared client has already attempted exactly one recovery at
            // this point. A second broker 401 is not evidence that the auth
            // refresh itself was rejected (that outcome is carried explicitly
            // by CmxIrohBrokerTokenRecoveryError.authenticationRequired); it
            // can still be a broker-side propagation race. Keep the first few
            // occurrences on the bounded activation ladder; the lifecycle
            // policy escalates a persistent sequence to reauthentication.
            .transient
        case 403 where code?.lowercased() == "binding_request_proof_required"
            || code?.lowercased() == "invalid_binding_request_proof":
            .transient
        case 403 where [
            "unauthorized", "invalid_token", "token_expired", "auth_required",
            "account_mismatch"
        ].contains(code?.lowercased() ?? ""):
            .authenticationRequired
        case 404:
            // A missing broker route or peer is a durable server/input
            // mismatch, not a connectivity outage. Stop and surface it so a
            // client cannot poll the same guaranteed 404 forever.
            .rejected
        case 408, 425, 429, 500 ... 599:
            .transient
        default:
            .rejected
        }
    }
}

extension IrxBrokerFailure: DiagnosticFailureProviding {
    public var diagnosticFailureKind: DiagnosticFailureKind {
        switch kind {
        case .authenticationRequired:
            .authorizationFailed
        case .transient:
            .offline
        case .rejected:
            .policyUnavailable
        case .invalid:
            .protocolViolation
        }
    }
}

private extension CmxIrohTrustBrokerClientError {
    var code: String? {
        switch self {
        case .missingAuthentication: "missing_authentication"
        case .invalidAuthentication: "invalid_authentication"
        case .connectivity: "connectivity"
        case .invalidBaseURL: "invalid_base_url"
        case .nonHTTPResponse: "non_http_response"
        case .invalidResponse: "invalid_response"
        case let .rateLimited(code, _): code
        case let .rejected(_, code): code
        }
    }
}

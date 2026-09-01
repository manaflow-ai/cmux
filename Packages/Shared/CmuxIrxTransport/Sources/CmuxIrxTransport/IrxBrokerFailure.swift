public import CMUXMobileCore
import CmuxIrohTransport

/// Broker failure context carried from the transport to the host lifecycle.
///
/// The wrapper retains only stable operation, status, and error-code fields;
/// raw response bodies and token material never cross into the journal or UI.
public struct IrxBrokerFailure: Error, Codable, Equatable, Sendable {
    /// Selects the counter used for bounded auth-recovery escalation.
    public typealias EscalationBucket = IrxBrokerFailureEscalationBucket

    /// The broker operation that produced the failure.
    public let operation: IrxBrokerOperation
    /// The privacy-safe failure category selected by the transport.
    public let kind: IrxBrokerFailureKind
    /// The HTTP status, when the failure came from an HTTP response.
    public let statusCode: Int?
    /// A stable, sanitized broker or local error code.
    public let errorCode: String?
    /// The validated server-provided retry floor, if present.
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
            case .invalidEndpointBinding:
                kind = .invalid
                errorCode = "invalid_endpoint_binding"
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
                kind = irxBrokerFailureKind(
                    operation: operation,
                    statusCode: status,
                    code: code
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

    /// The single counter bucket shared by the policy and every lifecycle
    /// owner. Definitive auth failures do not consume a retry counter.
    public var escalationBucket: EscalationBucket {
        guard !requiresReauthentication else { return .transient }
        if statusCode == 401 { return .unauthorized }
        if statusCode == nil, errorCode == "missing_authentication" {
            return .missingAuthentication
        }
        return .transient
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

}

/// Classifies an HTTP broker rejection without retaining its response body.
private func irxBrokerFailureKind(
    operation: IrxBrokerOperation,
    statusCode: Int,
    code: String?
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
        // Activation endpoints can briefly return 404 while a backend route
        // or CDN deployment rolls out. Keep those operations on the bounded
        // retry ladder; account-management and peer-targeted 404s remain
        // terminal because retrying them cannot create the target.
        switch operation {
        case .register, .discover, .mint, .hintRefresh:
            .transient
        case .pairGrant, .revoke, .endpoint:
            .rejected
        }
    case 408, 425, 429, 500 ... 599:
        .transient
    default:
        .rejected
    }
}

extension IrxBrokerFailure: DiagnosticFailureProviding {
    /// Maps this broker failure to the shared diagnostic taxonomy.
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

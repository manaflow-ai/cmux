/// Selects the counter used for bounded irx auth-recovery escalation.
///
/// A broker response body that happens to use the `missing_authentication`
/// code with an HTTP status remains a normal transient failure; only a
/// missing, status-less auth snapshot enters the dedicated account-transition
/// bucket.
public enum IrxBrokerFailureEscalationBucket: String, Codable, Equatable, Sendable {
    /// A post-recovery HTTP 401 that may be a short propagation race.
    case unauthorized
    /// A status-less missing session snapshot during account transition.
    case missingAuthentication = "missing_authentication"
    /// All other retryable failures use the generic transient ladder.
    case transient
}

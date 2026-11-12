import IrohLib

extension RelayFailureKind {
    /// Stable local diagnostic code, independent of peer-supplied error text.
    var diagnosticCode: String {
        switch self {
        case .unknownIssuer: "UnknownIssuer"
        case .hostnameMismatch: "HostnameMismatch"
        case .certificateExpired: "CertificateExpired"
        case .certificateNotYetValid: "CertificateNotYetValid"
        case .certificateRevoked: "CertificateRevoked"
        case .systemTrustFailed: "SystemTrustFailed"
        case .tlsFailed: "TLSFailed"
        case .networkFailed: "NetworkFailed"
        case .other: "Other"
        }
    }
}

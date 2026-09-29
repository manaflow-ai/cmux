/// The first pairing surface shown when the add-computer sheet opens.
enum PairingPresentation: Equatable {
    /// The manual name, host, and port form.
    case manual

    /// The QR scanner, with the manual form still available after a scan error.
    case scanner(entry: PairingAnalyticsEntry)

    /// Approval for an externally supplied attach ticket whose compatibility
    /// level differs from this iPhone. This is not a manual-pairing entrypoint.
    case versionApproval

    var showsScanner: Bool {
        switch self {
        case .scanner:
            return true
        default:
            return false
        }
    }

    var showsManualPairingControls: Bool {
        switch self {
        case .manual, .scanner:
            return true
        case .versionApproval:
            return false
        }
    }

    var analyticsEntry: String {
        switch self {
        case .manual:
            "post_sign_in"
        case let .scanner(entry):
            entry.rawValue
        case .versionApproval:
            "version_approval"
        }
    }
}

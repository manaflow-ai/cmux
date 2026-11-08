/// The first pairing surface shown when the add-computer sheet opens.
enum PairingPresentation: Equatable {
    /// The manual name, host, and port form.
    case manual

    /// The QR scanner, with the manual form still available after a scan error.
    case scanner(entry: PairingAnalyticsEntry)

    /// The same add-connection sheet opened from a Computer's Tailscale
    /// method section, titled as adding a Tailscale connection. The scanner
    /// stays one tap away inside the sheet instead of opening the camera
    /// directly.
    case tailscaleSetup

    /// Replaces the selected Computer's existing Tailscale route. The QR
    /// scanner opens immediately, while the manual form remains available if
    /// the user needs it.
    case tailscaleReplacement

    /// Approval for an externally supplied attach ticket whose compatibility
    /// level differs from this iPhone. This is not a manual-pairing entrypoint.
    case versionApproval

    var showsScanner: Bool {
        switch self {
        case .scanner, .tailscaleReplacement:
            return true
        default:
            return false
        }
    }

    var showsManualPairingControls: Bool {
        self != .versionApproval
    }

    var analyticsEntry: String {
        switch self {
        case .manual:
            "post_sign_in"
        case let .scanner(entry):
            entry.rawValue
        case .tailscaleSetup:
            "tailscale_setup"
        case .tailscaleReplacement:
            "tailscale_replacement"
        case .versionApproval:
            "version_approval"
        }
    }
}

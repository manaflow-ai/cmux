/// The first pairing surface shown when the add-computer sheet opens.
enum PairingPresentation: Equatable {
    /// The manual name, host, and port form.
    case manual

    /// The QR scanner, with the manual form still available after a scan error.
    case scanner(entry: PairingAnalyticsEntry)

    /// Adds a Tailscale connection to one already-paired Computer. The camera
    /// opens immediately and the sheet never shows the Add Computer form: the
    /// Computer exists, and hand-entered addresses belong in its Direct
    /// address list, not the pairing flow.
    case tailscaleSetup

    /// Replaces the selected Computer's existing Tailscale route. Scanner-only,
    /// like ``tailscaleSetup``.
    case tailscaleReplacement

    /// Approval for an externally supplied attach ticket whose compatibility
    /// level differs from this iPhone. This is not a manual-pairing entrypoint.
    case versionApproval

    var showsScanner: Bool {
        switch self {
        case .scanner, .tailscaleSetup, .tailscaleReplacement:
            return true
        default:
            return false
        }
    }

    var showsManualPairingControls: Bool {
        switch self {
        case .manual, .scanner:
            return true
        case .tailscaleSetup, .tailscaleReplacement, .versionApproval:
            return false
        }
    }

    /// A scan scoped to one already-paired Computer: the sheet is the scanner
    /// plus scan results, with a rescan affordance after a failed code.
    var isPerComputerScan: Bool {
        switch self {
        case .tailscaleSetup, .tailscaleReplacement:
            return true
        default:
            return false
        }
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

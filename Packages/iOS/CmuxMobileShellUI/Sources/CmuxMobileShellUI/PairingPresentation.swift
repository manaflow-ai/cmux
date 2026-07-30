/// The first pairing surface shown when the add-computer sheet opens.
enum PairingPresentation: Equatable {
    /// The manual name, host, and port form.
    case manual

    /// The QR scanner, with the manual form still available after a scan error.
    case scanner(entry: PairingAnalyticsEntry)

    var showsScanner: Bool {
        if case .scanner = self { return true }
        return false
    }

    var analyticsEntry: String {
        switch self {
        case .manual:
            "post_sign_in"
        case let .scanner(entry):
            entry.rawValue
        }
    }
}

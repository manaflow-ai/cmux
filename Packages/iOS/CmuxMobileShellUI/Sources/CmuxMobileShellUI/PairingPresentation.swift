/// The first pairing surface shown when the add-computer sheet opens.
enum PairingPresentation: Equatable {
    /// The manual name, host, and port form.
    case manual

    /// The QR scanner, with the manual form still available after a scan error.
    case scanner
}

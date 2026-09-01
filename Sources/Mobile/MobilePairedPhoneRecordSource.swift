/// How a paired-phone record became known to the Mac.
enum MobilePairedPhoneRecordSource: String, Codable, Sendable {
    case authenticatedHandshake
    /// A pre-metadata iOS client completed an authenticated status handshake;
    /// its historical lane/selection target is retained for compatibility.
    case legacyCompatibility
    case legacyPickerMigration
}

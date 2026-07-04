enum PendingManualHostTrust {
    case manual(
        name: String,
        host: String,
        port: Int,
        pairedMacDeviceID: String?,
        recordsPairingAttempt: Bool,
        ifStillCurrent: (() -> Bool)?
    )
    case pairingURL(rawURL: String, acceptedVersionWarning: Bool)
}

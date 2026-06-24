import CMUXMobileCore

/// A minted iPhone pairing ticket ready for display in the Mac pairing window.
struct MobilePairingReady: Equatable {
    /// The `cmux-ios://attach?...` URL encoded into the QR code.
    let attachURL: String
    /// The Mac's display name, shown above the code.
    let macName: String
    /// Reachable Tailscale `host:port` routes. Empty when QR pairing is unavailable.
    let tailscaleLines: [String]
    /// The best route for manual phone entry, behind the "Copy IP" and "Copy Port"
    /// buttons. `nil` when no phone-dialable route exists.
    let manualEntry: CmxManualPairingEntry?
    /// One-time key required when the user manually enters a trusted LAN/VPN
    /// route instead of scanning the QR code.
    let trustedNetworkPairingSecret: String

    /// Whether at least one Tailscale route resolved.
    var reachableViaTailscale: Bool { !tailscaleLines.isEmpty }
}

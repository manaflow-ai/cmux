/// The transport tab displayed by the Mac pairing window.
enum MobilePairingTransportChoice: Hashable {
    /// Authenticated Iroh discovery, without a QR code.
    case iroh
    /// Explicit Tailscale pairing through the displayed QR code.
    case tailscale
    /// No currently reachable transport can present a pairing flow.
    case unavailable
}

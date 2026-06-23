/// Network route state shown in the Mac pairing window's requirements list.
enum MobilePairingNetworkStatus {
    /// QR pairing is available over an automatically detected Tailscale route.
    case automatic
    /// QR pairing is unavailable, but manual VPN/LAN host entry is available.
    case manual
}

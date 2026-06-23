/// Manual pairing details when the user brings their own VPN/LAN route.
struct MobilePairingManualOnly: Equatable {
    /// The Mac's display name, shown in the manual instructions.
    let macName: String
    /// The listener port the iPhone should use with the user's chosen host/IP.
    let port: Int
    /// One-time secret shown on the Mac and typed on the iPhone for trusted
    /// LAN/VPN manual ticket minting.
    let trustedNetworkPairingSecret: String
}

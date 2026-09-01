import CMUXMobileCore

/// One device-local Tailscale route grant and the event that created it.
struct MobilePairedMacTailscaleRouteGrant {
    let route: CmxAttachRoute
    let origin: MobilePairedMacTailscaleGrantOrigin
}

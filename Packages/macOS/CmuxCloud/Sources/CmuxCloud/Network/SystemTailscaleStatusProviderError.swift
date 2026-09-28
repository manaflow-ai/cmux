/// Failures reading the authenticated local Tailscale peer map.
enum SystemTailscaleStatusProviderError: Error, Equatable, Sendable {
    case statusUnavailable
}

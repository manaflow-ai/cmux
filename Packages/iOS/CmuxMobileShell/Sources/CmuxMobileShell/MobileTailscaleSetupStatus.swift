/// Readiness of the selected Tailscale connection method.
///
/// Keeping the load phase explicit prevents presentation code from treating a
/// not-yet-loaded authorization as either confirmed or missing.
public enum MobileTailscaleSetupStatus: Equatable, Sendable {
    case notSelected
    case loadingAuthorization
    case pairingRequired
    case authorized
}

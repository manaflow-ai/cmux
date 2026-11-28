/// The UI-facing tri-state of this device's tailnet, read through
/// ``TailscaleStatusObserving``.
///
/// Mirrors the transport layer's classification without coupling UI code to
/// the concrete system detector; the app's composition root adapts the
/// detector onto this type.
public enum TailnetStatus: Equatable, Sendable {
    /// A Tailscale tunnel interface with a tailnet self-address is up.
    case active
    /// No tailnet interface was found: Tailscale is off or not installed.
    case inactiveOrNotInstalled
    /// Interface enumeration failed, so the state cannot be determined.
    case unknown
}

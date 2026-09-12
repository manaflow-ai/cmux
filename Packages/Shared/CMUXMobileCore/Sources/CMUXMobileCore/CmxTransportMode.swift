import Foundation

/// The user's selected transport policy.
public enum CmxTransportMode: String, Codable, CaseIterable, Hashable, Sendable {
    /// Let the runtime use its normal route ordering and Iroh fallback policy.
    case automatic = "auto"
    /// Permit only a local-network route.
    case lan
    /// Permit only a Tailscale route.
    case tailscale
    /// Permit only an Iroh route and Iroh-native paths.
    case iroh
    /// Preserve the legacy per-computer direct-address allowlist. The wire
    /// transport remains Iroh; its configured candidates are enforced by the
    /// direct-candidate policy rather than this generic path filter.
    case direct

    /// Source-compatible spelling for callers that use the UI vocabulary.
    public static var auto: Self { .automatic }
    /// Source-compatible spelling for the LAN-only mode.
    public static var lanOnly: Self { .lan }
    /// Source-compatible spelling for the Tailscale-only mode.
    public static var tailscaleOnly: Self { .tailscale }
    /// Source-compatible spelling for the Iroh-only mode.
    public static var irohOnly: Self { .iroh }

    /// The class required by a pinned mode, or `nil` for Auto.
    public var pinnedClass: CmxTransportClass? {
        switch self {
        case .automatic: nil
        case .lan: .lan
        case .tailscale: .tailscale
        case .iroh: .iroh
        case .direct: .iroh
        }
    }

    /// Whether this mode is a hard (non-fallback) constraint.
    public var isPinned: Bool { pinnedClass != nil }

    /// Stable human-readable name used in errors and fallback diagnostics.
    public var displayName: String {
        switch self {
        case .automatic:
            String(localized: "cmux.transport.mode.auto", defaultValue: "Auto", bundle: .module)
        case .lan:
            String(localized: "cmux.transport.mode.lan", defaultValue: "LAN only", bundle: .module)
        case .tailscale:
            String(localized: "cmux.transport.mode.tailscale", defaultValue: "Tailscale only", bundle: .module)
        case .iroh:
            String(localized: "cmux.transport.mode.iroh", defaultValue: "iroh only", bundle: .module)
        case .direct:
            String(localized: "cmux.transport.mode.direct", defaultValue: "Direct", bundle: .module)
        }
    }
}

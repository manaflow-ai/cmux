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
    public static var lanOnly: Self { .lan }
    public static var tailscaleOnly: Self { .tailscale }
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
        case .automatic: Self.localized("cmux.transport.mode.auto", "Auto")
        case .lan: Self.localized("cmux.transport.mode.lan", "LAN only")
        case .tailscale: Self.localized("cmux.transport.mode.tailscale", "Tailscale only")
        case .iroh: Self.localized("cmux.transport.mode.iroh", "iroh only")
        case .direct: Self.localized("cmux.transport.mode.direct", "Direct")
        }
    }

    private static func localized(_ key: StaticString, _ value: String) -> String {
        String(localized: key, defaultValue: String.LocalizationValue(value), bundle: .module)
    }
}

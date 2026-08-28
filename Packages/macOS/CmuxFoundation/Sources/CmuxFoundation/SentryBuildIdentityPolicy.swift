import Foundation

/// Decides whether Sentry telemetry may be emitted for the current build
/// identity.
///
/// The cmux repository is public, and rebranded forks have shipped with the
/// hardcoded cmux DSN intact (Sentry issue CMUXTERM-MACOS-1RZF: ~11k
/// "mosaic_cli" events from `mosaic.com.emergent.app` builds). Telemetry is
/// therefore fail-closed: it is allowed only when the resolved bundle
/// identifier affirmatively identifies a cmux build (the trusted base
/// identifier itself, or a dotted descendant such as nightly, staging, and
/// tagged debug builds). A missing or foreign identity emits nothing.
public struct SentryBuildIdentityPolicy: Sendable {
    /// Whether the resolved build identity may report to the cmux DSN.
    public let allowsTelemetry: Bool

    /// Creates a policy from a resolved bundle identifier.
    ///
    /// - Parameters:
    ///   - bundleIdentifier: The build identity, resolved from the trusted
    ///     process environment or the enclosing app bundle. `nil` and empty
    ///     values deny telemetry.
    ///   - trustedBaseBundleIdentifier: The stable cmux bundle identifier that
    ///     roots every cmux build flavor.
    public init(bundleIdentifier: String?, trustedBaseBundleIdentifier: String) {
        guard let bundleIdentifier = bundleIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !bundleIdentifier.isEmpty
        else {
            allowsTelemetry = false
            return
        }
        allowsTelemetry = bundleIdentifier == trustedBaseBundleIdentifier
            || bundleIdentifier.hasPrefix(trustedBaseBundleIdentifier + ".")
    }
}

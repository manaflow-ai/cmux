public import Foundation

/// A debug-build-only forced relay for tagged test builds.
///
/// When active, every host (Mac) and dial (iOS) endpoint generation uses
/// exactly one operator-supplied relay, replacing managed policy, cached
/// credentials, and account preference. The override is read at each
/// endpoint-profile installation, so a later broker policy refresh cannot
/// displace it. Release builds compile the override away entirely.
public enum CmxIrohDebugRelayOverride {
    /// The environment variable consulted first, and the `UserDefaults` key
    /// consulted second. A `-CMUX_IROH_RELAY_URL_OVERRIDE <url>` launch
    /// argument populates the defaults key on iOS builds whose launch
    /// environment cannot carry variables.
    public static let key = "CMUX_IROH_RELAY_URL_OVERRIDE"

    /// The process-wide override profile, or nil when inactive.
    static func activeProfile() -> CmxIrohEndpointRelayProfile? {
        #if DEBUG
        profile(rawValue: rawValue())
        #else
        nil
        #endif
    }

    /// The active override's single relay URL, exposed for local debug
    /// diagnostics (the `iroh_diag` socket verb). Nil when the override is
    /// inactive, and always nil in release builds, where the override
    /// compiles away.
    public static var diagnosticsActiveRelayURL: String? {
        activeProfile()?.activeRelays.first?.url
    }

    #if DEBUG
    /// Reads the raw override value, preferring the process environment.
    static func rawValue(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard
    ) -> String? {
        if let fromEnvironment = environment[key], !fromEnvironment.isEmpty {
            return fromEnvironment
        }
        return defaults.string(forKey: key)
    }

    /// Builds a strict single-relay custom profile, or nil for unusable input.
    ///
    /// The value must be a canonical HTTPS origin; a missing trailing slash
    /// is added. Any other malformed value deactivates the override instead
    /// of failing endpoint activation.
    static func profile(rawValue: String?) -> CmxIrohEndpointRelayProfile? {
        guard var url = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !url.isEmpty else {
            return nil
        }
        if !url.hasSuffix("/") { url += "/" }
        guard let relay = try? CmxIrohCustomRelay(url: url),
              let custom = try? CmxIrohCustomRelayProfile(relays: [relay]) else {
            return nil
        }
        return CmxIrohEndpointRelayProfile(customProfile: custom)
    }
    #endif
}

public import Foundation

/// A debug-build-only deployment-protection bypass for tagged test builds.
///
/// Vercel preview deployments of the broker sit behind deployment
/// protection, which the app's broker client cannot pass. When active,
/// every trust-broker request carries the platform's
/// `x-vercel-protection-bypass` header so a tagged test build can talk to
/// a protected preview directly. Release builds compile the bypass away
/// entirely, and the value never applies to relay traffic (relays carry
/// their own bypass in their configured URLs).
public enum CmxIrohDebugBrokerBypassHeader {
    /// The environment variable consulted first, and the `UserDefaults`
    /// key consulted second, mirroring ``CmxIrohDebugRelayOverride``.
    public static let key = "CMUX_IROH_BROKER_PROTECTION_BYPASS"

    /// The deployment-platform header that carries the bypass value.
    static let headerField = "x-vercel-protection-bypass"

    /// The process-wide bypass value, or nil when inactive.
    static func activeValue() -> String? {
        #if DEBUG
        value(rawValue: rawValue())
        #else
        nil
        #endif
    }

    #if DEBUG
    /// Reads the raw bypass value, preferring the process environment.
    static func rawValue(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard
    ) -> String? {
        if let fromEnvironment = environment[key], !fromEnvironment.isEmpty {
            return fromEnvironment
        }
        return defaults.string(forKey: key)
    }

    /// Accepts only a bounded single-line token safe to place in a header.
    static func value(rawValue: String?) -> String? {
        guard let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value.utf8.count <= 128,
              value.utf8.allSatisfy({ byte in
                  byte > 0x20 && byte < 0x7F
              }) else {
            return nil
        }
        return value
    }
    #endif
}

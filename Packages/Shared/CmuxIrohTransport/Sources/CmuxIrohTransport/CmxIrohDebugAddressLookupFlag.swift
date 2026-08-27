public import Foundation

/// A debug-build-only opt-in for the registry-backed iroh address lookup.
///
/// When enabled, every endpoint generation installs
/// ``CmxIrohRegistryAddressLookup`` on the endpoint builder while keeping
/// today's hint dials, so magicsock merges both path sets (app hints as
/// `Source::App`, lookup results as `Source::AddressLookup`) and the two
/// resolve paths can be compared safely. The flag is read at each endpoint
/// bind. Release builds compile the mechanism away entirely, so the default
/// build behavior is byte-identical to a build without this code.
public enum CmxIrohDebugAddressLookupFlag {
    /// The environment variable consulted first, and the `UserDefaults` key
    /// consulted second. A `-CMUX_IROH_ADDRESS_LOOKUP 1` launch argument
    /// populates the defaults key on iOS builds whose launch environment
    /// cannot carry variables.
    public static let key = "CMUX_IROH_ADDRESS_LOOKUP"

    /// Whether the address lookup service should be installed at bind.
    public static func isEnabled() -> Bool {
        #if DEBUG
        isEnabled(rawValue: rawValue())
        #else
        false
        #endif
    }

    #if DEBUG
    /// Reads the raw flag value, preferring the process environment.
    static func rawValue(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard
    ) -> String? {
        if let fromEnvironment = environment[key], !fromEnvironment.isEmpty {
            return fromEnvironment
        }
        return defaults.string(forKey: key)
    }

    /// Interprets the raw value; anything but an explicit opt-in stays off.
    static func isEnabled(rawValue: String?) -> Bool {
        guard let rawValue else { return false }
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "on", "yes":
            return true
        default:
            return false
        }
    }
    #endif
}

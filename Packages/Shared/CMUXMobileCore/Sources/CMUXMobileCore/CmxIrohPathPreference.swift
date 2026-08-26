public import Foundation

/// Legacy device-local Iroh path preference retained for version compatibility.
public enum CmxIrohPathPreference: String, CaseIterable, Equatable, Sendable {
    /// Allows Iroh to select automatic, direct, private-network, or relay paths.
    case automatic = "auto"

    /// Keeps Iroh connections on relay paths.
    case relayOnly

    /// Prevents this device from listening or dialing through Iroh relays.
    case neverUseRelays

    /// Shared defaults key used independently by the macOS and iOS apps.
    public static let defaultsKey = "cmux.iroh.pathPreference"

    /// The release transport mode after normalizing retired preferences.
    ///
    /// Relay-only is a DEBUG verification mode. A value persisted by an older
    /// release must not constrain a current production connection.
    public var transportVerificationMode: CmxIrohTransportVerificationMode {
        switch self {
        case .automatic: .automatic
        case .relayOnly: .automatic
        case .neverUseRelays: .directOnly
        }
    }

    /// Reads the persisted preference; absent or unknown values are automatic.
    ///
    /// - Parameter defaults: The device-local defaults domain to read.
    /// - Returns: The stored preference, or ``automatic`` when no known value exists.
    public static func stored(in defaults: UserDefaults) -> CmxIrohPathPreference {
        guard let rawValue = defaults.string(forKey: defaultsKey) else { return .automatic }
        return CmxIrohPathPreference(rawValue: rawValue) ?? .automatic
    }
}

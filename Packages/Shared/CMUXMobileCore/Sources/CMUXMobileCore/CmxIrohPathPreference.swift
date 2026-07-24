public import Foundation

/// Release-safe, device-local Iroh path constraint chosen in Settings.
public enum CmxIrohPathPreference: String, CaseIterable, Equatable, Sendable {
    /// Allows Iroh to select automatic, direct, private-network, or relay paths.
    case automatic = "auto"

    /// Keeps Iroh connections on relay paths.
    case relayOnly

    /// Shared defaults key used independently by the macOS and iOS apps.
    public static let defaultsKey = "cmux.iroh.pathPreference"

    /// The transport constraint this preference imposes on the runtime.
    public var transportVerificationMode: CmxIrohTransportVerificationMode {
        switch self {
        case .automatic: .automatic
        case .relayOnly: .relayOnly
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

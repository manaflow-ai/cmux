import Foundation

/// Why the provider could not start, as macOS shows it to the app.
enum ProviderError: LocalizedError {
    case missingConfiguration
    case invalidConfiguration(String)
    case noTunnelInterface
    case engine(String)

    var errorDescription: String? {
        switch self {
        case .missingConfiguration: "The Cloud Tunnel has no saved configuration."
        case .invalidConfiguration(let reason): "The Cloud Tunnel's configuration is invalid: \(reason)"
        case .noTunnelInterface: "macOS gave the Cloud Tunnel no network interface."
        case .engine(let reason): "The Cloud Tunnel's WireGuard engine did not start: \(reason)"
        }
    }
}

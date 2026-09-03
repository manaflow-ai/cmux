import Foundation

/// Strips key material from WireGuard's runtime configuration dump (the
/// `wg show`-style text ``CloudTunnelProviderMessage/runtimeConfiguration``
/// asks the provider for). The app only needs peers, handshakes, and transfer
/// counters; the private and pre-shared keys stay inside the extension.
/// Compiled into both the app and the extension.
enum CloudTunnelRuntimeConfigurationRedactor {
    static let redactedKeys: Set<String> = ["private_key", "preshared_key"]

    static func redacted(_ runtimeConfiguration: String) -> String {
        runtimeConfiguration
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                guard let separator = line.firstIndex(of: "=") else { return true }
                return !redactedKeys.contains(String(line[..<separator]))
            }
            .joined(separator: "\n")
    }
}

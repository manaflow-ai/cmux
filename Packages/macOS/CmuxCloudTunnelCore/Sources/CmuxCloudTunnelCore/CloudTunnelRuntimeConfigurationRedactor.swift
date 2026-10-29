import Foundation

/// Strips key material from WireGuard's runtime configuration dump (the
/// `wg show`-style text ``CloudTunnelProviderMessage/runtimeConfiguration``
/// asks the provider for). The app only needs peers, handshakes, and transfer
/// counters; the private and pre-shared keys stay inside the extension.
/// Linked into both the app and the extension.
public struct CloudTunnelRuntimeConfigurationRedactor: Sendable {
    private let redactedKeys: Set<String>

    /// Creates a redactor.
    ///
    /// - Parameter redactedKeys: The runtime-configuration keys whose lines are dropped;
    ///   defaults to the private and pre-shared keys.
    public init(redactedKeys: Set<String> = ["private_key", "preshared_key"]) {
        self.redactedKeys = redactedKeys
    }

    /// Returns `runtimeConfiguration` without the lines for ``redactedKeys``.
    ///
    /// - Parameter runtimeConfiguration: The provider's runtime configuration text.
    /// - Returns: The same text with key-material lines removed.
    public func redacted(_ runtimeConfiguration: String) -> String {
        runtimeConfiguration
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                guard let separator = line.firstIndex(of: "=") else { return true }
                return !redactedKeys.contains(String(line[..<separator]))
            }
            .joined(separator: "\n")
    }
}

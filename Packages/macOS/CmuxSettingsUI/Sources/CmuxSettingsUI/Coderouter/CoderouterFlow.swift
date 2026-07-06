import Foundation

/// Host-supplied dependency for creating and displaying cmux AI Gateway keys.
///
/// The settings UI package does not depend on the app target or auth runtime.
/// The host wraps those services in this protocol and injects it through
/// ``SettingsRuntime``.
@MainActor
public protocol CoderouterFlow: AnyObject {
    /// Whether the host has an authenticated cmux account snapshot.
    var isSignedIn: Bool { get }

    /// Gateway base URL exported to routed agent processes.
    var gatewayBaseURL: String { get }

    /// Creates a new gateway key and returns the one-time `crk_` secret.
    ///
    /// - Returns: The gateway key secret to store in ``SecretFileStore``.
    func createKey() async throws -> String
}

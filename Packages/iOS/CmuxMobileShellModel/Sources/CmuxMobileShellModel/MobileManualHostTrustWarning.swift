import Foundation

/// UI state describing a manual-host route that needs explicit trust.
public struct MobileManualHostTrustWarning: Equatable, Sendable {
    /// The trust scope that will be persisted if the user approves.
    public let scope: MobileManualHostTrustScope
    /// The host text shown to the user.
    public let displayHost: String

    /// Creates a warning for a pending manual-host approval.
    /// - Parameters:
    ///   - scope: The narrow host/port/account trust scope.
    ///   - displayHost: The host string to show. Defaults to the normalized host.
    public init(scope: MobileManualHostTrustScope, displayHost: String? = nil) {
        self.scope = scope
        self.displayHost = displayHost ?? scope.normalizedHost
    }

    /// The approved endpoint, formatted for display.
    public var endpoint: String {
        let host = if displayHost.hasPrefix("[") && displayHost.hasSuffix("]") {
            String(displayHost.dropFirst().dropLast())
        } else {
            displayHost
        }
        return host.contains(":")
            ? "[\(host)]:\(scope.port)"
            : "\(host):\(scope.port)"
    }
}

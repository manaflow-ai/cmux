public import CMUXMobileCore
import Foundation

/// A narrowly-scoped manual-host trust decision.
///
/// Trust is keyed to the normalized host, port, and current Stack user id when
/// one is available. That keeps an approval for one LAN host from becoming a
/// global permission for unrelated plaintext routes.
public struct MobileManualHostTrustScope: Equatable, Hashable, Sendable {
    /// The normalized host, lowercased for DNS/IP-literal comparisons.
    public let normalizedHost: String
    /// The approved TCP port.
    public let port: Int
    /// The Stack user id that approved this route, or `nil` when no account is known.
    public let stackUserID: String?

    /// Creates a trust scope from a user-entered host and port.
    /// - Parameters:
    ///   - host: A DNS name or IP literal.
    ///   - port: The TCP port in `1...65535`.
    ///   - stackUserID: The approving Stack user id, if known.
    public init?(host: String, port: Int, stackUserID: String?) {
        guard let manualHost = CmxManualHost(routeHost: host),
              (1...65535).contains(port) else {
            return nil
        }
        self.normalizedHost = manualHost.rawValue.lowercased()
        self.port = port
        let trimmedUserID = stackUserID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.stackUserID = trimmedUserID?.isEmpty == false ? trimmedUserID : nil
    }

    /// Creates a trust scope from an attach route.
    /// - Parameters:
    ///   - route: The manual-host route to scope.
    ///   - stackUserID: The approving Stack user id, if known.
    public init?(route: CmxAttachRoute, stackUserID: String?) {
        guard case let .hostPort(host, port) = route.endpoint else {
            return nil
        }
        self.init(host: host, port: port, stackUserID: stackUserID)
    }

    var storageKey: String {
        [
            (stackUserID ?? "").mobileManualHostTrustStorageEscaped,
            normalizedHost.mobileManualHostTrustStorageEscaped,
            "\(port)",
        ].joined(separator: "|")
    }
}

private extension String {
    var mobileManualHostTrustStorageEscaped: String {
        self
            .replacing("%", with: "%25")
            .replacing("|", with: "%7C")
    }
}

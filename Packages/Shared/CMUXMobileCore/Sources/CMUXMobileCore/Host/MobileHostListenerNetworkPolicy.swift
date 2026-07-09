import Foundation
import Network

/// Network-level admission and bind decisions the mobile pairing host's
/// `NWListener` makes: whether a bind error means the port is unusable, and
/// whether an incoming peer is on the loopback interface.
///
/// Stateless: construct one inline wherever a decision is needed; every
/// instance applies the same rules.
///
/// Loopback classification here is deliberately distinct from
/// ``CmxLoopbackHost``. That type classifies *dialer* host strings with libc
/// resolver semantics (`inet_aton`/`inet_pton`, including the unspecified
/// `0.0.0.0`/`::` ranges and numeric spellings) to decide what a phone may
/// dial. This type classifies an already-parsed `NWEndpoint.Host` for an
/// *accepted* connection's remote peer, matching exactly the bytes Network
/// hands the listener, so the release-build loopback refusal admits the same
/// peers it always has.
public struct MobileHostListenerNetworkPolicy: Sendable {
    /// Creates the classifier. It is stateless.
    public init() {}

    /// Whether `error` means the address/port cannot be bound (in use, not
    /// available, or permission denied) versus a transient waiting reason.
    public func isAddressUnavailable(_ error: NWError) -> Bool {
        if case let .posix(code) = error {
            return code == .EADDRINUSE || code == .EADDRNOTAVAIL || code == .EACCES
        }
        return false
    }

    /// Whether an incoming connection's remote peer is on the loopback
    /// interface.
    ///
    /// Used to refuse local connections in release builds, where no legitimate
    /// client ever connects via `127.0.0.1`/`::1`.
    public func isLoopbackConnection(_ connection: NWConnection) -> Bool {
        isLoopbackEndpoint(connection.endpoint) || isLoopbackEndpoint(connection.currentPath?.remoteEndpoint)
    }

    /// Whether `endpoint` names a loopback host.
    public func isLoopbackEndpoint(_ endpoint: NWEndpoint?) -> Bool {
        guard case let .hostPort(host, _)? = endpoint else { return false }
        switch host {
        case let .ipv4(address):
            // 127.0.0.0/8
            return address.rawValue.first == 127
        case let .ipv6(address):
            let bytes = Array(address.rawValue)
            guard bytes.count == 16 else { return false }
            // ::1
            let isV6Loopback = bytes[0..<15].allSatisfy { $0 == 0 } && bytes[15] == 1
            // IPv4-mapped loopback ::ffff:127.0.0.0/8
            let isV4MappedLoopback = bytes[0..<10].allSatisfy { $0 == 0 }
                && bytes[10] == 0xff && bytes[11] == 0xff && bytes[12] == 127
            return isV6Loopback || isV4MappedLoopback
        case let .name(name, _):
            let lowered = name.lowercased()
            return lowered == "localhost" || lowered.hasSuffix(".localhost")
        @unknown default:
            return false
        }
    }
}

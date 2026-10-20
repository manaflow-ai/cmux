import Foundation

/// Source of the current interface-address snapshot. The system
/// implementation walks `getifaddrs`; tests inject fixtures.
public protocol NetworkInterfaceAddressProviding: Sendable {
    /// The current interface addresses, or `nil` when enumeration failed.
    func currentInterfaceAddresses() -> [NetworkInterfaceAddress]?
}

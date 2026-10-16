/// Selects listening ports that are useful as workspace sidebar links.
public struct SidebarPortPolicy: Sendable {
    /// Creates the policy that suppresses dynamic ports bound only to loopback.
    public init() {}

    /// Whether a listener should be published to the workspace.
    ///
    /// - Parameters:
    ///   - port: The listener's port in host byte order.
    ///   - addressBytes: The IPv4 (4 bytes) or IPv6 (16 bytes) bind address in
    ///     network order. Unknown address shapes are retained conservatively.
    /// - Returns: False for invalid ports and loopback ports in 49152...65535.
    public func includes(port: Int, addressBytes: [UInt8]) -> Bool {
        guard (1...65_535).contains(port) else { return false }
        guard port >= 49_152 else { return true }
        switch addressBytes.count {
        case 4:
            return addressBytes[0] != 127
        case 16:
            let isIPv6Loopback = addressBytes.prefix(15).allSatisfy { $0 == 0 }
                && addressBytes[15] == 1
            let isMappedLoopback = addressBytes.prefix(10).allSatisfy { $0 == 0 }
                && addressBytes[10] == 255 && addressBytes[11] == 255
                && addressBytes[12] == 127
            return !isIPv6Loopback && !isMappedLoopback
        default:
            return true
        }
    }
}

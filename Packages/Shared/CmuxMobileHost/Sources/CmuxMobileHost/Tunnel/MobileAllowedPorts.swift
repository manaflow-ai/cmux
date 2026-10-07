/// Ports the user allowed on the Mac for phone forwarding (a Mac setting).
public protocol MobileAllowedPorts: Sendable {
    func allowedPorts() async -> [UInt16]
}

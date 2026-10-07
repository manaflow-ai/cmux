/// A fixed allowlist (tests, DEV, or no setting: empty).
public struct StaticAllowedPorts: MobileAllowedPorts {
    public var ports: [UInt16]

    public init(_ ports: [UInt16] = []) {
        self.ports = ports
    }

    public func allowedPorts() async -> [UInt16] {
        ports
    }
}

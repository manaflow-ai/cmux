import CmuxMobileWire

/// `read tunnel.ports`: what this device may open with `tcp.forward` now
/// (the directory filtered by the same policy every open applies).
public struct TunnelPortsReadHandler: MobileReadHandler {
    let policy: MobileTunnelPolicy
    let ports: any MobileTunnelPortDirectory

    init(policy: MobileTunnelPolicy, ports: any MobileTunnelPortDirectory) {
        self.policy = policy
        self.ports = ports
    }

    public func read(_ frame: ReadFrame, principal: MobileDevicePrincipal) async throws -> JSONValue {
        try JSONValue(encoding: TunnelPortsResult(ports: policy.admitted(await ports.ports(for: principal))))
    }
}

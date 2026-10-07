public import CmuxMobileWire

/// The standard directory (c14-web.md section 3.3): listeners of the user's
/// workspace processes (`detected`) plus the user's Mac-side allowlist
/// (`allowed`), one entry per port, in port order. Computed on demand.
public struct DetectedTunnelPorts: MobileTunnelPortDirectory {
    public let processes: any MobileWorkspaceProcesses
    public let scanner: any ListeningPortScanner
    public let allowed: any MobileAllowedPorts

    public init(processes: any MobileWorkspaceProcesses, scanner: any ListeningPortScanner,
                allowed: any MobileAllowedPorts = StaticAllowedPorts()) {
        self.processes = processes
        self.scanner = scanner
        self.allowed = allowed
    }

    public func ports(for principal: MobileDevicePrincipal) async -> [TunnelPort] {
        let running = await processes.processes()
        let listening = scanner.listeningPorts(of: running.map(\.pid))
        var byPort: [UInt16: TunnelPort] = [:]
        for process in running {
            for port in listening[process.pid] ?? [] where byPort[port] == nil {
                byPort[port] = TunnelPort(port: port, source: .detected, workspace: process.workspace, process: process.name)
            }
        }
        for port in await allowed.allowedPorts() where byPort[port] == nil {
            byPort[port] = TunnelPort(port: port, source: .allowed)
        }
        return byPort.values.sorted { $0.port < $1.port }
    }
}

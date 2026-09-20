import Foundation

extension CmuxTuiSurfaceProvider {
    static func info(
        from summary: VMSummary,
        linkState: SurfaceLinkState,
        linkError: String?,
        stats: VMStats?,
        remoteWorkspaces: [SurfaceRemoteWorkspace]? = nil,
        portDiscoveryState: CloudPortDiscoveryState = .notRequested
    ) -> SurfaceMachineInfo {
        SurfaceMachineInfo(
            id: .cloud(summary.id),
            name: summary.preferredName,
            status: summary.status,
            image: summary.image,
            hasDesktop: summary.resolvedKind.hasDesktop,
            memoryMb: stats?.memoryTotalMb,
            diskMb: stats?.diskTotalMb,
            linkState: linkState,
            linkError: linkError,
            cpuPercent: stats?.cpuPercent,
            memoryUsedMb: stats?.memoryUsedMb,
            diskUsedMb: stats?.diskUsedMb,
            remoteWorkspaces: remoteWorkspaces,
            privateAddress: summary.preferredPrivateAddress,
            portDiscoveryState: portDiscoveryState
        )
    }

    static func portDiscoveryState(
        for scan: CloudPortScanResult,
        privateAddress: String?
    ) -> CloudPortDiscoveryState {
        if privateAddress == nil, !scan.ports.isEmpty {
            return .unavailable(.privateAddress)
        }
        if let emptyReason = scan.emptyReason {
            return .empty(emptyReason)
        }
        return .available
    }

    func ports(
        link: CloudMachineLink,
        socketPath: String,
        force: Bool,
        generation: UInt64,
        privateAddress: String?
    ) async -> CloudPortScanResult? {
        if !force, let cached = portsCache, Date.now.timeIntervalSince(cached.at) < portsTTL {
            return cached.scan
        }
        guard let arguments = CloudTuiRequests.listeningPortsArguments(socketPath: socketPath),
              let data = try? await link.run(arguments: arguments),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stdout = object["stdout"] as? String else {
            return nil
        }
        let result = VMExecResult(exitCode: 0, stdout: stdout, stderr: "")
        guard let scan = Self.portScan(from: result, privateAddress: privateAddress) else { return nil }
        guard generation == refreshGeneration else { return nil }
        portsCache = (scan, Date.now)
        return scan
    }
}

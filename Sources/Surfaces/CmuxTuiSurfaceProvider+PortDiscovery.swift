import Foundation

extension CmuxTuiSurfaceProvider {
    /// Re-read only this machine's metadata, fencing deletion, replacement, account changes, and newer summaries.
    func refreshPortMetadata() async throws {
        guard isRegisteredInCatalog() else { throw CancellationError() }
        let lifecycle = currentLifecycleGeneration
        let summaryVersion = summaryGeneration
        let next = try await loadPortSummary(machineID)
        try Task.checkCancellation()
        guard isCurrentLifecycleGeneration(lifecycle), isRegisteredInCatalog() else { throw CancellationError() }
        guard next.id == machineID else { throw ProviderError.invalidSnapshot(machineID) }
        guard summaryGeneration == summaryVersion else { return }
        await links.setPrivateAddresses([next.addressIPv4, next.addressIPv6].compactMap { $0 }, for: machineID)
        try Task.checkCancellation()
        guard isCurrentLifecycleGeneration(lifecycle), isRegisteredInCatalog(), summaryGeneration == summaryVersion else {
            throw CancellationError()
        }
        update(summary: next)
    }

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

    func ports(
        link: CloudMachineLink,
        socketPath: String,
        force: Bool,
        generation: UInt64,
        privateAddress: String?
    ) async -> CloudPortScanResult? {
        guard portDiscovery.mayScan else { return nil }
        if let cached = portDiscovery.cachedScan(at: Date.now, socketPath: socketPath, force: force) {
            return cached
        }
        let request = portDiscovery.beginScan()
        publishPortDiscovery()
        let scan: CloudPortScanResult?
        if let arguments = CloudTuiRequests.listeningPortsArguments(socketPath: socketPath),
           let data = try? await link.run(arguments: arguments),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let stdout = object["stdout"] as? String {
            scan = Self.portScan(from: VMExecResult(exitCode: 0, stdout: stdout, stderr: ""))
        } else {
            scan = nil
        }
        guard !Task.isCancelled, generation == refreshGeneration, isRegisteredInCatalog(),
              portDiscovery.complete(scan, request: request, at: Date.now, socketPath: socketPath) else { return nil }
        publishPortDiscovery()
        return scan
    }
}

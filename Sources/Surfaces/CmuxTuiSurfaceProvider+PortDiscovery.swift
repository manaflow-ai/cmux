import CmuxCloud
import CmuxSurfaceCatalogModel
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

import Foundation

/// Supplies a machine's shared cmux-tui carrier independently of its hosting provider.
protocol RemoteTuiLinkManaging: Sendable {
    var operations: CloudOperationRecorder? { get }
    func connected(machineID: String) async throws -> CloudMachineLink.Connected
    func link(machineID: String) async -> CloudMachineLink?
    func status(machineID: String) async -> CloudMachineLinkManager.LinkStatus?
    func privateAddresses(for machineID: String) async -> [String]
    func browserProxy(machineID: String) async throws -> CloudBrowserProxyEndpoint
}

extension CloudMachineLinkManager: RemoteTuiLinkManaging {}

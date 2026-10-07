import CmuxCloud
import Foundation

/// Supplies a machine's shared cmux-tui carrier independently of its hosting provider.
protocol RemoteTuiLinkManaging: Sendable {
    var operations: CloudOperationRecorder? { get }
    func connected(machineID: String) async throws -> CloudMachineLink.Connected
    func link(machineID: String) async -> CloudMachineLink?
    func status(machineID: String) async -> CloudMachineLinkManager.LinkStatus?
    func privateAddresses(for machineID: String) async -> [String]
    func setPrivateAddresses(_ addresses: [String], for machineID: String) async
    func browserProxy(machineID: String) async throws -> CloudBrowserProxyEndpoint
    func loopbackForward(machineID: String, target: CloudPortForwardTarget) async throws -> UInt16
    func closeLoopbackForward(machineID: String, target: CloudPortForwardTarget) async
}

extension CloudMachineLinkManager: RemoteTuiLinkManaging {}

extension RemoteTuiLinkManaging {
    func loopbackForward(machineID: String, target: CloudPortForwardTarget) async throws -> UInt16 {
        throw CancellationError()
    }

    func closeLoopbackForward(machineID: String, target: CloudPortForwardTarget) async {}
}

import CmuxIrxTransport
import Foundation

/// Borrowed connectivity resources for one authenticated Mac runtime generation.
struct DeviceIrxClientContext: Sendable {
    let broker: IrxBrokerService
    let supervisor: IrxEndpointSupervisor
    let relayCredentials: IrxRelayCredentialAutopilot
    let deviceList: IrxDeviceListCurrent
    let localBinding: IrxBindingSnapshot
    let allowsDirectPaths: Bool
    let isCurrent: @Sendable () async -> Bool
}

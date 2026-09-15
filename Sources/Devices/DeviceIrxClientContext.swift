import CmuxIrxTransport
import Foundation

/// Borrowed connectivity resources for one authenticated Mac runtime generation.
struct DeviceIrxClientContext: Sendable {
    let control: V2ControlService
    let supervisor: IrxEndpointSupervisor
    let localDevice: V2DeviceRecord
    let allowsDirectPaths: Bool
    let isCurrent: @Sendable () async -> Bool
}

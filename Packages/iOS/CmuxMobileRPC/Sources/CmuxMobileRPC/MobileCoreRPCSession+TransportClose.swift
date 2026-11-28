import CMUXMobileCore
import Foundation

// MobileCoreRPCSession's transport close: closing an installed transport once and tracking
// the close tasks.
extension MobileCoreRPCSession {
    func tearDownIfInstalled(
        connectionID: UUID,
        error: MobileShellConnectionError
    ) async {
        guard installedConnectionID == connectionID else { return }
        await tearDown(error: error)
    }

    func transportDidClose(connectionID: UUID) async {
        guard installedConnectionID == connectionID else { return }
        await tearDown(error: .connectionClosed)
    }

    /// Detaches one installed transport close from session request handling and
    /// transfers its exact task to the shared physical-resource registry.
    func enqueueTransportClose(
        _ transport: any CmxByteTransport,
        lease: MobileRPCConnectAttemptLease?
    ) async {
        let taskID = UUID()
        let closeTask = Task.detached { [weak self] in
            await transport.close()
            await self?.transportCloseDidFinish(taskID: taskID)
        }
        transportCloseTasks[taskID] = closeTask
        await connectAttemptRegistry.handOffPhysicalCleanup(
            lease: lease
        ) {
            await closeTask.value
        }
    }

    private func transportCloseDidFinish(taskID: UUID) {
        transportCloseTasks[taskID] = nil
    }
}

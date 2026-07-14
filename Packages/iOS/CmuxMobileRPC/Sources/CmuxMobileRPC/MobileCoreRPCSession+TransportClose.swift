internal import CMUXMobileCore
import Foundation

extension MobileCoreRPCSession {
    /// Serializes detached transport cleanup without letting a non-cooperative
    /// `close()` callback block session recovery or create unbounded tasks.
    /// While one close is active, only the newest replacement is retained.
    func enqueueTransportClose(_ transport: any CmxByteTransport) {
        guard transportCloseTask == nil else {
            pendingTransportClose = transport
            return
        }

        let taskID = UUID()
        transportCloseTaskID = taskID
        transportCloseTask = Task.detached { [weak self] in
            await transport.close()
            await self?.transportCloseDidFinish(taskID: taskID)
        }
    }

    private func transportCloseDidFinish(taskID: UUID) {
        guard transportCloseTaskID == taskID else { return }
        transportCloseTask = nil
        transportCloseTaskID = nil
        guard let pendingTransportClose else { return }
        self.pendingTransportClose = nil
        enqueueTransportClose(pendingTransportClose)
    }
}

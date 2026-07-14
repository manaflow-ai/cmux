internal import CMUXMobileCore
import Foundation

extension MobileCoreRPCSession {
    /// Serializes detached transport cleanup without letting a non-cooperative
    /// `close()` callback block session recovery or create unbounded tasks.
    /// Connection creation is backpressured while the one pending slot is full,
    /// so every detached transport reaches `close()` without unbounded growth.
    func enqueueTransportClose(_ transport: any CmxByteTransport) {
        guard transportCloseTask == nil else {
            pendingTransportCloses.append(transport)
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
        guard !pendingTransportCloses.isEmpty else { return }
        let nextTransport = pendingTransportCloses.removeFirst()
        enqueueTransportClose(nextTransport)
    }
}

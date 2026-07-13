internal import CMUXMobileCore
import Foundation

extension MobileCoreRPCSession {
    func writeLoop(
        transport: any CmxByteTransport,
        connectionID: UUID,
        frames: AsyncStream<PendingWrite>
    ) async {
        for await write in frames {
            if Task.isCancelled { return }
            guard shouldSendQueuedWrite(write) else { continue }

            let sendTask = Task {
                try await transport.send(write.frame)
            }
            activeWrite = (connectionID, write.requestID, sendTask)
            do {
                try await sendTask.value
                clearActiveWrite(
                    connectionID: connectionID,
                    requestID: write.requestID
                )
            } catch {
                clearActiveWrite(
                    connectionID: connectionID,
                    requestID: write.requestID
                )
                await tearDownIfInstalled(
                    connectionID: connectionID,
                    error: .connectionClosed
                )
                return
            }
        }
    }

    private func clearActiveWrite(connectionID: UUID, requestID: String) {
        guard activeWrite?.connectionID == connectionID,
              activeWrite?.requestID == requestID else { return }
        activeWrite = nil
    }

    func tearDownIfInstalled(
        connectionID: UUID,
        error: MobileShellConnectionError
    ) async {
        guard installedConnectionID == connectionID else { return }
        await tearDown(error: error)
    }
}

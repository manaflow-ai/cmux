import Foundation

extension V2ControlService {
    func acknowledge(_ receipt: V2DeliveryReceipt, run: UUID, connection: UUID, socket: any V2ControlSocket) {
        if receipt.sequence > (pendingReceipt?.sequence ?? -1) { pendingReceipt = receipt }
        guard acknowledgementTask == nil else { return }
        let owner = UUID()
        acknowledgementTaskID = owner
        acknowledgementTask = Task { [weak self] in
            await self?.sendAcknowledgements(run: run, connection: connection, owner: owner, socket: socket)
        }
    }

    private func sendAcknowledgements(run: UUID, connection: UUID, owner: UUID, socket: any V2ControlSocket) async {
        defer {
            if acknowledgementTaskID == owner {
                acknowledgementTask = nil
                acknowledgementTaskID = nil
            }
        }
        while runID == run, socketID == connection, !Task.isCancelled, let receipt = pendingReceipt {
            pendingReceipt = nil
            let request = V2AcknowledgementRequest(requestID: UUID().uuidString.lowercased(), schemaID: .sessionACKV1, sequence: receipt.sequence, token: receipt.token)
            do { try await socket.send(codec.encode(request)) }
            catch {
                await socketFailed(error, run: run, connection: connection)
                return
            }
        }
    }
}

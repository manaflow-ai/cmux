internal import CmuxRemoteDaemon
internal import Foundation

extension RemotePTYBridgeServer.Session {
    fileprivate typealias InputWrite = RemotePTYBridgeInputFlow.Write

    func forwardInput(_ data: Data) {
        guard !data.isEmpty else { return }
        guard let remoteAttachment else {
            close(detach: true)
            return
        }
        guard let drain = inputFlow.enqueue(data) else {
            close(detach: true)
            return
        }
        sendInputWrites(drain.writes, remoteAttachment: remoteAttachment)
    }

    func handleInputAck(seq: UInt64) {
        guard let drain = inputFlow.acknowledge(upTo: seq) else {
            close(detach: true)
            return
        }
        drainInputFlow(drain)
    }

    private func sendInputWrites(
        _ writes: [InputWrite],
        remoteAttachment: RemotePTYBridgeAttachment
    ) {
        for write in writes {
            sendInputWrite(write, remoteAttachment: remoteAttachment)
        }
    }

    private func sendInputWrite(
        _ write: InputWrite,
        remoteAttachment: RemotePTYBridgeAttachment
    ) {
        let currentSessionID = sessionID
        rpcQueue.async { [weak self, write, remoteAttachment] in
            guard let self else { return }
            let shouldWrite = self.queue.sync { !self.isClosed }
            guard shouldWrite else {
                self.queue.async {
                    self.handleInputWriteFinished(write: write, error: nil)
                }
                return
            }
            self.rpcClient.writePTY(
                sessionID: currentSessionID,
                attachmentID: remoteAttachment.attachmentID,
                attachmentToken: remoteAttachment.token,
                data: write.data,
                seq: write.seq
            ) { [weak self] writeError in
                guard let self else { return }
                self.queue.async {
                    self.handleInputWriteFinished(write: write, error: writeError)
                }
            }
        }
    }

    private func handleInputWriteFinished(write: InputWrite, error: (any Error)?) {
        guard let drain = inputFlow.complete(write, error: error) else {
            close(detach: true)
            return
        }
        drainInputFlow(drain)
    }

    private func drainInputFlow(_ drain: RemotePTYBridgeInputFlow.DrainResult) {
        if let remoteAttachment {
            sendInputWrites(drain.writes, remoteAttachment: remoteAttachment)
        }
        if drain.shouldResumeReads, !clientInputDidComplete {
            receiveNext()
        }
    }
}

internal import Foundation

extension RemoteDaemonRPCClient {
    func sendPTYAttachCancellation(
        requestID: Int,
        attachParams: [String: Any]
    ) {
        var cancellationParams: [String: Any] = ["request_id": requestID]
        for key in ["session_id", "attachment_id", "client_attachment_token"] {
            if let value = attachParams[key] as? String {
                cancellationParams[key] = value
            }
        }
        guard let payload = try? Self.encodeJSON([
            "method": "pty.attach.cancel",
            "params": cancellationParams,
        ]) else {
            stop(suppressTerminationCallback: false)
            return
        }

        // The attach deadline has already expired, so cancellation must not
        // make that synchronous caller wait on a congested transport writer.
        // If the queued write cannot finish promptly, the transport is no
        // longer safe to preserve and the established stop path takes over.
        let writeFinished = DispatchSemaphore(value: 0)
        writeQueue.async { [weak self] in
            defer { writeFinished.signal() }
            guard let self else { return }
            try? self.writePayload(payload)
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + Self.ptyAttachCancellationWriteTimeout
        ) { [weak self] in
            guard writeFinished.wait(timeout: .now()) == .timedOut else { return }
            self?.stop(suppressTerminationCallback: false)
        }
    }
}

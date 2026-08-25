internal import Foundation
internal import CmuxFoundation

/// Owns the cancellation deadline's dispatch source across callback queues.
///
/// `DispatchSourceTimer` supports concurrent, idempotent cancellation, but
/// Xcode 16 does not declare it `Sendable`. This wrapper is the explicit
/// concurrency boundary shared by the timer callback and transport writer.
private final class PTYAttachCancellationTimer: @unchecked Sendable {
    private let source: any DispatchSourceTimer

    init(
        deadline: DispatchTime,
        queue: DispatchQueue,
        handler: @escaping @Sendable () -> Void
    ) {
        source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: deadline)
        source.setEventHandler(handler: handler)
        source.activate()
    }

    deinit {
        source.cancel()
    }

    func cancel() {
        source.cancel()
    }
}

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
        // The timer callback and write completion race to settle this one
        // deadline; a lock-free gate avoids shared mutable lifecycle state.
        let deadlineSettled = AtomicBooleanGate(false)
        // A one-shot DispatchSource is required here because this legacy
        // synchronous client has no async task in which to host the deadline.
        let timeoutTimer = PTYAttachCancellationTimer(
            deadline: .now() + Self.ptyAttachCancellationWriteTimeout,
            queue: ptyAttachCancellationTimerQueue
        ) { [weak self] in
            guard deadlineSettled.compareExchange(expected: false, desired: true) else { return }
            self?.stop(suppressTerminationCallback: false)
        }
        writeQueue.async { [weak self] in
            defer {
                _ = deadlineSettled.compareExchange(expected: false, desired: true)
                timeoutTimer.cancel()
            }
            guard let self else { return }
            try? self.writePayload(payload)
        }
    }
}

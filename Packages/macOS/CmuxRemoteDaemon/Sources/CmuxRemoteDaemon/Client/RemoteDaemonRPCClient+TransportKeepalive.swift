internal import Foundation

// Timer-backed keepalive for non-websocket daemon transports. WebSocket uses
// URLSession's ping path in RemoteDaemonRPCClient+Events.swift.
extension RemoteDaemonRPCClient {
    func startTransportKeepalive() {
        stateQueue.sync {
            guard configuration.transport != .websocket else { return }
            startTransportKeepaliveLocked()
        }
    }

    func startTransportKeepaliveLocked() {
        stopTransportKeepaliveLocked()
        lastInboundFrameAt = .now()
        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        timer.schedule(deadline: .now() + keepaliveInterval, repeating: keepaliveInterval)
        timer.setEventHandler { [weak self] in
            self?.sendTransportKeepaliveLocked()
        }
        transportKeepaliveTimer = timer
        timer.resume()
    }

    func stopTransportKeepaliveLocked() {
        transportKeepaliveTimer?.cancel()
        transportKeepaliveTimer = nil
        transportKeepaliveTimeoutWorkItem?.cancel()
        transportKeepaliveTimeoutWorkItem = nil
        transportKeepaliveInFlight = false
    }

    func sendTransportKeepaliveLocked() {
        guard !isClosed, webSocketTask == nil else {
            stopTransportKeepaliveLocked()
            return
        }
        let now = DispatchTime.now()
        let elapsed = Double(now.uptimeNanoseconds - lastInboundFrameAt.uptimeNanoseconds) / 1_000_000_000
        guard elapsed >= keepaliveInterval else { return }
        guard !transportKeepaliveInFlight else { return }

        transportKeepaliveInFlight = true
        let timeoutWorkItem = DispatchWorkItem { [weak self] in
            guard let self, !self.isClosed, self.transportKeepaliveInFlight else { return }
            self.handleTransportKeepaliveFailureLocked("daemon transport keepalive timed out")
        }
        transportKeepaliveTimeoutWorkItem?.cancel()
        transportKeepaliveTimeoutWorkItem = timeoutWorkItem
        stateQueue.asyncAfter(deadline: .now() + keepaliveTimeout, execute: timeoutWorkItem)

        // The blocking probe runs off stateQueue. If the watchdog above fires
        // first, handleTransportKeepaliveFailureLocked closes the transport
        // handles, which makes this in-flight call fail shortly afterwards;
        // its late completion lands on stateQueue behind the teardown and is
        // dropped by the isClosed guards below. The keepalive queue thread is
        // expected to drain on its own that way — nothing waits on it, and it
        // must not acquire resources beyond the call itself.
        transportKeepaliveQueue.async { [weak self] in
            guard let self else { return }
            do {
                _ = try self.call(method: "hello", params: [:], timeout: self.keepaliveTimeout)
            } catch {
                self.stateQueue.async {
                    guard !self.isClosed else { return }
                    self.handleTransportKeepaliveFailureLocked("daemon transport keepalive failed: \(error.localizedDescription)")
                }
                return
            }
            self.stateQueue.async {
                guard !self.isClosed else { return }
                self.transportKeepaliveTimeoutWorkItem?.cancel()
                self.transportKeepaliveTimeoutWorkItem = nil
                self.transportKeepaliveInFlight = false
            }
        }
    }

    func handleTransportKeepaliveFailureLocked(_ detail: String) {
        let shouldNotify = !isClosed && shouldReportTermination
        let capturedProcess = process
        let capturedStdin = stdinHandle
        let capturedStdout = stdoutHandle
        let capturedStderr = stderrHandle

        isClosed = true
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
        stdinHandle = nil
        stdoutHandle = nil
        stderrHandle = nil
        streamSubscriptions.removeAll(keepingCapacity: false)
        failPTYSubscriptionsLocked(detail)
        signalPendingFailureLocked(detail)
        stopWebSocketKeepaliveLocked()
        stopTransportKeepaliveLocked()

        capturedStdout?.readabilityHandler = nil
        capturedStderr?.readabilityHandler = nil
        try? capturedStdin?.close()
        try? capturedStdout?.close()
        try? capturedStderr?.close()
        if let capturedProcess, capturedProcess.isRunning {
            capturedProcess.terminate()
        }

        guard shouldNotify else { return }
        onUnexpectedTermination(detail)
    }
}

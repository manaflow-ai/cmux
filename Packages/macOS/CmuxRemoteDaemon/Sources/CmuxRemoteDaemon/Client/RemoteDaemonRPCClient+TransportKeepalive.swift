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
        transportKeepaliveQueue.async { [weak self] in
            guard let self else { return }
            do {
                let response = try self.callIfIdle(
                    method: "hello",
                    params: [:],
                    timeout: self.keepaliveTimeout
                ) {
                    self.armTransportKeepaliveTimeout()
                }
                guard response != nil else {
                    self.stateQueue.async {
                        guard !self.isClosed else { return }
                        self.finishTransportKeepaliveLocked()
                    }
                    return
                }
            } catch {
                self.stateQueue.async {
                    guard !self.isClosed else { return }
                    self.handleTransportKeepaliveFailureLocked("daemon transport keepalive failed: \(error.localizedDescription)")
                }
                return
            }
            self.stateQueue.async {
                guard !self.isClosed else { return }
                self.finishTransportKeepaliveLocked()
            }
        }
    }

    /// Arms the watchdog only after the probe has atomically reserved an idle
    /// write slot. A busy transport therefore remains governed by the timeout
    /// of its real RPC instead of a competing heartbeat deadline.
    func armTransportKeepaliveTimeout() {
        stateQueue.sync {
            guard !isClosed, transportKeepaliveInFlight else { return }
            let timeoutWorkItem = DispatchWorkItem { [weak self] in
                guard let self, !self.isClosed, self.transportKeepaliveInFlight else { return }
                self.handleTransportKeepaliveFailureLocked("daemon transport keepalive timed out")
            }
            transportKeepaliveTimeoutWorkItem?.cancel()
            transportKeepaliveTimeoutWorkItem = timeoutWorkItem
            stateQueue.asyncAfter(deadline: .now() + keepaliveTimeout, execute: timeoutWorkItem)
        }
    }

    func finishTransportKeepaliveLocked() {
        transportKeepaliveTimeoutWorkItem?.cancel()
        transportKeepaliveTimeoutWorkItem = nil
        transportKeepaliveInFlight = false
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

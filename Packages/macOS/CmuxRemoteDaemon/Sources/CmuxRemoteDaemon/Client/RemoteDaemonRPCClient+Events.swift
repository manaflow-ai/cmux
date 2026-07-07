internal import Foundation

// Inbound frame handling: stdout/websocket framing, response routing into the
// pending-call registry, push-event fan-out to stream/PTY subscriptions, and
// transport-termination cleanup. Everything in this file runs on stateQueue
// (the `Locked` suffix and the dispatch in the transport callbacks enforce
// it). Framing is wire-pinned: one JSON object per `\n`-terminated line, an
// optional trailing `\r` stripped, 256 KiB buffer cap.
extension RemoteDaemonRPCClient {
    func consumeStdoutData(_ data: Data) {
        guard !data.isEmpty else {
            signalPendingFailureLocked("daemon transport closed stdout")
            return
        }

        func failOversizedBuffer(_ detail: String) {
            stdoutBuffer.removeAll(keepingCapacity: false)
            signalPendingFailureLocked(detail)
            process?.terminate()
        }

        stdoutBuffer.append(data)
        while let newlineIndex = stdoutBuffer.firstIndex(of: 0x0A) {
            guard newlineIndex <= Self.maxStdoutBufferBytes else {
                failOversizedBuffer("daemon transport stdout frame exceeded \(Self.maxStdoutBufferBytes) bytes")
                return
            }
            var lineData = Data(stdoutBuffer[..<newlineIndex])
            stdoutBuffer.removeSubrange(...newlineIndex)

            if let carriageIndex = lineData.lastIndex(of: 0x0D), carriageIndex == lineData.index(before: lineData.endIndex) {
                lineData.remove(at: carriageIndex)
            }
            guard !lineData.isEmpty else { continue }
            consumeJSONPayload(lineData)
        }
        if stdoutBuffer.count > Self.maxStdoutBufferBytes {
            failOversizedBuffer("daemon transport stdout exceeded \(Self.maxStdoutBufferBytes) bytes without message framing")
        }
    }

    func receiveNextWebSocketMessageLocked() {
        guard let task = webSocketTask, let delegate = webSocketDelegate else { return }
        task.receive { [weak self] result in
            guard let self else { return }
            self.stateQueue.async {
                switch result {
                case .success(let message):
                    switch message {
                    case .string(let text):
                        self.consumeJSONPayload(Data(text.utf8))
                    case .data(let data):
                        self.consumeJSONPayload(data)
                    @unknown default:
                        break
                    }
                    if !self.isClosed {
                        self.receiveNextWebSocketMessageLocked()
                    }
                case .failure(let error):
                    if delegate.isClosed || self.isClosed {
                        self.handleWebSocketTermination("daemon websocket closed")
                    } else {
                        self.handleWebSocketTermination("daemon websocket failed: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    func startWebSocketKeepaliveLocked() {
        webSocketKeepaliveTimer?.cancel()
        webSocketKeepaliveTimeoutWorkItem?.cancel()
        webSocketKeepaliveTimeoutWorkItem = nil
        webSocketKeepaliveInFlight = false
        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        timer.schedule(
            deadline: .now() + Self.webSocketKeepaliveInterval,
            repeating: Self.webSocketKeepaliveInterval
        )
        timer.setEventHandler { [weak self] in
            self?.sendWebSocketKeepaliveLocked()
        }
        webSocketKeepaliveTimer = timer
        timer.resume()
    }

    func stopWebSocketKeepaliveLocked() {
        webSocketKeepaliveTimer?.cancel()
        webSocketKeepaliveTimer = nil
        webSocketKeepaliveTimeoutWorkItem?.cancel()
        webSocketKeepaliveTimeoutWorkItem = nil
        webSocketKeepaliveInFlight = false
    }

    func sendWebSocketKeepaliveLocked() {
        guard !isClosed, let task = webSocketTask else {
            stopWebSocketKeepaliveLocked()
            return
        }
        if webSocketKeepaliveInFlight {
            return
        }

        webSocketKeepaliveInFlight = true
        let timeoutWorkItem = DispatchWorkItem { [weak self] in
            guard let self, !self.isClosed, self.webSocketKeepaliveInFlight else { return }
            self.handleWebSocketTermination("daemon websocket keepalive timed out")
        }
        webSocketKeepaliveTimeoutWorkItem?.cancel()
        webSocketKeepaliveTimeoutWorkItem = timeoutWorkItem
        stateQueue.asyncAfter(deadline: .now() + Self.webSocketKeepaliveInterval, execute: timeoutWorkItem)
        task.sendPing { [weak self] error in
            guard let self else { return }
            self.stateQueue.async {
                guard !self.isClosed else { return }
                self.webSocketKeepaliveTimeoutWorkItem?.cancel()
                self.webSocketKeepaliveTimeoutWorkItem = nil
                self.webSocketKeepaliveInFlight = false
                if let error {
                    self.handleWebSocketTermination("daemon websocket keepalive failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func consumeJSONPayload(_ data: Data) {
        guard let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            return
        }
        lastInboundFrameAt = .now()
        if let responseID = Self.responseID(in: payload) {
            _ = pendingCalls.resolve(id: responseID, payload: payload)
            return
        }
        consumeEventPayload(payload)
    }

    func consumeStderrData(_ data: Data) {
        guard !data.isEmpty else { return }
        guard let chunk = String(data: data, encoding: .utf8), !chunk.isEmpty else { return }
        stderrBuffer.append(chunk)
        if stderrBuffer.count > 8192 {
            stderrBuffer.removeFirst(stderrBuffer.count - 8192)
        }
    }

    func consumeEventPayload(_ payload: [String: Any]) {
        if consumeCLIRequestPayload(payload) {
            return
        }
        if consumePTYEventPayload(payload) {
            return
        }

        guard let eventName = (payload["event"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !eventName.isEmpty,
              let streamID = (payload["stream_id"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !streamID.isEmpty else {
            return
        }

        let subscription: StreamSubscription?
        let event: RemoteDaemonStreamEvent?
        switch eventName {
        case "proxy.stream.data":
            subscription = streamSubscriptions[streamID]
            event = .data(Self.decodeBase64Data(payload["data_base64"]))

        case "proxy.stream.eof":
            subscription = streamSubscriptions.removeValue(forKey: streamID)
            event = .eof(Self.decodeBase64Data(payload["data_base64"]))

        case "proxy.stream.error":
            subscription = streamSubscriptions.removeValue(forKey: streamID)
            let detail = ((payload["error"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
                ?? "stream error"
            event = .error(detail)

        default:
            return
        }

        guard let subscription, let event else { return }
        subscription.queue.async {
            subscription.handler(event)
        }
    }

    func consumeCLIRequestPayload(_ payload: [String: Any]) -> Bool {
        guard let eventName = (payload["event"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              eventName == "cli.request" else {
            return false
        }
        guard let requestID = (payload["request_id"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !requestID.isEmpty else {
            return true
        }
        guard let cliRequestHandler else {
            sendCLIResponseAsync(requestID: requestID, data: nil, error: "cloud CLI bridge is not configured")
            return true
        }
        guard cliRequestsInFlight < Self.maxCloudCLIRequestsInFlight else {
            sendCLIResponseAsync(requestID: requestID, data: nil, error: "cloud CLI bridge is busy")
            return true
        }
        cliRequestsInFlight += 1
        let request = Self.decodeBase64Data(payload["data_base64"])
        cliRequestQueue.async { [weak self] in
            guard let self else { return }
            defer {
                self.stateQueue.async { [weak self] in
                    guard let self else { return }
                    self.cliRequestsInFlight = max(0, self.cliRequestsInFlight - 1)
                }
            }
            do {
                self.sendCLIResponse(requestID: requestID, data: try cliRequestHandler(request), error: nil)
            } catch {
                self.sendCLIResponse(requestID: requestID, data: nil, error: error.localizedDescription)
            }
        }
        return true
    }

    private func sendCLIResponseAsync(requestID: String, data: Data?, error: String?) {
        cliRequestQueue.async { [weak self] in
            self?.sendCLIResponse(requestID: requestID, data: data, error: error)
        }
    }

    func consumePTYEventPayload(_ payload: [String: Any]) -> Bool {
        guard let eventName = (payload["event"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              eventName.hasPrefix("pty."),
              let sessionID = (payload["session_id"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionID.isEmpty,
              let attachmentID = (payload["attachment_id"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !attachmentID.isEmpty else {
            return false
        }

        let attachmentToken = (payload["attachment_token"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let key = Self.ptySubscriptionKey(
            sessionID: sessionID,
            attachmentID: attachmentID,
            attachmentToken: attachmentToken
        )
        let legacyKey = Self.ptySubscriptionKey(sessionID: sessionID, attachmentID: attachmentID)
        let subscription: PTYSubscription?
        let event: RemoteDaemonPTYEvent?
        switch eventName {
        case "pty.ready":
            subscription = ptySubscriptions[key] ?? ptySubscriptions[legacyKey]
            event = .ready

        case "pty.data":
            subscription = ptySubscriptions[key] ?? ptySubscriptions[legacyKey]
            event = .data(Self.decodeBase64Data(payload["data_base64"]))

        case "pty.exit":
            subscription = ptySubscriptions.removeValue(forKey: key)
                ?? ptySubscriptions.removeValue(forKey: legacyKey)
            event = .exit

        case "pty.error":
            subscription = ptySubscriptions.removeValue(forKey: key)
                ?? ptySubscriptions.removeValue(forKey: legacyKey)
            let detail = ((payload["error"] as? String) ?? (payload["message"] as? String))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            event = .error(detail?.isEmpty == false ? detail! : "PTY error")

        default:
            return true
        }

        guard let subscription, let event else { return true }
        subscription.queue.async {
            subscription.handler(event)
        }
        return true
    }

    func sendCLIResponse(requestID: String, data: Data?, error: String?) {
        var params: [String: Any] = ["request_id": requestID]
        if let data {
            params["ok"] = true
            params["data_base64"] = data.base64EncodedString()
        } else {
            params["ok"] = false
            params["error"] = error ?? "cmux app rejected cloud CLI request"
        }
        do {
            _ = try call(method: "cli.response", params: params, timeout: 4.0)
        } catch {
            // The originating terminal command will time out and show the
            // daemon-side failure. There is no local UI surface to report here.
        }
    }

    func handleProcessTermination(_ process: Process) {
        let shouldNotify: Bool = {
            guard self.process === process else { return false }
            return !isClosed && shouldReportTermination
        }()
        let detail = Self.bestErrorLine(stderr: stderrBuffer) ?? "daemon transport exited with status \(process.terminationStatus)"

        isClosed = true
        self.process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
        stdinHandle = nil
        stdoutHandle?.readabilityHandler = nil
        stdoutHandle = nil
        stderrHandle?.readabilityHandler = nil
        stderrHandle = nil
        streamSubscriptions.removeAll(keepingCapacity: false)
        failPTYSubscriptionsLocked(detail)
        signalPendingFailureLocked(detail)

        guard shouldNotify else { return }
        onUnexpectedTermination(detail)
    }

    func handleWebSocketTermination(_ detail: String) {
        let shouldNotify = !isClosed && shouldReportTermination
        let capturedTask = webSocketTask
        let capturedSession = webSocketSession

        isClosed = true
        stopWebSocketKeepaliveLocked()
        webSocketTask = nil
        webSocketSession = nil
        webSocketDelegate = nil
        streamSubscriptions.removeAll(keepingCapacity: false)
        failPTYSubscriptionsLocked(detail)
        signalPendingFailureLocked(detail)
        capturedTask?.cancel(with: .normalClosure, reason: nil)
        capturedSession?.invalidateAndCancel()

        guard shouldNotify else { return }
        onUnexpectedTermination(detail)
    }

    static func responseID(in payload: [String: Any]) -> Int? {
        if let intValue = payload["id"] as? Int {
            return intValue
        }
        if let numberValue = payload["id"] as? NSNumber {
            return numberValue.intValue
        }
        return nil
    }

    static func decodeBase64Data(_ value: Any?) -> Data {
        guard let encoded = value as? String, !encoded.isEmpty else { return Data() }
        return Data(base64Encoded: encoded) ?? Data()
    }

    static func ptySubscriptionKey(
        sessionID: String,
        attachmentID: String,
        attachmentToken: String? = nil
    ) -> String {
        let token = attachmentToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return [
            sessionID.trimmingCharacters(in: .whitespacesAndNewlines),
            attachmentID.trimmingCharacters(in: .whitespacesAndNewlines),
            token,
        ].joined(separator: "\u{1f}")
    }
}

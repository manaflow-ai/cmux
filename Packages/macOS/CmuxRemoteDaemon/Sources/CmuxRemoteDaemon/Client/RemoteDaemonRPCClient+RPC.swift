public import Foundation

// Hands a write completion's error across the @Sendable URLSession completion
// boundary to the thread blocked on `semaphore`; the signal->wait pair is the
// happens-before edge (legacy used a captured local var, which Swift 6
// rejects in a @Sendable closure).
private final class RemoteDaemonSendErrorBox: @unchecked Sendable {
    var error: (any Error)?
}

// The synchronous RPC surface (proxy streams + PTY sessions) and the JSON
// request plumbing. Method names, payload keys, timeouts, and NSError
// domains/codes/messages are wire-pinned; do not change them.
extension RemoteDaemonRPCClient {
    /// Opens a daemon-side TCP stream to `host:port` (`proxy.open`) and
    /// returns its stream id.
    public func openStream(host: String, port: Int, timeoutMs: Int = 10000) throws -> String {
        let result = try call(
            method: "proxy.open",
            params: [
                "host": host,
                "port": port,
                "timeout_ms": timeoutMs,
            ],
            timeout: 12.0
        )
        let streamID = (result["stream_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !streamID.isEmpty else {
            throw NSError(domain: "cmux.remote.daemon.rpc", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "proxy.open missing stream_id",
            ])
        }
        return streamID
    }

    /// Writes bytes to an open stream (`proxy.write`).
    public func writeStream(streamID: String, data: Data) throws {
        _ = try call(
            method: "proxy.write",
            params: [
                "stream_id": streamID,
                "data_base64": data.base64EncodedString(),
            ],
            timeout: 8.0
        )
    }

    /// Subscribes to a stream's push events (`proxy.stream.subscribe`);
    /// `onEvent` is delivered on `queue`. The subscription is unregistered if
    /// the subscribe call fails.
    public func attachStream(
        streamID: String,
        queue: DispatchQueue,
        onEvent: @escaping (RemoteDaemonStreamEvent) -> Void
    ) throws {
        let trimmedStreamID = streamID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedStreamID.isEmpty else {
            throw NSError(domain: "cmux.remote.daemon.rpc", code: 17, userInfo: [
                NSLocalizedDescriptionKey: "proxy.stream.subscribe requires stream_id",
            ])
        }

        stateQueue.sync {
            streamSubscriptions[trimmedStreamID] = StreamSubscription(queue: queue, handler: onEvent)
        }

        do {
            _ = try call(
                method: "proxy.stream.subscribe",
                params: ["stream_id": trimmedStreamID],
                timeout: 8.0
            )
        } catch {
            unregisterStream(streamID: trimmedStreamID)
            throw error
        }
    }

    /// Drops a local stream subscription without telling the daemon.
    public func unregisterStream(streamID: String) {
        let trimmedStreamID = streamID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedStreamID.isEmpty else { return }
        _ = stateQueue.sync {
            streamSubscriptions.removeValue(forKey: trimmedStreamID)
        }
    }

    /// Unsubscribes locally, then best-effort closes the stream daemon-side
    /// (`proxy.close`).
    public func closeStream(streamID: String) {
        unregisterStream(streamID: streamID)
        _ = try? call(
            method: "proxy.close",
            params: ["stream_id": streamID],
            timeout: 4.0
        )
    }

    /// Attaches to (or creates) a remote PTY session (`pty.attach`),
    /// streaming events to `onEvent` on `queue`, and returns the attachment
    /// identity the daemon echoed back.
    public func attachPTY(
        sessionID: String,
        attachmentID: String,
        cols: Int,
        rows: Int,
        command: String?,
        requireExisting: Bool,
        inputSeqAck: Bool = false,
        queue: DispatchQueue,
        onEvent: @escaping (RemoteDaemonPTYEvent) -> Void
    ) throws -> RemotePTYBridgeAttachment {
        let trimmedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAttachmentID = attachmentID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSessionID.isEmpty else {
            throw NSError(domain: "cmux.remote.daemon.rpc", code: 28, userInfo: [
                NSLocalizedDescriptionKey: "pty.attach requires session_id",
            ])
        }
        guard !trimmedAttachmentID.isEmpty else {
            throw NSError(domain: "cmux.remote.daemon.rpc", code: 29, userInfo: [
                NSLocalizedDescriptionKey: "pty.attach requires attachment_id",
            ])
        }

        let clientAttachmentToken = UUID().uuidString.lowercased()
        let key = Self.ptySubscriptionKey(
            sessionID: trimmedSessionID,
            attachmentID: trimmedAttachmentID,
            attachmentToken: clientAttachmentToken
        )
        stateQueue.sync {
            ptySubscriptions[key] = PTYSubscription(queue: queue, handler: onEvent)
        }

        var params: [String: Any] = [
            "session_id": trimmedSessionID,
            "attachment_id": trimmedAttachmentID,
            "client_attachment_token": clientAttachmentToken,
            "cols": max(1, cols),
            "rows": max(1, rows),
        ]
        if let command = command?.trimmingCharacters(in: .whitespacesAndNewlines),
           !command.isEmpty {
            params["command"] = command
        }
        if requireExisting {
            params["require_existing"] = true
        }
        if inputSeqAck {
            params["input_seq_ack"] = true
        }

        do {
            let result = try call(method: "pty.attach", params: params, timeout: 12.0)
            let returnedAttachmentID = (result["attachment_id"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                ?? trimmedAttachmentID
            let returnedToken = (result["attachment_token"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                ?? clientAttachmentToken
            return RemotePTYBridgeAttachment(
                attachmentID: returnedAttachmentID,
                token: returnedToken
            )
        } catch {
            unregisterPTY(
                sessionID: trimmedSessionID,
                attachmentID: trimmedAttachmentID,
                attachmentToken: clientAttachmentToken
            )
            throw error
        }
    }

    /// Sends input bytes to an attachment as a `pty.write` notification;
    /// `completion` is invoked synchronously with the write error or `nil`.
    public func writePTY(
        sessionID: String,
        attachmentID: String,
        attachmentToken: String,
        data: Data,
        seq: UInt64? = nil,
        completion: @escaping ((any Error)?) -> Void
    ) {
        var params: [String: Any] = [
            "session_id": sessionID,
            "attachment_id": attachmentID,
            "client_attachment_token": attachmentToken,
            "data_base64": data.base64EncodedString(),
        ]
        if let seq {
            params["seq"] = seq
        }
        do {
            try notify(
                method: "pty.write",
                params: params
            )
            completion(nil)
        } catch {
            completion(error)
        }
    }

    /// Sends a best-effort resize notification (`pty.resize`); cols/rows clamp to >= 1.
    public func resizePTY(sessionID: String, attachmentID: String, attachmentToken: String, cols: Int, rows: Int) throws {
        try notify(
            method: "pty.resize",
            params: [
                "session_id": sessionID,
                "attachment_id": attachmentID,
                "client_attachment_token": attachmentToken,
                "cols": max(1, cols),
                "rows": max(1, rows),
            ]
        )
    }

    /// Unregisters the local subscription, then detaches daemon-side
    /// (`pty.detach`), throwing on failure.
    public func detachPTYChecked(sessionID: String, attachmentID: String, attachmentToken: String) throws {
        unregisterPTY(sessionID: sessionID, attachmentID: attachmentID, attachmentToken: attachmentToken)
        _ = try call(
            method: "pty.detach",
            params: [
                "session_id": sessionID,
                "attachment_id": attachmentID,
                "client_attachment_token": attachmentToken,
            ],
            timeout: 4.0
        )
    }

    /// ``detachPTYChecked(sessionID:attachmentID:attachmentToken:)`` with the
    /// error swallowed (fire-and-forget, like the legacy client).
    public func detachPTY(sessionID: String, attachmentID: String, attachmentToken: String) {
        _ = try? detachPTYChecked(
            sessionID: sessionID,
            attachmentID: attachmentID,
            attachmentToken: attachmentToken
        )
    }

    /// Terminates a PTY session (`pty.close`).
    ///
    /// - Parameters:
    ///   - sessionID: Persistent PTY session to terminate.
    ///   - timeout: Maximum time to await the daemon response. The default
    ///     preserves the established standalone close behavior.
    public func closePTY(sessionID: String, timeout: TimeInterval = 8.0) throws {
        _ = try call(
            method: "pty.close",
            params: ["session_id": sessionID],
            timeout: max(0, timeout)
        )
    }

    /// Lists the daemon's PTY sessions (`pty.list`) as raw JSON dictionaries.
    public func listPTY() throws -> [[String: Any]] {
        let result = try call(method: "pty.list", params: [:], timeout: 8.0)
        return result["sessions"] as? [[String: Any]] ?? []
    }

    /// Drops a local PTY subscription without telling the daemon.
    public func unregisterPTY(sessionID: String, attachmentID: String, attachmentToken: String? = nil) {
        let key = Self.ptySubscriptionKey(
            sessionID: sessionID,
            attachmentID: attachmentID,
            attachmentToken: attachmentToken
        )
        _ = stateQueue.sync {
            ptySubscriptions.removeValue(forKey: key)
        }
    }

    func call(method: String, params: [String: Any], timeout: TimeInterval) throws -> [String: Any] {
        let pendingCall = pendingCalls.register()
        let requestID = pendingCall.id

        let payload: Data
        do {
            payload = try Self.encodeJSON([
                "id": requestID,
                "method": method,
                "params": params,
            ])
        } catch {
            pendingCalls.remove(pendingCall)
            throw NSError(domain: "cmux.remote.daemon.rpc", code: 10, userInfo: [
                NSLocalizedDescriptionKey: "failed to encode daemon RPC request \(method): \(error.localizedDescription)",
            ])
        }

        do {
            try writeQueue.sync {
                try writePayload(payload)
            }
        } catch {
            pendingCalls.remove(pendingCall)
            throw error
        }

        let response: [String: Any]
        switch pendingCalls.wait(for: pendingCall, timeout: timeout) {
        case .timedOut:
            stop(suppressTerminationCallback: false)
            throw NSError(domain: "cmux.remote.daemon.rpc", code: 11, userInfo: [
                NSLocalizedDescriptionKey: "daemon RPC timeout waiting for \(method) response",
            ])
        case .failure(let failure):
            throw NSError(domain: "cmux.remote.daemon.rpc", code: 12, userInfo: [
                NSLocalizedDescriptionKey: failure,
            ])
        case .missing:
            throw NSError(domain: "cmux.remote.daemon.rpc", code: 13, userInfo: [
                NSLocalizedDescriptionKey: "daemon RPC \(method) returned empty response",
            ])
        case .response(let pendingResponse):
            response = pendingResponse
        }

        let ok = (response["ok"] as? Bool) ?? false
        if ok {
            return (response["result"] as? [String: Any]) ?? [:]
        }

        let errorObject = (response["error"] as? [String: Any]) ?? [:]
        let code = (errorObject["code"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "rpc_error"
        let message = (errorObject["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "daemon RPC call failed"
        throw NSError(domain: "cmux.remote.daemon.rpc", code: 14, userInfo: [
            NSLocalizedDescriptionKey: "\(method) failed (\(code)): \(message)",
        ])
    }

    func notify(method: String, params: [String: Any]) throws {
        let payload: Data
        do {
            payload = try Self.encodeJSON([
                "method": method,
                "params": params,
            ])
        } catch {
            throw NSError(domain: "cmux.remote.daemon.rpc", code: 10, userInfo: [
                NSLocalizedDescriptionKey: "failed to encode daemon RPC notification \(method): \(error.localizedDescription)",
            ])
        }

        try writeQueue.sync {
            try writePayload(payload)
        }
    }

    func writePayload(_ payload: Data) throws {
        let webSocketTask: URLSessionWebSocketTask? = stateQueue.sync {
            self.webSocketTask
        }
        if let webSocketTask {
            guard let text = String(data: payload, encoding: .utf8) else {
                throw NSError(domain: "cmux.remote.daemon.rpc", code: 27, userInfo: [
                    NSLocalizedDescriptionKey: "failed encoding daemon websocket request as UTF-8",
                ])
            }
            let semaphore = DispatchSemaphore(value: 0)
            let sendErrorBox = RemoteDaemonSendErrorBox()
            webSocketTask.send(.string(text)) { error in
                sendErrorBox.error = error
                semaphore.signal()
            }
            semaphore.wait()
            if let sendError = sendErrorBox.error {
                stop(suppressTerminationCallback: false)
                throw NSError(domain: "cmux.remote.daemon.rpc", code: 16, userInfo: [
                    NSLocalizedDescriptionKey: "failed writing daemon RPC request: \(sendError.localizedDescription)",
                ])
            }
            return
        }

        let stdinHandle: FileHandle = stateQueue.sync {
            self.stdinHandle ?? FileHandle.nullDevice
        }
        if stdinHandle === FileHandle.nullDevice {
            throw NSError(domain: "cmux.remote.daemon.rpc", code: 15, userInfo: [
                NSLocalizedDescriptionKey: "daemon transport is not connected",
            ])
        }
        do {
            try stdinHandle.write(contentsOf: payload)
            try stdinHandle.write(contentsOf: Data([0x0A]))
        } catch {
            stop(suppressTerminationCallback: false)
            throw NSError(domain: "cmux.remote.daemon.rpc", code: 16, userInfo: [
                NSLocalizedDescriptionKey: "failed writing daemon RPC request: \(error.localizedDescription)",
            ])
        }
    }

    static func encodeJSON(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [])
    }
}

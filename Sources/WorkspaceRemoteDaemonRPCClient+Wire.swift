import Foundation
import SwiftUI
import AppKit
import Bonsplit
import CMUXAgentLaunch
import CmuxSocketControl
import Combine
import CryptoKit
import Darwin
import Network
import CoreText


// MARK: - JSON-RPC wire protocol IO
extension WorkspaceRemoteDaemonRPCClient {
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
            var sendError: Error?
            webSocketTask.send(.string(text)) { error in
                sendError = error
                semaphore.signal()
            }
            semaphore.wait()
            if let sendError {
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

    private func consumeJSONPayload(_ data: Data) {
        guard let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            return
        }
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

    private func consumeEventPayload(_ payload: [String: Any]) {
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
        let event: StreamEvent?
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

    private func consumePTYEventPayload(_ payload: [String: Any]) -> Bool {
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
        let event: PTYEvent?
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

    private func handleWebSocketTermination(_ detail: String) {
        let shouldNotify = !isClosed && shouldReportTermination
        let capturedTask = webSocketTask
        let capturedSession = webSocketSession

        isClosed = true
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

    func stop(suppressTerminationCallback: Bool) {
        let captured: (Process?, FileHandle?, FileHandle?, FileHandle?, URLSessionWebSocketTask?, URLSession?, Bool, String) = stateQueue.sync {
            let detail = Self.bestErrorLine(stderr: stderrBuffer) ?? "daemon transport stopped"
            let shouldNotify = !suppressTerminationCallback && !isClosed
            shouldReportTermination = !suppressTerminationCallback
            if isClosed {
                return (nil, nil, nil, nil, nil, nil, false, detail)
            }

            isClosed = true
            signalPendingFailureLocked("daemon transport stopped")
            let capturedProcess = process
            let capturedStdin = stdinHandle
            let capturedStdout = stdoutHandle
            let capturedStderr = stderrHandle
            let capturedWebSocketTask = webSocketTask
            let capturedWebSocketSession = webSocketSession

            process = nil
            stdinPipe = nil
            stdoutPipe = nil
            stderrPipe = nil
            stdinHandle = nil
            stdoutHandle = nil
            stderrHandle = nil
            webSocketTask = nil
            webSocketSession = nil
            webSocketDelegate = nil
            streamSubscriptions.removeAll(keepingCapacity: false)
            failPTYSubscriptionsLocked(detail)
            return (
                capturedProcess,
                capturedStdin,
                capturedStdout,
                capturedStderr,
                capturedWebSocketTask,
                capturedWebSocketSession,
                shouldNotify,
                detail
            )
        }

        captured.2?.readabilityHandler = nil
        captured.3?.readabilityHandler = nil
        try? captured.1?.close()
        try? captured.2?.close()
        try? captured.3?.close()
        if let process = captured.0, process.isRunning {
            process.terminate()
        }
        captured.4?.cancel(with: .normalClosure, reason: nil)
        captured.5?.invalidateAndCancel()
        if captured.6 {
            onUnexpectedTermination(captured.7)
        }
    }

    private func signalPendingFailureLocked(_ message: String) {
        pendingCalls.failAll(message)
    }

    private static func responseID(in payload: [String: Any]) -> Int? {
        if let intValue = payload["id"] as? Int {
            return intValue
        }
        if let numberValue = payload["id"] as? NSNumber {
            return numberValue.intValue
        }
        return nil
    }

    private static func decodeBase64Data(_ value: Any?) -> Data {
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

    static func encodeJSON(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [])
    }

}

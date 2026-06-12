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


// MARK: - Stream and PTY RPC API
extension WorkspaceRemoteDaemonRPCClient {
    func openStream(host: String, port: Int, timeoutMs: Int = 10000) throws -> String {
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

    func writeStream(streamID: String, data: Data) throws {
        _ = try call(
            method: "proxy.write",
            params: [
                "stream_id": streamID,
                "data_base64": data.base64EncodedString(),
            ],
            timeout: 8.0
        )
    }

    func attachStream(
        streamID: String,
        queue: DispatchQueue,
        onEvent: @escaping (StreamEvent) -> Void
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

    private func unregisterStream(streamID: String) {
        let trimmedStreamID = streamID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedStreamID.isEmpty else { return }
        _ = stateQueue.sync {
            streamSubscriptions.removeValue(forKey: trimmedStreamID)
        }
    }

    func closeStream(streamID: String) {
        unregisterStream(streamID: streamID)
        _ = try? call(
            method: "proxy.close",
            params: ["stream_id": streamID],
            timeout: 4.0
        )
    }

    func attachPTY(
        sessionID: String,
        attachmentID: String,
        cols: Int,
        rows: Int,
        command: String?,
        requireExisting: Bool,
        queue: DispatchQueue,
        onEvent: @escaping (PTYEvent) -> Void
    ) throws -> WorkspaceRemotePTYBridgeAttachment {
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

        do {
            let result = try call(method: "pty.attach", params: params, timeout: 12.0)
            let returnedAttachmentID = (result["attachment_id"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                ?? trimmedAttachmentID
            let returnedToken = (result["attachment_token"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                ?? clientAttachmentToken
            return WorkspaceRemotePTYBridgeAttachment(
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

    func writePTY(
        sessionID: String,
        attachmentID: String,
        attachmentToken: String,
        data: Data,
        completion: @escaping (Error?) -> Void
    ) {
        do {
            try notify(
                method: "pty.write",
                params: [
                    "session_id": sessionID,
                    "attachment_id": attachmentID,
                    "client_attachment_token": attachmentToken,
                    "data_base64": data.base64EncodedString(),
                ]
            )
            completion(nil)
        } catch {
            completion(error)
        }
    }

    func resizePTY(sessionID: String, attachmentID: String, attachmentToken: String, cols: Int, rows: Int) throws {
        _ = try call(
            method: "pty.resize",
            params: [
                "session_id": sessionID,
                "attachment_id": attachmentID,
                "client_attachment_token": attachmentToken,
                "cols": max(1, cols),
                "rows": max(1, rows),
            ],
            timeout: 8.0
        )
    }

    func detachPTYChecked(sessionID: String, attachmentID: String, attachmentToken: String) throws {
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

    func detachPTY(sessionID: String, attachmentID: String, attachmentToken: String) {
        _ = try? detachPTYChecked(
            sessionID: sessionID,
            attachmentID: attachmentID,
            attachmentToken: attachmentToken
        )
    }

    func closePTY(sessionID: String) throws {
        _ = try call(
            method: "pty.close",
            params: ["session_id": sessionID],
            timeout: 8.0
        )
    }

    func listPTY() throws -> [[String: Any]] {
        let result = try call(method: "pty.list", params: [:], timeout: 8.0)
        return result["sessions"] as? [[String: Any]] ?? []
    }

    private func unregisterPTY(sessionID: String, attachmentID: String, attachmentToken: String? = nil) {
        let key = Self.ptySubscriptionKey(
            sessionID: sessionID,
            attachmentID: attachmentID,
            attachmentToken: attachmentToken
        )
        _ = stateQueue.sync {
            ptySubscriptions.removeValue(forKey: key)
        }
    }

}

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


// MARK: - PTY bridge session management
extension WorkspaceRemoteSessionController {
    func listPTYSessions(timeout: TimeInterval = 8.0) throws -> [[String: Any]] {
        try runOnControllerQueue(timeout: timeout) {
            guard self.daemonReady, self.proxyLease != nil else {
                throw NSError(domain: "cmux.remote.pty", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "remote daemon is not ready",
                ])
            }
            return try WorkspaceRemoteProxyBroker.shared.listPTY(configuration: self.configuration)
        }
    }

    func closePTYSession(sessionID: String, timeout: TimeInterval = 8.0) throws {
        try runOnControllerQueue(timeout: timeout) {
            guard self.daemonReady, self.proxyLease != nil else {
                throw NSError(domain: "cmux.remote.pty", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "remote daemon is not ready",
                ])
            }
            try WorkspaceRemoteProxyBroker.shared.closePTY(configuration: self.configuration, sessionID: sessionID)
        }
    }

    func startPTYBridge(
        sessionID: String,
        attachmentID: String,
        command: String?,
        requireExisting: Bool,
        waitForReady: Bool = false,
        timeout: TimeInterval = 8.0
    ) throws -> WorkspaceRemotePTYBridgeServer.Endpoint {
        if waitForReady {
            return try startPTYBridgeWhenReady(
                sessionID: sessionID,
                attachmentID: attachmentID,
                command: command,
                requireExisting: requireExisting,
                timeout: timeout
            )
        }
        return try runOnControllerQueue(timeout: timeout) {
            try self.startPTYBridgeLocked(
                sessionID: sessionID,
                attachmentID: attachmentID,
                command: command,
                requireExisting: requireExisting
            )
        }
    }

    private func startPTYBridgeWhenReady(
        sessionID: String,
        attachmentID: String,
        command: String?,
        requireExisting: Bool,
        timeout: TimeInterval
    ) throws -> WorkspaceRemotePTYBridgeServer.Endpoint {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return try startPTYBridgeLocked(
                sessionID: sessionID,
                attachmentID: attachmentID,
                command: command,
                requireExisting: requireExisting
            )
        }

        let waiterID = UUID()
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var captured: Result<WorkspaceRemotePTYBridgeServer.Endpoint, Error>?
        let isCancelled: () -> Bool = {
            lock.lock()
            let completed = captured != nil
            lock.unlock()
            return completed
        }
        let complete: (Result<WorkspaceRemotePTYBridgeServer.Endpoint, Error>) -> Void = { result in
            lock.lock()
            if captured == nil {
                captured = result
                semaphore.signal()
            }
            lock.unlock()
        }

        queue.async { [weak self] in
            guard let self else {
                complete(.failure(NSError(domain: "cmux.remote.pty", code: 7, userInfo: [
                    NSLocalizedDescriptionKey: "remote daemon is not ready",
                ])))
                return
            }
            guard !self.isStopping else {
                complete(.failure(NSError(domain: "cmux.remote.pty", code: 7, userInfo: [
                    NSLocalizedDescriptionKey: "remote daemon is not ready",
                ])))
                return
            }
            if self.canStartPTYBridgeLocked {
                complete(Result {
                    try self.startPTYBridgeLocked(
                        sessionID: sessionID,
                        attachmentID: attachmentID,
                        command: command,
                        requireExisting: requireExisting
                    )
                })
                return
            }
            guard !isCancelled() else { return }
            self.pendingPTYBridgeStarts[waiterID] = PendingPTYBridgeStart(
                sessionID: sessionID,
                attachmentID: attachmentID,
                command: command,
                requireExisting: requireExisting,
                isCancelled: isCancelled,
                completion: complete
            )
        }

        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            let timeoutError = NSError(domain: "cmux.remote.pty", code: 8, userInfo: [
                NSLocalizedDescriptionKey: "timed out waiting for remote PTY operation",
            ])
            lock.lock()
            if captured == nil {
                captured = .failure(timeoutError)
            }
            lock.unlock()
            queue.async { [weak self] in
                _ = self?.pendingPTYBridgeStarts.removeValue(forKey: waiterID)
            }
            throw timeoutError
        }

        lock.lock()
        let result = captured
        lock.unlock()
        switch result {
        case .success(let endpoint):
            return endpoint
        case .failure(let error):
            throw error
        case nil:
            throw NSError(domain: "cmux.remote.pty", code: 9, userInfo: [
                NSLocalizedDescriptionKey: "remote PTY operation returned no result",
            ])
        }
    }

    private var canStartPTYBridgeLocked: Bool {
        daemonReady && proxyLease != nil && proxyEndpoint != nil
    }

    private func startPTYBridgeLocked(
        sessionID: String,
        attachmentID: String,
        command: String?,
        requireExisting: Bool
    ) throws -> WorkspaceRemotePTYBridgeServer.Endpoint {
        guard canStartPTYBridgeLocked else {
            throw NSError(domain: "cmux.remote.pty", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "remote daemon is not ready",
            ])
        }
        return try WorkspaceRemoteProxyBroker.shared.startPTYBridge(
            configuration: configuration,
            sessionID: sessionID,
            attachmentID: attachmentID,
            command: command,
            requireExisting: requireExisting
        )
    }

    func fulfillPendingPTYBridgeStartsLocked() {
        guard canStartPTYBridgeLocked, !pendingPTYBridgeStarts.isEmpty else { return }
        let pending = pendingPTYBridgeStarts
        pendingPTYBridgeStarts.removeAll(keepingCapacity: false)
        for request in pending.values {
            guard !request.isCancelled() else { continue }
            request.completion(Result {
                try startPTYBridgeLocked(
                    sessionID: request.sessionID,
                    attachmentID: request.attachmentID,
                    command: request.command,
                    requireExisting: request.requireExisting
                )
            })
        }
    }

    func failPendingPTYBridgeStartsLocked(_ message: String) {
        guard !pendingPTYBridgeStarts.isEmpty else { return }
        let pending = pendingPTYBridgeStarts
        pendingPTYBridgeStarts.removeAll(keepingCapacity: false)
        let error = NSError(domain: "cmux.remote.pty", code: 10, userInfo: [
            NSLocalizedDescriptionKey: message,
        ])
        for request in pending.values {
            request.completion(.failure(error))
        }
    }

    func resizePTY(
        sessionID: String,
        attachmentID: String,
        attachmentToken: String,
        cols: Int,
        rows: Int,
        timeout: TimeInterval = 8.0
    ) throws {
        try runOnControllerQueue(timeout: timeout) {
            guard self.daemonReady, self.proxyLease != nil else {
                throw NSError(domain: "cmux.remote.pty", code: 6, userInfo: [
                    NSLocalizedDescriptionKey: "remote daemon is not ready",
                ])
            }
            try WorkspaceRemoteProxyBroker.shared.resizePTY(
                configuration: self.configuration,
                sessionID: sessionID,
                attachmentID: attachmentID,
                attachmentToken: attachmentToken,
                cols: cols,
                rows: rows
            )
        }
    }

    func detachPTYSession(
        sessionID: String,
        attachmentID: String,
        attachmentToken: String,
        timeout: TimeInterval = 8.0
    ) throws {
        try runOnControllerQueue(timeout: timeout) {
            guard self.daemonReady, self.proxyLease != nil else {
                throw NSError(domain: "cmux.remote.pty", code: 7, userInfo: [
                    NSLocalizedDescriptionKey: "remote daemon is not ready",
                ])
            }
            try WorkspaceRemoteProxyBroker.shared.detachPTY(
                configuration: self.configuration,
                sessionID: sessionID,
                attachmentID: attachmentID,
                attachmentToken: attachmentToken
            )
        }
    }

}

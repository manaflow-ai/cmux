public import CmuxRemoteWorkspace
public import Foundation

// Synchronous persistent-PTY entry points (list/close/start-bridge/resize/
// detach) for callers that cannot await (socket command handlers blocking a
// real thread), plus the parked-start queue for `waitForReady`. Faithful
// lift: every NSError domain/code/message, the timeout semantics, and the
// semaphore-based completion contract are pinned legacy behavior (the
// blocking bridges are the load-bearing sync contract from the isolation
// essay, not new semaphore re-entry).
extension RemoteSessionCoordinator {
    /// Lists the daemon's persistent PTY sessions as raw wire dictionaries.
    /// Blocks the calling thread (never the coordinator queue) up to
    /// `timeout`.
    public func listPTYSessions(timeout: TimeInterval = 8.0) throws -> [[String: Any]] {
        try runOnControllerQueue(timeout: timeout) {
            guard self.daemonReady, self.proxyLease != nil else {
                throw NSError(domain: "cmux.remote.pty", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "remote daemon is not ready",
                ])
            }
            return try self.proxyBroker.listPTY(configuration: self.configuration)
        }
    }

    /// Closes one persistent PTY session by ID; same blocking contract as
    /// ``listPTYSessions(timeout:)``.
    public func closePTYSession(sessionID: String, timeout: TimeInterval = 8.0) throws {
        try runOnControllerQueue(timeout: timeout) {
            guard self.daemonReady, self.proxyLease != nil else {
                throw NSError(domain: "cmux.remote.pty", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "remote daemon is not ready",
                ])
            }
            try self.proxyBroker.closePTY(configuration: self.configuration, sessionID: sessionID)
        }
    }

    /// Starts a loopback PTY bridge for a persistent session, optionally
    /// parking the request until the daemon/proxy are ready
    /// (`waitForReady`); returns the bridge's loopback endpoint.
    public func startPTYBridge(
        sessionID: String,
        attachmentID: String,
        command: String?,
        requireExisting: Bool,
        waitForReady: Bool = false,
        timeout: TimeInterval = 8.0
    ) throws -> RemotePTYBridgeServer.Endpoint {
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
    ) throws -> RemotePTYBridgeServer.Endpoint {
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
        // First-writer-wins slot (the legacy captured-`var` + NSLock shape,
        // boxed for Swift 6 sendability; identical lock/signal ordering).
        let box = LockedResult<RemotePTYBridgeServer.Endpoint>()
        let isCancelled: @Sendable () -> Bool = {
            box.hasValue
        }
        let complete: @Sendable (Result<RemotePTYBridgeServer.Endpoint, Error>) -> Void = { result in
            if box.setIfEmpty(result) {
                semaphore.signal()
            }
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
            _ = box.setIfEmpty(.failure(timeoutError))
            queue.async { [weak self] in
                _ = self?.pendingPTYBridgeStarts.removeValue(forKey: waiterID)
            }
            throw timeoutError
        }

        switch box.current {
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

    var canStartPTYBridgeLocked: Bool {
        daemonReady && proxyLease != nil && proxyEndpoint != nil
    }

    private func startPTYBridgeLocked(
        sessionID: String,
        attachmentID: String,
        command: String?,
        requireExisting: Bool
    ) throws -> RemotePTYBridgeServer.Endpoint {
        guard canStartPTYBridgeLocked else {
            throw NSError(domain: "cmux.remote.pty", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "remote daemon is not ready",
            ])
        }
        return try proxyBroker.startPTYBridge(
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

    /// Resizes a persistent PTY attachment; same blocking contract as
    /// ``listPTYSessions(timeout:)``.
    public func resizePTY(
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
            try self.proxyBroker.resizePTY(
                configuration: self.configuration,
                sessionID: sessionID,
                attachmentID: attachmentID,
                attachmentToken: attachmentToken,
                cols: cols,
                rows: rows
            )
        }
    }

    /// Detaches a persistent PTY attachment; same blocking contract as
    /// ``listPTYSessions(timeout:)``.
    public func detachPTYSession(
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
            try self.proxyBroker.detachPTY(
                configuration: self.configuration,
                sessionID: sessionID,
                attachmentID: attachmentID,
                attachmentToken: attachmentToken
            )
        }
    }

    // Blocking hop onto the coordinator queue for the synchronous PTY
    // contract: direct call when already on the queue, otherwise a
    // semaphore-bridged async dispatch with the legacy timeout errors.
    func runOnControllerQueue<T>(timeout: TimeInterval, _ body: @escaping @Sendable () throws -> T) throws -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return try body()
        }

        let semaphore = DispatchSemaphore(value: 0)
        // First-writer-wins slot (the legacy captured-`var` + NSLock shape,
        // boxed for Swift 6 sendability; identical lock/signal ordering).
        let box = LockedResult<T>()
        queue.async {
            _ = box.setIfEmpty(Result { try body() })
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            throw NSError(domain: "cmux.remote.pty", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "timed out waiting for remote PTY operation",
            ])
        }
        switch box.current {
        case .success(let value):
            return value
        case .failure(let error):
            throw error
        case nil:
            throw NSError(domain: "cmux.remote.pty", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "remote PTY operation returned no result",
            ])
        }
    }
}

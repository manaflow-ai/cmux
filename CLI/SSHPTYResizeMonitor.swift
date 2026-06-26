import Darwin
import Foundation

actor SSHPTYResizeMonitor {
    private typealias ResizeEvent = (size: (cols: Int, rows: Int), force: Bool)
    // Keep input-edge ordering bounded; failed sends resume waiters immediately
    // and retry the latest size on a timer (see `scheduleResizeRetry`).
    private static let resizeResponseTimeout: TimeInterval = 0.05
    // A resize send can fail transiently (the bounded RPC races a stale or
    // blocked remote-session control path and times out). Recording the pending
    // size is not enough: without a self-driven retry the remote PTY/TUI stays
    // frozen until the next SIGWINCH or input edge — or a manual workspace
    // reconnect. Retry the latest size with bounded backoff so it converges on
    // its own. https://github.com/manaflow-ai/cmux/issues/6306
    private static let initialRetryBackoff: TimeInterval = 0.1
    private static let maxRetryBackoff: TimeInterval = 2.0

    private let socketPath: String
    private let explicitPassword: String?
    private let workspaceId: String
    private let surfaceID: String?
    private let sessionID: String
    private let attachmentID: String
    private let attachmentToken: String
    // AsyncStream.Continuation is safe to yield from signal callbacks; the
    // newest-1 buffer bounds resize churn while actor state drains.
    private let eventContinuation: AsyncStream<ResizeEvent>.Continuation
    private let source: DispatchSourceSignal
    private var lastSentSize: (cols: Int, rows: Int)
    private var pendingSize: (cols: Int, rows: Int)?
    private var inputWaiters: [CheckedContinuation<Void, Never>] = []
    private var isDraining = false
    private var isCancelled = false
    private var retryBackoff: TimeInterval = SSHPTYResizeMonitor.initialRetryBackoff
    private var retryWorkItem: DispatchWorkItem?

    init(
        socketPath: String,
        explicitPassword: String?,
        workspaceId: String,
        surfaceID: String?,
        sessionID: String,
        attachmentID: String,
        attachmentToken: String,
        initialSize: (cols: Int, rows: Int)
    ) {
        self.socketPath = socketPath
        self.explicitPassword = explicitPassword
        self.workspaceId = workspaceId
        self.surfaceID = surfaceID
        self.sessionID = sessionID
        self.attachmentID = attachmentID
        self.attachmentToken = attachmentToken
        self.lastSentSize = initialSize
        let events = AsyncStream<ResizeEvent>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.eventContinuation = events.continuation
        self.source = DispatchSource.makeSignalSource(
            signal: SIGWINCH,
            queue: DispatchQueue(label: "com.cmux.ssh-pty.resize.signal")
        )
        signal(SIGWINCH, SIG_IGN)
        source.setEventHandler { [eventContinuation] in
            let size = CMUXCLI.currentCLITerminalSize()
            eventContinuation.yield((size: size, force: true))
        }
        source.resume()
        Task { [stream = events.stream] in
            await self.processResizeEvents(stream)
        }
    }

    func resizeBeforeInputIfNeeded() async {
        let size = CMUXCLI.currentCLITerminalSize()
        await withCheckedContinuation { continuation in
            recordPendingResize(size: size, force: false, waiter: continuation)
        }
    }

    nonisolated func requestCurrentResize() {
        let size = CMUXCLI.currentCLITerminalSize()
        eventContinuation.yield((size: size, force: true))
    }

    nonisolated func cancel() {
        source.cancel()
        eventContinuation.finish()
        Task {
            await self.markCancelled()
        }
    }

    private func processResizeEvents(_ events: AsyncStream<ResizeEvent>) async {
        for await event in events {
            guard !isCancelled else { break }
            recordPendingResize(size: event.size, force: event.force, waiter: nil)
        }
        markCancelled()
    }

    private func markCancelled() {
        isCancelled = true
        pendingSize = nil
        retryWorkItem?.cancel()
        retryWorkItem = nil
        resumeInputWaiters()
    }

    private func recordPendingResize(
        size: (cols: Int, rows: Int),
        force: Bool,
        waiter: CheckedContinuation<Void, Never>?
    ) {
        guard !isCancelled else {
            waiter?.resume()
            return
        }
        if force || !Self.sameSize(size, lastSentSize) {
            pendingSize = size
        } else {
            if pendingSize == nil {
                waiter?.resume()
                return
            }
        }
        if let waiter {
            inputWaiters.append(waiter)
        }
        startDrainIfNeeded()
    }

    private func startDrainIfNeeded() {
        guard !isDraining else { return }
        isDraining = true
        Task {
            await self.drainPendingResizes()
        }
    }

    private func drainPendingResizes() async {
        defer {
            isDraining = false
        }
        while true {
            if isCancelled {
                pendingSize = nil
                resumeInputWaiters()
                return
            }
            guard let size = pendingSize else {
                return
            }
            pendingSize = nil
            let waiters = inputWaiters
            inputWaiters = []

            let sent = await sendResize(size: size)
            // Waiters that existed before this send still need any newer
            // resize that arrived during the socket round trip.
            inputWaiters = waiters + inputWaiters
            if isCancelled {
                pendingSize = nil
                resumeInputWaiters()
                return
            }
            if sent {
                lastSentSize = size
                resetResizeRetry()
                let currentSize = CMUXCLI.currentCLITerminalSize()
                pendingSize = Self.sameSize(currentSize, lastSentSize) ? nil : currentSize
                if pendingSize == nil {
                    resumeInputWaiters()
                    return
                }
                continue
            }

            // Delivery failed. Keep the latest desired size pending, resume any
            // input waiters immediately so typing is never blocked behind a
            // wedged resize, and schedule a backoff retry so the size still
            // converges without waiting for the next SIGWINCH/input edge.
            if pendingSize == nil {
                pendingSize = size
            }
            resumeInputWaiters()
            scheduleResizeRetry()
            return
        }
    }

    private func scheduleResizeRetry() {
        guard !isCancelled, pendingSize != nil, retryWorkItem == nil else { return }
        let delay = retryBackoff
        retryBackoff = min(retryBackoff * 2, Self.maxRetryBackoff)
        // One-shot timer callback (the codebase idiom for delayed work): after
        // the backoff elapses, hop back onto the actor and re-drain the pending
        // size so delivery converges without another SIGWINCH/input edge.
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { await self.retryPendingResize() }
        }
        retryWorkItem = workItem
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func retryPendingResize() {
        retryWorkItem = nil
        guard !isCancelled, pendingSize != nil else { return }
        startDrainIfNeeded()
    }

    private func resetResizeRetry() {
        retryBackoff = Self.initialRetryBackoff
        retryWorkItem?.cancel()
        retryWorkItem = nil
    }

    private func resumeInputWaiters() {
        let waiters = inputWaiters
        inputWaiters = []
        waiters.forEach { $0.resume() }
    }

    private func sendResize(size: (cols: Int, rows: Int)) async -> Bool {
        let socketPath = self.socketPath
        let explicitPassword = self.explicitPassword
        let workspaceId = self.workspaceId
        let surfaceID = self.surfaceID
        let sessionID = self.sessionID
        let attachmentID = self.attachmentID
        let attachmentToken = self.attachmentToken
        // SocketClient is synchronous; run the bounded RPC off the actor executor.
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: Self.sendResizeBlocking(
                    socketPath: socketPath,
                    explicitPassword: explicitPassword,
                    workspaceId: workspaceId,
                    surfaceID: surfaceID,
                    sessionID: sessionID,
                    attachmentID: attachmentID,
                    attachmentToken: attachmentToken,
                    size: size
                ))
            }
        }
    }

    private static func sendResizeBlocking(
        socketPath: String,
        explicitPassword: String?,
        workspaceId: String,
        surfaceID: String?,
        sessionID: String,
        attachmentID: String,
        attachmentToken: String,
        size: (cols: Int, rows: Int)
    ) -> Bool {
        var params: [String: Any] = [
            "workspace_id": workspaceId,
            "session_id": sessionID,
            "attachment_id": attachmentID,
            "attachment_token": attachmentToken,
            "cols": size.cols,
            "rows": size.rows,
        ]
        if let surfaceID {
            params["surface_id"] = surfaceID
            params["allow_moved_surface"] = true
        }
        let resizeClient = SocketClient(path: socketPath)
        defer { resizeClient.close() }
        do {
            try resizeClient.connectWithoutRetry(responseTimeout: Self.resizeResponseTimeout)
            try CMUXCLI.authenticateSocketClientIfNeeded(
                resizeClient,
                explicitPassword: explicitPassword,
                socketPath: socketPath,
                responseTimeout: Self.resizeResponseTimeout
            )
            _ = try resizeClient.sendV2(
                method: "workspace.remote.pty_resize",
                params: params,
                responseTimeout: Self.resizeResponseTimeout
            )
            return true
        } catch {
            return false
        }
    }

    private static func sameSize(
        _ lhs: (cols: Int, rows: Int),
        _ rhs: (cols: Int, rows: Int)
    ) -> Bool {
        lhs.cols == rhs.cols && lhs.rows == rhs.rows
    }
}

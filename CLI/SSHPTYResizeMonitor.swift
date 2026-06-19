import Darwin
import Foundation

actor SSHPTYResizeMonitor {
    private typealias ResizeEvent = (size: (cols: Int, rows: Int), force: Bool)

    private let socketPath: String
    private let explicitPassword: String?
    private let workspaceId: String
    private let surfaceID: String?
    private let sessionID: String
    private let attachmentID: String
    private let attachmentToken: String
    // AsyncStream.Continuation is safe to yield from stdin/signal callbacks;
    // the newest-1 buffer bounds input-hot-path work while actor state drains.
    private let eventContinuation: AsyncStream<ResizeEvent>.Continuation
    private let source: DispatchSourceSignal
    private var lastSentSize: (cols: Int, rows: Int)
    private var pendingSize: (cols: Int, rows: Int)?
    private var isCancelled = false

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

    nonisolated func enqueueResizeIfNeeded() {
        let size = CMUXCLI.currentCLITerminalSize()
        eventContinuation.yield((size: size, force: false))
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
            await enqueue(size: event.size, force: event.force)
        }
        isCancelled = true
        pendingSize = nil
    }

    private func markCancelled() {
        isCancelled = true
        pendingSize = nil
    }

    private func enqueue(size: (cols: Int, rows: Int), force: Bool) async {
        guard !isCancelled else { return }
        if force || !Self.sameSize(size, lastSentSize) {
            pendingSize = size
        } else {
            pendingSize = nil
        }
        await drainPendingResizes()
    }

    private func drainPendingResizes() async {
        while true {
            if isCancelled {
                pendingSize = nil
                return
            }
            guard let size = pendingSize else {
                return
            }
            pendingSize = nil

            let sent = await sendResize(size: size)
            if isCancelled {
                pendingSize = nil
                return
            }
            if sent {
                lastSentSize = size
                let currentSize = CMUXCLI.currentCLITerminalSize()
                pendingSize = Self.sameSize(currentSize, lastSentSize) ? nil : currentSize
                if pendingSize == nil {
                    return
                }
                continue
            }

            if pendingSize == nil {
                pendingSize = size
            }
            return
        }
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
            try resizeClient.connectWithoutRetry()
            try CMUXCLI.authenticateSocketClientIfNeeded(
                resizeClient,
                explicitPassword: explicitPassword,
                socketPath: socketPath
            )
            _ = try resizeClient.sendV2(method: "workspace.remote.pty_resize", params: params)
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

import Darwin
import Foundation

actor SSHPTYResizeMonitor {
    private let socketPath: String
    private let explicitPassword: String?
    private let workspaceId: String
    private let surfaceID: String?
    private let sessionID: String
    private let attachmentID: String
    private let attachmentToken: String
    // DispatchSourceSignal supports cross-thread cancel/resume; all mutable
    // resize state stays actor-isolated.
    private nonisolated(unsafe) let source: DispatchSourceSignal
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
        self.source = DispatchSource.makeSignalSource(
            signal: SIGWINCH,
            queue: DispatchQueue(label: "com.cmux.ssh-pty.resize.signal")
        )
        signal(SIGWINCH, SIG_IGN)
        source.setEventHandler { [weak self] in
            Task { await self?.enqueueCurrentSize(force: true) }
        }
        source.resume()
    }

    nonisolated func enqueueResizeIfNeeded() {
        let size = CMUXCLI.currentCLITerminalSize()
        Task { await self.enqueue(size: size, force: false) }
    }

    nonisolated func cancel() {
        source.cancel()
        Task { await self.cancelState() }
    }

    private func enqueueCurrentSize(force: Bool) {
        enqueue(size: CMUXCLI.currentCLITerminalSize(), force: force)
    }

    private func cancelState() {
        isCancelled = true
        pendingSize = nil
    }

    private func enqueue(size: (cols: Int, rows: Int), force: Bool) {
        guard !isCancelled else { return }
        if force || !Self.sameSize(size, lastSentSize) {
            pendingSize = size
        } else {
            pendingSize = nil
        }
        drainPendingResizes()
    }

    private func drainPendingResizes() {
        while true {
            if isCancelled {
                return
            }
            guard let size = pendingSize else {
                return
            }
            pendingSize = nil

            if sendResize(size: size) {
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

    private func sendResize(size: (cols: Int, rows: Int)) -> Bool {
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

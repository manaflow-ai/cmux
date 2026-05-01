import AppKit
import Combine
import Foundation
#if DEBUG
import Bonsplit
#endif

/// Single persistent bidirectional Unix-socket connection to cmuxd.
///
/// Replaces WorkspaceDaemonBridge (workspace.sync push) and DaemonTerminalBridge
/// (per-surface read/write sockets). One socket per app process, regardless of
/// the number of terminals or workspaces.
///
/// Architecture:
///   - Persistent socket with dedicated reader thread.
///   - Reader routes by message shape: presence of `id` => RPC response, presence
///     of `event` => push notification.
///   - Writer is serial via a dedicated DispatchQueue (no main-thread blocking).
///   - Pending RPCs: `id -> continuation` map, fulfilled by reader.
///   - Terminal subscriptions: `session_id -> handlers` map, drained by reader.
///   - On reconnect: re-send hello, re-subscribe workspace + every active terminal.
final class DaemonConnection: @unchecked Sendable {
    static let shared = DaemonConnection()

    // Required server capabilities for this client to function.
    private static let requiredCapabilities: Set<String> = [
        "workspace.sync",
        "terminal.subscribe",
        "workspace.subscribe",
    ]

    private let socketPath: String
    private var fd: Int32 = -1
    private let stateLock = NSLock()
    private var connecting = false
    private var reconnectTimer: DispatchSourceTimer?
    private var nextRpcID: Int = 0
    private let writeQueue = DispatchQueue(label: "cmux.daemon-connection.write", qos: .userInitiated)
    private var pending: [Int: (Result<[String: Any], Error>) -> Void] = [:]
    private struct QueuedTerminalWrite {
        let sessionID: String
        let writeID: String
        let data: Data
    }
    private static let maxQueuedTerminalWriteBytes = 8 * 1024 * 1024
    private var queuedTerminalWrites: [QueuedTerminalWrite] = []
    private var queuedTerminalWriteBytes = 0
    /// All per-session mac state (output handler, attachmentID, last offset,
    /// grid generation) now lives in `TerminalSessionRegistry.shared`. That
    /// registry enforces one-surface-per-sessionID, so cross-session
    /// keystroke routing is impossible at the boundary.
    private var workspaceSubscribed = false
    private var workspaceSyncProvider: (() -> [String: Any]?)?
    private var workspaceChangedHandler: (([String: Any]) -> Void)?
    /// Workspace IDs (lowercased UUID strings) for which the macOS app has just
    /// sent `workspace.create` to the daemon. While present, the workspace.changed
    /// echo for that id should NOT spawn a duplicate local Workspace; field updates
    /// are still applied. Cleared when the create RPC response arrives (success or
    /// failure) and on workspace.changed consumption.
    private var pendingCreates: Set<String> = []
    /// Subset of `pendingCreates` whose `workspace.create` RPC has not
    /// completed yet. `workspace.open_pane` waits on this signal instead of
    /// racing the daemon with timer-based retries.
    private var pendingCreateRPCs: Set<String> = []
    private var pendingCreateWaiters: [String: [() -> Void]] = [:]
    /// Workspace IDs (lowercased UUID strings) for which the macOS app has just
    /// closed locally and sent `workspace.close` to the daemon. While present,
    /// the daemon-authority remove path should NOT close the local workspace
    /// (it is already gone) and the daemon-authority add path should NOT
    /// re-instantiate the workspace from a stale workspace.changed echo.
    private var pendingDeletes: Set<String> = []
    #if DEBUG
    private let debugStatusProbeLock = NSLock()
    private var debugStatusProbeInFlight: Set<String> = []
    #endif

    /// Register a handler for `workspace.changed` push events. Invoked on the
    /// reader thread; handler is responsible for dispatching to main actor if
    /// it mutates UI state. Pass nil to clear.
    func setWorkspaceChangedHandler(_ handler: (([String: Any]) -> Void)?) {
        stateLock.lock()
        workspaceChangedHandler = handler
        stateLock.unlock()
    }

    // MARK: - pending_creates / pending_deletes

    /// Mark a workspace id as pending a daemon-side create (RPC in flight).
    func markPendingCreate(workspaceID: UUID) {
        stateLock.lock()
        let key = workspaceID.uuidString.lowercased()
        pendingCreates.insert(key)
        pendingCreateRPCs.insert(key)
        stateLock.unlock()
    }

    /// Returns true and removes the entry if the workspace id was marked pending.
    /// Call from the workspace.changed applier so the macOS-initiated create echo
    /// only updates fields and never creates a duplicate.
    @discardableResult
    func consumePendingCreate(workspaceID: UUID) -> Bool {
        stateLock.lock()
        let removed = pendingCreates.remove(workspaceID.uuidString.lowercased()) != nil
        stateLock.unlock()
        return removed
    }

    /// Drop a pending create entry without consuming. Used when the create RPC
    /// errors or times out (we should let the daemon-authority pipeline handle
    /// the next state arriving naturally).
    func clearPendingCreate(workspaceID: UUID) {
        let waiters: [() -> Void]
        stateLock.lock()
        let key = workspaceID.uuidString.lowercased()
        pendingCreates.remove(key)
        pendingCreateRPCs.remove(key)
        waiters = pendingCreateWaiters.removeValue(forKey: key) ?? []
        stateLock.unlock()
        waiters.forEach { $0() }
    }

    private func completePendingCreateRPC(workspaceID: UUID) {
        let waiters: [() -> Void]
        stateLock.lock()
        let key = workspaceID.uuidString.lowercased()
        pendingCreateRPCs.remove(key)
        waiters = pendingCreateWaiters.removeValue(forKey: key) ?? []
        stateLock.unlock()
        waiters.forEach { $0() }
    }

    private func waitForPendingCreateRPCIfNeeded(
        workspaceID: UUID,
        action: @escaping () -> Void
    ) -> Bool {
        stateLock.lock()
        let key = workspaceID.uuidString.lowercased()
        if pendingCreateRPCs.contains(key) {
            pendingCreateWaiters[key, default: []].append(action)
            stateLock.unlock()
            return true
        }
        stateLock.unlock()
        return false
    }

    /// Mark a workspace id as pending a daemon-side close (local already gone,
    /// RPC in flight, daemon may still echo it back briefly).
    func markPendingDelete(workspaceID: UUID) {
        stateLock.lock()
        pendingDeletes.insert(workspaceID.uuidString.lowercased())
        stateLock.unlock()
    }

    /// True if the workspace id is pending a daemon-side close.
    func isPendingDelete(workspaceID: UUID) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return pendingDeletes.contains(workspaceID.uuidString.lowercased())
    }

    /// Update pending_deletes after a workspace.changed event. An id that is
    /// still present in the daemon's payload means the close hasn't propagated
    /// yet, so we keep it in pending_deletes (suppresses re-instantiation by
    /// the daemon-authority add path). An id that is no longer present means
    /// the daemon has confirmed the close, so we drop it from pending_deletes.
    func reconcilePendingDeletes(currentDaemonIDs: Set<String>) {
        stateLock.lock()
        pendingDeletes.formIntersection(currentDaemonIDs)
        stateLock.unlock()
    }

    /// Set by AppDelegate after the TabManager is wired up. Called whenever the
    /// daemon (re)connects so we can push the current workspace snapshot.
    func setWorkspaceSyncProvider(_ provider: @escaping () -> [String: Any]?) {
        stateLock.lock()
        workspaceSyncProvider = provider
        let connected = fd >= 0
        stateLock.unlock()
        if connected { performWorkspaceSync() }
    }

    static var defaultSocketPath: String {
        let env = ProcessInfo.processInfo.environment
        if let path = env["CMUXD_UNIX_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty {
            return path
        }
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?.appendingPathComponent("cmux").path ?? "/tmp"
        let tag = env["CMUX_TAG"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return tag.isEmpty ? "\(appSupport)/cmuxd.sock" : "\(appSupport)/cmuxd-dev-\(tag).sock"
    }

    init(socketPath: String = DaemonConnection.defaultSocketPath) {
        self.socketPath = socketPath
        connectAsync()
    }

    var isConnected: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return fd >= 0
    }

    var statusDescription: String { isConnected ? "connected" : "disconnected" }
    var currentSocketPath: String { socketPath }

    // MARK: - Session bootstrap for restored panels

    /// Ensure a daemon session with a known id exists (idempotent). Used by the
    /// session-restore path to bring the daemon's view in line with saved
    /// ids so iOS clients can attach before the desktop surface materializes.
    /// Fresh panels (no saved id) must use `openPane(workspaceID:...)` instead —
    /// the daemon mints the authoritative id.
    static func ensureSession(
        sessionID: String,
        shellCommand: String,
        cols: Int = 80,
        rows: Int = 24
    ) {
        DaemonConnection.shared.preCreate(sessionID: sessionID, shellCommand: shellCommand, cols: cols, rows: rows)
    }

    private func preCreate(sessionID: String, shellCommand: String, cols: Int, rows: Int) {
        sendRPCAsync(method: "terminal.open", params: [
            "session_id": sessionID,
            "command": shellCommand,
            "cols": cols,
            "rows": rows,
        ]) { [weak self] result in
            guard let self else { return }
            // Detach the bootstrap attachment so the session has zero attachments
            // until something subscribes.
            if case .success(let resp) = result,
               let ok = resp["ok"] as? Bool, ok,
               let r = resp["result"] as? [String: Any],
               let bootstrap = r["attachment_id"] as? String {
                self.sendRPCAsync(method: "session.detach", params: [
                    "session_id": sessionID,
                    "attachment_id": bootstrap,
                ], completion: nil)
            }
        }
    }

    // MARK: - Public API: workspace.open_pane (daemon-minted session IDs)

    /// Ask the daemon to mint a new terminal session and bind it to a
    /// pane in the given workspace. This is the canonical path for
    /// creating a new shell — the daemon returns the session_id, and
    /// every other client (iOS included) discovers it via
    /// `workspace.list`. Call sites never need to invent a session_id
    /// themselves when they use this.
    ///
    /// On success the completion receives `(sessionID, paneID)`. On any
    /// failure (daemon not reachable, workspace missing, RPC malformed)
    /// the completion receives nil and callers must surface the
    /// failure rather than fabricating an id.
    func openPane(
        workspaceID: UUID,
        command: String,
        cols: Int,
        rows: Int,
        parentPaneID: String? = nil,
        direction: String? = nil,
        completion: @escaping (_ sessionID: String?, _ paneID: String?) -> Void
    ) {
        if waitForPendingCreateRPCIfNeeded(workspaceID: workspaceID, action: { [weak self] in
            self?.openPane(
                workspaceID: workspaceID,
                command: command,
                cols: cols,
                rows: rows,
                parentPaneID: parentPaneID,
                direction: direction,
                completion: completion
            )
        }) {
            #if DEBUG
            dlog("blank.conn.openPane.defer workspace=\(workspaceID.uuidString.prefix(8)) reason=workspace_create_in_flight")
            #endif
            return
        }

        sendOpenPane(
            workspaceID: workspaceID,
            command: command,
            cols: cols,
            rows: rows,
            parentPaneID: parentPaneID,
            direction: direction,
            completion: completion
        )
    }

    private func sendOpenPane(
        workspaceID: UUID,
        command: String,
        cols: Int,
        rows: Int,
        parentPaneID: String?,
        direction: String?,
        completion: @escaping (_ sessionID: String?, _ paneID: String?) -> Void
    ) {
        var params: [String: Any] = [
            "workspace_id": workspaceID.uuidString.lowercased(),
            "command": command,
            "cols": max(1, cols),
            "rows": max(1, rows),
        ]
        if let parentPaneID { params["parent_pane_id"] = parentPaneID }
        if let direction { params["direction"] = direction }
        sendRPCAsync(method: "workspace.open_pane", params: params) { result in
            #if DEBUG
            let ok: Bool = {
                if case .success(let resp) = result, let ok = resp["ok"] as? Bool { return ok }
                return false
            }()
            if !ok {
                let errorText: String = {
                    switch result {
                    case .success(let resp):
                        return String(describing: resp["error"] ?? resp)
                    case .failure(let error):
                        return error.localizedDescription
                    }
                }()
                dlog("blank.conn.openPane.result workspace=\(workspaceID.uuidString.prefix(8)) ok=0 error=\(errorText)")
            }
            #endif
            if case .success(let resp) = result,
               let ok = resp["ok"] as? Bool, ok,
               let r = resp["result"] as? [String: Any],
               let sid = r["session_id"] as? String,
               let pid = r["pane_id"] as? String {
                completion(sid, pid)
                return
            }
            completion(nil, nil)
        }
    }

    // MARK: - Public API: workspace sync (replaces WorkspaceDaemonBridge.performSync)

    func sendWorkspaceSync(_ params: [String: Any]) {
        sendRPCAsync(method: "workspace.sync", params: params, completion: nil)
    }

    func sendWorkspacePin(workspaceID: UUID, pinned: Bool) {
        sendRPCAsync(method: "workspace.pin", params: [
            "workspace_id": workspaceID.uuidString.lowercased(),
            "pinned": pinned,
        ], completion: nil)
    }

    func sendWorkspaceRename(workspaceID: UUID, title: String) {
        sendRPCAsync(method: "workspace.rename", params: [
            "workspace_id": workspaceID.uuidString.lowercased(),
            "title": title,
        ], completion: nil)
    }

    func sendWorkspaceSetColor(workspaceID: UUID, color: String?) {
        sendRPCAsync(method: "workspace.set_color", params: [
            "workspace_id": workspaceID.uuidString.lowercased(),
            "color": color ?? "",
        ], completion: nil)
    }

    /// Incremental workspace RPCs added in PR 2 of the SSOT refactor. These
    /// let the mac push one field at a time to the daemon instead of
    /// re-sending the whole workspace list via `workspace.sync`, which is
    /// lossy (any omitted workspace gets deleted).

    func sendWorkspaceSetUnread(workspaceID: UUID, unreadCount: Int) {
        sendRPCAsync(method: "workspace.set_unread", params: [
            "workspace_id": workspaceID.uuidString.lowercased(),
            "unread_count": max(0, unreadCount),
        ], completion: nil)
    }

    func sendWorkspaceSetDirectory(workspaceID: UUID, directory: String) {
        sendRPCAsync(method: "workspace.set_directory", params: [
            "workspace_id": workspaceID.uuidString.lowercased(),
            "directory": directory,
        ], completion: nil)
    }

    func sendWorkspaceSetPreview(workspaceID: UUID, preview: String) {
        sendRPCAsync(method: "workspace.set_preview", params: [
            "workspace_id": workspaceID.uuidString.lowercased(),
            "preview": preview,
        ], completion: nil)
    }

    func sendWorkspaceSetPhase(workspaceID: UUID, phase: String) {
        sendRPCAsync(method: "workspace.set_phase", params: [
            "workspace_id": workspaceID.uuidString.lowercased(),
            "phase": phase,
        ], completion: nil)
    }

    func sendWorkspaceReorder(orderedIDs: [UUID]) {
        sendRPCAsync(method: "workspace.reorder", params: [
            "ordered_ids": orderedIDs.map { $0.uuidString.lowercased() },
        ], completion: nil)
    }

    func sendWorkspaceSelect(workspaceID: UUID) {
        sendRPCAsync(method: "workspace.select", params: [
            "workspace_id": workspaceID.uuidString.lowercased(),
        ], completion: nil)
    }

    func sendPaneSetTitle(workspaceID: UUID, paneID: String, title: String) {
        sendRPCAsync(method: "pane.set_title", params: [
            "workspace_id": workspaceID.uuidString.lowercased(),
            "pane_id": paneID,
            "title": title,
        ], completion: nil)
    }

    func sendPaneResize(workspaceID: UUID, paneID: String, ratio: Double) {
        sendRPCAsync(method: "pane.resize", params: [
            "workspace_id": workspaceID.uuidString.lowercased(),
            "pane_id": paneID,
            "ratio": max(0.05, min(0.95, ratio)),
        ], completion: nil)
    }

    func sendPaneFocus(workspaceID: UUID, paneID: String) {
        sendRPCAsync(method: "pane.focus", params: [
            "workspace_id": workspaceID.uuidString.lowercased(),
            "pane_id": paneID,
        ], completion: nil)
    }

    func sendPaneClose(workspaceID: UUID, paneID: String) {
        sendRPCAsync(method: "pane.close", params: [
            "workspace_id": workspaceID.uuidString.lowercased(),
            "pane_id": paneID,
        ], completion: nil)
    }

    // MARK: - Workspace history (PR 6 SSOT refactor)

    /// One entry in the daemon-side workspace history log.
    struct HistoryEntry {
        let seq: Int
        let workspaceID: String
        let eventType: String
        let payloadJSON: String
        let at: Date
    }

    /// Query the daemon's workspace history log. Pass `workspaceID` to
    /// filter to a single workspace's events; otherwise returns newest
    /// events across all workspaces. `beforeSeq` lets the caller paginate
    /// backwards.
    func fetchWorkspaceHistory(
        workspaceID: UUID? = nil,
        limit: Int = 100,
        beforeSeq: Int? = nil,
        completion: @escaping (Result<[HistoryEntry], Error>) -> Void
    ) {
        var params: [String: Any] = ["limit": max(1, min(limit, 1000))]
        if let workspaceID {
            params["workspace_id"] = workspaceID.uuidString.lowercased()
        }
        if let beforeSeq {
            params["before_seq"] = beforeSeq
        }
        sendRPCAsync(method: "workspace.history.list", params: params) { result in
            switch result {
            case .success(let resp):
                guard let ok = resp["ok"] as? Bool, ok,
                      let r = resp["result"] as? [String: Any],
                      let rawHistory = r["history"] as? [[String: Any]] else {
                    completion(.failure(NSError(domain: "cmux.daemon", code: -1)))
                    return
                }
                let entries: [HistoryEntry] = rawHistory.compactMap { row in
                    guard let seq = row["seq"] as? Int,
                          let wid = row["workspace_id"] as? String,
                          let etype = row["event_type"] as? String,
                          let payload = row["payload_json"] as? String,
                          let atMs = row["at"] as? Int64 else {
                        return nil
                    }
                    return HistoryEntry(
                        seq: seq,
                        workspaceID: wid,
                        eventType: etype,
                        payloadJSON: payload,
                        at: Date(timeIntervalSince1970: Double(atMs) / 1000)
                    )
                }
                completion(.success(entries))
            case .failure(let err):
                completion(.failure(err))
            }
        }
    }

    /// Erase every entry in the daemon-side history log. Surface as a
    /// Settings action "Clear workspace history".
    func clearWorkspaceHistory(completion: ((Bool) -> Void)? = nil) {
        sendRPCAsync(method: "workspace.history.clear", params: [:]) { result in
            switch result {
            case .success(let resp):
                let ok = (resp["ok"] as? Bool) ?? false
                completion?(ok)
            case .failure:
                completion?(false)
            }
        }
    }

    /// Send `workspace.create` to the daemon for a workspace the macOS app just
    /// created locally. The caller is expected to have already inserted the id
    /// into `pendingCreates` (via `markPendingCreate`) so the daemon's echo via
    /// `workspace.changed` does not spawn a duplicate. On RPC failure we drop
    /// the pending entry so a future daemon-authority push can apply.
    func sendWorkspaceCreate(workspaceID: UUID, title: String, directory: String) {
        sendRPCAsync(method: "workspace.create", params: [
            "id": workspaceID.uuidString.lowercased(),
            "title": title,
            "directory": directory,
        ]) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let resp):
                if let ok = resp["ok"] as? Bool, ok {
                    self.completePendingCreateRPC(workspaceID: workspaceID)
                    return
                }
                self.clearPendingCreate(workspaceID: workspaceID)
            case .failure:
                self.clearPendingCreate(workspaceID: workspaceID)
            }
        }
    }

    /// Send `workspace.close` to the daemon for a workspace the macOS app just
    /// closed locally. The caller is expected to have already inserted the id
    /// into `pendingDeletes` (via `markPendingDelete`).
    func sendWorkspaceClose(workspaceID: UUID) {
        sendRPCAsync(method: "workspace.close", params: [
            "workspace_id": workspaceID.uuidString.lowercased(),
        ], completion: nil)
    }

    private func performWorkspaceSync() {
        if let provider = workspaceSyncProvider, let params = provider() {
            sendWorkspaceSync(params)
        }
    }

    // MARK: - Public API: terminal subscribe (replaces DaemonTerminalBridge.start)

    /// Subscribe a mac surface to a terminal session. Multi-subscriber:
    /// a single session id may be displayed in multiple surfaces (split
    /// panes, workspaces referencing the same session, mac + iOS). Each
    /// surface gets its own attachment (daemon-side size constraint)
    /// and its own output handler (mac-side fan-out). The first binding
    /// for a session id opens the daemon-side `terminal.subscribe`;
    /// subsequent bindings ride the same subscription.
    func subscribeTerminal(
        surfaceID: UUID,
        sessionID: String,
        shellCommand: String,
        cols: Int,
        rows: Int,
        onOutput: @escaping (Data) -> Void,
        onDisconnect: @escaping (String?) -> Void,
        onViewSize: @escaping (_ cols: Int, _ rows: Int) -> Void = { _, _ in },
        onReady: @escaping () -> Void = {}
    ) {
        let attachmentID = "bridge-\(UUID().uuidString.prefix(8).lowercased())"
        let binding = TerminalSessionRegistry.Binding(
            sessionID: sessionID,
            surfaceID: surfaceID,
            attachmentID: attachmentID,
            onOutput: onOutput,
            onDisconnect: onDisconnect,
            onViewSize: onViewSize,
            onReady: onReady,
            phase: .attaching,
            cols: max(1, cols),
            rows: max(1, rows),
            shellCommand: shellCommand,
            lastOffset: 0,
            lastGridGeneration: 0
        )

        let result = TerminalSessionRegistry.shared.register(binding)
        let connected = stateLock.withLock { fd >= 0 }

        #if DEBUG
        dlog("blank.conn.subscribeTerminal sid=\(sessionID) surface=\(surfaceID.uuidString.prefix(8)) cols=\(cols) rows=\(rows) connected=\(connected) attachmentID=\(attachmentID) first=\(result.isFirstForSession)")
        #endif
        if connected {
            if result.isFirstForSession {
                // First mac surface viewing this session — open the
                // daemon-side subscription and attach.
                issueTerminalSubscribe(sessionID: sessionID)
            } else {
                // Additional surface for a session that mac already
                // subscribes to. Only attach (per-surface attachmentID
                // for resize coordination); don't re-subscribe output.
                issueSessionAttachOnly(sessionID: sessionID, surfaceID: surfaceID)
            }
        }
    }

    func unsubscribeTerminal(sessionID: String, surfaceID: UUID) {
        guard let result = TerminalSessionRegistry.shared.unregister(sessionID: sessionID, surfaceID: surfaceID) else { return }
        let connected = stateLock.withLock { fd >= 0 }
        if connected {
            sendRPCAsync(method: "session.detach", params: [
                "session_id": sessionID,
                "attachment_id": result.binding.attachmentID,
            ], completion: nil)
            if result.isLastForSession {
                sendRPCAsync(method: "terminal.unsubscribe", params: ["session_id": sessionID], completion: nil)
            }
        }
    }

    func writeToSession(sessionID: String, data: Data) {
        let writeID = Self.makeTerminalWriteID()
        let connected = stateLock.withLock { fd >= 0 }
        guard connected else {
            enqueueTerminalWrite(sessionID: sessionID, writeID: writeID, data: data, reason: "disconnected")
            connectAsync()
            return
        }
        sendTerminalWrite(sessionID: sessionID, writeID: writeID, data: data)
    }

    private static func makeTerminalWriteID() -> String {
        "mac-\(UUID().uuidString.lowercased())"
    }

    private func sendTerminalWrite(sessionID: String, writeID: String, data: Data) {
        sendRPCAsync(method: "terminal.write", params: [
            "session_id": sessionID,
            "write_id": writeID,
            "data": data.base64EncodedString(),
        ]) { [weak self] result in
            #if DEBUG
            switch result {
            case .success(let resp):
                let ok = (resp["ok"] as? Bool) ?? false
                dlog("blank.conn.terminal.write.result sid=\(sessionID) writeID=\(writeID) ok=\(ok)")
            case .failure(let error):
                dlog("blank.conn.terminal.write.result sid=\(sessionID) writeID=\(writeID) ok=0 error=\(error.localizedDescription)")
            }
            #endif
            guard case .failure(let error) = result,
                  Self.shouldRetryTerminalWrite(after: error) else {
                return
            }
            self?.enqueueTerminalWrite(sessionID: sessionID, writeID: writeID, data: data, reason: "write_failure")
            self?.connectAsync()
        }
    }

    private static func shouldRetryTerminalWrite(after error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == "DaemonConnection" else { return false }
        return nsError.code == -1 || nsError.code == -3 || nsError.code == -10
    }

    private func enqueueTerminalWrite(sessionID: String, writeID: String, data: Data, reason: String) {
        guard !data.isEmpty else { return }
        guard data.count <= Self.maxQueuedTerminalWriteBytes else {
            #if DEBUG
            dlog("blank.conn.queueWrite.drop reason=too_large sid=\(sessionID) writeID=\(writeID) bytes=\(data.count)")
            #endif
            return
        }

        stateLock.lock()
        while queuedTerminalWriteBytes + data.count > Self.maxQueuedTerminalWriteBytes,
              !queuedTerminalWrites.isEmpty {
            let removed = queuedTerminalWrites.removeFirst()
            queuedTerminalWriteBytes -= removed.data.count
        }
        queuedTerminalWrites.append(QueuedTerminalWrite(sessionID: sessionID, writeID: writeID, data: data))
        queuedTerminalWriteBytes += data.count
        let count = queuedTerminalWrites.count
        let bytes = queuedTerminalWriteBytes
        stateLock.unlock()

        #if DEBUG
        dlog("blank.conn.queueWrite.enqueue reason=\(reason) sid=\(sessionID) writeID=\(writeID) bytes=\(data.count) queued=\(count) queuedBytes=\(bytes)")
        #endif
    }

    private func flushQueuedTerminalWrites(for sessionID: String, reason: String) {
        stateLock.lock()
        var writes: [QueuedTerminalWrite] = []
        var remaining: [QueuedTerminalWrite] = []
        for write in queuedTerminalWrites {
            if write.sessionID == sessionID {
                writes.append(write)
                queuedTerminalWriteBytes -= write.data.count
            } else {
                remaining.append(write)
            }
        }
        queuedTerminalWrites = remaining
        stateLock.unlock()

        guard !writes.isEmpty else { return }
        #if DEBUG
        dlog("blank.conn.queueWrite.flush reason=\(reason) sid=\(sessionID) count=\(writes.count)")
        #endif
        for write in writes {
            sendTerminalWrite(sessionID: write.sessionID, writeID: write.writeID, data: write.data)
        }
    }

    func resizeSession(sessionID: String, surfaceID: UUID, cols: Int, rows: Int) {
        guard let binding = TerminalSessionRegistry.shared.binding(sessionID: sessionID, surfaceID: surfaceID) else { return }
        TerminalSessionRegistry.shared.updateSize(sessionID: sessionID, surfaceID: surfaceID, cols: max(1, cols), rows: max(1, rows))
        let connected = stateLock.withLock { fd >= 0 }
        guard connected else { return }
        sendRPCAsync(method: "session.resize", params: [
            "session_id": sessionID,
            "attachment_id": binding.attachmentID,
            "cols": max(1, cols),
            "rows": max(1, rows),
        ]) { [weak self] result in
            if case .success(let resp) = result,
               let ok = resp["ok"] as? Bool, ok,
               let r = resp["result"] as? [String: Any],
               let (ec, er, gen) = DaemonConnection.effectiveSizeFromResult(r) {
                #if DEBUG
                self?.debugRecordSessionStatusResult(
                    r,
                    fallbackSessionID: sessionID,
                    source: "session.resize",
                    localAttachmentID: binding.attachmentID
                )
                #endif
                self?.dispatchViewSize(sessionID: sessionID, cols: ec, rows: er, generation: gen)
            }
        }
    }

    private func issueTerminalSubscribe(sessionID: String) {
        guard let binding = TerminalSessionRegistry.shared.firstBinding(for: sessionID) else { return }
        issueTerminalAttachAndSubscribe(
            sessionID: sessionID,
            surfaceID: binding.surfaceID,
            attachmentID: binding.attachmentID,
            cols: binding.cols,
            rows: binding.rows,
            shellCommand: binding.shellCommand,
            lastOffset: binding.lastOffset,
            allowOpenFallback: true
        )
    }

    private func issueTerminalAttachAndSubscribe(
        sessionID: String,
        surfaceID: UUID,
        attachmentID: String,
        cols: Int,
        rows: Int,
        shellCommand: String,
        lastOffset: UInt64,
        allowOpenFallback: Bool
    ) {
        #if DEBUG
        dlog("blank.conn.issueSubscribe sid=\(sessionID) cols=\(cols) rows=\(rows) attachFirst=1 allowOpenFallback=\(allowOpenFallback ? 1 : 0)")
        #endif
        sendRPCAsync(method: "session.attach", params: [
            "session_id": sessionID,
            "attachment_id": attachmentID,
            "cols": cols,
            "rows": rows,
        ]) { [weak self] attachResult in
            guard let self else { return }
            #if DEBUG
            let attachOK: Bool = {
                if case .success(let r) = attachResult, let ok = r["ok"] as? Bool { return ok }
                return false
            }()
            dlog("blank.conn.session.attach.result sid=\(sessionID) attachmentID=\(attachmentID) ok=\(attachOK) mode=primary")
            #endif
            if case .success(let r) = attachResult,
               let ok = r["ok"] as? Bool, ok,
               let result = r["result"] as? [String: Any] {
                #if DEBUG
                self.debugRecordSessionStatusResult(
                    result,
                    fallbackSessionID: sessionID,
                    source: "session.attach",
                    localAttachmentID: attachmentID
                )
                #endif
                if let (ec, er, gen) = DaemonConnection.effectiveSizeFromResult(result) {
                    self.dispatchViewSize(sessionID: sessionID, cols: ec, rows: er, generation: gen)
                }
                self.issueTerminalSubscribeAfterAttach(
                    sessionID: sessionID,
                    surfaceID: surfaceID,
                    lastOffset: lastOffset
                )
                return
            }

            guard allowOpenFallback else { return }
            self.openTerminalThenSubscribe(
                sessionID: sessionID,
                surfaceID: surfaceID,
                attachmentID: attachmentID,
                cols: cols,
                rows: rows,
                shellCommand: shellCommand,
                lastOffset: lastOffset
            )
        }
    }

    private func openTerminalThenSubscribe(
        sessionID: String,
        surfaceID: UUID,
        attachmentID: String,
        cols: Int,
        rows: Int,
        shellCommand: String,
        lastOffset: UInt64
    ) {
        sendRPCAsync(method: "terminal.open", params: [
            "session_id": sessionID,
            "command": shellCommand,
            "cols": cols,
            "rows": rows,
        ]) { [weak self] result in
            guard let self else { return }
            #if DEBUG
            let openOK: Bool = {
                if case .success(let resp) = result, let ok = resp["ok"] as? Bool { return ok }
                return false
            }()
            dlog("blank.conn.terminal.open.result sid=\(sessionID) ok=\(openOK)")
            #endif
            if case .success(let resp) = result,
               let ok = resp["ok"] as? Bool, ok,
               let r = resp["result"] as? [String: Any] {
                #if DEBUG
                self.debugRecordSessionStatusResult(
                    r,
                    fallbackSessionID: sessionID,
                    source: "terminal.open",
                    localAttachmentID: nil
                )
                #endif
                if let (ec, er, gen) = DaemonConnection.effectiveSizeFromResult(r) {
                    self.dispatchViewSize(sessionID: sessionID, cols: ec, rows: er, generation: gen)
                }
                if let bootstrap = r["attachment_id"] as? String {
                    self.sendRPCAsync(method: "session.detach", params: [
                        "session_id": sessionID,
                        "attachment_id": bootstrap,
                    ], completion: nil)
                }
            }
            self.issueTerminalAttachAndSubscribe(
                sessionID: sessionID,
                surfaceID: surfaceID,
                attachmentID: attachmentID,
                cols: cols,
                rows: rows,
                shellCommand: shellCommand,
                lastOffset: lastOffset,
                allowOpenFallback: false
            )
        }
    }

    private func issueTerminalSubscribeAfterAttach(
        sessionID: String,
        surfaceID: UUID,
        lastOffset: UInt64
    ) {
        sendRPCAsync(method: "terminal.subscribe", params: [
            "session_id": sessionID,
            "offset": lastOffset,
        ]) { [weak self] subResult in
            guard let self else { return }
            #if DEBUG
            var subDataLen = 0
            var subOK = false
            if case .success(let r) = subResult, let ok = r["ok"] as? Bool, ok {
                subOK = true
                if let result = r["result"] as? [String: Any],
                   let base64 = result["data"] as? String,
                   let data = Data(base64Encoded: base64) {
                    subDataLen = data.count
                }
            }
            dlog("blank.conn.terminal.subscribe.result sid=\(sessionID) ok=\(subOK) dataBytes=\(subDataLen)")
            #endif
            guard case .success(let r) = subResult,
                  let ok = r["ok"] as? Bool, ok,
                  let result = r["result"] as? [String: Any] else {
                return
            }

            let offset = DaemonConnection.readUInt64(result["offset"])
            let baseOffset = DaemonConnection.readUInt64(result["base_offset"])
            if let base64 = result["data"] as? String,
               let data = Data(base64Encoded: base64), !data.isEmpty {
                self.deliverTerminalOutput(sessionID: sessionID, data: data, offset: offset, baseOffset: baseOffset)
            } else if let offset {
                TerminalSessionRegistry.shared.updateLastOffset(sessionID: sessionID, offset: offset)
            }
            let onReady = TerminalSessionRegistry.shared.markLive(sessionID: sessionID, surfaceID: surfaceID)
            self.flushQueuedTerminalWrites(for: sessionID, reason: "terminal.subscribe")
            onReady?()
        }
    }

    /// Forward a `session.view_size` delivery to this session's
    /// subscriber, ordered by `grid_generation`. Stale updates (where
    /// `grid_generation <= last_seen`) are dropped so an out-of-order
    /// RPC response can't override a newer broadcast (or vice versa).
    /// Generation/monotonicity enforcement now lives in the registry.
    private func dispatchViewSize(sessionID: String, cols: Int, rows: Int, generation: UInt64) {
        TerminalSessionRegistry.shared.deliverViewSize(sessionID: sessionID, cols: cols, rows: rows, generation: generation)
    }

    /// Attach an additional surface to an already-subscribed session.
    /// Called when a second (or later) mac surface is rendering a
    /// session the mac already subscribes to. Only fires `session.attach`
    /// with this surface's own attachmentID — the `terminal.subscribe`
    /// is shared with the first binding.
    private func issueSessionAttachOnly(sessionID: String, surfaceID: UUID) {
        guard let binding = TerminalSessionRegistry.shared.binding(sessionID: sessionID, surfaceID: surfaceID) else { return }
        let attachmentID = binding.attachmentID
        let cols = binding.cols
        let rows = binding.rows
        sendRPCAsync(method: "session.attach", params: [
            "session_id": sessionID,
            "attachment_id": attachmentID,
            "cols": cols,
            "rows": rows,
        ]) { [weak self] attachResult in
            #if DEBUG
            let attachOK: Bool = {
                if case .success(let r) = attachResult, let ok = r["ok"] as? Bool { return ok }
                return false
            }()
            dlog("blank.conn.session.attach.result sid=\(sessionID) attachmentID=\(attachmentID) ok=\(attachOK) mode=addl")
            #endif
            if case .success(let r) = attachResult,
               let ok = r["ok"] as? Bool, ok,
               let result = r["result"] as? [String: Any] {
                #if DEBUG
                self?.debugRecordSessionStatusResult(
                    result,
                    fallbackSessionID: sessionID,
                    source: "session.attach.addl",
                    localAttachmentID: attachmentID
                )
                #endif
                let onReady = TerminalSessionRegistry.shared.markLive(sessionID: sessionID, surfaceID: surfaceID)
                self?.flushQueuedTerminalWrites(for: sessionID, reason: "session.attach.addl")
                onReady?()
                if let (ec, er, gen) = DaemonConnection.effectiveSizeFromResult(result) {
                    self?.dispatchViewSize(sessionID: sessionID, cols: ec, rows: er, generation: gen)
                }
            }
        }
    }

    /// Read view-size fields out of a `session.view_size` event frame
    /// where `cols` / `rows` / `grid_generation` live at the top level.
    /// Tolerates Int and UInt64 decode shapes. Returns nil when cols/rows
    /// are missing; generation defaults to 0 ("not reported").
    private static func viewSizeFields(_ dict: [String: Any]) -> (cols: Int, rows: Int, generation: UInt64)? {
        guard let cols = readInt(dict["cols"]), cols > 0,
              let rows = readInt(dict["rows"]), rows > 0 else {
            return nil
        }
        let gen = readUInt64(dict["grid_generation"]) ?? 0
        return (cols, rows, gen)
    }

    /// Read `effective_cols` / `effective_rows` / `grid_generation` from
    /// an RPC response's `result` object. Used when the daemon inlines
    /// the current authoritative size in a resize/attach response so
    /// the client can converge on the first RPC without waiting for
    /// the subsequent broadcast.
    private static func effectiveSizeFromResult(_ dict: [String: Any]) -> (cols: Int, rows: Int, generation: UInt64)? {
        guard let cols = readInt(dict["effective_cols"]), cols > 0,
              let rows = readInt(dict["effective_rows"]), rows > 0 else {
            return nil
        }
        let gen = readUInt64(dict["grid_generation"]) ?? 0
        return (cols, rows, gen)
    }

    #if DEBUG
    private static func attachmentSnapshots(from value: Any?) -> [TerminalSessionRegistry.AttachmentStatusSnapshot] {
        guard let rawItems = value as? [Any] else { return [] }
        return rawItems.compactMap { item in
            guard let dict = item as? [String: Any],
                  let attachmentID = dict["attachment_id"] as? String,
                  let cols = readInt(dict["cols"]),
                  let rows = readInt(dict["rows"]) else {
                return nil
            }
            return TerminalSessionRegistry.AttachmentStatusSnapshot(
                attachmentID: attachmentID,
                cols: cols,
                rows: rows
            )
        }
    }

    private static func debugAttachmentSummary(_ attachments: [TerminalSessionRegistry.AttachmentStatusSnapshot]) -> String {
        guard !attachments.isEmpty else { return "[]" }
        return "[" + attachments.map { "\($0.attachmentID):\($0.cols)x\($0.rows)" }.joined(separator: ",") + "]"
    }

    private func debugRecordSessionStatusResult(
        _ result: [String: Any],
        fallbackSessionID: String,
        source: String,
        localAttachmentID: String?
    ) {
        let sessionID = result["session_id"] as? String ?? fallbackSessionID
        let attachments = Self.attachmentSnapshots(from: result["attachments"])
        TerminalSessionRegistry.shared.updateAttachmentSnapshot(
            sessionID: sessionID,
            attachments: attachments
        )
        let effective = Self.effectiveSizeFromResult(result)
        dlog(
            "resize.status source=\(source) session=\(String(sessionID.prefix(12))) " +
            "effective=\(effective.map { "\($0.cols)x\($0.rows)" } ?? "nil") " +
            "gen=\(effective.map { "\($0.generation)" } ?? "nil") " +
            "localAttachment=\(localAttachmentID ?? "nil") " +
            "attachments=\(Self.debugAttachmentSummary(attachments))"
        )
    }

    private func debugRefreshSessionStatusIfNeeded(
        sessionID: String,
        effectiveCols: Int,
        effectiveRows: Int,
        generation: UInt64
    ) {
        guard TerminalSessionRegistry.shared.shouldRefreshAttachmentSnapshot(
            sessionID: sessionID,
            effectiveCols: effectiveCols,
            effectiveRows: effectiveRows
        ) else {
            return
        }

        debugStatusProbeLock.lock()
        if debugStatusProbeInFlight.contains(sessionID) {
            debugStatusProbeLock.unlock()
            return
        }
        debugStatusProbeInFlight.insert(sessionID)
        debugStatusProbeLock.unlock()

        sendRPCAsync(method: "session.status", params: [
            "session_id": sessionID,
        ]) { [weak self] result in
            guard let self else { return }
            self.debugStatusProbeLock.lock()
            self.debugStatusProbeInFlight.remove(sessionID)
            self.debugStatusProbeLock.unlock()

            guard case .success(let resp) = result,
                  let ok = resp["ok"] as? Bool, ok,
                  let status = resp["result"] as? [String: Any] else {
                dlog(
                    "resize.status source=session.status.push session=\(String(sessionID.prefix(12))) " +
                    "effective=\(effectiveCols)x\(effectiveRows) gen=\(generation) ok=0"
                )
                return
            }
            self.debugRecordSessionStatusResult(
                status,
                fallbackSessionID: sessionID,
                source: "session.status.push",
                localAttachmentID: nil
            )
        }
    }
    #endif

    private static func readInt(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let u = value as? UInt64 { return Int(u) }
        if let n = value as? NSNumber { return n.intValue }
        return nil
    }

    private static func readUInt64(_ value: Any?) -> UInt64? {
        if let u = value as? UInt64 { return u }
        if let i = value as? Int, i >= 0 { return UInt64(i) }
        if let n = value as? NSNumber { return n.uint64Value }
        return nil
    }

    private func deliverTerminalOutput(sessionID: String, data: Data, offset: UInt64?, baseOffset: UInt64?) {
        #if DEBUG
        if TerminalSessionRegistry.shared.firstBinding(for: sessionID) == nil {
            dlog("blank.conn.deliverOutput.NO_HANDLER sid=\(sessionID) bytes=\(data.count)")
        }
        #endif
        TerminalSessionRegistry.shared.deliverOutput(sessionID: sessionID, data: data, offset: offset, baseOffset: baseOffset)
    }

    // MARK: - RPC core

    @discardableResult
    private func nextID() -> Int {
        stateLock.lock(); defer { stateLock.unlock() }
        nextRpcID += 1
        return nextRpcID
    }

    private func sendRPCAsync(
        method: String,
        params: [String: Any],
        completion: (((Result<[String: Any], Error>)) -> Void)?
    ) {
        let id = nextID()
        if let completion {
            stateLock.lock()
            pending[id] = completion
            stateLock.unlock()
        }

        writeQueue.async { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let fd = self.fd
            self.stateLock.unlock()
            guard fd >= 0 else {
                self.fulfill(id: id, with: .failure(NSError(domain: "DaemonConnection", code: -1)))
                self.connectAsync()
                return
            }
            let payload: [String: Any] = ["id": id, "method": method, "params": params]
            guard var data = try? JSONSerialization.data(withJSONObject: payload) else {
                self.fulfill(id: id, with: .failure(NSError(domain: "DaemonConnection", code: -2)))
                return
            }
            data.append(0x0A)
            if !Self.writeAll(fd: fd, data: data) {
                #if DEBUG
                dlog("blank.conn.write.failed fd=\(fd) method=\(method) id=\(id) errno=\(errno)")
                #endif
                self.fulfill(id: id, with: .failure(NSError(domain: "DaemonConnection", code: -3)))
                self.handleSocketFailure(failedFD: fd)
            }
        }
    }

    private static func writeAll(fd: Int32, data: Data) -> Bool {
        data.withUnsafeBytes { rawBuffer -> Bool in
            guard let baseAddress = rawBuffer.baseAddress else { return true }
            var written = 0
            while written < rawBuffer.count {
                let n = Darwin.write(fd, baseAddress.advanced(by: written), rawBuffer.count - written)
                if n > 0 {
                    written += n
                    continue
                }
                if n < 0, errno == EINTR {
                    continue
                }
                return false
            }
            return true
        }
    }

    private func fulfill(id: Int, with result: Result<[String: Any], Error>) {
        stateLock.lock()
        let cb = pending.removeValue(forKey: id)
        stateLock.unlock()
        cb?(result)
    }

    // MARK: - Connection lifecycle

    private func connectAsync() {
        stateLock.lock()
        guard fd < 0, !connecting else { stateLock.unlock(); return }
        let timer = reconnectTimer
        reconnectTimer = nil
        connecting = true
        stateLock.unlock()
        timer?.cancel()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.connectBlocking()
        }
    }

    private func connectBlocking() {
        let newFD = openSocket()
        guard newFD >= 0 else {
            stateLock.lock(); connecting = false; stateLock.unlock()
            scheduleReconnect()
            return
        }

        // Send hello synchronously and verify capabilities before exposing the fd.
        guard performHello(fd: newFD) else {
            Darwin.close(newFD)
            stateLock.lock(); connecting = false; stateLock.unlock()
            scheduleReconnect()
            return
        }

        stateLock.lock()
        fd = newFD
        connecting = false
        let needsWorkspaceSubscribe = !workspaceSubscribed
        let provider = workspaceSyncProvider
        stateLock.unlock()
        let sessions = TerminalSessionRegistry.shared.allSessionIDs()

        // Start reader thread
        let reader = Thread { [weak self] in self?.readerLoop(fd: newFD) }
        reader.name = "cmux.daemon-connection.reader"
        reader.qualityOfService = .userInteractive
        reader.start()

        // Re-subscribe workspace
        if needsWorkspaceSubscribe {
            sendRPCAsync(method: "workspace.subscribe", params: [:]) { [weak self] _ in
                self?.stateLock.lock()
                self?.workspaceSubscribed = true
                self?.stateLock.unlock()
            }
        }

        // Re-subscribe every terminal we know about
        for sid in sessions {
            issueTerminalSubscribe(sessionID: sid)
        }

        // Push current workspace snapshot
        if let provider, let params = provider() {
            sendWorkspaceSync(params)
        }
    }

    private func openSocket() -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathSize = MemoryLayout.size(ofValue: addr.sun_path)
        socketPath.withCString { cstr in
            _ = memcpy(&addr.sun_path, cstr, min(Int(strlen(cstr)), pathSize - 1))
        }
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(fd, sockaddrPtr, addrLen)
            }
        }
        if result != 0 {
            Darwin.close(fd)
            return -1
        }
        var sendTimeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }

    /// Send hello synchronously on a freshly opened fd, before reader thread starts.
    /// Returns true if the server reports all required capabilities.
    private func performHello(fd: Int32) -> Bool {
        let payload: [String: Any] = [
            "id": 0,
            "method": "hello",
            "params": ["client": "cmux-macos", "version": 1],
        ]
        guard var data = try? JSONSerialization.data(withJSONObject: payload) else { return false }
        data.append(0x0A)
        guard Self.writeAll(fd: fd, data: data) else { return false }

        var accumulated = Data()
        var buf = [UInt8](repeating: 0, count: 8192)
        var rcv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &rcv, socklen_t(MemoryLayout<timeval>.size))
        while !accumulated.contains(0x0A) {
            let r = Darwin.read(fd, &buf, buf.count)
            if r <= 0 { return false }
            accumulated.append(contentsOf: buf[0..<r])
        }
        // Reset to no recv timeout for the reader loop (blocking read).
        var noTimeout = timeval(tv_sec: 0, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &noTimeout, socklen_t(MemoryLayout<timeval>.size))

        guard let nlIdx = accumulated.firstIndex(of: 0x0A),
              let json = try? JSONSerialization.jsonObject(with: accumulated[..<nlIdx]) as? [String: Any],
              let ok = json["ok"] as? Bool, ok,
              let result = json["result"] as? [String: Any] else {
            return false
        }
        let caps = (result["capabilities"] as? [String]).map(Set.init) ?? []
        let missing = DaemonConnection.requiredCapabilities.subtracting(caps)
        if !missing.isEmpty {
            NSLog("📱 DaemonConnection: missing required capabilities: %@", missing.joined(separator: ","))
            return false
        }
        return true
    }

    private func handleSocketFailure(failedFD: Int32) {
        stateLock.lock()
        guard fd == failedFD else {
            stateLock.unlock()
            Darwin.close(failedFD)
            #if DEBUG
            dlog("blank.conn.handleSocketFailure.ignore staleFD=\(failedFD)")
            #endif
            return
        }
        if fd >= 0 { Darwin.close(fd); fd = -1 }
        workspaceSubscribed = false
        // Fail all pending RPCs
        let pendingCopy = pending
        pending.removeAll()
        stateLock.unlock()
        for cb in pendingCopy.values {
            cb(.failure(NSError(domain: "DaemonConnection", code: -10)))
        }
        // DO NOT drain the registry on transport disconnect. Bindings
        // must survive so `connectBlocking`'s reconnect loop can
        // iterate `allSessionIDs()` and re-issue subscribe for each.
        // Draining fires each binding's onDisconnect → bridge.stop() →
        // evicted=true, which was permanent (no un-evict path). Result:
        // every daemon reload broke typing in every terminal until the
        // user reopened the tab. Shell-EOF (per-sid) still uses
        // `deliverDisconnect` below, which is the one legitimate path
        // that should remove a binding.
        #if DEBUG
        let surviving = TerminalSessionRegistry.shared.allSessionIDs().count
        dlog("blank.conn.handleSocketFailure survivingBindings=\(surviving) willReconnect=1")
        #endif
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        stateLock.lock()
        guard fd < 0, !connecting else {
            stateLock.unlock()
            return
        }
        reconnectTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
        reconnectTimer = timer
        timer.setEventHandler { [weak self, weak timer] in
            guard let self else { return }
            self.stateLock.lock()
            if let timer, self.reconnectTimer === timer {
                self.reconnectTimer = nil
            }
            let shouldConnect = self.fd < 0 && !self.connecting
            self.stateLock.unlock()
            if shouldConnect {
                self.connectAsync()
            }
        }
        timer.schedule(deadline: .now() + 1)
        timer.resume()
        stateLock.unlock()
    }

    // MARK: - Reader thread

    private func readerLoop(fd: Int32) {
        var accumulated = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = Darwin.read(fd, &buf, buf.count)
            if n < 0 {
                let err = errno
                if err == EINTR || err == EAGAIN || err == EWOULDBLOCK {
                    continue
                }
                #if DEBUG
                dlog("blank.conn.reader.error fd=\(fd) errno=\(err)")
                #endif
                handleSocketFailure(failedFD: fd)
                return
            }
            if n == 0 {
                #if DEBUG
                dlog("blank.conn.reader.eof fd=\(fd)")
                #endif
                handleSocketFailure(failedFD: fd)
                return
            }
            accumulated.append(contentsOf: buf[0..<n])
            while let nlIdx = accumulated.firstIndex(of: 0x0A) {
                let line = accumulated[accumulated.startIndex..<nlIdx]
                accumulated.removeSubrange(accumulated.startIndex...nlIdx)
                guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    continue
                }
                handleIncoming(obj)
            }
        }
    }

    private func handleIncoming(_ obj: [String: Any]) {
        if let event = obj["event"] as? String {
            handleEvent(event, obj)
            return
        }
        if let id = obj["id"] as? Int {
            stateLock.lock()
            let cb = pending.removeValue(forKey: id)
            stateLock.unlock()
            cb?(.success(obj))
        }
    }

    private func handleEvent(_ event: String, _ obj: [String: Any]) {
        switch event {
        case "terminal.output":
            // Daemon emits event fields at the top level of the frame
            // (see session_service.pushOneSubscriber and the integration
            // tests in daemon/remote/zig/tests/integration.zig which
            // read session_id/data/offset directly off the object).
            guard let sid = obj["session_id"] as? String else { return }
            let offset = Self.readUInt64(obj["offset"])
            let baseOffset = Self.readUInt64(obj["base_offset"])
            if let base64 = obj["data"] as? String,
               let data = Data(base64Encoded: base64), !data.isEmpty {
                deliverTerminalOutput(sessionID: sid, data: data, offset: offset, baseOffset: baseOffset)
            } else if let offset {
                TerminalSessionRegistry.shared.updateLastOffset(sessionID: sid, offset: offset)
            }
            if let eof = obj["eof"] as? Bool, eof {
                TerminalSessionRegistry.shared.deliverDisconnect(sessionID: sid, reason: nil)
            }
        case "session.view_size":
            // Top-level cols/rows. Daemon broadcasts unconditionally on
            // every attach/resize/detach so clients always converge on
            // the current authoritative render grid.
            guard let sid = obj["session_id"] as? String else { return }
            if let (cols, rows, gen) = DaemonConnection.viewSizeFields(obj) {
                #if DEBUG
                dlog(
                    "resize.push session=\(String(sid.prefix(12))) effective=\(cols)x\(rows) " +
                    "gen=\(gen) attachments=\(TerminalSessionRegistry.shared.debugAttachmentSummary(sessionID: sid))"
                )
                debugRefreshSessionStatusIfNeeded(
                    sessionID: sid,
                    effectiveCols: cols,
                    effectiveRows: rows,
                    generation: gen
                )
                #endif
                dispatchViewSize(sessionID: sid, cols: cols, rows: rows, generation: gen)
            }
        case "workspace.changed":
            guard let result = obj["result"] as? [String: Any] else { return }
            stateLock.lock()
            let handler = workspaceChangedHandler
            stateLock.unlock()
            handler?(result)
        default:
            break
        }
    }
}

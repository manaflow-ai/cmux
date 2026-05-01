import Foundation
#if DEBUG
import Bonsplit
#endif

struct DaemonInitialWriteGate {
    let enabled: Bool
    private(set) var isReady = false

    var shouldQueueWrites: Bool {
        enabled && !isReady
    }

    mutating func takeWritesForAssignedSession(_ pendingWrites: inout [Data]) -> (writes: [Data], queuedCount: Int) {
        let ready = markReadyAndTakeWrites(&pendingWrites)
        return (ready.writes, 0)
    }

    mutating func takeWritesAfterOutput(_ pendingWrites: inout [Data], outputIsEmpty: Bool) -> (writes: [Data], becameReady: Bool) {
        guard shouldQueueWrites, !outputIsEmpty else {
            return ([], false)
        }
        return takeWritesAfterReady(&pendingWrites)
    }

    mutating func takeWritesAfterReady(_ pendingWrites: inout [Data]) -> (writes: [Data], becameReady: Bool) {
        guard shouldQueueWrites else {
            return ([], false)
        }
        return markReadyAndTakeWrites(&pendingWrites)
    }

    private mutating func markReadyAndTakeWrites(_ pendingWrites: inout [Data]) -> (writes: [Data], becameReady: Bool) {
        let becameReady = enabled && !isReady
        isReady = true
        let writes = pendingWrites
        pendingWrites = []
        return (writes, becameReady)
    }
}

/// Thin facade preserving the old per-surface bridge API while routing all
/// socket I/O through the single shared `DaemonConnection`. Creates no socket
/// of its own.
///
/// The bridge can be constructed with a nil `sessionID` (daemon hasn't minted
/// one yet via `workspace.open_pane`). Writes and `start(cols:rows:)` calls
/// are buffered until `assignSessionID(_:)` lands, at which point the pending
/// subscription fires and buffered writes flush to the PTY in order. Writes do
/// not wait for scrollback subscription readiness; shell PTYs already accept
/// input before the first prompt paints, and delaying there can drop automated
/// split/setup commands behind a stuck initial-output gate.
final class DaemonTerminalBridge: @unchecked Sendable {
    private(set) var sessionID: String?
    /// Stable UUID of the mac `TerminalSurface` that owns this bridge.
    /// Passed to every daemon-side subscribe/resize/unsubscribe call so
    /// the `TerminalSessionRegistry` can enforce one-surface-per-session
    /// (and evict stale owners cleanly when a new surface claims the
    /// same session id).
    let surfaceID: UUID
    /// True once the bridge knows its daemon session id is never coming
    /// (openPane gave up after retries). The pane is stuck in Manual IO
    /// mode without a daemon session; treat buffered writes as dropped
    /// and unblock `workspace.sync` (which defers while any bridge is
    /// pending) so the rest of the app keeps syncing.
    private(set) var bootstrapFailed = false
    private let shellCommand: String
    private var started = false
    private var subscribed = false
    /// Set to true when the registry evicts this bridge's binding
    /// (another surface claimed the same sessionID) or the underlying
    /// session is closed. Writes after eviction are dropped at this
    /// layer so a captured Ghostty write-callback pointer can't push
    /// bytes to the wrong session. Structural guarantee, not a race.
    private var evicted = false
    private let lock = NSLock()
    private var pendingStart: (cols: Int, rows: Int)?
    private var pendingWrites: [Data] = []
    private var pendingResize: (cols: Int, rows: Int)?
    private var initialWriteGate: DaemonInitialWriteGate

    var onOutput: ((_ data: Data) -> Void)?
    var onDisconnect: ((_ error: String?) -> Void)?
    /// Authoritative `session.view_size` delivery from the daemon.
    var onViewSize: ((_ cols: Int, _ rows: Int) -> Void)?

    init(surfaceID: UUID, sessionID: String?, shellCommand: String) {
        self.surfaceID = surfaceID
        self.sessionID = sessionID
        self.shellCommand = shellCommand
        self.initialWriteGate = DaemonInitialWriteGate(enabled: sessionID == nil)
    }

    deinit { stopInternal() }

    /// Mark the bridge as permanently unable to bootstrap. Called when
    /// `workspace.open_pane` exhausts its retries. Flushes the pending
    /// queues (writes/resize) — those bytes have nowhere to go.
    func markBootstrapFailed() {
        lock.lock()
        guard !bootstrapFailed, sessionID == nil else { lock.unlock(); return }
        bootstrapFailed = true
        pendingStart = nil
        pendingResize = nil
        pendingWrites.removeAll()
        lock.unlock()
    }

    /// Populate the daemon-minted session id. Flushes any buffered
    /// `start`/`writeToSession`/`resize` calls in order.
    func assignSessionID(_ sid: String) {
        lock.lock()
        guard sessionID == nil else {
            let existing = sessionID ?? "nil"
            lock.unlock()
            #if DEBUG
            dlog("blank.bridge.assignSessionID.duplicate sid=\(sid) existing=\(existing)")
            #endif
            return
        }
        sessionID = sid
        let shouldStart = started && !subscribed
        let pendingStart = self.pendingStart
        let pendingResize = self.pendingResize
        let assignedWrites = initialWriteGate.takeWritesForAssignedSession(&self.pendingWrites)
        let pendingWrites = assignedWrites.writes
        let queuedWriteCount = assignedWrites.queuedCount
        self.pendingStart = nil
        self.pendingResize = nil
        lock.unlock()
        #if DEBUG
        dlog("blank.bridge.assignSessionID sid=\(sid) shouldStart=\(shouldStart) pendingStart=\(pendingStart.map { "\($0.cols)x\($0.rows)" } ?? "nil") pendingResize=\(pendingResize.map { "\($0.cols)x\($0.rows)" } ?? "nil") pendingWrites=\(pendingWrites.count) queuedUntilOutput=\(queuedWriteCount)")
        #endif

        if shouldStart, let ps = pendingStart {
            subscribe(cols: ps.cols, rows: ps.rows)
        }
        if let pr = pendingResize {
            DaemonConnection.shared.resizeSession(sessionID: sid, surfaceID: surfaceID, cols: pr.cols, rows: pr.rows)
        }
        for data in pendingWrites {
            DaemonConnection.shared.writeToSession(sessionID: sid, data: data)
        }
    }

    func start(cols: Int, rows: Int) {
        lock.lock()
        guard !started else {
            lock.unlock()
            #if DEBUG
            dlog("blank.bridge.start.duplicate cols=\(cols) rows=\(rows)")
            #endif
            return
        }
        started = true
        guard let sid = sessionID else {
            pendingStart = (cols, rows)
            lock.unlock()
            #if DEBUG
            dlog("blank.bridge.start.pending cols=\(cols) rows=\(rows)")
            #endif
            return
        }
        subscribed = true
        lock.unlock()
        #if DEBUG
        dlog("blank.bridge.start.immediate sid=\(sid) cols=\(cols) rows=\(rows)")
        #endif
        subscribe(sessionID: sid, cols: cols, rows: rows)
    }

    private func subscribe(cols: Int, rows: Int) {
        guard let sid = sessionID else { return }
        lock.lock()
        subscribed = true
        lock.unlock()
        subscribe(sessionID: sid, cols: cols, rows: rows)
    }

    private func subscribe(sessionID: String, cols: Int, rows: Int) {
        DaemonConnection.shared.subscribeTerminal(
            surfaceID: surfaceID,
            sessionID: sessionID,
            shellCommand: shellCommand,
            cols: cols,
            rows: rows,
            onOutput: { [weak self] data in
                self?.handleDaemonOutput(data, sessionID: sessionID)
            },
            onDisconnect: { [weak self] err in self?.onDisconnect?(err) },
            onViewSize: { [weak self] c, r in self?.onViewSize?(c, r) },
            onReady: { [weak self] in self?.handleDaemonReady(sessionID: sessionID) }
        )
    }

    private func handleDaemonReady(sessionID: String) {
        let writesToFlush: [Data]
        lock.lock()
        let flushed = initialWriteGate.takeWritesAfterReady(&pendingWrites)
        writesToFlush = flushed.writes
        lock.unlock()

        #if DEBUG
        if !writesToFlush.isEmpty {
            dlog("blank.bridge.subscribeReady.flush sid=\(sessionID) pendingWrites=\(writesToFlush.count)")
        }
        #endif

        for pending in writesToFlush {
            DaemonConnection.shared.writeToSession(sessionID: sessionID, data: pending)
        }
    }

    private func handleDaemonOutput(_ data: Data, sessionID: String) {
        let writesToFlush: [Data]
        let didMarkInitialOutputReady: Bool
        lock.lock()
        let flushed = initialWriteGate.takeWritesAfterOutput(&pendingWrites, outputIsEmpty: data.isEmpty)
        writesToFlush = flushed.writes
        didMarkInitialOutputReady = flushed.becameReady
        lock.unlock()

        #if DEBUG
        if !writesToFlush.isEmpty {
            dlog("blank.bridge.initialOutput.flush sid=\(sessionID) bytes=\(data.count) pendingWrites=\(writesToFlush.count)")
        } else if didMarkInitialOutputReady {
            dlog("blank.bridge.initialOutput.ready sid=\(sessionID) bytes=\(data.count)")
        }
        #endif

        onOutput?(data)

        for pending in writesToFlush {
            DaemonConnection.shared.writeToSession(sessionID: sessionID, data: pending)
        }
    }

    func stop() { stopInternal() }

    private func stopInternal() {
        lock.lock()
        let wasStarted = started
        let wasSubscribed = subscribed
        let sid = sessionID
        started = false
        subscribed = false
        evicted = true
        pendingStart = nil
        pendingResize = nil
        pendingWrites.removeAll()
        lock.unlock()
        guard wasStarted, wasSubscribed, let sid else { return }
        DaemonConnection.shared.unsubscribeTerminal(sessionID: sid, surfaceID: surfaceID)
    }

    func writeToSession(_ data: Data) {
        lock.lock()
        if evicted {
            lock.unlock()
            #if DEBUG
            dlog("blank.bridge.write.dropped reason=stopped surface=\(surfaceID.uuidString.prefix(8)) sid=\(sessionID ?? "nil") bytes=\(data.count)")
            #endif
            return
        }
        if let sid = sessionID {
            if initialWriteGate.shouldQueueWrites {
                pendingWrites.append(data)
                let pendingWriteCount = pendingWrites.count
                lock.unlock()
                #if DEBUG
                dlog("blank.bridge.write.queued_until_initial_output surface=\(surfaceID.uuidString.prefix(8)) sid=\(sid) bytes=\(data.count) pendingWrites=\(pendingWriteCount)")
                #endif
                return
            }
            lock.unlock()
            DaemonConnection.shared.writeToSession(sessionID: sid, data: data)
            return
        }
        if bootstrapFailed {
            lock.unlock()
            return
        }
        pendingWrites.append(data)
        lock.unlock()
    }

    func resize(cols: Int, rows: Int) {
        lock.lock()
        if evicted {
            lock.unlock()
            return
        }
        if let sid = sessionID {
            lock.unlock()
            DaemonConnection.shared.resizeSession(sessionID: sid, surfaceID: surfaceID, cols: cols, rows: rows)
            return
        }
        if bootstrapFailed {
            lock.unlock()
            return
        }
        pendingResize = (cols, rows)
        lock.unlock()
    }
}

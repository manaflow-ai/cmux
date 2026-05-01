import Foundation
#if DEBUG
import Bonsplit
#endif

/// Single source of truth for "which mac surfaces are currently viewing
/// daemon session X?". Multi-subscriber by design — the daemon itself
/// treats subscribers as a set, and a single session id legitimately
/// appears in multiple mac surfaces (same session visible in a split,
/// in tabs, across workspaces, and eventually mac + iOS concurrently).
///
/// Each per-surface `Binding` has its own `attachmentID`. The daemon
/// computes the effective PTY size from the smallest live attachment so
/// every attached renderer can display the same shared grid; mac fans
/// output / view-size locally so we only need one daemon
/// `terminal.subscribe` per session id (first binding opens it, last
/// binding closes it). Writes are ungated at this layer — they flow
/// through whatever bridge the user's keystroke reached via AppKit
/// focus routing.
///
/// All mutations are gated on `lock` so the daemon reader thread and
/// the main thread can both call through without races. Handlers are
/// read under the lock and invoked outside it so a callback can
/// re-enter the registry (e.g. a surface reacting to disconnect by
/// unregistering).
final class TerminalSessionRegistry: @unchecked Sendable {
    static let shared = TerminalSessionRegistry()

    /// Lifecycle phase of one surface's binding to a session. Each
    /// transition is logged so we can reconstruct state from the log.
    enum Phase: Equatable {
        /// Registered, attach/subscribe RPCs in flight for this binding.
        case attaching
        /// Attached; output + view-size events delivered.
        case live
        /// Bridge explicitly stopped (surface closed). No further delivery.
        case closed
    }

    struct Binding {
        let sessionID: String
        let surfaceID: UUID
        let attachmentID: String
        let onOutput: (Data) -> Void
        let onDisconnect: (String?) -> Void
        let onViewSize: (Int, Int) -> Void
        let onReady: () -> Void
        var phase: Phase
        var cols: Int
        var rows: Int
        var shellCommand: String
        var lastOffset: UInt64
        var lastGridGeneration: UInt64
    }

    struct AttachmentStatusSnapshot {
        let attachmentID: String
        let cols: Int
        let rows: Int
    }

    /// Result of a register call. Callers need `isFirstForSession` to
    /// decide whether to issue `terminal.subscribe` on the daemon
    /// (subsequent bindings ride the existing subscription).
    struct RegisterResult {
        let binding: Binding
        let isFirstForSession: Bool
    }

    /// Result of an unregister call. Callers need `isLastForSession` to
    /// decide whether to issue `terminal.unsubscribe` on the daemon.
    struct UnregisterResult {
        let binding: Binding
        let isLastForSession: Bool
    }

    private let lock = NSLock()
    private var bindingsBySession: [String: [Binding]] = [:]
    private var attachmentSnapshotsBySession: [String: [AttachmentStatusSnapshot]] = [:]

    /// Register a new binding. Appends to the session's binding list —
    /// never replaces. A re-registration from the same `surfaceID`
    /// updates the mutable fields of the existing entry rather than
    /// adding a duplicate (idempotent).
    func register(_ binding: Binding) -> RegisterResult {
        lock.lock()
        var list = bindingsBySession[binding.sessionID] ?? []
        let isFirst = list.isEmpty
        if let existingIndex = list.firstIndex(where: { $0.surfaceID == binding.surfaceID }) {
            // Same surface re-registering; merge mutable fields but
            // keep the original callbacks so existing deliveries still
            // land on the same closures.
            var merged = list[existingIndex]
            merged.cols = binding.cols
            merged.rows = binding.rows
            merged.shellCommand = binding.shellCommand
            list[existingIndex] = merged
            bindingsBySession[binding.sessionID] = list
            lock.unlock()
            #if DEBUG
            dlog("session.registry.reregister sid=\(binding.sessionID) surface=\(binding.surfaceID.uuidString.prefix(8)) phase=\(merged.phase)")
            #endif
            return RegisterResult(binding: merged, isFirstForSession: false)
        }
        var installed = binding
        installed.phase = .attaching
        list.append(installed)
        bindingsBySession[binding.sessionID] = list
        lock.unlock()
        #if DEBUG
        dlog("session.registry.register sid=\(installed.sessionID) surface=\(installed.surfaceID.uuidString.prefix(8)) attachmentID=\(installed.attachmentID) bindings=\(list.count) first=\(isFirst)")
        #endif
        return RegisterResult(binding: installed, isFirstForSession: isFirst)
    }

    /// Remove a single binding scoped to (sid, surfaceID). Returns the
    /// removed binding along with a flag indicating whether it was the
    /// last one for that session id (so the transport layer knows when
    /// to release the daemon-side subscription).
    func unregister(sessionID: String, surfaceID: UUID) -> UnregisterResult? {
        lock.lock()
        guard var list = bindingsBySession[sessionID],
              let index = list.firstIndex(where: { $0.surfaceID == surfaceID }) else {
            lock.unlock()
            return nil
        }
        var removed = list.remove(at: index)
        removed.phase = .closed
        if list.isEmpty {
            bindingsBySession.removeValue(forKey: sessionID)
        } else {
            bindingsBySession[sessionID] = list
        }
        let isLast = list.isEmpty
        lock.unlock()
        #if DEBUG
        dlog("session.registry.unregister sid=\(sessionID) surface=\(surfaceID.uuidString.prefix(8)) remaining=\(list.count)")
        #endif
        return UnregisterResult(binding: removed, isLastForSession: isLast)
    }

    /// Mark a binding live (attach RPC completed). No-op if the binding
    /// was removed in the meantime.
    @discardableResult
    func markLive(sessionID: String, surfaceID: UUID) -> (() -> Void)? {
        lock.lock()
        guard var list = bindingsBySession[sessionID],
              let index = list.firstIndex(where: { $0.surfaceID == surfaceID }) else {
            lock.unlock()
            return nil
        }
        list[index].phase = .live
        let onReady = list[index].onReady
        bindingsBySession[sessionID] = list
        lock.unlock()
        return onReady
    }

    /// Update cols/rows for one binding (reported by this surface).
    func updateSize(sessionID: String, surfaceID: UUID, cols: Int, rows: Int) {
        lock.lock()
        guard var list = bindingsBySession[sessionID],
              let index = list.firstIndex(where: { $0.surfaceID == surfaceID }) else {
            lock.unlock()
            return
        }
        list[index].cols = cols
        list[index].rows = rows
        bindingsBySession[sessionID] = list
        lock.unlock()
    }

    /// Update last-seen offset for a session. Applied to the whole
    /// session (all bindings share the same offset cursor since they
    /// ride a single daemon subscription).
    func updateLastOffset(sessionID: String, offset: UInt64) {
        lock.lock()
        guard var list = bindingsBySession[sessionID] else {
            lock.unlock()
            return
        }
        for i in list.indices {
            list[i].lastOffset = offset
        }
        bindingsBySession[sessionID] = list
        lock.unlock()
    }

    func updateAttachmentSnapshot(sessionID: String, attachments: [AttachmentStatusSnapshot]) {
        lock.lock()
        attachmentSnapshotsBySession[sessionID] = attachments
        lock.unlock()
    }

    #if DEBUG
    func shouldRefreshAttachmentSnapshot(sessionID: String, effectiveCols: Int, effectiveRows: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let attachments = attachmentSnapshotsBySession[sessionID], !attachments.isEmpty else {
            return true
        }
        return !attachments.contains { $0.cols == effectiveCols && $0.rows == effectiveRows }
    }

    func debugAttachmentSummary(sessionID: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        return Self.attachmentSummary(attachmentSnapshotsBySession[sessionID] ?? [])
    }

    func debugResizeSummary(
        sessionID: String?,
        surfaceID: UUID,
        effectiveCols: Int,
        effectiveRows: Int,
        naturalCols: Int,
        naturalRows: Int
    ) -> String {
        lock.lock()
        defer { lock.unlock() }
        guard let sessionID else {
            return "session=nil localAttachment=nil localReported=nil attachments=unknown remoteWidthLimiter=unknown remoteHeightLimiter=unknown"
        }

        let local = bindingsBySession[sessionID]?.first(where: { $0.surfaceID == surfaceID })
        let localAttachmentID = local?.attachmentID ?? "nil"
        let localReported = local.map { "\($0.cols)x\($0.rows)" } ?? "nil"
        let attachments = attachmentSnapshotsBySession[sessionID] ?? []
        let remoteWidthLimiter = attachments.first {
            $0.attachmentID != localAttachmentID && $0.cols == effectiveCols
        }?.attachmentID ?? "none"
        let remoteHeightLimiter = attachments.first {
            $0.attachmentID != localAttachmentID && $0.rows == effectiveRows
        }?.attachmentID ?? "none"

        return "session=\(String(sessionID.prefix(12))) localAttachment=\(localAttachmentID) localReported=\(localReported) attachments=\(Self.attachmentSummary(attachments)) remoteWidthLimiter=\(remoteWidthLimiter) remoteHeightLimiter=\(remoteHeightLimiter) natural=\(naturalCols)x\(naturalRows) effective=\(effectiveCols)x\(effectiveRows)"
    }

    private static func attachmentSummary(_ attachments: [AttachmentStatusSnapshot]) -> String {
        guard !attachments.isEmpty else { return "unknown" }
        return "[" + attachments.map { "\($0.attachmentID):\($0.cols)x\($0.rows)" }.joined(separator: ",") + "]"
    }
    #endif

    /// Look up the first binding for a session id. Used by the transport
    /// layer's reconnect path, which issues subscribe on the first
    /// binding's attach metadata (command, last offset). Subsequent
    /// bindings just ride the same subscription.
    func firstBinding(for sessionID: String) -> Binding? {
        lock.lock(); defer { lock.unlock() }
        return bindingsBySession[sessionID]?.first
    }

    /// Look up a specific binding by (sid, surfaceID). Used by the
    /// transport layer when issuing per-attachment RPCs like
    /// `session.attach` / `session.resize`.
    func binding(sessionID: String, surfaceID: UUID) -> Binding? {
        lock.lock(); defer { lock.unlock() }
        return bindingsBySession[sessionID]?.first(where: { $0.surfaceID == surfaceID })
    }

    /// Fan an output frame to every binding for this session.
    ///
    /// When the daemon includes raw-buffer offsets, use them as the delivery
    /// cursor before invoking handlers. Reconnect snapshots can overlap bytes
    /// already rendered on this client; trimming here keeps replay idempotent
    /// for both full duplicates and partial overlaps.
    @discardableResult
    func deliverOutput(sessionID: String, data: Data, offset: UInt64? = nil, baseOffset: UInt64? = nil) -> Bool {
        lock.lock()
        guard var list = bindingsBySession[sessionID], !list.isEmpty else {
            lock.unlock()
            return false
        }

        var payload = data
        if let offset {
            let currentOffset = list.map(\.lastOffset).max() ?? 0
            if currentOffset >= offset {
                lock.unlock()
                return false
            }

            let frameStart = offset >= UInt64(data.count)
                ? offset - UInt64(data.count)
                : (baseOffset ?? 0)
            if currentOffset > frameStart {
                let dropBytes = min(data.count, Int(currentOffset - frameStart))
                payload = Data(data.dropFirst(dropBytes))
            }

            for i in list.indices {
                list[i].lastOffset = offset
            }
            bindingsBySession[sessionID] = list
        }

        let handlers = list.map { $0.onOutput }
        lock.unlock()
        guard !payload.isEmpty else { return true }
        for handler in handlers {
            handler(payload)
        }
        return true
    }

    /// Fan a view-size update to every binding, with generation-based
    /// stale-drop (monotonicity enforced on the per-binding `lastGridGeneration`).
    func deliverViewSize(sessionID: String, cols: Int, rows: Int, generation: UInt64) {
        guard cols > 0, rows > 0 else { return }
        lock.lock()
        guard var list = bindingsBySession[sessionID] else {
            lock.unlock()
            return
        }
        var handlers: [(Int, Int) -> Void] = []
        for i in list.indices {
            if generation > 0 {
                if list[i].lastGridGeneration > 0 && generation <= list[i].lastGridGeneration {
                    continue
                }
                list[i].lastGridGeneration = generation
            }
            handlers.append(list[i].onViewSize)
        }
        bindingsBySession[sessionID] = list
        lock.unlock()
        for handler in handlers {
            handler(cols, rows)
        }
    }

    /// Remove all bindings for a session id and fire onDisconnect for
    /// each. Called when the daemon signals `eof`.
    func deliverDisconnect(sessionID: String, reason: String?) {
        lock.lock()
        let list = bindingsBySession.removeValue(forKey: sessionID) ?? []
        lock.unlock()
        for binding in list {
            binding.onDisconnect(reason)
        }
    }

    /// Disconnect every live binding. Used on full transport shutdown.
    func drainOnDisconnect(reason: String?) {
        lock.lock()
        let snapshot = bindingsBySession.values.flatMap { $0 }
        bindingsBySession.removeAll()
        lock.unlock()
        for binding in snapshot {
            binding.onDisconnect(reason)
        }
    }

    /// Snapshot of all live session IDs with at least one binding.
    /// Used by reconnect: one `terminal.subscribe` per unique sid.
    func allSessionIDs() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(bindingsBySession.keys)
    }
}

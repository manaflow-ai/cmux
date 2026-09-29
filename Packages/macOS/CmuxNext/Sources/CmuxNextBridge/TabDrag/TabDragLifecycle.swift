public import CmuxNextDaemon

/// The contract every tab drag must honor: it ends exactly once, and the
/// source strip's detached tab comes back (`restore`) whenever the tab did
/// not move: cancel, no target, or a rejected commit. A committed drag
/// carries a client transaction id that settles it (daemon response or
/// transaction echo); a late or duplicate settle is ignored.
@MainActor
public final class TabDragLifecycle {
    public enum Phase: Equatable, Sendable {
        case dragging
        case committing(ClientTransactionID)
        /// The move landed; the model change removes the tab from the strip.
        case settled
        /// The tab was restored to its origin.
        case restored
    }

    public private(set) var phase: Phase = .dragging
    private let restore: () -> Void
    private let makeTransaction: () -> ClientTransactionID

    public init(makeTransaction: @escaping () -> ClientTransactionID = { .generate() }, restore: @escaping () -> Void) {
        self.makeTransaction = makeTransaction
        self.restore = restore
    }

    public var isDragging: Bool { phase == .dragging }

    public var isEnded: Bool {
        switch phase {
        case .settled, .restored: true
        case .dragging, .committing: false
        }
    }

    public var transaction: ClientTransactionID? {
        if case .committing(let id) = phase { id } else { nil }
    }

    /// Escape, no target, or a lost drag. Restores at once. No-op after the
    /// drag left `dragging`.
    public func cancel() {
        guard phase == .dragging else { return }
        phase = .restored
        restore()
    }

    /// Starts a commit and returns its transaction id, or nil when the drag
    /// already ended.
    public func beginCommit() -> ClientTransactionID? {
        guard phase == .dragging else { return nil }
        let id = makeTransaction()
        phase = .committing(id)
        return id
    }

    /// Settles the commit `transaction`. `ok == false` restores the tab.
    /// Ignores other transactions and repeats.
    public func settle(_ transaction: ClientTransactionID, ok: Bool) {
        guard case .committing(let current) = phase, current == transaction else { return }
        if ok {
            phase = .settled
        } else {
            phase = .restored
            restore()
        }
    }
}

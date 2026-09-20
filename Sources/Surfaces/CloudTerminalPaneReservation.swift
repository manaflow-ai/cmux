import CmuxSurfaceCatalogModel
import CmuxTerminal
import Foundation

/// Input typed into an optimistic Cloud pane before its remote PTY exists.
///
/// The pane is inserted the moment the user asks for it; the machine's terminal
/// arrives later. Keystrokes made in between are queued here and handed to the
/// attachment's input router once the pane is adopted, so the first characters
/// a user types into a new pane are not lost.
final class CloudOptimisticInputRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var router: CloudTuiManualIOInputRouter?
    private var pending: [TerminalManualInput] = []
    private var discarded = false
    /// Bounded like the router's own queue: a runaway paste into a pane that
    /// never attaches must not grow without limit.
    private let pendingLimit = 4_096

    /// Number of inputs waiting for a router. Diagnostics and tests only.
    var pendingCount: Int {
        lock.lock(); defer { lock.unlock() }
        return pending.count
    }

    /// Callable from Ghostty's I/O thread, like the router it fronts.
    func send(_ input: TerminalManualInput) {
        lock.lock()
        if let router {
            lock.unlock()
            router.send(input)
            return
        }
        if !discarded, pending.count < pendingLimit { pending.append(input) }
        lock.unlock()
    }

    /// Delivers everything queued so far to `router` and forwards from now on.
    func attach(_ router: CloudTuiManualIOInputRouter) {
        lock.lock()
        // Enqueue the backlog before publishing the router. send() only queues
        // work, so holding this lock performs no socket I/O. A concurrent key
        // cannot overtake earlier input at the handoff boundary.
        for input in pending { router.send(input) }
        pending.removeAll()
        discarded = false
        self.router = router
        lock.unlock()
    }

    /// Drops queued input and stops forwarding: the request was cancelled or the
    /// pane failed. A later `attach` (retry) resumes forwarding.
    func discard() {
        lock.lock()
        pending.removeAll()
        router = nil
        discarded = true
        lock.unlock()
    }
}

/// A native pane that already occupies the user's requested split or tab while
/// the machine creates the terminal behind it.
///
/// One reservation is one UI intent. The attachment adopts the pane when the
/// remote terminal resolves (`CmuxTuiSurfaceProvider.materialize(…, adopting:)`),
/// a failure is shown inside the pane, and the request is cancelled when the
/// user closes the pane first. While it waits the pane shows nothing but its
/// tab-strip spinner: no progress card, no placeholder text.
@MainActor
final class CloudTerminalPaneReservation {
    let workspaceID: UUID
    let panelID: UUID
    let machine: SurfaceMachineID
    let inputRelay: CloudOptimisticInputRelay
    /// When the pane was inserted. Adoption hands the elapsed wait to the
    /// attachment session so the connection card does not restart its grace.
    let startedAt: ContinuousClock.Instant
    /// Replays the same request (create receipt first, then projection).
    var retry: (@MainActor () -> Void)?
    /// Cancels the local request; a remote terminal already created stays alive.
    var cancel: (@MainActor () -> Void)?

    init(
        workspaceID: UUID,
        panelID: UUID,
        machine: SurfaceMachineID,
        inputRelay: CloudOptimisticInputRelay = CloudOptimisticInputRelay(),
        startedAt: ContinuousClock.Instant = .now
    ) {
        self.workspaceID = workspaceID
        self.panelID = panelID
        self.machine = machine
        self.inputRelay = inputRelay
        self.startedAt = startedAt
    }

    var elapsed: Duration { ContinuousClock.now - startedAt }
}

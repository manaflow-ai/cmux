public import CmuxNextWakeups

/// A jump's wait for its workspace's first pane: the jump's window shows the workspace before any
/// of its panes mounted, so the chat opens in the first pane that mounts. The wait ends when a pane
/// mounts (it opens the chat once), when the window closes or shows another workspace (it opens
/// nothing), or when ``cancel()`` runs (the next jump replaces it).
///
/// It waits on the model, not a view: a ``ServiceObservation`` in the userBlocking class (the person
/// waits for the chat they picked), so a burst of mounts reads `decide` once, in the next flush.
@MainActor
public final class AgentChatPaneWait {
    /// What the wait does with the window's state now.
    public enum Decision: Equatable, Sendable {
        /// A pane mounted: open the chat there.
        case open
        /// None yet: wait for the next mount.
        case wait
        /// The window closed or shows another workspace: the jump is over.
        case stop

        /// - Parameters:
        ///   - showing: The workspace the jump's window shows now, nil once it closed.
        ///   - workspaceID: The workspace the jump went to.
        ///   - hasPane: Whether that window has a pane yet.
        public static func decide(showing: String?, workspaceID: String, hasPane: Bool) -> Decision {
            guard showing == workspaceID else { return .stop }
            return hasPane ? .open : .wait
        }
    }

    private var observation: ServiceObservation<Decision>?
    /// The wait decided (opened or stopped) or was cancelled: nothing opens after that.
    public private(set) var isOver = false

    /// Starts waiting; when `decide` says ``Decision/open`` already, the chat opens before this returns.
    ///
    /// - Parameters:
    ///   - work: The app's main-thread scheduler.
    ///   - decide: Reads the window's state with tracking (``Decision/decide(showing:workspaceID:hasPane:)``).
    ///   - open: Opens the chat in the pane that mounted.
    public init(on work: MainWorkScheduler, decide: @escaping @MainActor () -> Decision, open: @escaping @MainActor () -> Void) {
        let observation = ServiceObservation(.userBlocking, owner: "agent-activity.pane-wait", on: work, read: decide) { [weak self] next in
            self?.decided(next, open: open)
        }
        if isOver { observation.cancel() } else { self.observation = observation }
    }

    /// Ends the wait with nothing opened. Idempotent.
    public func cancel() {
        isOver = true
        observation?.cancel()
        observation = nil
    }

    private func decided(_ next: Decision, open: () -> Void) {
        guard next != .wait, !isOver else { return }
        cancel()
        if next == .open { open() }
    }
}

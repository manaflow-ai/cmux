package import CmuxNextWakeups

/// The one-shot deadline of ``HiddenWorkspaceDetach``: a `background` ``MainDeadline`` in the app, a fake in tests.
@MainActor
package protocol HiddenWorkspaceDetachDeadline: AnyObject {
    /// Runs `action` once after `delay`, replacing a pending deadline.
    func schedule(after delay: Duration, _ action: @escaping @MainActor () -> Void)
    /// Drops the pending deadline.
    func cancel()
}

extension MainDeadline: HiddenWorkspaceDetachDeadline {}

/// Where the hidden workspaces are: a window's main pane in the app.
@MainActor
package protocol HiddenWorkspaceDetachHost: AnyObject {
    /// Whether `workspace` is still hidden in the window: not torn down, not shown beside the shown one.
    func holdsHidden(_ workspace: AnyObject) -> Bool
    /// Takes `workspace` out of the window; showing it adds it back.
    func detach(_ workspace: AnyObject)
}

/// The detach arm of p03-rendering-096 (feature `hiddenWorkspaceDetachAfterGrace`, default off): a workspace
/// that stayed hidden for ``grace`` leaves its window as background work, the oldest first and one per
/// deadline turn.
///
/// Hide-only is the default (plans/cmux-next/chrome-parity/p03-rendering.md R6): the switch hides the
/// outgoing workspace in its turn, its content is evicted as its own step (terminal frames volatile,
/// ``HiddenFrameLRU``), and a switch back moves no view into the window. Chrome hides a background tab's
/// view and evicts its frame (`content/browser/renderer_host/delegated_frame_host.cc` `WasHidden`,
/// `components/viz/client/frame_eviction_manager.cc`); it never takes the view out of the window. This
/// arm stays only if activation-perf.py STRESS shows it frees memory with switch-in p95 < 8.3 ms.
@MainActor
package final class HiddenWorkspaceDetach {
    /// How long a workspace stays hidden in its window before it leaves it.
    package let grace: Duration
    /// Workspaces taken out of the window so far (tests and diagnostics).
    package private(set) var detachedCount = 0
    /// The window the hidden workspaces leave.
    package weak var host: (any HiddenWorkspaceDetachHost)?

    private struct Entry {
        weak var workspace: AnyObject?
        let id: ObjectIdentifier
        let hiddenAt: ContinuousClock.Instant
    }

    /// Hidden workspaces still in the window, oldest first: at most the window's parked workspaces.
    private var hidden: [Entry] = []
    private let deadline: any HiddenWorkspaceDetachDeadline
    private let now: () -> ContinuousClock.Instant

    /// - Parameters:
    ///   - grace: How long a workspace stays hidden in its window.
    ///   - deadline: The one deadline, aimed at the oldest hidden workspace.
    ///   - now: The injected clock of hide times.
    package init(grace: Duration, deadline: any HiddenWorkspaceDetachDeadline,
                 now: @escaping () -> ContinuousClock.Instant = { .now }) {
        self.grace = grace
        self.deadline = deadline
        self.now = now
    }

    /// Workspaces waiting for their grace to end.
    package var pendingCount: Int { hidden.count }

    /// `workspace` hid in its window (a switch, or the side-by-side view taking it off screen): its grace starts
    /// again from now. An O(parked) list edit and one deadline plan.
    package func didHide(_ workspace: AnyObject) {
        forget(workspace)
        hidden.append(Entry(workspace: workspace, id: ObjectIdentifier(workspace), hiddenAt: now()))
        arm()
    }

    /// `workspace` shows again (the shown one, or one beside it): it stays in, or joins, the window. The host
    /// reports every show and hide, so a workspace hidden again later is measured from that hide.
    package func willShow(_ workspace: AnyObject) {
        guard forget(workspace) else { return }
        arm()
    }

    /// The deadline: the oldest workspace whose grace ended leaves the window, then the next one is aimed at.
    /// One per turn: a workspace leaving the window runs AppKit's window exit over its whole subtree.
    package func detachDue() {
        let host = self.host
        hidden.removeAll { entry in
            guard let workspace = entry.workspace, let host else { return true }
            return !host.holdsHidden(workspace)
        }
        if let oldest = hidden.first, now() - oldest.hiddenAt >= grace, let workspace = oldest.workspace {
            hidden.removeFirst()
            host?.detach(workspace)
            detachedCount += 1
        }
        arm()
    }

    @discardableResult
    private func forget(_ workspace: AnyObject) -> Bool {
        let id = ObjectIdentifier(workspace)
        guard let index = hidden.firstIndex(where: { $0.id == id }) else { return false }
        hidden.remove(at: index)
        return true
    }

    /// Aims the one deadline at the oldest hidden workspace's grace end, or drops it when none waits.
    private func arm() {
        guard let oldest = hidden.first else { return deadline.cancel() }
        let wait = grace - (now() - oldest.hiddenAt)
        deadline.schedule(after: max(.zero, wait)) { [weak self] in self?.detachDue() }
    }
}

internal import CmuxMobileSSH

/// Decides which cmux-tui session notifications change the phone's rows and
/// coalesces them to one relist request per listing: a burst of
/// `tree-changed` lines (a laptop splitting and renaming) asks once, and a
/// change that arrives while a listing runs asks again after it.
///
/// A disconnect counts: the session's owner may have exited, so its rows
/// must go. Titles are not topology: a shell prompt retitles its terminal on every
/// command, and row names refresh on the next relist anyway.
struct MobileSSHCmuxTUITopologyGate {
    /// A relist was requested and no listing has started since.
    private var requested = false
    /// A control disconnect invalidated the last complete snapshot.
    private var snapshotRequired = false
    /// Generation of the control that produced the accepted events.
    private(set) var generation: UInt64 = 0

    /// Records `event`; `true` when the caller should request a relist.
    /// Events from a superseded control are ignored.
    mutating func admit(_ event: CmuxTUIControlEvent, generation: UInt64? = nil) -> Bool {
        guard generation == nil || generation == self.generation else { return false }
        guard Self.changesTopology(event), !requested else { return false }
        requested = true
        return true
    }

    /// Records a control replacement or a transport gap.
    mutating func generationChanged(to generation: UInt64) {
        guard generation >= self.generation else { return }
        self.generation = generation
        snapshotRequired = true
    }

    /// A listing started: it observes every change admitted so far. A stale
    /// listing cannot clear the snapshot requirement of a newer generation.
    mutating func listed(generation: UInt64? = nil) {
        guard generation == nil || generation == self.generation else { return }
        requested = false
        snapshotRequired = false
    }

    /// Requests a full snapshot after a reconnect if no relist is already in
    /// flight. This preserves the event coalescing invariant across a gap.
    mutating func forceSnapshotIfNeeded(generation: UInt64) -> Bool {
        guard generation == self.generation, snapshotRequired, !requested else { return false }
        requested = true
        return true
    }

    static func changesTopology(_ event: CmuxTUIControlEvent) -> Bool {
        switch event {
        case .treeChanged, .surfaceExited, .empty, .overflow, .daemonShutdown, .disconnected:
            true
        case .titleChanged, .surfaceResized, .bell:
            false
        }
    }
}

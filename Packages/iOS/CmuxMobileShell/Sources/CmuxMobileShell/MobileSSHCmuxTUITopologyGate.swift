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

    /// Records `event`; `true` when the caller should request a relist.
    mutating func admit(_ event: CmuxTUIControlEvent) -> Bool {
        guard Self.changesTopology(event), !requested else { return false }
        requested = true
        return true
    }

    /// A listing started: it observes every change admitted so far.
    mutating func listed() {
        requested = false
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

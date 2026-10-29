import CmuxNextTrace
public import CmuxNextWakeups

/// The local daemon in the process's crash-key page: its connection state and pid, the
/// Ghostty commit it reports, and how many workspaces its tree holds, so a crash or a fatal hang names the daemon
/// the app talked to. Only the local daemon's store has the app's ``CrashKeySlots`` (`DaemonService`).
extension CrashKeySlots {
    /// Names the connection `state` (each change of `DaemonStore.connectionState`): ``CrashKeySlot/daemonState``
    /// (``DaemonConnectionState/crashKeyValue``), and while connected the daemon's pid and the first 8 bytes of
    /// its Ghostty commit. A disconnect clears the pid and keeps the commit.
    public func noteDaemon(_ state: DaemonConnectionState) {
        page.set(.daemonState, state.crashKeyValue)
        guard case .connected(let identity) = state else {
            page.set(.daemonPID, 0)
            return
        }
        page.set(.daemonPID, UInt64(clamping: identity.pid))
        if let commit = identity.ghosttyCommit.flatMap({ UInt64($0.prefix(16), radix: 16) }) {
            page.set(.ghosttyCommit, commit)
        }
    }

    /// Names how many workspaces the local daemon's tree holds (each change of `DaemonStore.workspaces`), as a
    /// power-of-two bucket.
    public func noteWorkspaces(_ count: Int) {
        page.setCount(.workspaceCount, count)
    }
}

extension DaemonConnectionState {
    /// The state as ``CrashKeySlot/daemonState`` stores it: 1 connecting, 2 connected, 3 disconnected (the
    /// service reconnects), 4 failed.
    public var crashKeyValue: UInt64 {
        switch self {
        case .connecting: 1
        case .connected: 2
        case .disconnected: 3
        case .failed: 4
        }
    }
}

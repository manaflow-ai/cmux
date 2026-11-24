import Foundation
public import CmuxNextCompat
import Observation
public import CmuxNextAgentActivity
public import CmuxNextSidebar

/// The per-window machine surfaces above the durable sidebar document.
/// Hosts owns the Labs gate; the remote chat groups are bound only while that gate is on.
@MainActor
public final class SidebarMachineSections {
    public let hosts: HostsSidebar
    public let remote: RemoteMachinesSidebar
    private var labsWatch: Task<Void, Never>?

    public init(hosts: HostsSidebar = HostsSidebar(), remote: RemoteMachinesSidebar = RemoteMachinesSidebar()) {
        self.hosts = hosts
        self.remote = remote
    }

    nonisolated deinit { labsWatch?.cancel() }

    public func bind(host: HostsSidebar.Host, visible: @escaping @MainActor () -> Bool,
                     socketPath: String?, displayName: @escaping (String) -> String?,
                     open: @escaping (AgentActivityLane) -> Void,
                     remoteHost suppliedRemoteHost: RemoteMachinesSidebar.Host? = nil) {
        labsWatch?.cancel()
        remote.stop()
        hosts.bind(host: host, visible: visible)
        let remoteHost = suppliedRemoteHost ?? RemoteMachinesSidebar.host(socketPath: socketPath, displayName: displayName, open: open)
        labsWatch = Task { [weak self] in
            for await enabled in ObservationStream({ [weak self] in self?.hosts.isEnabled == true }) {
                guard !Task.isCancelled, let self else { return }
                if enabled { self.remote.bind(host: remoteHost) } else { self.remote.stop() }
            }
        }
    }

    /// Keeps the process-wide turn feed's callback in the domain owner; the App only supplies its windows.
    /// `also`: the App's own listener for the same push (the device list's re-read), run first.
    public static func bindPeerState(_ turns: AgentTurnStateFeed,
                                     sections: @escaping @MainActor () -> [SidebarMachineSections],
                                     also: (@MainActor (_ peer: String?, _ state: String?) -> Void)? = nil) {
        turns.peerStateChanged = { peer, state in
            also?(peer, state)
            sections().forEach { $0.peerStateChanged(peer: peer, state: state) }
        }
    }

    public func stop() {
        labsWatch?.cancel()
        labsWatch = nil
        hosts.stop()
        remote.stop()
    }

    /// Forwards daemon peer pushes only while Labs owns the remote section. This keeps a
    /// disabled section inert even when the process-wide turn feed still has subscribers.
    public func peerStateChanged(peer: String?, state: String?) {
        guard hosts.isEnabled else {
            remote.stop()
            return
        }
        remote.peerStateChanged(peer: peer, state: state)
    }

    public func topItems() -> [SidebarTransientItem] {
        let rows = hosts.rows()
        guard hosts.isEnabled else {
            remote.stop()
            return []
        }
        return rows + remote.rows()
    }

    public func activate(_ id: LayoutItemID) -> Bool {
        guard hosts.isEnabled else { return false }
        return hosts.activate(id) || remote.activate(id)
    }
}

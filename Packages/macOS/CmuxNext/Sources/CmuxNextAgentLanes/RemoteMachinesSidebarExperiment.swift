import CmuxNextAgentActivity
import CmuxNextBridge
import CmuxNextCompat
import CmuxNextSidebar
import Foundation
import Observation

/// Owns the first Labs-gated remote-machine sidebar slice for one app window.
/// The app supplies only transport and navigation closures; the feed observer and lifetime stay
/// in the agent-lanes target so closing a window cannot leak a listener or a peer read.
@MainActor
public final class RemoteMachinesSidebarExperiment {
    private let sidebar: RemoteMachinesSidebar
    private let currentFeed: @MainActor @Sendable () -> AgentTurnStateFeed?
    private var feed: AgentTurnStateFeed?
    private let enabled: @MainActor @Sendable () -> Bool
    private let socketPath: @MainActor @Sendable () -> String?
    private let displayName: (String) -> String?
    private let open: (AgentActivityLane) -> Void
    private var observation: Task<Void, Never>?
    private var observerID: String?

    public init(sidebar: RemoteMachinesSidebar,
                enabled: @escaping @MainActor @Sendable () -> Bool,
                socketPath: @escaping @MainActor @Sendable () -> String?,
                displayName: @escaping (String) -> String?,
                open: @escaping (Any) -> Void,
                currentFeed: (@MainActor @Sendable () -> AgentTurnStateFeed?)? = nil) {
        self.sidebar = sidebar
        self.currentFeed = currentFeed ?? {
            // The launch window predates ChatsFeed.started. Its first page changes `live`,
            // waking this read after the feed is installed, without moving work before the frame.
            _ = AgentLaneStore.shared.live
            return AgentTurnStateFeed.shared
        }
        self.enabled = enabled
        self.socketPath = socketPath
        self.displayName = displayName
        self.open = { lane in open(lane) }
    }

    public func start() {
        stop()
        // main-hop-allow: ObservationStream is MainActor-isolated; this hop only watches the Labs setting and
        // binds or stops the per-window sidebar, with no transport or frame work inside the observer.
        observation = Task { @MainActor [weak self] in
            guard let self else { return }
            for await (on, feed) in ObservationStream({ (self.enabled(), self.currentFeed()) }) {
                guard !Task.isCancelled else { return }
                self.observePeerState(on ? feed : nil)
                if on {
                    self.sidebar.bind(host: RemoteMachinesSidebar.host(socketPath: self.socketPath,
                                                                         displayName: self.displayName,
                                                                         open: self.open))
                } else {
                    self.sidebar.stop()
                }
            }
        }
    }

    public func stop() {
        observation?.cancel()
        observation = nil
        observePeerState(nil)
        sidebar.stop()
    }

    private func observePeerState(_ next: AgentTurnStateFeed?) {
        guard feed !== next else { return }
        if let observerID, let feed { feed.removePeerStateObserver(observerID) }
        feed = next
        observerID = next?.addPeerStateObserver { [weak sidebar] peer, state in
            sidebar?.peerStateChanged(peer: peer, state: state)
        }
        // A newly available feed may have emitted its initial peer event before we subscribed.
        if next != nil { sidebar.peerStateChanged(peer: nil, state: nil) }
    }
}

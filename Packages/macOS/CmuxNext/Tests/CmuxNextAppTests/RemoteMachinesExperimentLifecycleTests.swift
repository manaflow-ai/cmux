import CmuxNextAgentActivity
@testable import CmuxNextAgentLanes
import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextSidebar
import Observation
import Testing

@MainActor
struct RemoteMachinesExperimentLifecycleTests {
    @Observable @MainActor
    final class Source {
        var enabled = true
        var feed: AgentTurnStateFeed?
    }

    @Test func lateFeedReplacementDisableAndStopManageEachWindowObserver() async {
        let source = Source()
        let sidebar = RemoteMachinesSidebar(lanes: AgentLaneStore())
        var reads = 0
        let experiment = RemoteMachinesSidebarExperiment(
            sidebar: sidebar, enabled: { source.enabled }, socketPath: { nil },
            displayName: { _ in nil }, open: { _ in },
            currentFeed: { reads += 1; return source.feed })
        experiment.start()
        defer { experiment.stop() }
        #expect(await PeerStatePushTests.settle { reads > 0 }, "the window starts before the feed exists")

        let first = AgentTurnStateFeed(socketPath: "/nonexistent/first.sock", turns: AgentTurnStateStore(), lanes: AgentLaneStore())
        source.feed = first
        #expect(await PeerStatePushTests.settle { first.peerStateObservers.count == 1 })
        source.enabled = false
        #expect(await PeerStatePushTests.settle { first.peerStateObservers.isEmpty })
        #expect(sidebar.rows().isEmpty)
        source.enabled = true
        #expect(await PeerStatePushTests.settle { first.peerStateObservers.count == 1 })

        let second = AgentTurnStateFeed(socketPath: "/nonexistent/second.sock", turns: AgentTurnStateStore(), lanes: AgentLaneStore())
        source.feed = second
        #expect(await PeerStatePushTests.settle { first.peerStateObservers.isEmpty && second.peerStateObservers.count == 1 })
        experiment.stop()
        #expect(second.peerStateObservers.isEmpty)
        #expect(sidebar.rows().isEmpty)
    }

    @Test func transportResolvesSocketForEveryRequest() async {
        var reads = 0
        let host = RemoteMachinesSidebar.host(socketPath: { reads += 1; return nil },
                                             displayName: { _ in nil }, open: { _ in })
        #expect(reads == 0, "building a window does not freeze the socket path")
        #expect(await host.peers() == nil)
        #expect(await host.peers() == nil)
        #expect(await host.older("peer", nil) == nil)
        #expect(reads == 3, "each request gets the current path even if an earlier read had none")
    }

    @Test func watchGapKeepsDisplayedChatNavigableAndFreshPageRemovesIt() {
        let lanes = AgentLaneStore()
        let lane = RemoteMachinesSidebarTests.lane("durable", peer: "studio")
        lanes.lanes = [lane.id: lane]
        lanes.live = true
        let sidebar = RemoteMachinesSidebar(lanes: lanes)
        var opened: [AgentActivityLane] = []
        sidebar.bind(host: .init(peers: { nil }, older: { _, _ in nil },
                                 displayName: { _ in nil }, open: { opened.append($0) }))
        defer { sidebar.stop() }
        let shown = sidebar.machines
        let row = LayoutItemID(LayoutItemID.transientPrefix + "remote:session:" + lane.id)

        // Match AgentTurnStateFeed.lost: mark the watch down before clearing its live store.
        lanes.live = false
        lanes.lanes = [:]
        sidebar.rebuild()
        #expect(sidebar.machines == shown, "a watch gap keeps the last rows for the quiet period")
        #expect(sidebar.activate(row))
        #expect(opened == [lane], "the visible row still opens the same remote session")

        lanes.live = true
        sidebar.rebuild()
        #expect(sidebar.machines.isEmpty, "a fresh empty page really removes the chat")
        _ = sidebar.activate(row)
        #expect(opened == [lane], "removed rows retain no navigation state")
        sidebar.stop()
        #expect(sidebar.rows().isEmpty)
    }
}

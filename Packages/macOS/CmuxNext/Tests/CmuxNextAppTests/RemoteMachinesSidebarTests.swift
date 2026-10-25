import CmuxNextAgentActivity
@testable import CmuxNextAgentLanes
@testable import CmuxNextAgentPane
import CmuxNextDesign
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Leo 2026-10-24: the agent chats on other machines show in the sidebar, one group per machine
/// with the cloud icon. Groups fold by default and count only live chats; unfolded, a page of
/// chats newest first; a machine the daemon cannot reach shows as offline with no rows.
@MainActor
struct RemoteMachinesSidebarTests {
    static func lane(_ name: String, peer: String?, _ state: AgentActivityLane.State = .idle, since: TimeInterval = 0,
                     title: String? = nil) -> AgentActivityLane {
        AgentActivityLane(id: "id-" + name, name: peer.map { "\($0)/\(name)" } ?? name, title: title ?? (peer.map { "\($0)/\(name)" } ?? name),
                          peer: peer, parent: nil, state: state, since: Date(timeIntervalSince1970: since), error: nil, harness: "codex")
    }

    static func rows(_ machines: [RemoteMachinesSidebar.Machine], expanded: Set<String> = [], pages: [String: Int] = [:]) -> [SidebarTransientItem] {
        RemoteMachinesSidebar.rows(machines: machines, expanded: expanded, pages: pages, displayName: { _ in nil })
    }

    @Test func onePerPeerByNameAndThisMacsChatsAreLeftOut() {
        let machines = RemoteMachinesSidebar.machines(lanes: [Self.lane("a", peer: "huge-blue"), Self.lane("b", peer: "big-red"),
                                                              Self.lane("local", peer: nil)], peers: nil)
        #expect(machines.map(\.peer) == ["big-red", "huge-blue"])
        #expect(machines.allSatisfy { $0.online && $0.chats.count == 1 })
    }

    @Test func newestStateChangeFirstAndTitlesDropThePeerPrefix() {
        let machine = RemoteMachinesSidebar.machines(lanes: [Self.lane("old", peer: "cmux16", since: 10),
                                                             Self.lane("new", peer: "cmux16", .working, since: 20, title: "Fix the rail")],
                                                     peers: nil)[0]
        #expect(machine.chats.map(\.title) == ["Fix the rail", "old"])
        #expect(machine.chats[0].activity == .working)
    }

    @Test func anUnreachablePeerIsOfflineWithNoChatsAndAListedPeerWithNoneStillShows() {
        let peers = [AcpmuxPeerList.Peer(name: "big-red", connected: false), AcpmuxPeerList.Peer(name: "air-blue", connected: true)]
        let machines = RemoteMachinesSidebar.machines(lanes: [Self.lane("a", peer: "big-red", .working)], peers: peers)
        #expect(machines.map(\.peer) == ["air-blue", "big-red"])
        #expect(machines[0].online && machines[0].chats.isEmpty)
        #expect(!machines[1].online && machines[1].chats.isEmpty)
        let header = Self.rows(machines)[1].info
        #expect(header.isMissing && header.badge == nil && header.title.contains("big-red"))
    }

    @Test func foldedByDefaultWithTheCloudIconAndALiveCount() {
        let machines = RemoteMachinesSidebar.machines(lanes: (0..<3).map { Self.lane("s\($0)", peer: "huge-blue", .input) }, peers: nil)
        let rows = Self.rows(machines)
        #expect(rows.count == 1)
        #expect(rows[0].info.icon == .cloud && rows[0].info.badge == 3 && rows[0].info.activity == .waiting)
    }

    @Test func unfoldedShowsAPageThenShowMore() {
        let lanes = (0..<(RemoteMachinesSidebar.pageSize + 3)).map { Self.lane("s\($0)", peer: "huge-blue", since: TimeInterval($0)) }
        let machines = RemoteMachinesSidebar.machines(lanes: lanes, peers: nil)
        let page = Self.rows(machines, expanded: ["huge-blue"])
        #expect(page.count == 1 + RemoteMachinesSidebar.pageSize + 1)
        #expect(page.dropFirst().allSatisfy { $0.info.indent == 1 })
        #expect(page.last?.info.title == RemoteMachinesStrings.showMore)
        #expect(Self.rows(machines, expanded: ["huge-blue"], pages: ["huge-blue": 2]).count == 1 + lanes.count)
    }

    @Test func clicksFoldAndPageWithoutOpeningAnything() {
        let sidebar = RemoteMachinesSidebar(lanes: AgentLaneStore())
        sidebar.expanded = []
        let header = LayoutItemID(LayoutItemID.transientPrefix + "remote:machine:huge-blue")
        #expect(sidebar.activate(header))
        #expect(sidebar.expanded == ["huge-blue"])
        #expect(sidebar.activate(LayoutItemID(LayoutItemID.transientPrefix + "remote:more:huge-blue")))
        #expect(sidebar.pages["huge-blue"] == 2)
        #expect(sidebar.activate(header))
        #expect(sidebar.expanded.isEmpty && sidebar.pages["huge-blue"] == nil)
        #expect(!sidebar.activate(LayoutItemID(LayoutItemID.transientPrefix + "channels")))
        sidebar.expanded = []
    }

    /// The groups draw after the top items, above the workspaces, in order.
    @Test func groupsFollowTheTopItems() {
        let model = SidebarModel()
        model.transientTopItems = Self.rows(RemoteMachinesSidebar.machines(lanes: [Self.lane("a", peer: "huge-blue"), Self.lane("b", peer: "big-red")],
                                                                           peers: nil))
        let section = LayoutSection(id: LayoutSectionID("sec_top"), showsTitle: false, region: .top, look: .builtIn,
                                    items: [LayoutItem(id: LayoutItemID("itm_home"), ref: .app("cmux/home")),
                                            LayoutItem(id: LayoutItemID("itm_app_store"), ref: .app("cmux/app-store"))])
        let ids = model.placingTransientItems(in: [section]).flatMap(\.items).map(\.id.rawValue)
        #expect(ids == ["itm_home", "itm_app_store", LayoutItemID.transientPrefix + "remote:machine:big-red",
                        LayoutItemID.transientPrefix + "remote:machine:huge-blue"])
    }

    /// Without the App Store the groups follow Channels (anchored after Home), never land before it.
    @Test func groupsFollowChannelsWhenTheAppStoreIsGone() {
        let model = SidebarModel()
        model.transientTopItems = [SidebarTransientItem.channels]
            + Self.rows(RemoteMachinesSidebar.machines(lanes: [Self.lane("a", peer: "huge-blue")], peers: nil))
        let section = LayoutSection(id: LayoutSectionID("sec_top"), showsTitle: false, region: .top, look: .builtIn,
                                    items: [LayoutItem(id: LayoutItemID("itm_home"), ref: .app("cmux/home"))])
        let ids = model.placingTransientItems(in: [section]).flatMap(\.items).map(\.id.rawValue)
        #expect(ids == ["itm_home", SidebarTransientItem.channelsID.rawValue, LayoutItemID.transientPrefix + "remote:machine:huge-blue"])
    }

    @Test func peerListReadsNamesAndLinks() {
        let peers = AcpmuxPeerList.peers(["peers": [["name": "cmux16", "connected": true, "sessions": 484],
                                                    ["name": "big-red", "connected": false], ["connected": true]]])
        #expect(peers == [AcpmuxPeerList.Peer(name: "cmux16", connected: true), AcpmuxPeerList.Peer(name: "big-red", connected: false)])
    }
}

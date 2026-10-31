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
        // The header, a page, Show More, then Older.
        #expect(page.count == 1 + RemoteMachinesSidebar.pageSize + 2)
        #expect(page.dropFirst().allSatisfy { $0.info.indent == 1 })
        #expect(page.dropLast().last?.info.title == RemoteMachinesStrings.showMore)
        #expect(page.last?.info.title == RemoteMachinesStrings.older)
        #expect(Self.rows(machines, expanded: ["huge-blue"], pages: ["huge-blue": 2]).count == 1 + lanes.count + 1)
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

    /// The user 2026-10-25: "pressing cmd 1 no longer takes me to home". Client-only rows anchored after Home in
    /// the document's top block are stops after Home and the App Store, never before them, so Cmd-1 is Home.
    @Test func remoteChatsNeverComeBeforeHomeInTheCmdNumberOrder() throws {
        let model = SidebarModel(sections: [SidebarSection(
            kind: .custom(SidebarCustomSection(id: SidebarLayoutDocument.topSectionID.rawValue, title: "", showsTitle: false)), nodes: [])])
        model.transientTopItems = Self.rows(RemoteMachinesSidebar.machines(lanes: [Self.lane("a", peer: "huge-blue"), Self.lane("b", peer: "big-red")],
                                                                           peers: nil))
        try #require(model.transientTopItems.count == 2)
        let settings = SidebarNavigationSettings(numbering: .allItems, cmd9: .last)
        let first = try #require(model.itemOrder.pick(1, settings))
        #expect(first == .topItem(LayoutItemID("itm_home")), "Cmd-1 is \(first); order \(model.itemOrder.items)")
    }

    /// The user 2026-10-26: "CMUX performance lead, CMUX community lead, and CMUX and chief 2-week/fast iteration
    /// are the ones I actually manually drag up there. Everything that is [a subagent] I did not put there." The top
    /// band holds Home and what the person put there; the agent chats of another machine (here a Cloud VM's eleven
    /// idle Chief subagents, titled with their prompt) never draw in it.
    @Test func remoteChatsNeverDrawInTheTopBand() {
        // A remote model holds the chats, as one would in the running app.
        let remote = RemoteMachinesSidebar(lanes: AgentLaneStore())
        let prompt = "You are a subagent of Chief, an AI agent that works for one user"
        remote.machines = RemoteMachinesSidebar.machines(
            lanes: (0..<11).map { Self.lane("optchat-sub-2e448bc2-a6\($0)", peer: "chief-subagents-2", since: TimeInterval($0), title: prompt) }
                + [Self.lane("busy", peer: "cmux-lawrence", .working, since: 99, title: "Fix the rail")],
            peers: nil)
        defer { remote.machines = [] }
        let model = SidebarModel()
        model.transientTopItems = SidebarModel.topItems(chief: ChiefSidebar(lanes: AgentLaneStore()))
            .filter { $0.item.id != SidebarTransientItem.channelsID }
        let pinned = ["itm_perf", "itm_chromium", "itm_tui"]
        let section = LayoutSection(id: SidebarLayoutDocument.topSectionID, showsTitle: false, region: .top, look: .builtIn,
                                    items: [LayoutItem(id: LayoutItemID("itm_home"), ref: .app("cmux/home"))]
                                        + pinned.map { LayoutItem(id: LayoutItemID($0), ref: .app("example/\($0)")) })
        let ids = model.placingTransientItems(in: [section]).flatMap(\.items).map(\.id.rawValue)
        #expect(ids == ["itm_home"] + pinned, "the top band drew \(ids)")
        #expect(model.transientTopItems.isEmpty, "no client-only remote row at all: \(model.transientTopItems.map(\.info.title))")
    }

    @Test func peerListReadsNamesAndLinks() {
        let peers = AcpmuxPeerList.peers(["peers": [["name": "cmux16", "connected": true, "sessions": 484],
                                                    ["name": "big-red", "connected": false], ["connected": true]]])
        #expect(peers == [AcpmuxPeerList.Peer(name: "cmux16", connected: true), AcpmuxPeerList.Peer(name: "big-red", connected: false)])
    }

    /// Leo 2026-10-24: "how much RAM do you have before you start ... how much CPU utilization". Each peer row's
    /// `health` (acpmux reads it every 60 s) becomes whole numbers, so a reading that moves by a fraction changes nothing.
    @Test func peerListReadsEachMachinesRoomInWholeUnits() {
        let health: [String: Any] = ["cpus": 32, "load": [11.6, 9.0, 8.0], "ram": ["freeBytes": 31_400_000_000, "totalBytes": 64_000_000_000],
                                     "disk": ["freeBytes": 180_200_000_000], "pressure": ["ok": true, "cores": 32]]
        var later = health
        later["load"] = [12.2, 9.0, 8.0]
        let peers = AcpmuxPeerList.peers(["peers": [["name": "huge-blue", "connected": true, "health": health, "healthAt": 1],
                                                    ["name": "old", "connected": true, "health": ["unsupported": true]],
                                                    ["name": "cmux16", "connected": true, "health": NSNull()]]])
        let room = AcpmuxPeerList.Resources(ramFreeGB: 31, coresBusy: 12, cores: 32, diskFreeGB: 180, over: false)
        #expect(peers.map(\.resources) == [room, nil, nil])
        let again = AcpmuxPeerList.peers(["peers": [["name": "huge-blue", "connected": true, "health": later, "healthAt": 2]]])
        #expect(again[0] == peers[0])
        var hot = health
        hot["load"] = [99.0]
        hot["pressure"] = ["ok": false, "cores": 32]
        let busy = AcpmuxPeerList.peers(["peers": [["name": "huge-blue", "connected": true, "health": hot]]])[0].resources
        #expect(busy?.coresBusy == 32 && busy?.over == true)
    }

    /// A partial or bad reading never shows made-up numbers: no core count, a negative or non-finite value, or a
    /// boolean where a number goes means no row; a missing disk only leaves the disk out; `unsupported: false` is no veto.
    @Test func aPartialOrBadReadingShowsNoMadeUpNumbers() {
        let good: [String: Any] = ["load": [3.0], "ram": ["freeBytes": 8_000_000_000], "pressure": ["ok": true, "cores": 8]]
        func room(_ h: [String: Any]) -> AcpmuxPeerList.Resources? {
            AcpmuxPeerList.peers(["peers": [["name": "m", "connected": true, "health": h]]])[0].resources
        }
        #expect(room(good) == .init(ramFreeGB: 8, coresBusy: 3, cores: 8, diskFreeGB: nil, over: false))
        var flagged = good
        flagged["unsupported"] = false
        #expect(room(flagged) != nil)
        var noCores = good
        noCores["pressure"] = ["ok": true]
        #expect(room(noCores) == nil)
        var cpus = noCores
        cpus["cpus"] = 4
        #expect(room(cpus)?.cores == 4)
        for bad: Any in [-1.0, Double.nan, Double.infinity, 1e300, true, "8"] {
            var h = good
            h["ram"] = ["freeBytes": bad]
            #expect(room(h) == nil, "ram \(bad)")
            h = good
            h["load"] = [bad]
            #expect(room(h) == nil, "load \(bad)")
            h = good
            h["disk"] = ["freeBytes": bad]
            #expect(room(h)?.diskFreeGB == nil, "disk \(bad)")
        }
    }

    @Test func anUnfoldedMachineSaysItsRoomFirstAndTheHeaderStyleNamesItsFreeRAM() {
        let room = AcpmuxPeerList.Resources(ramFreeGB: 31, coresBusy: 12, cores: 32, diskFreeGB: 180, over: false)
        let peers = [AcpmuxPeerList.Peer(name: "huge-blue", connected: true, resources: room),
                     AcpmuxPeerList.Peer(name: "big-red", connected: false, resources: room)]
        let machines = RemoteMachinesSidebar.machines(lanes: [Self.lane("a", peer: "huge-blue")], peers: peers)
        #expect(machines.first { $0.peer == "big-red" }?.resources == nil)
        let rows = RemoteMachinesSidebar.rows(machines: machines, expanded: ["huge-blue", "big-red"], pages: [:], resources: .row,
                                              displayName: { _ in nil })
        #expect(rows.map(\.info.title) == ["huge-blue", "31 GB free · CPU 12/32", "a", RemoteMachinesStrings.older,
                                            RemoteMachinesStrings.offline("big-red")])
        #expect(rows[1].info.indent == 1)
        // VoiceOver names the machine on its room row.
        #expect(rows[1].info.accessibilityTitle == "huge-blue: 31 GB free · CPU 12/32")
        // The room row does nothing on a click, and folded groups show no row.
        let sidebar = RemoteMachinesSidebar(lanes: AgentLaneStore())
        #expect(sidebar.activate(rows[1].item.id))
        let folded = RemoteMachinesSidebar.rows(machines: machines, expanded: [], pages: [:], resources: .row, displayName: { _ in nil })
        #expect(folded.count == 2)
        let header = RemoteMachinesSidebar.rows(machines: machines, expanded: [], pages: [:], resources: .header, displayName: { _ in nil })
        #expect(header.map(\.info.title) == ["huge-blue · 31 GB free", RemoteMachinesStrings.offline("big-red")])
        let off = RemoteMachinesSidebar.rows(machines: machines, expanded: ["huge-blue"], pages: [:], resources: .off, displayName: { _ in nil })
        #expect(off.map(\.info.title) == ["huge-blue", "a", RemoteMachinesStrings.older, RemoteMachinesStrings.offline("big-red")])
        var hot = room
        hot.over = true
        hot.diskFreeGB = 8
        #expect(RemoteMachinesStrings.resources(hot) == "Busy · 31 GB free · CPU 12/32 · 8 GB disk")
        // No disk reading: no disk part, never "0 GB disk". One core reads "CPU 1/1".
        #expect(RemoteMachinesStrings.resources(.init(ramFreeGB: 1, coresBusy: 1, cores: 1, diskFreeGB: nil, over: false)) == "1 GB free · CPU 1/1")
    }

    /// Closed chats never count: they sit behind an Older row, dimmed, a page at a time.
    @Test func olderShowsTheReadClosedChatsDimmedThenShowMore() {
        let machines = RemoteMachinesSidebar.machines(lanes: [Self.lane("a", peer: "huge-blue")], peers: nil)
        var read = RemoteMachinesSidebar.Older()
        read.chats = [AcpmuxSessionPage.Chat(id: "c1", title: "Old fix", harness: "claude")]
        (read.next, read.read) = ("k1.2", true)
        let rows = RemoteMachinesSidebar.rows(machines: machines, expanded: ["huge-blue"], pages: [:], resources: .off,
                                              olderShown: ["huge-blue"], older: ["huge-blue": read], displayName: { _ in nil })
        #expect(rows.map(\.info.title) == ["huge-blue", "a", RemoteMachinesStrings.older, "Old fix", RemoteMachinesStrings.showMore])
        #expect(rows[0].info.badge == 1)
        #expect(rows[3].info.isMissing && rows[3].info.indent == 2)
        #expect(rows[3].item.id.rawValue == LayoutItemID.transientPrefix + "remote:older-session:huge-blue/c1")
        // Closed: the rows stay but the chats hide.
        let closed = RemoteMachinesSidebar.rows(machines: machines, expanded: ["huge-blue"], pages: [:], resources: .off,
                                                older: ["huge-blue": read], displayName: { _ in nil })
        #expect(closed.map(\.info.title) == ["huge-blue", "a", RemoteMachinesStrings.older])
    }

    @Test func olderOpensAndClosesAndAFoldForgetsIt() {
        let sidebar = RemoteMachinesSidebar(lanes: AgentLaneStore())
        sidebar.expanded = ["huge-blue"]
        let olderRow = LayoutItemID(LayoutItemID.transientPrefix + "remote:older:huge-blue")
        #expect(sidebar.activate(olderRow))
        #expect(sidebar.olderShown == ["huge-blue"])
        #expect(sidebar.activate(olderRow))
        #expect(sidebar.olderShown.isEmpty)
        #expect(sidebar.activate(olderRow))
        #expect(sidebar.activate(LayoutItemID(LayoutItemID.transientPrefix + "remote:machine:huge-blue")))
        #expect(sidebar.olderShown.isEmpty && sidebar.older["huge-blue"] == nil)
        sidebar.expanded = []
    }

    @Test func aSessionsPageReadsTitlesAndTheNextCursor() {
        let closed = ["peer": "cmux16", "status": "closed"]
        let page = AcpmuxSessionPage.page(["sessions": [closed.merging(["sessionId": "s1", "name": "cmux16/cx3-dots", "title": "Dots", "harness": "codex"]) { $1 },
                                                         closed.merging(["sessionId": "s2", "name": "cmux16/cx3-rail", "title": "cmux16/cx3-rail"]) { $1 },
                                                         closed.merging(["name": "no-id"]) { $1 },
                                                         // An older daemon ignores the filters: another peer's, this Mac's and a live chat stay out.
                                                         ["sessionId": "o1", "name": "huge-blue/x", "peer": "huge-blue", "status": "closed"],
                                                         ["sessionId": "o2", "name": "local", "status": "closed"],
                                                         ["sessionId": "o3", "name": "cmux16/live", "peer": "cmux16", "status": "idle"]],
                                           "nextCursor": "k5.9"], peer: "cmux16")
        #expect(page.chats == [AcpmuxSessionPage.Chat(id: "s1", title: "Dots", harness: "codex"),
                               AcpmuxSessionPage.Chat(id: "s2", title: "cx3-rail", harness: nil)])
        #expect(page.next == "k5.9")
        #expect(AcpmuxSessionPage.page(["sessions": [], "nextCursor": NSNull()], peer: "cmux16").next == nil)
    }
}

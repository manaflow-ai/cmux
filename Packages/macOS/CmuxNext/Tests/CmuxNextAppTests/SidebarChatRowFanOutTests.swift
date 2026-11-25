import AppKit
import CmuxNextAgentPane
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Leo's NIGHTLY, 2026-11-21 (620 workspace entries, 214 agent chats, about 10 streaming): 18 % of the main thread's
/// busy time was `SidebarRowFeed.flush` mapping rows again from the display frame. A streaming chat changes its own
/// session's facts (turn state, last message, usage detail, its tab's presence, a new subagent session record): each
/// such change must map that chat's row only, never every chat row of the sidebar (Leo: interaction cost stays
/// constant as workspaces, sessions and panes grow).
///
/// The rows are the app's own mapping (`SidebarBridge.sections`, `AppServices.sidebarPageFace`,
/// `SidebarBridge.tabTitle`) through a row feed whose frames run by hand, as `SidebarRowFanOutTests` does, over
/// workspaces that each hold one agent chat tab of its own session.
@MainActor @Suite(.serialized) struct SidebarChatRowFanOutTests {
    nonisolated static let count = 40
    static let host = "install:chat-fan-out"
    static func keys(_ count: Int) -> [String] { (0..<count).map { String(format: "c%04d", $0) } }
    static func session(_ index: Int) -> String { "chat-fan-out-s\(index)" }
    static func surface(_ index: Int) -> SurfaceID { SurfaceID(rawValue: UInt64(index + 1) * 100 + 1) }

    /// Workspace `key`: one pane holding one agent chat tab of its own session.
    static func workspace(_ key: String, index: Int) -> WorkspaceSnapshot {
        let base = UInt64(index + 1) * 100
        var chat = TabSnapshot(surface: surface(index), kind: .conversation, cwd: "/tmp/\(key)")
        chat.title = "chat \(key)"
        chat.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: host, session: session(index), harness: "claude"))
        let pane = PaneSnapshot(id: PaneID(rawValue: base), tabs: [chat])
        let screen = ScreenSnapshot(id: ScreenID(rawValue: base), layout: .leaf(PaneID(rawValue: base)), panes: [pane])
        return WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64(index + 1)), key: WorkspaceKey(rawValue: key), name: key, screens: [screen])
    }

    static func tree(_ keys: [String]) -> DaemonTree {
        var tree = DaemonTree(registryID: "s-local", workspaces: keys.enumerated().map { workspace($1, index: $0) })
        tree.personal = PersonalState(groups: [], workspaces: keys.enumerated().map { index, key in
            PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: key), index: index, group: nil)
        })
        return tree
    }

    @MainActor final class Fixture {
        let services: AppServices
        let state: WindowState
        let feed: SidebarRowFeed
        final class Frames { var work: [@MainActor @Sendable () -> Void] = [] }
        let frames = Frames()
        private(set) var listed = 0
        let keys: [String]

        /// `count` chat rows; the chats from `recorded` on have no session record (acpmux no longer lists their session,
        /// or the watch has not sent it yet), as many of a long-lived sidebar's chats do.
        init(count: Int = SidebarChatRowFanOutTests.count, recorded: Int? = nil) throws {
            _ = NSApplication.shared
            keys = SidebarChatRowFanOutTests.keys(count)
            AgentTurnStateStore.shared.mirroredHosts.insert(SidebarChatRowFanOutTests.host)
            for index in 0..<count { AgentTurnStateStore.shared.sessionEnded(SidebarChatRowFanOutTests.session(index)) }
            for index in 0..<(recorded ?? count - 1) {
                AgentTurnStateStore.shared.apply(session: SidebarChatRowFanOutTests.session(index), state: nil, lastMessage: "hello \(index)",
                                                 muted: false, title: "chat \(index)", detail: nil, recordsTimeline: false)
            }
            services = AppServices(environment: AppEnvironment.current([:]))
            let store = services.machines.local.store
            let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(#"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1"}"#.utf8))
            store.noteHandshake(identity)
            store.connectionState = .connected(identity)
            store.apply(snapshot: SidebarChatRowFanOutTests.tree(keys))
            let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"chat-fan-out","workspace_key":"chat-fan-out-home"}"#.utf8))
            state = WindowState(record: record)
            services.windows.registry.provisional[state.id] = keys
            feed = SidebarRowFeed(schedule: { [frames] work in frames.work.append(work) })
            pass()
            frame()
        }

        func pass() {
            feed.beginPass(inputs: 0)
            let sections = SidebarBridge.sections(services.machines, doc: services.sidebarDoc, members: keys,
                                                  profile: state.profileID, pageFace: services.sidebarPageFace,
                                                  tabTitle: SidebarBridge.tabTitle(services), rows: feed.rowSource)
            listed = feed.fill(sections).flatMap(\.workspaces).count
        }

        func frame() {
            let work = frames.work
            frames.work.removeAll()
            work.forEach { $0() }
        }

        /// The rows `body` invalidated and the rows the next frame mapped again (no structural pass: a chat's
        /// stream changes no structure).
        func cost(_ body: () -> Void) -> (invalidated: Int, mapped: Int) {
            let measured = timedCost(body)
            return (measured.invalidated, measured.mapped)
        }

        /// `cost`, with the frame's main-thread time in microseconds.
        func timedCost(_ body: () -> Void) -> (invalidated: Int, mapped: Int, frameUs: Int) {
            _ = SidebarPerfCounters.report(reset: true)
            body()
            let start = DispatchTime.now().uptimeNanoseconds
            frame()
            let us = Int((DispatchTime.now().uptimeNanoseconds - start) / 1000)
            let report = SidebarPerfCounters.report(reset: true)
            return (report["row_invalidations"] ?? 0, report["row_maps"] ?? 0, us)
        }

        func tearDown() {
            feed.reset()
            AgentTurnStateStore.shared.mirroredHosts.remove(SidebarChatRowFanOutTests.host)
        }
    }

    @Test func aStreamingChatMapsOnlyItsOwnRow() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let turns = AgentTurnStateStore.shared, store = fixture.services.machines.local.store
        #expect(fixture.listed == Self.count, "the fixture lists every workspace")
        let s = Self.session(3)
        let working = fixture.cost {
            turns.apply(session: s, state: .working, lastMessage: "hello 3", muted: false, title: "chat 3", detail: nil, recordsTimeline: false)
        }
        let message = fixture.cost {
            turns.apply(session: s, state: .working, lastMessage: "streaming text", muted: false, title: "chat 3", detail: nil, recordsTimeline: false)
        }
        let usage = fixture.cost {
            var detail = AgentChatDetail()
            detail.contextTokens = 1200
            turns.apply(session: s, state: .working, lastMessage: "streaming text", muted: false, title: "chat 3", detail: detail, recordsTimeline: false)
        }
        let presence = fixture.cost {
            _ = store.apply(.agentPresenceChanged(AgentPresence(surface: Self.surface(3), activity: .editing, agent: "claude", path: "/r/a.rs")))
        }
        // A subagent of that chat starts: a session record nobody's tab shows is made.
        let subagent = fixture.cost {
            turns.apply(session: "chat-fan-out-sub-\(UUID().uuidString)", state: .working, lastMessage: nil, muted: false, title: nil,
                        detail: nil, recordsTimeline: false)
        }
        let all = [("working", working), ("message", message), ("usage", usage), ("presence", presence), ("subagent", subagent)]
        print("SIDEBAR-CHAT-FAN-OUT n=\(Self.count) " + all.map { "\($0.0)=\($0.1)" }.joined(separator: " "))
        for (name, cost) in all.dropLast() {
            #expect(cost.invalidated <= 1, "a chat's \(name) change invalidated \(cost.invalidated) of \(Self.count) rows")
            #expect(cost.mapped <= 1, "a chat's \(name) change mapped \(cost.mapped) of \(Self.count) rows")
        }
        // A record made for a session no row shows maps no row; the one row whose chat has no record yet may read again.
        #expect(subagent.mapped <= 1, "a new session record mapped \(subagent.mapped) of \(Self.count) rows")
    }

    /// Half the chats have no session record. A record made for another session (a subagent starts, a peer's chat
    /// appears: many a minute under ten streaming agents) maps none of their rows, at 40 rows as at 400.
    @Test(arguments: [40, 400]) func aNewSessionRecordMapsNoRecordlessRow(count: Int) throws {
        let fixture = try Fixture(count: count, recorded: count / 2)
        defer { fixture.tearDown() }
        #expect(fixture.listed == count)
        let made = fixture.timedCost {
            AgentTurnStateStore.shared.apply(session: "chat-fan-out-new-\(UUID().uuidString)", state: .working, lastMessage: nil, muted: false,
                                             title: nil, detail: nil, recordsTimeline: false)
        }
        print("SIDEBAR-CHAT-FAN-OUT new-record n=\(count) recordless=\(count - count / 2) \(made)")
        #expect(made.mapped == 0, "a new session record mapped \(made.mapped) of \(count) rows (\(made.frameUs) us)")
    }

    /// One chat streams (its state, last message and presence move each frame): the frame's cost is that one row's, at
    /// 40 rows as at 400.
    @Test(arguments: [40, 400]) func aStreamingTickCostsOneRowAtAnySize(count: Int) throws {
        let fixture = try Fixture(count: count, recorded: count)
        defer { fixture.tearDown() }
        let store = fixture.services.machines.local.store
        var maps: [Int] = [], us: [Int] = []
        for step in 0..<20 {
            let tick = fixture.timedCost {
                AgentTurnStateStore.shared.apply(session: Self.session(7), state: .working, lastMessage: "step \(step)", muted: false,
                                                 title: "chat 7", detail: nil, recordsTimeline: false)
                _ = store.apply(.agentPresenceChanged(AgentPresence(surface: Self.surface(7), activity: step % 2 == 0 ? .editing : .reading,
                                                                    agent: "claude", path: "/r/\(step).rs")))
            }
            maps.append(tick.mapped)
            us.append(tick.frameUs)
        }
        let sorted = us.sorted()
        print("SIDEBAR-CHAT-FAN-OUT tick n=\(count) maps=\(maps.reduce(0, +))/20 frame_us p50=\(sorted[10]) max=\(sorted.last ?? 0)")
        #expect(maps.allSatisfy { $0 <= 1 }, "a streaming tick mapped \(maps) rows of \(count)")
    }

    /// A subagent pane's page names what it shows (`chat.subagentShown`, many a minute while subagents stream): its
    /// own tab's title changes, and no chat row reads it again, at 40 rows as at 400. Each chat row's title reads
    /// `SubagentTabTitles` for its own tab; before, a write for any tab woke every one.
    @Test(arguments: [40, 400]) func aSubagentPaneShowingAnotherSubagentMapsNoChatRow(count: Int) throws {
        let fixture = try Fixture(count: count, recorded: count)
        defer { fixture.tearDown() }
        let tab = "chat-fan-out-subagent-pane-\(UUID().uuidString)"
        var maps: [Int] = []
        for step in 0..<10 {
            let shown = fixture.timedCost {
                SubagentTabTitles.shared.show("subagent \(step)", inTab: tab, tone: step % 3, mark: nil)
                SubagentTabTitles.shared.showFacts(nil, inTab: tab)
            }
            maps.append(shown.mapped)
        }
        let again = fixture.cost { SubagentTabTitles.shared.show("subagent 9", inTab: tab, tone: 0, mark: nil) }
        print("SIDEBAR-CHAT-FAN-OUT subagent-shown n=\(count) maps=\(maps) same-value=\(again)")
        #expect(maps.allSatisfy { $0 == 0 }, "a subagent pane's subagentShown mapped \(maps) of \(count) chat rows")
        #expect(again.mapped == 0)
        SubagentTabTitles.shared.bind("none", of: "none", toTab: tab) { $0 != tab }
    }
}

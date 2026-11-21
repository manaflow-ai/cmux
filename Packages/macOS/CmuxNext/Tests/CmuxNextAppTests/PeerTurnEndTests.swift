import AppKit
import CmuxNextActions
import CmuxNextAgentActivity
@testable import CmuxNextAgentLanes
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextDaemon
import CmuxNextDesign
@testable import CmuxNextKeepAwake
@testable import CmuxNextSettings
import Foundation
import Observation
import Testing

/// Design audit 2026-11-18, finding 7: a push of an acpmux peer's session wrote the peer's state into this
/// Mac's record of the session id. So each peer turn end walked every tab of every workspace on main
/// (O(1,600 tabs) per turn end of any of ~30 machines), and `hasWorkingSession` held this Mac awake while
/// any other machine's agent worked. A peer push now writes only that peer's row; a turn end reaches only
/// the chat's own tabs, through the store's index by session id; the working count is this Mac's sessions.
@MainActor @Suite(.serialized)
struct PeerTurnEndTests {
    static let peerSession = "peer-turn-end-s1"

    /// A `_acpmux/session_changed` of `session` as peer `peer`'s row on this Mac's acpmux.
    static func peerChange(_ peer: String, session: String = peerSession, indicator: String) throws -> AgentTurnStateFeed.Message {
        let line = #"{"jsonrpc":"2.0","method":"_acpmux/session_changed","params":{"sessionId":"\#(session)","peer":"\#(peer)","session":{"sessionId":"\#(session)","indicator":"\#(indicator)","peer":"\#(peer)"}}}"#
        return try #require(AgentTurnStateFeed.Message(line: Data(line.utf8)))
    }

    /// A `_acpmux/session_changed` of this Mac's own session `session`.
    static func localChange(_ session: String, indicator: String) throws -> AgentTurnStateFeed.Message {
        let line = #"{"jsonrpc":"2.0","method":"_acpmux/session_changed","params":{"sessionId":"\#(session)","session":{"sessionId":"\#(session)","indicator":"\#(indicator)"}}}"#
        return try #require(AgentTurnStateFeed.Message(line: Data(line.utf8)))
    }

    /// `workspaces` workspaces of `tabsEach` agent chat tabs: the first tab shows the peer's chat, every other one
    /// a chat of this Mac.
    static func session(workspaces: Int, tabsEach: Int) -> DaemonTree {
        var trees: [WorkspaceSnapshot] = []
        var surface: UInt64 = 0
        for w in 0..<workspaces {
            var tabs: [TabSnapshot] = []
            for t in 0..<tabsEach {
                surface += 1
                var tab = TabSnapshot(surface: SurfaceID(rawValue: surface), kind: .conversation, cwd: nil)
                let peer = w == 0 && t == 0
                tab.conversation = ConversationTabRef(agentSession: AgentSessionRef(
                    host: peer ? "registry:peer-turn-end" : "install:peer-turn-end", hostName: peer ? "lab" : nil,
                    session: peer ? peerSession : "local-\(surface)", harness: "claude"))
                tabs.append(tab)
            }
            let id = UInt64(w + 1)
            let pane = PaneSnapshot(id: PaneID(rawValue: id), tabs: tabs)
            let screen = ScreenSnapshot(id: ScreenID(rawValue: id), layout: .leaf(PaneID(rawValue: id)), panes: [pane])
            trees.append(WorkspaceSnapshot(id: WorkspaceHandle(rawValue: id), key: nil, name: "w\(w)", screens: [screen]))
        }
        return DaemonTree(workspaces: trees)
    }

    nonisolated final class Flag: @unchecked Sendable { var raised = false }

    /// The detector: a peer's turn end reads the tabs of its own session and no other. Base walked every
    /// tab of every workspace (it read each tab's `agentSession`), so a change of any other tab's facts
    /// after the turn end woke what it read.
    @Test func aPeerTurnEndReadsNoTabOutsideItsOwnSession() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.daemon.store
        store.apply(snapshot: Self.session(workspaces: 20, tabsEach: 10))
        let tabs = store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs)
        let target = try #require(tabs.first { $0.agentSession?.session == Self.peerSession })
        let service = NotificationCenterService()
        service.services = services
        let turns = AgentTurnStateStore()
        turns.localHost = "install:peer-turn-end"
        turns.onTurnEnded = { [weak service] in service?.agentTurnEnded($0) }
        let feed = AgentTurnStateFeed(socketPath: "/nonexistent/peer-turn-end.sock", turns: turns, lanes: AgentLaneStore())
        let design = DesignSettings.shared
        let before = design.attention
        defer { design.attention = before }
        design.attention = AttentionSettings()
        design.attention.agentChatRing = .ring

        feed.handle(try Self.peerChange("lab", indicator: "working"))
        let end = try Self.peerChange("lab", indicator: "idle")
        let woke = Flag()
        withObservationTracking {
            feed.handle(end)
        } onChange: {
            woke.raised = true
        }
        #expect(service.agentFinished[target.id] != nil, "the peer chat's tab did not ring when its turn ended")
        // Every fact a walk of the tabs reads, changed on every tab but the peer chat's.
        for tab in tabs where tab !== target { tab.formerLocalHosts = ["install:former": "install:peer-turn-end"] }
        #expect(!woke.raised, "a peer's turn end read tabs outside its own session (a walk of every tab of every workspace)")
        #expect(turns.state(for: AgentSessionRef(host: "install:peer-turn-end", session: Self.peerSession)) == nil,
                "a peer's push wrote this Mac's state of the session id")
    }

    /// A chat of this Mac rings through the same index, and its turn end reads only its own tabs too.
    @Test func aLocalTurnEndRingsOnlyItsOwnTabs() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.daemon.store
        store.apply(snapshot: Self.session(workspaces: 4, tabsEach: 5))
        let tabs = store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs)
        let local = try #require(tabs.last)
        let session = try #require(local.agentSession?.session)
        let service = NotificationCenterService()
        service.services = services
        let turns = AgentTurnStateStore()
        turns.localHost = "install:peer-turn-end"
        turns.onTurnEnded = { [weak service] in service?.agentTurnEnded($0) }
        let feed = AgentTurnStateFeed(socketPath: "/nonexistent/peer-turn-end-local.sock", turns: turns, lanes: AgentLaneStore())
        let design = DesignSettings.shared
        let before = design.attention
        defer { design.attention = before }
        design.attention = AttentionSettings()
        design.attention.agentChatRing = .ring
        feed.handle(try Self.localChange(session, indicator: "working"))
        feed.handle(try Self.localChange(session, indicator: "idle"))
        #expect(Set(service.agentFinished.keys) == [local.id], "a turn end rang tabs of other chats")
    }

    /// The index follows the tree: a chat tab that closes leaves it, one that comes is in it.
    @Test func theSessionIndexFollowsTabsThatComeAndGo() {
        let store = DaemonStore()
        store.apply(snapshot: Self.session(workspaces: 2, tabsEach: 3))
        #expect(store.tabs(agentSession: Self.peerSession).count == 1)
        #expect(store.tabs(agentSession: "local-6").count == 1)
        store.apply(snapshot: Self.session(workspaces: 1, tabsEach: 3))
        #expect(store.tabs(agentSession: "local-6").isEmpty, "a closed chat tab stayed in the index")
        #expect(store.tabs(agentSession: Self.peerSession).count == 1)
    }

    /// Session ids are each daemon's own: this Mac, the lab and another peer each have a chat `shared`. A turn
    /// end of one rings only the tab of that machine's chat, never the others' tabs of the same id.
    @Test func aTurnEndRingsOnlyTheTabOfTheMachineWhoseTurnItWas() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.daemon.store
        let refs = [AgentSessionRef(host: "install:peer-turn-end", session: "shared", harness: "claude"),
                    AgentSessionRef(host: "registry:lab", hostName: "lab", session: "shared", harness: "claude"),
                    AgentSessionRef(host: "registry:elsewhere", hostName: "Elsewhere", session: "shared", harness: "claude")]
        let tabs = refs.enumerated().map { index, ref in
            var tab = TabSnapshot(surface: SurfaceID(rawValue: UInt64(index + 1)), kind: .conversation, cwd: nil)
            tab.conversation = ConversationTabRef(agentSession: ref)
            return tab
        }
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [PaneSnapshot(id: 1, tabs: tabs)])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [screen])]))
        let models = store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs)
        let ids = Dictionary(uniqueKeysWithValues: models.compactMap { tab in tab.agentSession.map { ($0.host, tab.id) } })
        let id = { (host: String) in ids[host] ?? "" }
        let service = NotificationCenterService()
        service.services = services
        let turns = AgentTurnStateStore()
        turns.localHost = "install:peer-turn-end"
        turns.onTurnEnded = { [weak service] in service?.agentTurnEnded($0, in: store, mirrorPeer: { _ in nil }, rings: true, viewed: { _ in false }) }
        let feed = AgentTurnStateFeed(socketPath: "/nonexistent/peer-turn-end-shared.sock", turns: turns, lanes: AgentLaneStore())

        feed.handle(try Self.peerChange("lab", session: "shared", indicator: "working"))
        feed.handle(try Self.localChange("shared", indicator: "working"))
        feed.handle(try Self.peerChange("lab", session: "shared", indicator: "idle"))
        #expect(Set(service.agentFinished.keys) == [id("registry:lab")], "the lab's turn end rang another machine's chat of the same id")
        feed.handle(try Self.localChange("shared", indicator: "idle"))
        #expect(Set(service.agentFinished.keys) == [id("registry:lab"), id("install:peer-turn-end")],
                "this Mac's turn end did not ring only this Mac's chat")
        // The other peer's turn end rings that peer's tab (its name matched in any case).
        feed.handle(try Self.peerChange("elsewhere", session: "shared", indicator: "working"))
        feed.handle(try Self.peerChange("elsewhere", session: "shared", indicator: "idle"))
        #expect(Set(service.agentFinished.keys) == Set(models.map(\.id)))
    }

    /// A tab of this Mac's host bound to a peer's mirrored session (cx-k21v) is that peer's chat: the peer's turn end
    /// rings it, this Mac's own turn end of the same id does not, and another peer's does not.
    @Test func aMirroredPeerChatTabIsThatPeersChat() {
        let mirrored = AgentSessionRef(host: "install:here", session: "m1")
        let own = AgentSessionRef(host: "install:here", session: "o1")
        let mirrorPeer = { (session: String) in session == "m1" ? "lab" : nil }
        let here: Set<String> = ["install:here", "chief:1"]
        #expect(AgentTurnEnd(session: "m1", peer: "lab", hostsHere: here).reaches(mirrored, mirrorPeer: mirrorPeer))
        #expect(!AgentTurnEnd(session: "m1", peer: "other", hostsHere: here).reaches(mirrored, mirrorPeer: mirrorPeer))
        #expect(!AgentTurnEnd(session: "m1", hostsHere: here).reaches(mirrored, mirrorPeer: mirrorPeer))
        #expect(AgentTurnEnd(session: "o1", hostsHere: here).reaches(own, mirrorPeer: mirrorPeer))
        #expect(!AgentTurnEnd(session: "o1", peer: "lab", hostsHere: here).reaches(own, mirrorPeer: mirrorPeer))
        #expect(AgentTurnEnd(session: "c1", hostsHere: here).reaches(AgentSessionRef(host: "chief:1", session: "c1"), mirrorPeer: mirrorPeer))
    }

    /// A peer's row of an id a mirrored acpmux holds (the Chief home's) never takes that record from it: this Mac's
    /// next page, which does not list the id as its own, leaves the mirrored chat's state and title as they were.
    @Test func aPeerRowLeavesAMirroredChatOfTheSameIdItsOwn() throws {
        let turns = AgentTurnStateStore()
        turns.localHost = "install:peer-turn-end"
        turns.mirroredHosts = ["chief:1"]
        let ref = AgentSessionRef(host: "chief:1", session: "c1")
        turns.apply(session: "c1", state: .working, lastMessage: nil, muted: false, title: "Chief task", detail: nil, source: "chief:1")
        // A push of the lab's row of c1, then this Mac's own page, which lists none of its own.
        turns.apply(session: "c1", state: .working, lastMessage: "the lab's last line", muted: false, title: "The lab's chat", detail: nil,
                    peer: AgentPeerRow(name: "lab", stale: false, state: .working), peerName: "lab")
        #expect(turns.title(for: ref) == "Chief task", "a peer's push wrote its chat's title over the mirrored chat of the same id")
        #expect(turns.lastMessage(for: ref) == nil, "a peer's push wrote its chat's last message over the mirrored chat of the same id")
        turns.replace(states: AgentTurnStates(), lastMessages: [:], muted: [], titles: [:], details: [:])
        #expect(turns.state(for: ref) == .working, "a peer's push took the mirrored chat's record, and this Mac's page cleared it")
        #expect(turns.title(for: ref) == "Chief task")
        // A page with the lab's row of c1 lays the row and leaves the mirrored chat's facts.
        turns.replace(states: AgentTurnStates(), lastMessages: [:], muted: [], titles: [:], details: [:],
                      peers: ["c1": ["lab": AgentPeerRow(name: "lab", stale: false)]])
        #expect(turns.state(for: ref) == .working, "a page's peer row of the id cleared the mirrored chat's state")
        #expect(turns.title(for: ref) == "Chief task")
        #expect(turns.peerRows("c1")["lab"] == AgentPeerRow(name: "lab", stale: false))
    }

    /// Leo, 2026-11-18, to "stay awake for local agents, and ignore other machines'": "Yeah sure". An agent of
    /// another machine working holds no sleep assertion here; this Mac's own agent working does. Read from the
    /// real service and from `pmset -g assertions` for this process.
    @Test func peerOnlyWorkHoldsNoSleepAssertionAndLocalWorkDoes() async throws {
        _ = NSApplication.shared
        let turns = AgentTurnStateStore.shared
        let feed = AgentTurnStateFeed(socketPath: "/nonexistent/peer-turn-end-awake.sock", turns: turns, lanes: AgentLaneStore())
        let peers = (0..<30).map { "peer-\($0)" }
        let rest = try peers.map { try Self.peerChange($0, session: "awake-\($0)", indicator: "idle") }
            + [try Self.peerChange("lab", session: "awake-local", indicator: "idle"), try Self.localChange("awake-local", indicator: "idle")]
        defer { for message in rest { feed.handle(message) } }
        let directory = FileManager.default.temporaryDirectory.appending(path: "peer-turn-end-awake-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "cmux.json")
        try Data("{}".utf8).write(to: url)
        let settings = SettingsController(writer: TestSettingsWriter(), registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        let keepAwake = KeepAwakeService()
        Self.kept.append(keepAwake) // its power-source monitor has an unretained context: never freed in this process
        keepAwake.start(settings: settings, store: DaemonStore())
        await LargeSessionFixture.drainMain()

        // Thirty machines' agents work; this Mac's are idle (one shares a session id with a peer's row).
        for peer in peers { feed.handle(try Self.peerChange(peer, session: "awake-\(peer)", indicator: "working")) }
        feed.handle(try Self.peerChange("lab", session: "awake-local", indicator: "working"))
        await LargeSessionFixture.drainMain()
        #expect(!turns.hasWorkingSession, "another machine's working agent read as this Mac's")
        #expect(turns.workingSessions == 0)
        #expect(!keepAwake.policy.agentsWorking, "peer-only work asked to keep this Mac awake")
        #expect(!keepAwake.policy.holds)
        let peerOnly = try await Self.holdsSleepAssertion()
        #expect(!peerOnly, "peer-only work holds a sleep assertion (pmset -g assertions)")

        // This Mac's own agent works: the hold is on (on adapter power, the default `sessions.keepAwake`).
        feed.handle(try Self.localChange("awake-local", indicator: "working"))
        await LargeSessionFixture.until { keepAwake.policy.agentsWorking }
        #expect(turns.hasWorkingSession && turns.workingSessions == 1)
        #expect(keepAwake.policy.agentsWorking, "this Mac's working agent did not ask to keep it awake")
        if !keepAwake.policy.onBattery {
            #expect(keepAwake.policy.holds)
            let local = try await Self.holdsSleepAssertion()
            #expect(local, "this Mac's working agent holds no sleep assertion (pmset -g assertions)")
        }

        // Its turn ends while the peers still work: the hold goes.
        feed.handle(try Self.localChange("awake-local", indicator: "idle"))
        await LargeSessionFixture.until { !keepAwake.policy.agentsWorking }
        #expect(!keepAwake.policy.holds, "the peers' work kept the hold after this Mac's agent stopped")
        let after = try await Self.holdsSleepAssertion()
        #expect(!after, "the hold stayed after this Mac's agent stopped (pmset -g assertions)")
    }

    private static var kept: [KeepAwakeService] = []

    /// Whether this process holds the keep-awake service's assertion, as `pmset -g assertions` lists it.
    static func holdsSleepAssertion() async throws -> Bool {
        let file = FileManager.default.temporaryDirectory.appending(path: "peer-turn-end-pmset-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: file) }
        let out = try FileHandle(forWritingTo: file)
        defer { try? out.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "assertions"]
        process.standardOutput = out
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in done.resume() }
            do { try process.run() } catch { process.terminationHandler = nil; done.resume() }
        }
        let output = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let pid = ProcessInfo.processInfo.processIdentifier
        return output.split(separator: "\n").contains { line in
            line.contains("pid \(pid)(") && line.contains("cmux keeps this Mac awake")
        }
    }

    /// When the Mac wakes, a peer's chats catch up from one list read: the page lays every peer row over the
    /// store at once, each row as the page has it, and this Mac's states of the same ids stay its own.
    @Test func aPeersChatsCatchUpFromOnePageAfterAWake() throws {
        let turns = AgentTurnStateStore()
        turns.localHost = "install:peer-turn-end"
        let feed = AgentTurnStateFeed(socketPath: "/nonexistent/peer-turn-end-wake.sock", turns: turns, lanes: AgentLaneStore())
        var ended: [String] = []
        turns.onTurnEnded = { ended.append($0.session) }
        feed.handle(try Self.peerChange("lab", session: "w1", indicator: "working"))
        feed.handle(try Self.peerChange("lab", session: "w2", indicator: "working"))
        feed.handle(try Self.localChange("w3", indicator: "working"))
        // Asleep: the lab's w1 finished, w2 still works; this Mac's w3 finished too. One page on wake.
        let page = #"{"jsonrpc":"2.0","id":2,"result":{"sessions":[{"sessionId":"w1","indicator":"idle","peer":"lab"},{"sessionId":"w2","indicator":"working","peer":"lab"},{"sessionId":"w3","indicator":"idle"}]}}"#
        feed.handle(try #require(AgentTurnStateFeed.Message(line: Data(page.utf8))))
        let ref = { (session: String) in AgentSessionRef(host: "registry:lab", hostName: "lab", session: session) }
        #expect(!turns.isWorking(ref("w1"), isChatMachine: { $0 == "lab" }), "a peer's chat that finished while asleep still reads as working")
        #expect(turns.isWorking(ref("w2"), isChatMachine: { $0 == "lab" }))
        #expect(ended.sorted() == ["w1", "w3"],"the page's turn ends were not told once each")
        #expect(!turns.hasWorkingSession, "a peer's working row on the page counted as this Mac's")
        #expect(turns.state(for: AgentSessionRef(host: "install:peer-turn-end", session: "w2")) == nil)
    }
}

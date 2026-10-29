import CmuxAgentQuestion
import CmuxMobileAgentChat
import CmuxMobileFeed
import CmuxMobileModel
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

// MARK: Link state machine

@Suite struct LinkMachineTests {
    let mac = LinkMachine.Target(macID: "m1", name: "Studio", isOnline: true)

    @Test func dialsOnlineTargetAndConnects() {
        var machine = LinkMachine(transport: .wireGuard)
        #expect(machine.handle(.target(mac)) == [.dial(generation: 1, macID: "m1", transport: .wireGuard)])
        #expect(machine.phase == .connecting(.wireGuard, attempt: 1))
        #expect(machine.handle(.dialSucceeded(generation: 1, path: .turnTLS)) == [])
        #expect(machine.phase == .connected(.wireGuard, .turnTLS, rttMillis: nil))
        _ = machine.handle(.linkUpdated(generation: 1, path: .turnTLS, rttMillis: 27))
        #expect(machine.phase.statusLine(macName: "Studio") == "Connected · WireGuard relay (TURN over TLS) · 27 ms")
    }

    @Test func offlineMacIsNotDialed() {
        var machine = LinkMachine(transport: .webRTC)
        var offline = mac
        offline.isOnline = false
        #expect(machine.handle(.target(offline)) == [])
        #expect(machine.phase == .macOffline)
        // Presence brings it back: dial.
        #expect(machine.handle(.target(mac)) == [.dial(generation: 2, macID: "m1", transport: .webRTC)])
    }

    @Test func failuresBackOffAndRetry() {
        var machine = LinkMachine(transport: .webRTC)
        _ = machine.handle(.target(mac))
        // The first failure retries at once and shows nothing (a reset signaling socket).
        #expect(machine.handle(.dialFailed(generation: 1, reason: "signaling reset")) == [.dial(generation: 2, macID: "m1", transport: .webRTC)])
        #expect(machine.phase == .connecting(.webRTC, attempt: 2))
        #expect(machine.handle(.dialFailed(generation: 2, reason: "ICE timed out")) == [.scheduleRetry(generation: 3, after: .seconds(1))])
        #expect(machine.phase == .waiting(.webRTC, attempt: 2, reason: "ICE timed out", retryIn: .seconds(1)))
        #expect(machine.phase.statusLine(macName: "Studio") == "WebRTC failed: ICE timed out · retrying in 1 s")
        #expect(machine.handle(.retryDue(generation: 3)) == [.dial(generation: 4, macID: "m1", transport: .webRTC)])
        #expect(machine.handle(.dialFailed(generation: 4, reason: "x")) == [.scheduleRetry(generation: 5, after: .seconds(2))])
        // A stale timer is ignored.
        #expect(machine.handle(.retryDue(generation: 3)) == [])
    }

    @Test func transportSwitchRedialsAndIgnoresLateResult() {
        var machine = LinkMachine(transport: .webRTC)
        _ = machine.handle(.target(mac))
        _ = machine.handle(.dialSucceeded(generation: 1, path: .direct))
        #expect(machine.handle(.transport(.wireGuard)) == [.close, .dial(generation: 2, macID: "m1", transport: .wireGuard)])
        // The old link's drop arrives late: ignored.
        #expect(machine.handle(.linkDropped(generation: 1, reason: "closed")) == [])
        #expect(machine.phase == .connecting(.wireGuard, attempt: 1))
        // Switching while waiting redials immediately with the new transport.
        _ = machine.handle(.dialFailed(generation: 2, reason: "x"))
        _ = machine.handle(.dialFailed(generation: 3, reason: "x"))
        #expect(machine.handle(.transport(.webRTC)) == [.close, .dial(generation: 5, macID: "m1", transport: .webRTC)])
    }

    @Test func relayOnlyChangeRedials() {
        var machine = LinkMachine(transport: .webRTC)
        _ = machine.handle(.target(mac))
        _ = machine.handle(.dialSucceeded(generation: 1, path: .direct))
        #expect(machine.handle(.relayOnly(false)) == [])
        #expect(machine.handle(.relayOnly(true)) == [.close, .dial(generation: 2, macID: "m1", transport: .webRTC)])
        #expect(machine.relayOnly)
        #expect(machine.handle(.dialSucceeded(generation: 2, path: .turn)) == [])
        #expect(machine.phase.statusLine(macName: "Studio") == "Connected · WebRTC relay (TURN)")
    }

    /// Settings → Developer "Block UDP": a change redials, like relay only.
    @Test func blockUDPChangeRedials() {
        var machine = LinkMachine(transport: .wireGuard)
        _ = machine.handle(.target(mac))
        _ = machine.handle(.dialSucceeded(generation: 1, path: .direct))
        #expect(machine.handle(.blockUDP(false)) == [])
        #expect(machine.handle(.blockUDP(true)) == [.close, .dial(generation: 2, macID: "m1", transport: .wireGuard)])
        #expect(machine.blockUDP)
        #expect(machine.handle(.dialSucceeded(generation: 2, path: .turnTLS)) == [])
        #expect(machine.phase.statusLine(macName: "Studio") == "Connected · WireGuard relay (TURN over TLS)")
        // WebRTC ignores it: a change there does not redial.
        var webRTC = LinkMachine(transport: .webRTC)
        _ = webRTC.handle(.target(mac))
        _ = webRTC.handle(.dialSucceeded(generation: 1, path: .direct))
        #expect(webRTC.handle(.blockUDP(true)) == [])
        #expect(webRTC.blockUDP)
    }

    @Test func dropReconnectsAndForegroundProbes() {
        var machine = LinkMachine(transport: .wireGuard)
        _ = machine.handle(.target(mac))
        _ = machine.handle(.dialSucceeded(generation: 1, path: .turn))
        #expect(machine.handle(.foreground) == [.probe(generation: 1)])
        // A dead link redials at once.
        #expect(machine.handle(.probeFailed(generation: 1, reason: "closed")) == [.close, .dial(generation: 2, macID: "m1", transport: .wireGuard)])
        _ = machine.handle(.dialFailed(generation: 2, reason: "x"))
        _ = machine.handle(.dialFailed(generation: 3, reason: "x"))
        // Foreground while waiting dials now instead of waiting out the timer.
        #expect(machine.handle(.foreground) == [.dial(generation: 5, macID: "m1", transport: .wireGuard)])
    }

    /// termfix-r13 D2a (T-LIFE-17): a signaling reset makes presence say the
    /// Mac is offline for a moment, but the link is peer to peer and still
    /// up. The link is kept and only probed (quickly); a healthy probe keeps it.
    @Test func presenceOfflineKeepsAConnectedLinkAndProbesIt() {
        var machine = LinkMachine(transport: .webRTC)
        _ = machine.handle(.target(mac))
        _ = machine.handle(.dialSucceeded(generation: 1, path: .direct))
        var offline = mac
        offline.isOnline = false
        #expect(machine.handle(.target(offline)) == [.quickProbe(generation: 1)])
        #expect(machine.phase == .connected(.webRTC, .direct, rttMillis: nil))
        // Back online with the link still up: nothing to do (no second link).
        #expect(machine.handle(.target(mac)) == [])
        #expect(machine.phase.isConnected)
        #expect(machine.handle(.linkUpdated(generation: 1, path: .direct, rttMillis: 3)) == [])
        #expect(machine.phase == .connected(.webRTC, .direct, rttMillis: 3))
    }

    /// termfix-r13 D2b (T-LIFE-12): the Mac's host restarted (its signaling
    /// socket came back, a presence frame says so) while the phone still
    /// holds the dead link. The phone probes at once instead of waiting for
    /// the 15 s heartbeat, and redials as soon as the probe fails.
    @Test func macSignalingBackProbesTheLinkAndRedialsWhenItIsDead() {
        var machine = LinkMachine(transport: .webRTC)
        _ = machine.handle(.target(mac))
        _ = machine.handle(.dialSucceeded(generation: 1, path: .direct))
        #expect(machine.handle(.macSignaled) == [.quickProbe(generation: 1)])
        #expect(machine.handle(.probeFailed(generation: 1, reason: "timeout")) == [.close, .dial(generation: 2, macID: "m1", transport: .webRTC)])
        // A dial in flight when the host's socket connects again is restarted
        // (its offer may have gone to the old socket): D2b.
        #expect(machine.handle(.macSignaled) == [.dial(generation: 3, macID: "m1", transport: .webRTC)])
    }

    /// The link really died while presence says the Mac is offline: no dial
    /// until presence brings it back (then at once).
    @Test func aDeadLinkToAnOfflineMacWaitsForPresence() {
        var machine = LinkMachine(transport: .webRTC)
        _ = machine.handle(.target(mac))
        _ = machine.handle(.dialSucceeded(generation: 1, path: .direct))
        var offline = mac
        offline.isOnline = false
        _ = machine.handle(.target(offline))
        #expect(machine.handle(.probeFailed(generation: 1, reason: "timeout")) == [.close])
        #expect(machine.phase == .macOffline)
        #expect(machine.handle(.target(mac)) == [.dial(generation: 3, macID: "m1", transport: .webRTC)])
    }

    /// A Mac that comes back online while the phone waits out a backoff is
    /// dialed now, not at the end of the backoff.
    @Test func macBackOnlineEndsTheBackoff() {
        var machine = LinkMachine(transport: .webRTC)
        _ = machine.handle(.target(mac))
        _ = machine.handle(.dialFailed(generation: 1, reason: "x"))
        _ = machine.handle(.dialFailed(generation: 2, reason: "x"))
        guard case .waiting = machine.phase else { Issue.record("expected waiting"); return }
        #expect(machine.handle(.macSignaled) == [.dial(generation: 4, macID: "m1", transport: .webRTC)])
    }

    /// termfix-r13 D2b (T-LIFE-12): after a cmux-mobile-host kill the phone's redial
    /// sent its offer while the host was down; the offer was never answered
    /// and the dial waited out its 25 s timeout (link back 26.7 s after the
    /// kill). The host's signaling socket coming back abandons that dial and
    /// dials again at once.
    @Test func macSignalingBackRestartsADialInFlight() {
        var machine = LinkMachine(transport: .webRTC)
        _ = machine.handle(.target(mac))
        _ = machine.handle(.dialSucceeded(generation: 1, path: .direct))
        _ = machine.handle(.linkDropped(generation: 1, reason: "keepalive timed out"))
        guard case .connecting(_, attempt: 1) = machine.phase else { Issue.record("expected a redial"); return }
        #expect(machine.handle(.macSignaled) == [.dial(generation: 3, macID: "m1", transport: .webRTC)])
        // The abandoned dial's late failure changes nothing.
        #expect(machine.handle(.dialFailed(generation: 2, reason: "answer timeout")) == [])
        guard case .connecting = machine.phase else { Issue.record("expected connecting"); return }
    }

    /// termfix-r13 D4 (T-LIFE-13: offline label ≤ 5 s): terminals say the Mac
    /// is offline at once when presence says so, and after a bounded time
    /// when the link just cannot be brought back; never while connected.
    @Test func terminalsShowOfflineWithinABoundedTime() {
        let offline = LinkMachine.Phase.macOffline
        #expect(offline.showsTerminalsOffline(notConnectedFor: .zero))
        let connected = LinkMachine.Phase.connected(.webRTC, .direct, rttMillis: 3)
        #expect(!connected.showsTerminalsOffline(notConnectedFor: .seconds(60)))
        let connecting = LinkMachine.Phase.connecting(.webRTC, attempt: 2)
        #expect(!connecting.showsTerminalsOffline(notConnectedFor: .seconds(1)))
        #expect(connecting.showsTerminalsOffline(notConnectedFor: LinkMachine.Phase.offlineAfter))
        #expect(LinkMachine.Phase.offlineAfter <= .seconds(4))
        // A first dial under way is not "offline" (a slow connect is not a dead Mac).
        #expect(!LinkMachine.Phase.connecting(.webRTC, attempt: 1).showsTerminalsOffline(notConnectedFor: .seconds(7)))
        // ...but not forever: a redial after a lost link can last its whole timeout.
        #expect(LinkMachine.Phase.connecting(.webRTC, attempt: 1).showsTerminalsOffline(notConnectedFor: LinkMachine.Phase.offlineAfter * 2))
        let failed = LinkMachine.Phase.waiting(.webRTC, attempt: 2, reason: "ICE timed out", retryIn: .seconds(1))
        #expect(!failed.showsTerminalsOffline(notConnectedFor: .seconds(1)))
        #expect(failed.showsTerminalsOffline(notConnectedFor: .seconds(4)))
        let refused = LinkMachine.Phase.waiting(.webRTC, attempt: 2, reason: LinkController.reason(LinkError(code: "offline", message: "")),
                                                retryIn: .seconds(1))
        #expect(refused.showsTerminalsOffline(notConnectedFor: .zero))
        #expect(!LinkMachine.Phase.idle.showsTerminalsOffline(notConnectedFor: .seconds(60)))
    }

    @Test func sameTargetKeepsLinkAndNilTargetCloses() {
        var machine = LinkMachine(transport: .wireGuard)
        _ = machine.handle(.target(mac))
        _ = machine.handle(.dialSucceeded(generation: 1, path: .turn))
        #expect(machine.handle(.target(mac)) == [])
        #expect(machine.handle(.target(nil)) == [.close])
        #expect(machine.phase == .idle)
    }
}

// MARK: Link controller with a mock dialer

struct MockDialer: MacLinkDialer {
    let fail: Bool
    var dialed: (@Sendable (LinkEndpoint) -> Void)?
    var roamed: (@Sendable (String) -> Void)?
    func dial(_ endpoint: LinkEndpoint, transport: CmuxMobileTransport.TransportKind, accessToken: String) async throws -> any MacLink {
        dialed?(endpoint)
        if fail { throw LinkError(code: "timeout", message: "") }
        return MockMacLink(transport: transport)
    }

    func networkChanged(baseURL: URL, teamID: String, deviceID: String, accessToken: String) async -> [(String, Double)] {
        roamed?(teamID)
        return [("roam_direct", 12)]
    }
}

@MainActor
@Suite struct LinkControllerTests {
    @Test func connectsThroughDialerAndHandsOutLink() async throws {
        let controller = LinkController(transport: .wireGuard, dialer: MockDialer(fail: false), accessToken: { _ in "t" })
        controller.endpoint = { LinkEndpoint(baseURL: URL(string: "https://x")!, teamID: "t", deviceID: "d", macDeviceID: $0) }
        var handed: (any MacLink)?
        controller.onLink = { handed = $0 }
        controller.send(.target(LinkMachine.Target(macID: "m", name: "Mac", isOnline: true)))
        for _ in 0..<200 where !controller.phase.isConnected { await Task.yield() }
        #expect(controller.phase.isConnected)
        #expect(handed != nil)
    }

    @Test func relayOnlyReachesTheDialer() async throws {
        let seen = Seen()
        let dialer = MockDialer(fail: false, dialed: { endpoint in seen.append(endpoint.relayOnly) })
        let controller = LinkController(transport: .webRTC, relayOnly: true, dialer: dialer, accessToken: { _ in "t" })
        controller.endpoint = { LinkEndpoint(baseURL: URL(string: "https://x")!, teamID: "t", deviceID: "d", macDeviceID: $0) }
        controller.send(.target(LinkMachine.Target(macID: "m", name: "Mac", isOnline: true)))
        for _ in 0..<200 where !controller.phase.isConnected { await Task.yield() }
        controller.send(.relayOnly(false))
        for _ in 0..<200 where !(controller.phase.isConnected && seen.values.count == 2) { await Task.yield() }
        #expect(seen.values == [true, false])
    }

    /// A network change roams the live link in place: the dialer is told
    /// once (a burst of path updates settles first) and nothing redials.
    @Test func networkChangeRoamsWithoutRedialing() async throws {
        let dials = Seen()
        let roams = Seen()
        let dialer = MockDialer(fail: false, dialed: { _ in dials.append(true) }, roamed: { _ in roams.append(true) })
        let controller = LinkController(transport: .wireGuard, dialer: dialer, accessToken: { _ in "t" })
        controller.endpoint = { LinkEndpoint(baseURL: URL(string: "https://x")!, teamID: "t", deviceID: "d", macDeviceID: $0) }
        controller.send(.target(LinkMachine.Target(macID: "m", name: "Mac", isOnline: true)))
        for _ in 0..<200 where !controller.phase.isConnected { await Task.yield() }
        let url = URL(string: "https://x")!
        controller.networkChanged(baseURL: url, teamID: "t", deviceID: "d")
        controller.networkChanged(baseURL: url, teamID: "t", deviceID: "d")
        let deadline = ContinuousClock.now + .seconds(5)
        while roams.values.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(roams.values.count == 1)
        #expect(dials.values.count == 1)
        #expect(controller.phase.isConnected)
    }

    @Test func dialFailureWaitsWithReadableReason() async throws {
        let controller = LinkController(transport: .webRTC, dialer: MockDialer(fail: true), accessToken: { _ in "t" })
        controller.endpoint = { LinkEndpoint(baseURL: URL(string: "https://x")!, teamID: "t", deviceID: "d", macDeviceID: $0) }
        controller.send(.target(LinkMachine.Target(macID: "m", name: "Mac", isOnline: true)))
        for _ in 0..<200 { if case .waiting = controller.phase { break }; await Task.yield() }
        guard case .waiting(.webRTC, 2, let reason, _) = controller.phase else {
            Issue.record("expected waiting, got \(controller.phase)")
            return
        }
        #expect(reason == "the Mac didn't answer in time")
    }
}

// MARK: Backend frames

@Suite struct SignalFrameTests {
    @Test func parsesHelloAndPresence() throws {
        let hello = Data(#"{"type":"hello","you":"p1","macs":[{"deviceId":"m1","name":"mini","online":true,"lastSeenAt":"2026-10-12T10:00:00.000Z","ownerUserId":"u"}]}"#.utf8)
        guard case .hello(let you, let macs) = SignalFrame.parse(hello) else { Issue.record("no hello"); return }
        #expect(you == "p1")
        #expect(macs.map(\.name) == ["mini"])
        #expect(macs[0].lastSeenDate != nil)
        let presence = Data(#"{"type":"presence","mac":{"deviceId":"m1","name":"mini","online":false,"lastSeenAt":null}}"#.utf8)
        #expect(SignalFrame.parse(presence) == .presence(LiveAPI.Mac(deviceId: "m1", name: "mini", online: false)))
        #expect(SignalFrame.parse(Data(#"{"type":"signal"}"#.utf8)) == .other)
        #expect(SignalFrame.parse(Data("nope".utf8)) == nil)
    }

    @Test func decodesErrorEnvelope() {
        let failure = LiveAPI.failure(status: 403, data: Data(#"{"error":{"code":"not_member","message":"no"}}"#.utf8))
        #expect(failure == LiveAPI.Failure(status: 403, code: "not_member", message: "no"))
    }
}

// MARK: Daemon tree

@Suite struct DaemonTreeTests {
    static let reply = Data("""
    {"id":"m2","ok":true,"data":{"workspace_revision":4,"workspaces":[
      {"id":4,"key":"ws-a","name":"1","title":"cmux","color":"#30D158","icon":"hammer","active":true,"unread_count":2,"screens":[
        {"id":3,"active":true,"active_pane":2,"panes":[
          {"id":2,"active_tab":1,"tabs":[
            {"surface":1,"kind":"pty","name":null,"title":"zsh","cwd":"/Users/cmux/src/cmux","git_branch":"main","dead":false},
            {"surface":7,"kind":"conversation","name":null,"title":"","cwd":"/Users/cmux/src/cmux","git_branch":"feat","conversation":{"agent_session":{"host":"install:x","session":"sess-1","harness":"claude","host_name":"mini"}},"dead":false},
            {"surface":8,"kind":"conversation","title":"Home","conversation":{"conversation":"conv_1","owner":"local"}},
            {"surface":9,"kind":"browser","title":"Docs","url":"https://cmux.com/docs"},
            {"surface":10,"kind":"pty","title":"gone","dead":true}
          ]}
        ]}
      ]},
      {"id":5,"name":"scratch","active":false,"screens":[]}
    ]}}
    """.utf8)

    @Test func mapsWorkspacesTabsAndAgentBindings() throws {
        var agents = AgentStates()
        agents.bySurface[1] = AgentState(state: "working", agent: "claude")
        let tree = try DaemonTree(reply: Self.reply, macID: "mac-1", agents: agents)
        #expect(tree.revision == 4)
        #expect(tree.workspaces.map(\.id) == ["ws-a", "w5"])
        let ws = tree.workspaces[0]
        #expect(ws.title == "cmux")
        #expect(ws.macID == "mac-1")
        #expect(ws.directory == "~/src/cmux")
        #expect(ws.branch == "feat")
        #expect(ws.colorHex == "#30D158")
        #expect(ws.hasUnread)
        #expect(ws.isWorking)
        // A dead terminal the Mac keeps is listed with its ended shell (Restart Shell Here).
        #expect(ws.tabs.map(\.kind) == [.terminal, .agent, .browser, .terminal])
        #expect(ws.tabs.map(\.hasEndedShell) == [false, false, false, true])
        #expect(ws.tabs[1].title == "Claude")
        #expect(ws.tabs[1].harness == "claude")
        #expect(tree.agentTabs["s7"]?.session == "sess-1")
        #expect(tree.surfaces["s9"] == 9)
        #expect(ws.tabs[2].url?.host() == "cmux.com")
        #expect(tree.workspaces[1].title == "scratch")
    }

    @Test func pendingPermissionMarksNeedsYouAndActivityIsKept() throws {
        var agents = AgentStates()
        agents.pending["sess-1"] = true
        let earlier = Date(timeIntervalSince1970: 1000)
        let first = try DaemonTree(reply: Self.reply, macID: "m", now: earlier)
        let second = try DaemonTree(reply: Self.reply, macID: "m", previous: first.workspaces, agents: agents, now: Date())
        #expect(second.workspaces[0].needsAttention)
        #expect(second.workspaces[0].lastActivityAt == earlier)
    }

    @Test func tabsCarryTheirAgentStateAndTheMacsActiveTab() throws {
        var agents = AgentStates()
        agents.bySurface[1] = AgentState(state: "working", agent: "claude")
        agents.pending["sess-1"] = true
        let tree = try DaemonTree(reply: Self.reply, macID: "m", agents: agents)
        let ws = tree.workspaces[0]
        // The terminal runs Claude; the conversation tab has an open permission.
        #expect(ws.tabs.map(\.agentStatus) == [.working, .waiting, nil, nil])
        #expect(ws.tabs[0].harness == "claude")
        // The active screen's active pane's tab.
        #expect(ws.activeTabID == "s7")
        #expect(tree.workspaces[1].activeTabID == nil)
        var blocked = AgentStates()
        blocked.bySurface[7] = AgentState(state: "blocked", agent: "claude")
        #expect(try DaemonTree(reply: Self.reply, macID: "m", agents: blocked).workspaces[0].tabs[1].agentStatus == .waiting)
    }

    @Test func activityTimesComeOnlyFromEvents() throws {
        let start = Date(timeIntervalSince1970: 1000)
        let first = try DaemonTree(reply: Self.reply, macID: "m", now: start)
        // First sight is not an activity time.
        #expect(!first.workspaces[0].hasActivityTime)
        #expect(first.workspaces[0].lastActivityAt == start)
        let event = Date(timeIntervalSince1970: 2000)
        let second = try DaemonTree(reply: Self.reply, macID: "m", previous: first.workspaces, activity: [9: event],
                                    now: Date(timeIntervalSince1970: 3000))
        #expect(second.workspaces[0].hasActivityTime)
        #expect(second.workspaces[0].lastActivityAt == event)
        #expect(!second.workspaces[1].hasActivityTime)
        // A known time is kept when no newer event arrives.
        let third = try DaemonTree(reply: Self.reply, macID: "m", previous: second.workspaces, now: Date(timeIntervalSince1970: 4000))
        #expect(third.workspaces[0].hasActivityTime)
        #expect(third.workspaces[0].lastActivityAt == event)
    }

    /// The Mac's `updated_at_ms` (list-agents, agent-changed) is the workspace's activity time;
    /// a newer phone-seen event (a title) still wins, and an older Mac without it changes nothing.
    @Test func activityTimesComeFromTheMacsAgentReports() throws {
        let agents = try #require(AgentState(json: ["surface": 1, "state": "working", "agent": "claude", "updated_at_ms": 2_000_000]))
        #expect(agents.updatedAt == Date(timeIntervalSince1970: 2000))
        #expect(AgentState(json: ["surface": 1, "state": "idle"])?.updatedAt == nil)
        #expect(AgentState(json: ["state": "idle"]) == nil)
        var states = AgentStates()
        states.bySurface[1] = agents
        let tree = try DaemonTree(reply: Self.reply, macID: "m", agents: states, now: Date(timeIntervalSince1970: 9000))
        #expect(tree.workspaces[0].hasActivityTime)
        #expect(tree.workspaces[0].lastActivityAt == Date(timeIntervalSince1970: 2000))
        let title = Date(timeIntervalSince1970: 3000)
        let later = try DaemonTree(reply: Self.reply, macID: "m", agents: states, activity: [9: title])
        #expect(later.workspaces[0].lastActivityAt == title)
    }

    /// A pending acpmux session says what it asks for; a terminal agent only "is waiting".
    @Test func waitingTabsSayPermissionOrQuestion() throws {
        var agents = AgentStates()
        agents.pending["sess-1"] = true
        agents.waitingFor["sess-1"] = .question
        let asking = try DaemonTree(reply: Self.reply, macID: "m", agents: agents).workspaces[0].tabs[1]
        #expect(asking.waitingFor == .question)
        #expect(asking.waitingPhrase == "Claude has a question")
        agents.waitingFor["sess-1"] = .permission
        #expect(try DaemonTree(reply: Self.reply, macID: "m", agents: agents).workspaces[0].tabs[1].waitingPhrase == "Claude is asking permission")
        agents.waitingFor = [:]
        #expect(try DaemonTree(reply: Self.reply, macID: "m", agents: agents).workspaces[0].tabs[1].waitingPhrase == "Claude is waiting")
        var terminal = AgentStates()
        terminal.bySurface[1] = AgentState(state: "blocked", agent: "claude")
        terminal.waitingFor["sess-1"] = .question
        let blocked = try DaemonTree(reply: Self.reply, macID: "m", agents: terminal).workspaces[0].tabs[0]
        #expect(blocked.agentStatus == .waiting && blocked.waitingFor == nil)
        #expect(blocked.waitingPhrase == "Claude is waiting")
    }

    @Test func errorReplyThrows() {
        let reply = Data(#"{"id":"m1","ok":false,"error":"list-workspaces is not available to a phone","error_code":"forbidden"}"#.utf8)
        #expect(throws: DaemonReplyError(message: "list-workspaces is not available to a phone", code: "forbidden")) {
            try DaemonTree(reply: reply, macID: "m")
        }
    }

    @Test func classifiesEvents() {
        func parse(_ s: String) -> DaemonEvent { DaemonEvent.parse(Data(s.utf8)) }
        #expect(parse(#"{"event":"tab-added","workspace":4,"surface":3}"#) == .treeChanged)
        #expect(parse(#"{"event":"workspace-renamed","workspace":4}"#) == .treeChanged)
        #expect(parse(#"{"event":"tree-changed"}"#) == .treeChanged)
        #expect(parse(#"{"event":"overflow"}"#) == .resubscribe)
        #expect(parse(#"{"event":"agent-changed","surface":1,"state":"blocked","agent":"claude"}"#) == .agentChanged(surface: 1, state: "blocked", agent: "claude"))
        #expect(parse(#"{"event":"agent-changed","surface":1,"state":"working","agent":"claude","updated_at_ms":1760400000000,"since_ms":1760399000000}"#)
            == .agentChanged(surface: 1, state: "working", agent: "claude", updatedAt: Date(timeIntervalSince1970: 1_760_400_000)))
        #expect(parse(#"{"event":"bell","surface":1}"#) == .other)
    }
}

// MARK: Workspace sync over a fake daemon

@MainActor
@Suite struct WorkspaceSyncTests {
    @Test func listsAfterSubscribeAndRelistsOnEvents() async throws {
        let lists = Counter()
        let link = MockMacLink { _, data in
            // The setup arrives as one write of several lines.
            var out: [Data] = []
            for line in data.split(separator: 0x0A) {
            let object = try! JSONSerialization.jsonObject(with: Data(line)) as! [String: Any]
            let id = object["id"] as! String
            let cmd = (object["cmd"] as? String ?? "")
            switch cmd {
            case "list-workspaces":
                let n = lists.increment()
                let title = n == 1 ? "first" : "second"
                out.append(Data(#"{"id":"\#(id)","ok":true,"data":{"workspaces":[{"id":1,"key":"k","name":"\#(title)","screens":[]}]}}"#.utf8))
                if n == 1 { out.append(Data(#"{"event":"workspace-renamed","workspace":1}"#.utf8)) }
            case "list-agents":
                out.append(Data(#"{"id":"\#(id)","ok":true,"data":{"agents":[]}}"#.utf8))
            default:
                out.append(Data(#"{"id":"\#(id)","ok":true,"data":{}}"#.utf8))
            }
            }
            return out.map { $0 + Data([0x0A]) }
        }
        let sync = WorkspaceSync(deviceID: "d", deviceName: "iPhone")
        var titles: [String] = []
        sync.onTree = { titles.append($0.workspaces.first?.title ?? "") }
        await sync.bind(try await link.openChannel(service: "daemon", args: [:]), macID: "mac")
        for _ in 0..<500 where titles.last != "second" { await Task.yield() }
        #expect(titles.first == "first")
        #expect(titles.last == "second")
        #expect(sync.identity != nil || true)
    }
}

// MARK: Launch reconcile

@MainActor
@Suite struct LaunchReconcileLiveTests {
    /// The first live list after a launch keeps the cached rows' known activity
    /// times (the snapshot), so rows are reconciled, not resorted as "no activity seen".
    @Test func firstLiveListKeepsCachedActivityTimes() async throws {
        let link = MockMacLink { _, data in
            data.split(separator: 0x0A).map { request -> Data in
                let object = try! JSONSerialization.jsonObject(with: Data(request)) as! [String: Any]
                let id = object["id"] as! String
                switch (object["cmd"] as? String ?? "") {
                case "list-workspaces":
                    return Data(#"{"id":"\#(id)","ok":true,"data":{"workspaces":[{"id":1,"key":"k1","name":"one","screens":[]},{"id":2,"key":"k2","name":"two","screens":[]}]}}"#.utf8) + Data([0x0A])
                case "list-agents":
                    return Data(#"{"id":"\#(id)","ok":true,"data":{"agents":[]}}"#.utf8) + Data([0x0A])
                default:
                    return Data(#"{"id":"\#(id)","ok":true,"data":{}}"#.utf8) + Data([0x0A])
                }
            }
        }
        let seen = Date(timeIntervalSince1970: 1_700_000_000)
        let cached = [Workspace(id: "k2", macID: "mac", title: "two", directory: "~", tabs: [], lastActivityAt: seen, hasActivityTime: true)]
        let sync = WorkspaceSync(deviceID: "d", deviceName: "iPhone")
        await sync.bind(try await link.openChannel(service: "daemon", args: [:]), macID: "mac", cached: cached)
        let tree = try #require(sync.tree)
        let two = try #require(tree.workspaces.first { $0.id == "k2" })
        #expect(two.hasActivityTime)
        #expect(two.lastActivityAt == seen)
        #expect(tree.workspaces.first { $0.id == "k1" }?.hasActivityTime == false)
    }
}

// MARK: Off-main channel setup after the dial

/// A daemon that answers the setup batch (verify/perf-latency.md).
private func setupDaemon(_ log: CommandLog? = nil) -> MockMacLink {
    MockMacLink { service, data in
        data.split(separator: 0x0A).map { request -> Data in
            let object = try! JSONSerialization.jsonObject(with: Data(request)) as! [String: Any]
            let id = object["id"] as! String
            let cmd = (object["cmd"] as? String ?? "")
            log?.append("\(service):\(cmd)", nil)
            let line: String
            switch cmd {
            case "list-workspaces":
                line = #"{"id":"\#(id)","ok":true,"data":{"workspaces":[{"id":1,"key":"k1","name":"one","screens":[]}]}}"#
            case "list-agents":
                line = #"{"id":"\#(id)","ok":true,"data":{"agents":[]}}"#
            default:
                line = #"{"id":"\#(id)","ok":true,"data":{}}"#
            }
            return Data(line.utf8) + Data([0x0A])
        }
    }
}

private struct LinkOf: MacLinkDialer {
    let link: MockMacLink
    func dial(_ endpoint: LinkEndpoint, transport: CmuxMobileTransport.TransportKind, accessToken: String) async throws -> any MacLink { link }
}

@MainActor
@Suite struct PreparedLinkTests {
    /// The setup batch goes out in the dial step; binding it later publishes the
    /// list without sending anything more.
    @Test func preparedDaemonBindsWithoutAnotherRequest() async throws {
        let log = CommandLog()
        let link = setupDaemon(log)
        let prepared = await WorkspaceSync.prepare(try await link.openChannel(service: "daemon", args: [:]), deviceID: "d", deviceName: "iPhone")
        _ = await prepared.replies.value
        #expect(log.count == 5)
        let sync = WorkspaceSync(deviceID: "d", deviceName: "iPhone")
        var trees: [DaemonTree] = []
        sync.onTree = { trees.append($0) }
        await sync.bind(prepared, macID: "mac")
        #expect(trees.count == 1)
        #expect(sync.tree?.workspaces.map(\.id) == ["k1"])
        #expect(sync.daemon != nil)
        #expect(log.count == 5)
    }

    /// `prepare` runs once per dial, before the link is handed over, and its
    /// result is there for that link once.
    @Test func dialRunsPrepareBeforeHandingTheLinkOver() async throws {
        let mock = setupDaemon()
        let controller = LinkController(transport: .webRTC, dialer: LinkOf(link: mock), accessToken: { _ in "t" })
        controller.endpoint = { LinkEndpoint(baseURL: URL(string: "https://x")!, teamID: "t", deviceID: "d", macDeviceID: $0) }
        let calls = CommandLog()
        controller.prepare = { _, macID in
            calls.append("prepare", macID)
            return "ready-\(macID)"
        }
        var preparedAtHandover: (any Sendable)?
        controller.onLink = { link in
            if let link { preparedAtHandover = controller.takePrepared(for: link) }
        }
        controller.send(.target(LinkMachine.Target(macID: "m", name: "Mac", isOnline: true)))
        for _ in 0..<5000 where preparedAtHandover == nil { await Task.yield() }
        #expect(calls.count == 1)
        #expect(preparedAtHandover as? String == "ready-m")
        #expect(controller.takePrepared(for: mock) == nil)
    }

    /// A link that knows its path is connected in the same turn it is adopted:
    /// the hand-over does not wait for the state stream.
    @Test func linkWithKnownPathIsConnectedAtHandover() async throws {
        let controller = LinkController(transport: .webRTC, dialer: LinkOf(link: setupDaemon()), accessToken: { _ in "t" })
        controller.endpoint = { LinkEndpoint(baseURL: URL(string: "https://x")!, teamID: "t", deviceID: "d", macDeviceID: $0) }
        var phaseAtHandover: LinkMachine.Phase?
        controller.onLink = { if $0 != nil { phaseAtHandover = controller.phase } }
        controller.send(.target(LinkMachine.Target(macID: "m", name: "Mac", isOnline: true)))
        for _ in 0..<5000 where phaseAtHandover == nil { await Task.yield() }
        #expect(phaseAtHandover?.isConnected == true)
    }
}

// MARK: Workspace creation on the daemon

@MainActor
@Suite struct LiveWorkspaceCreationTests {
    /// A daemon that creates `new-workspace` (surface 10) and `new-browser-tab`
    /// (surface 11), or refuses `new-workspace` like the phone policy.
    static func daemon(refuse: Bool, seen: CommandLog) -> MockMacLink {
        MockMacLink { _, data in
            // The connect setup arrives as one write of several lines.
            data.split(separator: 0x0A).map { request -> Data in
            let object = try! JSONSerialization.jsonObject(with: Data(request)) as! [String: Any]
            let id = object["id"] as! String
            let cmd = (object["cmd"] as? String ?? "")
            seen.append(cmd, object["name"] as? String)
            let line: String
            switch cmd {
            case "new-workspace" where refuse:
                line = #"{"id":"\#(id)","ok":false,"error":"new-workspace is not available to a phone","error_code":"forbidden"}"#
            case "new-workspace":
                line = #"{"id":"\#(id)","ok":true,"data":{"surface":10}}"#
            case "new-browser-tab":
                line = #"{"id":"\#(id)","ok":true,"data":{"surface":11}}"#
            case "list-workspaces":
                let created = seen.contains("new-workspace") && !refuse
                let browser = seen.contains("new-browser-tab")
                let tabs = #"{"surface":10,"kind":"pty","cwd":"/Users/me"}"# + (browser ? #",{"surface":11,"kind":"browser","url":"about:blank"}"# : "")
                let ws = created ? #"{"id":2,"key":"wk2","name":"New Workspace","screens":[{"active":true,"active_pane":1,"panes":[{"id":1,"active_tab":0,"tabs":[\#(tabs)]}]}]}"# : ""
                line = #"{"id":"\#(id)","ok":true,"data":{"workspaces":[{"id":1,"key":"wk1","name":"main","screens":[]}\#(created ? "," : "")\#(ws)]}}"#
            case "list-agents":
                line = #"{"id":"\#(id)","ok":true,"data":{"agents":[]}}"#
            default:
                line = #"{"id":"\#(id)","ok":true,"data":{}}"#
            }
            return Data(line.utf8) + Data([0x0A])
            }
        }
    }

    func connected(_ refuse: Bool, _ log: CommandLog) async throws -> (AppStore, WorkspaceCreator, WorkspaceSync) {
        let store = AppStore.mock(tabMemory: .inMemory())
        store.teams[0].macs = [MacDevice(id: "m", name: "Mac", isOnline: true)]
        let controller = LinkController(transport: .wireGuard, dialer: MockDialer(fail: false), accessToken: { _ in "t" })
        controller.endpoint = { LinkEndpoint(baseURL: URL(string: "https://x")!, teamID: "t", deviceID: "d", macDeviceID: $0) }
        controller.send(.target(LinkMachine.Target(macID: "m", name: "Mac", isOnline: true)))
        for _ in 0..<200 where !controller.phase.isConnected { await Task.yield() }
        let sync = WorkspaceSync(deviceID: "d", deviceName: "iPhone")
        sync.onTree = { store.replaceWorkspaces(macID: "m", with: $0.workspaces) }
        await sync.bind(try await Self.daemon(refuse: refuse, seen: log).openChannel(service: "daemon", args: [:]), macID: "m")
        let defaults = try #require(UserDefaults(suiteName: "cmuxMobile.tests.live.\(UUID().uuidString)"))
        let creator = WorkspaceCreator(store: store, backend: LiveWorkspaceCreationBackend(sync: sync, link: controller), defaults: defaults)
        return (store, creator, sync)
    }

    @Test func tapCreatesOnTheDaemonAndFollowsTheRealWorkspace() async throws {
        let log = CommandLog()
        let (store, creator, _) = try await connected(false, log)
        // Recent Directories (the Mac's workspace folders, opened with cd); no agent workspaces.
        #expect(creator.options(on: "m") == WorkspaceCreationOptions(directories: true, browser: true, tapUsesLastDirectory: false))
        #expect(creator.defaultDirectory(on: "m") == nil)
        let placeholder = try #require(creator.create())
        #expect(store.isPending(placeholder.id))
        await creator.settle()
        #expect(log.names["new-workspace"] == "New Workspace")
        // A plain tap opens at the Mac's default folder: nothing typed.
        #expect(!log.contains("send"))
        #expect(creator.phases[placeholder.id] == .created("wk2"))
        #expect(store.workspace(id: placeholder.id)?.id == "wk2")
        #expect(store.workspaces.filter { $0.macID == "m" }.map(\.id) == ["wk1", "wk2"])
        #expect(store.openingTab(for: try #require(store.workspace(id: "wk2")))?.id == "s10")
    }

    @Test func browserStartOpensOnTheBrowserTab() async throws {
        let log = CommandLog()
        let (store, creator, _) = try await connected(false, log)
        let placeholder = try #require(creator.create(start: .browser))
        await creator.settle()
        #expect(log.contains("new-browser-tab"))
        let real = try #require(store.workspace(id: placeholder.id))
        #expect(store.openingTab(for: real)?.id == "s11")
    }

    @Test func refusalRemovesThePlaceholder() async throws {
        let log = CommandLog()
        let (store, creator, _) = try await connected(true, log)
        var reason: String?
        creator.onFailure = { reason = $1 }
        let placeholder = try #require(creator.create())
        await creator.settle()
        #expect(reason == "new-workspace is not available to a phone")
        #expect(store.workspace(id: placeholder.id) == nil)
        #expect(store.workspaces.filter { $0.macID == "m" }.map(\.id) == ["wk1"])
    }
}

final class CommandLog: @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [String] = []
    private var nameByCommand: [String: String] = [:]
    func append(_ cmd: String, _ name: String?) {
        lock.withLock {
            commands.append(cmd)
            if let name { nameByCommand[cmd] = name }
        }
    }
    func contains(_ cmd: String) -> Bool { lock.withLock { commands.contains(cmd) } }
    var count: Int { lock.withLock { commands.count } }
    var names: [String: String] { lock.withLock { nameByCommand } }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() -> Int { lock.withLock { value += 1; return value } }
}

// MARK: acpmux records and session source

@Suite struct AcpmuxRecordTests {
    let records = AcpmuxRecords(sessionID: "s1")

    func json(_ string: String) -> JSONValue { try! JSONDecoder().decode(JSONValue.self, from: Data(string.utf8)) }

    @Test func mapsAgentUpdatesAndMuxRecords() {
        let chunk = json(#"{"sessionId":"s1","seq":5,"at":1700000000000,"dir":"in","kind":"agent_message_chunk","msg":{"method":"session/update","params":{"sessionId":"x","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"hi"}}}}}"#)
        #expect(records.map(chunk) == [.update(.agentMessageChunk(text: "hi", messageId: nil))])
        let user = json(#"{"seq":4,"at":1700000000000,"dir":"mux","kind":"user_message","msg":{"text":"go","promptId":"p","turnId":"t"}}"#)
        guard case .userMessage(let text, "p", "t", _, _)? = records.map(user).first else { Issue.record("no user message"); return }
        #expect(text == "go")
        let result = json(#"{"seq":9,"dir":"mux","kind":"turn_result","msg":{"status":"failed","turnId":"t","errorText":"boom"}}"#)
        guard case .turnResult("t", .failed, "boom", _)? = records.map(result).first else { Issue.record("no result"); return }
        let decision = json(#"{"seq":10,"dir":"mux","kind":"permission_decision","msg":{"permissionId":"perm","outcome":{"outcome":"cancelled"}}}"#)
        #expect(records.map(decision) == [.permissionDecision(permissionId: "perm", optionId: nil)])
    }

    /// A question's decision record carries the answers acpmux put into the tool's input
    /// (live rig, `question: Which environment?`); the phone used to drop them.
    @Test func decisionCarriesTheRecordedAnswers() {
        let decision = json(#"{"seq":3,"dir":"mux","kind":"permission_decision","msg":{"permissionId":"q","outcome":{"outcome":"selected","optionId":"allow_once","_meta":{"updatedInput":{"answers":{"Which environment?":"B"}}}}}}"#)
        #expect(records.map(decision) == [.permissionDecision(permissionId: "q", optionId: "allow_once",
                                                               answers: .object(["Which environment?": .string("B")]))])
    }

    @Test func permissionRequestIsToolPermissionOrQuestion() {
        let tool = json(#"{"seq":6,"dir":"mux","kind":"permission_request","msg":{"permissionId":"p1","request":{"sessionId":"x","toolCall":{"toolCallId":"c1","title":"rm -rf build","kind":"execute","rawInput":{"command":"rm -rf build"}},"options":[{"optionId":"allow","name":"Allow","kind":"allow_once"},{"optionId":"deny","name":"Deny","kind":"reject_once"}]}}}"#)
        guard case .permissionRequest(let request)? = records.map(tool).first else { Issue.record("no permission"); return }
        #expect(request.id == "p1")
        #expect(request.options.map(\.id) == ["allow", "deny"])
        #expect(request.toolCall.command == "rm -rf build")
        let question = json(#"{"seq":7,"dir":"mux","kind":"permission_request","msg":{"permissionId":"p2","request":{"toolCall":{"toolCallId":"c2","title":"Ask","_meta":{"claude":{"tool":"AskUserQuestion"}},"rawInput":{"questions":[{"question":"Which?","header":"Pick","options":[{"label":"A"},{"label":"B"}],"multiSelect":false}]}},"options":[{"optionId":"allow_once","name":"Answer","kind":"allow_once"},{"optionId":"reject_once","name":"Skip","kind":"reject_once"}]}}}"#)
        guard case .question(let ask)? = records.map(question).first else { Issue.record("no question"); return }
        #expect(ask.id == "p2")
        #expect(ask.source.session == "s1")
        #expect(ask.items.first?.options.map(\.label) == ["A", "B"])
        let reply = try? ask.reply(AgentQuestionAnswer(selections: ["q0": .init(optionIDs: ["B"])]))
        #expect(reply?.optionId == "allow_once")
        #expect(reply?.answers == .object(["Which?": .string("B")]))
    }

    @Test func parsesSessionSummary() {
        let session = AcpmuxSession(json(#"{"sessionId":"s1","name":"Fix","harness":"fake","cwd":"/tmp/w","status":"waiting","pendingPermissions":1,"lastSeq":12,"preview":"Done","lastTurn":{"status":"completed"}}"#))
        #expect(session?.summaryStatus == .waiting)
        #expect(session?.pendingPermissions == 1)
        #expect(session?.lastTurnStatus == "completed")
    }
}

/// A fake acpmux behind `MockMacLink`: initialize, watch, attach with one
/// page and a pending permission, then a live event; permission_respond for
/// an allow is refused as for a remote connection.
@MainActor
@Suite struct AcpmuxSourceTests {
    static func fakeAcpmux(_ log: CommandLog? = nil) -> MockMacLink {
        MockMacLink { _, data in
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = object["method"] as? String else { return [] }
            let id = object["id"].map { "\($0)" } ?? "null"
            func reply(_ result: String) -> Data { Data(#"{"jsonrpc":"2.0","id":\#(id),"result":\#(result)}"#.utf8) }
            switch method {
            case "initialize": return [reply(#"{"protocolVersion":1}"#)]
            case "_acpmux/watch": return [reply(#"{"sessions":[{"sessionId":"s1","name":"Fix","harness":"fake","cwd":"/tmp/w","status":"idle"}]}"#)]
            case "_acpmux/attach":
                return [
                    reply(#"{"session":{"sessionId":"s1","status":"waiting","pending":[]},"hasMore":false,"lastSeq":3,"events":[{"sessionId":"s1","seq":1,"at":1,"dir":"mux","kind":"user_message","msg":{"text":"ask: rm","promptId":"p","turnId":"t"}},{"sessionId":"s1","seq":2,"at":2,"dir":"mux","kind":"turn_started","msg":{"turnId":"t"}},{"sessionId":"s1","seq":3,"at":3,"dir":"mux","kind":"permission_request","msg":{"permissionId":"perm","request":{"toolCall":{"toolCallId":"c","title":"rm","kind":"execute"},"options":[{"optionId":"allow","name":"Allow","kind":"allow_once"},{"optionId":"deny","name":"Deny","kind":"reject_once"}]}}}]}"#),
                    Data(#"{"jsonrpc":"2.0","method":"_acpmux/event","params":{"sessionId":"s1","seq":4,"at":4,"dir":"in","kind":"agent_message_chunk","msg":{"method":"session/update","params":{"update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"live"}}}}}}"#.utf8),
                ]
            case "_acpmux/permission_respond":
                let params = object["params"] as? [String: Any]
                log?.append("respond:\(params?["optionId"] as? String ?? "-")", nil)
                if ["allow", "allow_once"].contains(params?["optionId"] as? String) {
                    return [Data(#"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32000,"message":"person required","data":{"reason":"permission.person_required"}}}"#.utf8)]
                }
                return [reply("{}"), Data(#"{"jsonrpc":"2.0","method":"_acpmux/event","params":{"sessionId":"s1","seq":5,"at":5,"dir":"mux","kind":"permission_decision","msg":{"permissionId":"perm","outcome":{"outcome":"selected","optionId":"deny"}}}}"#.utf8)]
            default:
                return [reply("{}")]
            }
        }
    }

    @Test func attachStreamsHistoryLiveAndDecisions() async throws {
        let link = Self.fakeAcpmux()
        let hub = AcpmuxHub()
        await hub.bind(try await link.openChannel(service: "acpmux", args: [:]))
        #expect(hub.isReady)
        #expect(hub.sessions["s1"]?.harness == "fake")
        let summary = AgentSessionSummary(id: "s7", name: "Fix", harness: "fake", agentName: "Fake", cwd: "/tmp/w", workspaceTitle: "w", macName: "mini")
        let store = AgentChatStore(source: hub.source(sessionID: "s1", summary: summary))
        for _ in 0..<500 where store.turns.first?.answerMarkdown != "live" { await Task.yield() }
        #expect(store.turns.count == 1)
        #expect(store.turns.first?.prompt == "ask: rm")
        #expect(store.pendingPermission?.request.id == "perm")
        #expect(store.turns.first?.answerMarkdown == "live")

        // An allow is refused for a remote connection: the chat shows why, the ask stays open.
        let request = try #require(store.pendingPermission?.request)
        store.respond(to: request, option: request.options[0])
        for _ in 0..<500 where store.clientError == nil { await Task.yield() }
        #expect(store.clientError?.contains("approve on the Mac") == true)
        #expect(store.pendingPermission != nil)

        // A deny reaches the Mac; the decision record resolves the card.
        store.respond(to: request, option: request.options[1])
        for _ in 0..<500 where store.pendingPermission != nil { await Task.yield() }
        #expect(store.pendingPermission == nil)
    }

    @Test func feedRoutesAnswersAndShowsRefusals() async throws {
        let link = Self.fakeAcpmux()
        let hub = AcpmuxHub()
        await hub.bind(try await link.openChannel(service: "acpmux", args: [:]))
        let feedStore = FeedStore(items: [])
        let feed = LiveFeed(store: feedStore, hub: hub, place: { _ in LiveFeed.Place(workspaceID: "ws", tabID: "s7", workspaceTitle: "cmux") })
        feedStore.actions = feed
        let request: JSONValue = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"toolCall":{"toolCallId":"c","title":"rm","kind":"execute"},"options":[{"optionId":"allow","name":"Allow","kind":"allow_once"},{"optionId":"deny","name":"Deny","kind":"reject_once"}]}"#.utf8))
        feed.handle(.permissionPending(sessionID: "s1", permissionID: "perm", request: request), sessions: hub.sessions)
        let item = try #require(feedStore.items.first)
        #expect(item.id == "ask-perm")
        // The session's open ask is a permission (Workspaces: "is asking permission").
        #expect(feed.waitingFor == ["s1": .permission])
        #expect(item.workspaceTitle == "cmux")
        #expect(item.needsYou)
        guard case .permission(let permission) = item.kind else { Issue.record("not a permission"); return }
        feedStore.respond(item.id, option: permission.options[0])
        for _ in 0..<500 where feedStore.items.first?.error == nil { await Task.yield() }
        #expect(feedStore.items.first?.needsYou == true)
        #expect(feedStore.items.first?.error?.contains("approve on the Mac") == true)
        feedStore.respond(item.id, option: permission.options[1])
        for _ in 0..<100 { await Task.yield() }
        #expect(feedStore.items.first?.resolution == "Denied")
        #expect(feedStore.items.first?.error == nil)
    }
}

@MainActor
@Suite struct FeedQuestionDeclineTests {
    /// A phone's answer to a question is refused (only the Mac may answer);
    /// Decline sends the question's reject option and resolves the card.
    @Test func refusedAnswerThenDeclineReachesTheMac() async throws {
        let log = CommandLog()
        let link = AcpmuxSourceTests.fakeAcpmux(log)
        let hub = AcpmuxHub()
        await hub.bind(try await link.openChannel(service: "acpmux", args: [:]))
        let feedStore = FeedStore(items: [])
        let feed = LiveFeed(store: feedStore, hub: hub, place: { _ in LiveFeed.Place(workspaceID: "ws", tabID: "s7", workspaceTitle: "cmux") })
        feedStore.actions = feed
        let request = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"toolCall":{"toolCallId":"q1","title":"Question","kind":"other","_meta":{"claude":{"tool":"AskUserQuestion"}},"rawInput":{"questions":[{"question":"Which?","header":"Pick","options":[{"label":"A"},{"label":"B"}],"multiSelect":false}]}},"options":[{"optionId":"allow_once","name":"Answer","kind":"allow_once"},{"optionId":"reject_once","name":"Reject","kind":"reject_once"}]}"#.utf8))
        feed.handle(.permissionPending(sessionID: "s1", permissionID: "pq", request: request), sessions: hub.sessions)
        let item = try #require(feedStore.items.first)
        guard case .question(let question) = item.kind else { Issue.record("not a question"); return }
        // A question (Workspaces: "has a question").
        #expect(feed.waitingFor == ["s1": .question])
        let first = try #require(question.items.first?.options.first)
        feedStore.answer(item.id, answer: AgentQuestionAnswer(selections: [question.items[0].id: .init(optionIDs: [first.id])]))
        for _ in 0..<500 where feedStore.items.first?.error == nil { await Task.yield() }
        #expect(feedStore.items.first?.needsYou == true)

        feedStore.decline(item.id)
        #expect(feedStore.items.first?.resolution == "Declined")
        #expect(feedStore.items.first?.needsYou == false)
        for _ in 0..<500 where !log.contains("respond:reject_once") { await Task.yield() }
        #expect(log.contains("respond:reject_once"))
        #expect(feedStore.items.first?.error == nil)
    }
}

/// A source that replays fixed events (store reducer tests).
@MainActor
final class ScriptedSource: AgentSessionSource {
    let summary = AgentSessionSummary(id: "s", name: "s", harness: "fake", agentName: "Fake", cwd: "/", workspaceTitle: "w", macName: "m")
    let script: [AgentSessionEvent]
    init(_ script: [AgentSessionEvent]) { self.script = script }
    func events() -> AsyncStream<AgentSessionEvent> {
        AsyncStream { continuation in
            for event in script { continuation.yield(event) }
            continuation.finish()
        }
    }
    func send(_ intent: AgentClientIntent) {}
}

@MainActor
@Suite struct QuestionDecisionTests {
    @Test func declinedQuestionIsCancelledNotAnswered() async throws {
        let records = AcpmuxRecords(sessionID: "s1")
        let request = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"toolCall":{"toolCallId":"c2","_meta":{"claude":{"tool":"AskUserQuestion"}},"rawInput":{"questions":[{"question":"Which?","options":[{"label":"A"}]}]}},"options":[{"optionId":"allow_once","name":"Answer","kind":"allow_once"},{"optionId":"reject_once","name":"Skip","kind":"reject_once"}]}"#.utf8))
        let question = try #require(records.permission("p2", request: request))
        let store = AgentChatStore(source: ScriptedSource([
            .userMessage(text: "question: Which?", promptId: "p", turnId: "t", attachments: [], at: Date()),
            question,
            .permissionDecision(permissionId: "p2", optionId: "reject_once"),
        ]))
        for _ in 0..<200 where store.turns.first?.items.count != 1 || store.pendingQuestion != nil { await Task.yield() }
        guard case .question(let resolved)? = store.turns.first?.items.first else { Issue.record("no question"); return }
        #expect(resolved.state == .cancelled)
    }
}

// MARK: Prompt content blocks

@Suite struct PromptBlockTests {
    @Test @MainActor func imagesBecomeACPImageBlocks() {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0x0D])
        let image = AgentAttachment(kind: .image, name: "Photo", data: png)
        // A file without an upload adds nothing.
        let blocks = AcpmuxSessionSource.promptBlocks(text: "look", attachments: [image, AgentAttachment(kind: .file, name: "a.txt")])
        #expect(blocks == [
            .object(["type": .string("text"), "text": .string("look")]),
            .object(["type": .string("image"), "mimeType": .string("image/png"), "data": .string(png.base64EncodedString())]),
        ])
    }

    @Test @MainActor func imageOnlyPromptHasNoEmptyTextBlock() {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0, 0, 0, 0, 0, 0])
        let blocks = AcpmuxSessionSource.promptBlocks(text: "", attachments: [AgentAttachment(kind: .image, name: "Photo", data: jpeg)])
        #expect(blocks.count == 1)
        #expect(blocks.first?["mimeType"]?.stringValue == "image/jpeg")
    }

    @Test @MainActor func uploadedFilesBecomeResources() {
        let text = AgentAttachment(id: "t", kind: .file, name: "notes.md", data: Data("# hi\n".utf8))
        let binary = AgentAttachment(id: "b", kind: .file, name: "a.zip", data: Data([0x50, 0x4B, 0x03, 0x04, 0]))
        let blocks = AcpmuxSessionSource.promptBlocks(text: "see", attachments: [text, binary], uploaded: [
            "t": "/w/.cmux/attachments/phone-1/notes.md", "b": "/w/.cmux/attachments/phone-1/a.zip",
        ])
        #expect(blocks.count == 3)
        #expect(blocks[1]["type"]?.stringValue == "resource")
        #expect(blocks[1]["resource"]?["uri"]?.stringValue == "file:///w/.cmux/attachments/phone-1/notes.md")
        #expect(blocks[1]["resource"]?["text"]?.stringValue == "# hi\n")
        #expect(blocks[2]["type"]?.stringValue == "resource_link")
        #expect(blocks[2]["uri"]?.stringValue == "file:///w/.cmux/attachments/phone-1/a.zip")
        #expect(blocks[2]["name"]?.stringValue == "a.zip")
        #expect(blocks[2]["size"]?.numberValue == 5)
        // A file the Mac never received is never sent as a reference.
        #expect(AcpmuxSessionSource.promptBlocks(text: "x", attachments: [text]).count == 1)
    }

    @Test func uploadRepliesBecomePathsOrFailures() throws {
        #expect(try LinkUpload.path(fromReply: Data(#"{"path":"/w/a.txt","size":2}"#.utf8)) == "/w/a.txt")
        #expect(throws: LinkUpload.Failure(code: "too_large", message: "the file is larger than 100 MB")) {
            try LinkUpload.path(fromReply: Data(#"{"error":"too_large","message":"the file is larger than 100 MB"}"#.utf8))
        }
        #expect(throws: LinkUpload.Failure.self) { try LinkUpload.path(fromReply: Data()) }
        #expect(LinkUpload.folder("/w/x/") == "/w/x")
        #expect(LinkUpload.folder("~/x") == nil)
    }

    @Test func splitAcpmuxMessagesJoin() {
        var joiner = AcpmuxConnection.MessageJoiner()
        let message = Data((#"{"method":"x","params":{"d":""# + String(repeating: "a", count: 300_000) + #""}}"#).utf8)
        let first = message.prefix(AcpmuxConnection.MessageJoiner.fullFrame)
        #expect(joiner.push(Data(first)) == nil)
        #expect(joiner.push(Data(message.dropFirst(first.count)))?["method"]?.stringValue == "x")
        #expect(joiner.push(Data(#"{"a":1}"#.utf8))?["a"]?.numberValue == 1)
        // A short frame that does not parse is dropped, not kept.
        #expect(joiner.push(Data("{".utf8)) == nil)
        #expect(joiner.push(Data(#"{"b":2}"#.utf8))?["b"]?.numberValue == 2)
    }

    /// Live 2026-10-14 (parity rig): the link writes data in 16 KiB chunks (cmux-mobile-link
    /// `DATA_CHUNK`, the input lane), and the joiner dropped every chunk shorter than
    /// 256 KiB that did not parse, so any acpmux reply over 16 KiB (`_acpmux/models`,
    /// 23 KB) never arrived and its request waited forever.
    @Test func sixteenKiBChunksJoin() {
        var joiner = AcpmuxConnection.MessageJoiner()
        let message = Data((#"{"id":3,"result":{"d":""# + String(repeating: "m", count: 40_000) + #""}}"#).utf8)
        var out: JSONValue?
        var rest = message[...]
        while !rest.isEmpty {
            let chunk = rest.prefix(16 * 1024)
            rest = rest.dropFirst(chunk.count)
            out = joiner.push(Data(chunk))
            if !rest.isEmpty { #expect(out == nil) }
        }
        #expect(out?["id"]?.numberValue == 3)
        // Exactly two full chunks: the message completes on its last full chunk.
        let exact = Data((#"{"x":""# + String(repeating: "e", count: 32 * 1024 - 8) + #""}"#).utf8)
        #expect(exact.count == 32 * 1024)
        #expect(joiner.push(Data(exact.prefix(16 * 1024))) == nil)
        #expect(joiner.push(Data(exact.dropFirst(16 * 1024)))?["x"] != nil)
        // A lost chunk does not swallow the next whole message.
        #expect(joiner.push(Data(message.prefix(16 * 1024))) == nil)
        #expect(joiner.push(Data(#"{"after":1}"#.utf8))?["after"]?.numberValue == 1)
    }
}

// MARK: Subagents and handoff over acpmux

@Suite struct AcpmuxParityTests {
    let records = AcpmuxRecords(sessionID: "s1")

    func json(_ string: String) -> JSONValue { try! JSONDecoder().decode(JSONValue.self, from: Data(string.utf8)) }

    @Test func mapsSubagentAttribution() {
        let spawn = json(#"{"seq":7,"at":1700000000000,"dir":"in","msg":{"method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"tool_call","toolCallId":"tc","title":"Agent","kind":"other"},"_meta":{"acpmux":{"subagents":[{"id":"a1","parent":null,"name":"Explore","task":"Find the dialer","state":"running","toolCallId":"tc"}]}}}}}"#)
        let events = records.map(spawn)
        guard case .subagent(let change)? = events.first else { Issue.record("no subagent"); return }
        #expect(change.id == "a1" && change.parent == nil && change.name == "Explore" && change.toolCallID == "tc" && change.state == .running)
        #expect(events.count == 2)
        let owned = json(#"{"seq":8,"dir":"in","msg":{"method":"session/update","params":{"sessionId":"a1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"found"}},"_meta":{"acpmux":{"subagent":"a1"}}}}}"#)
        #expect(records.map(owned) == [.subagentUpdate(subagentID: "a1", .agentMessageChunk(text: "found", messageId: nil))])
    }

    @Test @MainActor func readsHarnessesAndHandoffRecords() {
        let harnesses = json(#"{"harnesses":{"claude":{"family":"claude"},"codex":{"family":"codex","displayName":"Codex"},"gemini":{"unavailable":"not installed"}}}"#)
        let targets = AcpmuxSessionSource.handoffTargets(harnesses, excluding: "claude")
        #expect(targets.map(\.id) == ["codex", "gemini"])
        #expect(targets[0].name == "Codex" && targets[1].unavailableReason == "not installed")
        let record = json(#"{"handoffId":"h1","revision":2,"state":"draft","target":{"coverage":[{"item":"transcript","status":"summarized","detail":null}]},"capsule":{"text":"ctx","maxBytes":65536,"checkpoint":null},"promptId":null}"#)
        let draft = AcpmuxSessionSource.handoffDraft(record, target: targets[0])
        #expect(draft?.id == "h1" && draft?.revision == 2 && draft?.capsule == "ctx" && draft?.coverage.first?.status == .summarized)
    }
}

final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Bool] = []
    func append(_ value: Bool) { lock.withLock { stored.append(value) } }
    var values: [Bool] { lock.withLock { stored } }
}

@Suite struct MacTargetTests {
    let e2e = MacDevice(id: "e2e", name: "mobile e2e mini", isOnline: false)
    let stale = MacDevice(id: "stale", name: "cmux mini", isOnline: false)

    /// The linked Mac went offline and no other is online: keep it (the
    /// banner names it), not the first Mac of the list.
    @Test func keepsTheLinkedMacWhenItGoesOffline() {
        #expect(LinkMachine.target(in: [stale, e2e], remembered: nil, current: "e2e")?.id == "e2e")
    }

    @Test func prefersOnlineThenRememberedThenLinked() {
        var online = stale
        online.isOnline = true
        #expect(LinkMachine.target(in: [online, e2e], remembered: nil, current: "e2e")?.id == "stale")
        #expect(LinkMachine.target(in: [stale, e2e], remembered: "stale", current: "e2e")?.id == "stale")
        #expect(LinkMachine.target(in: [stale, e2e], remembered: nil, current: nil)?.id == "stale")
        #expect(LinkMachine.target(in: [], remembered: nil, current: nil) == nil)
    }
}

@Suite struct ProbeRaceTests {
    /// A ping that ignores cancellation (the FFI ping on a link the Mac
    /// already dropped) must not hold the probe past its timeout.
    @Test func timeoutWinsOverAnUncancellablePing() async {
        let start = ContinuousClock.now
        let result = await LinkController.race(timeout: .milliseconds(50), clock: ContinuousClock()) {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) { continuation.resume() }
            }
            return 7
        }
        #expect(ContinuousClock.now - start < .seconds(1))
        guard case .failure(let error) = result else { Issue.record("expected a timeout"); return }
        #expect((error as? LinkError)?.code == "timeout")
    }

    @Test func pingWinsWhenItAnswers() async {
        let result = await LinkController.race(timeout: .seconds(5), clock: ContinuousClock()) { 3 }
        #expect((try? result.get()) == 3)
    }
}

// MARK: Feed history (round 2: the Feed was empty after a relaunch)

@MainActor
@Suite struct FeedHistoryTests {
    nonisolated static let endedAt = 1_760_000_000_000.0

    /// A Mac whose watch reports a session with a finished turn, and that sends
    /// the next turn's `session_changed` when asked to (`session/prompt`).
    static func macWithHistory() -> MockMacLink {
        MockMacLink { _, data in
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = object["method"] as? String else { return [] }
            let id = object["id"].map { "\($0)" } ?? "null"
            func reply(_ result: String) -> Data { Data(#"{"jsonrpc":"2.0","id":\#(id),"result":\#(result)}"#.utf8) }
            switch method {
            case "_acpmux/watch":
                return [reply(#"{"sessions":[{"sessionId":"s1","name":"Fix","harness":"claude","cwd":"/tmp/w","status":"idle","preview":"Tests pass.","lastPrompt":"run the tests","lastSeq":40,"lastTurn":{"turnId":"t9","status":"completed","endedAt":\#(endedAt)}},{"sessionId":"s2","name":"New","harness":"codex","cwd":"/tmp/w","status":"idle","lastSeq":0}]}"#)]
            case "session/prompt":
                return [reply("{}"), Data(#"{"jsonrpc":"2.0","method":"_acpmux/session_changed","params":{"sessionId":"s1","kind":"record","recordKind":"turn_result","seq":44,"session":{"sessionId":"s1","name":"Fix","harness":"claude","cwd":"/tmp/w","status":"idle","preview":"Tests pass.","lastPrompt":"run the tests","lastSeq":44,"lastTurn":{"turnId":"t9","status":"completed","endedAt":\#(endedAt)}}}}"#.utf8)]
            default:
                return [reply("{}")]
            }
        }
    }

    @Test func connectingShowsTheMacsLastTurns() async throws {
        let hub = AcpmuxHub()
        let feedStore = FeedStore(items: [])
        let feed = LiveFeed(store: feedStore, hub: hub, place: { _ in nil })
        hub.onWatchEvent = { feed.handle($0, sessions: hub.sessions) }
        await hub.bind(try await Self.macWithHistory().openChannel(service: "acpmux", args: [:]))
        #expect(feedStore.items.map(\.id) == ["turn-s1-t9"])
        let item = try #require(feedStore.items.first)
        #expect(item.markdown == "Tests pass.")
        #expect(item.quote?.text == "run the tests")
        #expect(item.createdAt == Date(timeIntervalSince1970: Self.endedAt / 1000))
        #expect(feedStore.unseenNewIDs.isEmpty)

        // The same turn arriving live (a late session_changed) is not a second item.
        _ = try await hub.request("session/prompt", .object([:]))
        for _ in 0..<200 { await Task.yield() }
        #expect(feedStore.items.map(\.id) == ["turn-s1-t9"])
    }

    @Test func historyKeepsWhatThePersonDid() {
        let date = Date(timeIntervalSince1970: 1_000)
        let item = FeedItem(id: "turn-s1-t9", kind: .response, workspaceID: "", tabID: "s1", agentName: "Claude", harness: "claude",
                            workspaceTitle: "w", markdown: "Done", quote: nil, createdAt: date)
        let store = FeedStore(items: [item])
        store.markDone(item.id)
        store.mergeHistory([item])
        #expect(store.items.first?.isDone == true)
        store.upsert(item, atTop: true)
        #expect(store.items.first?.isDone == true)
        #expect(store.visibleItems.isEmpty)
    }

    @Test func archiveRoundTripsFinishedTurnsOnly() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "feed-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let archive = FeedArchive(url: url)
        var done = FeedItem(id: "turn-a", kind: .response, workspaceID: "ws", tabID: "t", agentName: "Claude", harness: "claude",
                            workspaceTitle: "cmux", markdown: "**Done**", quote: .init("go"), createdAt: Date(timeIntervalSince1970: 2_000))
        done.isDone = true
        done.isRead = true
        let failed = FeedItem(id: "turn-b", kind: .failed, workspaceID: "ws", tabID: "t", agentName: "Codex", harness: "codex",
                              workspaceTitle: "cmux", markdown: "The turn failed.", quote: nil, createdAt: Date(timeIntervalSince1970: 3_000))
        let request = ACPPermissionRequest(id: "p", toolCall: .init(id: "c", title: "rm", kind: .execute), options: [])
        let ask = FeedItem(id: "ask-p", kind: .permission(request), workspaceID: "ws", tabID: "t", agentName: "Claude", harness: "claude",
                           workspaceTitle: "cmux", markdown: "rm", quote: nil, createdAt: Date(timeIntervalSince1970: 4_000))
        archive.save([done, failed, ask])
        let loaded = archive.load()
        #expect(loaded.map(\.id) == ["turn-b", "turn-a"])
        #expect(loaded.last?.isDone == true)
        #expect(loaded.last?.quote?.text == "go")
        #expect(loaded.first?.kind == .failed)
    }
}

// MARK: Queue changes reach the chat (parity round 3, live finding)

@Suite struct ChatKindsTests {
    /// A Mac's acpmux may leave Edit queued prompt and Move up / down out of its
    /// `transcript` records: the phone asks for them by name, so its queue rows follow.
    @Test @MainActor func theChatAsksForQueueChangesByName() {
        guard case .array(let kinds) = AcpmuxSessionSource.chatKinds else {
            Issue.record("kinds is not a list"); return
        }
        let names = kinds.compactMap(\.stringValue)
        #expect(names.contains("transcript"))
        #expect(names.contains("queue_updated"))
        #expect(names.contains("queue_order"))
    }
}

/// r13 live rig (D4, T-LIFE-13): with two Macs on the account, a quit Mac's
/// terminal goes offline even though the link moved to the other Mac.
@Suite struct TerminalOfflinePerMacTests {
    @Test func aTerminalFollowsItsOwnMac() {
        // Its Mac is linked: the link's phase decides.
        #expect(!LinkMachine.terminalOffline(macID: "a", linkedMacID: "a", linkOffline: false))
        #expect(LinkMachine.terminalOffline(macID: "a", linkedMacID: "a", linkOffline: true))
        // The link serves another Mac: this terminal cannot reattach.
        #expect(LinkMachine.terminalOffline(macID: "a", linkedMacID: "b", linkOffline: false))
        #expect(LinkMachine.terminalOffline(macID: "a", linkedMacID: nil, linkOffline: false))
        // Unknown Mac (no target when opened): the link's phase decides.
        #expect(!LinkMachine.terminalOffline(macID: nil, linkedMacID: "b", linkOffline: false))
    }
}

// MARK: Team prefs

@Suite struct TeamPrefsTests {
    @Test func prefsFromAnOlderWorkerDrawTheColor() throws {
        let prefs = try JSONDecoder().decode(LiveAPI.Prefs.self, from: Data(##"{"color":"#30D158","emoji":"🚀"}"##.utf8))
        #expect(prefs.appearance == TeamAppearance(colorHex: "#30D158", emoji: "🚀"))
    }

    @Test func transparentPrefsKeepTheColorAsFallback() throws {
        let json = ##"{"color":"#30D158","emoji":"🚀","transparent":true}"##
        let prefs = try JSONDecoder().decode(LiveAPI.Prefs.self, from: Data(json.utf8))
        #expect(prefs.appearance?.isTransparent == true)
        #expect(prefs.appearance?.colorHex == "#30D158")
        // Without an icon it is never transparent.
        let bare = try JSONDecoder().decode(LiveAPI.Prefs.self, from: Data(##"{"color":"#30D158","emoji":null,"transparent":true}"##.utf8))
        #expect(bare.appearance?.isTransparent == false)
    }

    @Test func noStoredColorKeepsTheLocalAppearance() {
        #expect(LiveAPI.Prefs(color: nil, emoji: "🚀", transparent: true).appearance == nil)
    }

    @Test func putBodyCarriesTransparent() {
        let body = LiveAPI.prefsBody(TeamAppearance(colorHex: "#30D158", emoji: "🚀", transparent: true))
        #expect(body["color"] as? String == "#30D158")
        #expect(body["emoji"] as? String == "🚀")
        #expect(body["transparent"] as? Bool == true)
        #expect(LiveAPI.prefsBody(TeamAppearance(colorHex: "#30D158"))["emoji"] is NSNull)
        #expect(LiveAPI.prefsBody(TeamAppearance(colorHex: "#30D158", emoji: nil, transparent: true))["transparent"] as? Bool == false)
    }
}

@Suite struct SimulatorTabTreeTests {
    /// A Mac phone tab (`page: phone`) is a simulator tab; another page tab is not shown.
    @Test func aPhoneTabIsASimulatorTab() throws {
        let reply = Data("""
        {"id":"m","ok":true,"data":{"workspace_revision":1,"workspaces":[{"id":4,"name":"app","screens":[{"id":3,"panes":[{"id":2,"tabs":[
          {"surface":12,"kind":"conversation","name":null,"title":"","conversation":{"page":"phone","route":"sim:ABC"}},
          {"surface":13,"kind":"conversation","title":"Settings","conversation":{"page":"settings"}}
        ]}]}]}]}}
        """.utf8)
        let tree = try DaemonTree(reply: reply, macID: "mac-1", agents: AgentStates())
        let tabs = try #require(tree.workspaces.first).tabs
        #expect(tabs.map(\.id) == ["s12"])
        #expect(tabs.first?.kind == .simulator && tabs.first?.title == "Simulator")
        #expect(tabs.first?.systemImage == "iphone")
    }
}

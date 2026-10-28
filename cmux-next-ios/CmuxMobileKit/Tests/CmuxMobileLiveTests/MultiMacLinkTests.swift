import CmuxMobileAgentChat
import CmuxMobileBrowserStream
import CmuxMobileFeed
import CmuxMobileModel
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

/// Dials a fresh mock link per dial and counts dials and closes per Mac.
final class PerMacDialer: MacLinkDialer, @unchecked Sendable {
    private let lock = NSLock()
    private var dials: [String: Int] = [:]
    /// What each Mac's daemon answers (`read-screen` text, workspace keys).
    let screens: [String: String]
    /// Each Mac's `acpmux` service (by Mac id and request); nil leaves it unanswered.
    let acpmux: (@Sendable (String, Data) -> [Data])?

    init(screens: [String: String] = [:], acpmux: (@Sendable (String, Data) -> [Data])? = nil) {
        self.screens = screens
        self.acpmux = acpmux
    }

    func dialCount(_ macID: String) -> Int { lock.withLock { dials[macID] ?? 0 } }

    func dial(_ endpoint: LinkEndpoint, transport: CmuxMobileTransport.TransportKind, accessToken: String) async throws -> any MacLink {
        let mac = endpoint.macDeviceID
        lock.withLock { dials[mac, default: 0] += 1 }
        let screen = screens[mac] ?? mac
        let acpmux = acpmux
        return MockMacLink(transport: transport) { service, data in
            if service == "acpmux", let acpmux { return acpmux(mac, data) }
            guard service == "daemon" else { return [] }
            return data.split(separator: 0x0A).compactMap { request -> Data? in
                guard let object = try? JSONSerialization.jsonObject(with: Data(request)) as? [String: Any],
                      let id = object["id"] as? String else { return nil }
                let line: String
                switch object["cmd"] as? String ?? "" {
                case "list-workspaces":
                    // Both Macs number their surfaces from 1: the same tab id `s1` on each.
                    line = #"{"id":"\#(id)","ok":true,"data":{"workspaces":[{"id":1,"key":"ws-\#(mac)","name":"\#(mac)","screens":[{"id":1,"active":true,"active_pane":1,"panes":[{"id":1,"active_tab":0,"tabs":[{"surface":1,"kind":"pty","title":"zsh"}]}]}]}]}}"#
                case "list-agents":
                    line = #"{"id":"\#(id)","ok":true,"data":{"agents":[]}}"#
                case "read-screen":
                    line = #"{"id":"\#(id)","ok":true,"data":{"text":"\#(screen)"}}"#
                default:
                    line = #"{"id":"\#(id)","ok":true,"data":{}}"#
                }
                return Data(line.utf8) + Data([0x0A])
            }
        }
    }
}


/// Which Macs keep a link (PROTOCOL.md "One link per Mac"): bounded, lazy,
/// idle teardown.
@Suite struct MacLinkPolicyTests {
    let now = ContinuousClock.now
    let macs = [
        MacDevice(id: "m1", name: "One", isOnline: true), MacDevice(id: "m2", name: "Two", isOnline: true),
        MacDevice(id: "m3", name: "Three", isOnline: true), MacDevice(id: "m4", name: "Four", isOnline: false),
    ]

    @Test func everyShownMacIsLinkedFocusedFirst() {
        let decision = MacLinkPolicy().decide(macs: macs, focused: "m2", showing: ["m1", "m2", "m3"], lastShown: [:], now: now)
        #expect(decision.linked == ["m2", "m1", "m3"])
        #expect(decision.nextExpiry == nil)
    }

    /// Lazy: a Mac nothing shows, and never shown, is not dialed.
    @Test func aMacNothingShowsIsNotLinked() {
        let decision = MacLinkPolicy().decide(macs: macs, focused: "m1", showing: ["m1"], lastShown: [:], now: now)
        #expect(decision.linked == ["m1"])
    }

    /// Idle teardown: a Mac left keeps its link for `idleAfter`, then not.
    @Test func aMacLeftKeepsItsLinkUntilIdle() {
        let policy = MacLinkPolicy(idleAfter: .seconds(300))
        let left = now - .seconds(120)
        let kept = policy.decide(macs: macs, focused: "m1", showing: [], lastShown: ["m2": left], now: now)
        #expect(kept.linked == ["m1", "m2"])
        #expect(kept.nextExpiry == left + .seconds(300))
        let later = policy.decide(macs: macs, focused: "m1", showing: [], lastShown: ["m2": left], now: now + .seconds(181))
        #expect(later.linked == ["m1"])
        #expect(later.nextExpiry == nil)
    }

    /// Bounded: the focused Mac, then on screen, then the most recent, up to `maxLinks`.
    @Test func linksAreBounded() {
        let policy = MacLinkPolicy(maxLinks: 2)
        let decision = policy.decide(macs: macs, focused: "m3", showing: ["m1", "m2"], lastShown: [:], now: now)
        #expect(decision.linked == ["m3", "m1"])
        let recent = policy.decide(macs: macs, focused: "m1", showing: [],
                                   lastShown: ["m2": now - .seconds(10), "m3": now - .seconds(5)], now: now)
        #expect(recent.linked == ["m1", "m3"])
    }

    /// An offline Mac is never dialed ahead of an online one; the focused one
    /// stays targeted offline (its status says so).
    @Test func offlineMacsComeLast() {
        let policy = MacLinkPolicy(maxLinks: 2)
        #expect(policy.decide(macs: macs, focused: "m4", showing: [], lastShown: [:], now: now).linked == ["m4"])
        #expect(policy.decide(macs: macs, focused: "m1", showing: ["m4", "m2"], lastShown: [:], now: now).linked == ["m1", "m2"])
    }

    /// The Mac a held pairing code names comes next after the focused one, ahead of the
    /// Macs on screen, and never past `maxLinks`.
    @Test func thePinnedMacComesNextAfterTheFocusedOne() {
        let policy = MacLinkPolicy(maxLinks: 2)
        #expect(policy.decide(macs: macs, focused: "m1", showing: ["m1", "m2", "m3"], lastShown: [:], now: now,
                              pinned: "m3").linked == ["m1", "m3"])
        #expect(policy.decide(macs: macs, focused: "m1", showing: ["m2"], lastShown: [:], now: now,
                              pinned: "m1").linked == ["m1", "m2"])
        #expect(policy.decide(macs: macs, focused: "m1", showing: ["m2"], lastShown: [:], now: now,
                              pinned: "m9").linked == ["m1", "m2"])
        #expect(MacLinkPolicy(maxLinks: 1).decide(macs: macs, focused: "m1", showing: [], lastShown: [:], now: now,
                                                  pinned: "m3").linked == ["m1"])
    }
}

// The coordinator is iOS-only: these run in the iOS simulator test pass.
#if os(iOS)
/// The phone holds one link per online Mac at once (PROTOCOL.md "One link per
/// Mac"). Before, one link served the account: choosing a second Mac (opening
/// one of its workspaces) closed the first Mac's link, so its workspaces said
/// "Can't connect" and its terminals ended until it was chosen again.
@MainActor
@Suite(.serialized) struct MultiMacLinkTests {
    let host = "svc-\(UUID().uuidString.prefix(8).lowercased()).cmuxMobile.test"
    let userID = "user-\(UUID().uuidString)"

    func coordinator(store: AppStore, dialer: PerMacDialer) -> LiveCoordinator {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-mobile-multimac-\(UUID().uuidString)")
        let snapshots = LiveSnapshotStore(directory: directory)
        let saved = Date(timeIntervalSince1970: 1_000)
        snapshots.save(LiveSnapshot(
            teamID: "t-multimac", teamName: "One",
            macs: [MacDevice(id: "m1", name: "Aziz's MacBook Pro", isOnline: true), MacDevice(id: "m2", name: "MacBook Pro", isOnline: true)],
            linkedMacID: "m1",
            workspaces: ["m1": .init(workspaces: [], savedAt: saved), "m2": .init(workspaces: [], savedAt: saved)]
        ), accountID: userID)
        snapshots.flush()
        return LiveCoordinator(
            store: store,
            api: LiveAPI(baseURL: URL(string: "https://\(host)")!, session: ServiceStub.session()) { _ in "token" },
            identity: DeviceIdentity(link: UUID().uuidString, presence: UUID().uuidString),
            userID: userID, deviceName: "iPhone", transport: .wireGuard, dialer: dialer,
            feedStore: FeedStore(items: []), snapshots: snapshots
        )
    }

    func emptyStore() -> AppStore {
        AppStore(teams: [], activeTeamID: "", workspaces: [], feed: [], tabMemory: .inMemory())
    }

    func settle(_ done: () -> Bool) async {
        for _ in 0..<3000 where !done() { try? await Task.sleep(for: .milliseconds(1)) }
    }

    func drain() async {
        for _ in 0..<50 { try? await Task.sleep(for: .milliseconds(2)) }
    }

    /// The user's report: two Macs online, and only the one whose workspace was
    /// opened last stays connected. Opening the second Mac's workspace must not
    /// close the first Mac's link.
    @Test func choosingTheSecondMacKeepsTheFirstLinked() async {
        let key = "cmuxMobile.live.mac.t-multimac"
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let store = emptyStore()
        let dialer = PerMacDialer()
        let live = coordinator(store: store, dialer: dialer)
        defer { live.stop() }
        await settle { store.macConnection["m1"] == .connected }
        #expect(store.macConnection["m1"] == .connected)

        live.select(macID: "m2")
        await settle { store.macConnection["m2"] == .connected }
        await drain()
        #expect(store.macConnection["m2"] == .connected)
        #expect(store.macConnection["m1"] == .connected)
        // The first Mac's link was never closed and redialed.
        #expect(dialer.dialCount("m1") == 1)
        #expect(dialer.dialCount("m2") == 1)
        // Both Macs' workspaces are live at once.
        await settle { store.macDataPhase("m1") == .live && store.macDataPhase("m2") == .live }
        #expect(store.macDataPhase("m1") == .live)
        #expect(store.macDataPhase("m2") == .live)

        // Back to the first Mac: nothing redials either.
        live.select(macID: "m1")
        await drain()
        #expect(dialer.dialCount("m1") == 1)
        #expect(dialer.dialCount("m2") == 1)
        #expect(store.macConnection["m2"] == .connected)
    }
    /// A terminal tab opens its channels on its own Mac's link, even when tab ids
    /// repeat across Macs (both Macs number their surfaces from 1) and the other
    /// Mac is focused.
    @Test func aTerminalReadsItsOwnMac() async {
        let key = "cmuxMobile.live.mac.t-multimac"
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let store = emptyStore()
        let live = coordinator(store: store, dialer: PerMacDialer(screens: ["m1": "first Mac", "m2": "second Mac"]))
        defer { live.stop() }
        live.showing(macIDs: nil)
        await settle { store.macDataPhase("m1") == .live && store.macDataPhase("m2") == .live }
        live.select(macID: "m2")
        await drain()
        #expect(await live.terminalScreenText(tabID: "s1", macID: "m1") == "first Mac")
        #expect(await live.terminalScreenText(tabID: "s1", macID: "m2") == "second Mac")
        #expect(live.terminalSession(tabID: "s1", programName: "zsh", macID: "m1")?.macName == "Aziz's MacBook Pro")
        #expect(live.terminalSession(tabID: "s1", programName: "zsh", macID: "m2")?.macName == "MacBook Pro")
    }

    /// Lazy and idle: a Mac no screen shows closes its link after the idle
    /// window, quietly (its list is last-known, not "Can't connect"), and opens
    /// it again when it is shown.
    @Test func aMacLeftAloneClosesItsLinkAndReopensWhenShown() async {
        let key = "cmuxMobile.live.mac.t-multimac"
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let store = emptyStore()
        let dialer = PerMacDialer()
        let live = coordinator(store: store, dialer: dialer)
        defer { live.stop() }
        live.linkPolicy = MacLinkPolicy(idleAfter: .milliseconds(200))
        live.showing(macIDs: nil)
        await settle { store.macConnection["m1"] == .connected && store.macConnection["m2"] == .connected }
        // Only the first Mac's workspace is on screen now.
        live.showing(macIDs: ["m1"])
        await settle { store.macConnection["m2"] == nil }
        #expect(store.macConnection["m2"] == nil)
        #expect(store.macDataPhase("m2") == .cached(.idle))
        #expect(store.macConnection["m1"] == .connected)
        #expect(dialer.dialCount("m1") == 1)
        // The Workspaces list again: the second Mac's link opens again.
        live.showing(macIDs: nil)
        await settle { store.macConnection["m2"] == .connected }
        #expect(store.macConnection["m2"] == .connected)
        #expect(dialer.dialCount("m2") == 2)
    }

    /// Transport settings reach every Mac's link.
    @Test func aTransportChangeRedialsEveryLink() async {
        let key = "cmuxMobile.live.mac.t-multimac"
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let store = emptyStore()
        let dialer = PerMacDialer()
        let live = coordinator(store: store, dialer: dialer)
        defer { live.stop() }
        live.showing(macIDs: nil)
        await settle { store.macConnection["m1"] == .connected && store.macConnection["m2"] == .connected }
        live.setTransport(.webRTC)
        await settle { dialer.dialCount("m1") == 2 && dialer.dialCount("m2") == 2 }
        #expect(dialer.dialCount("m1") == 2)
        #expect(dialer.dialCount("m2") == 2)
        #expect(live.sessions.values.allSatisfy { $0.link.transport == .webRTC })
    }
    /// Lazy from launch: before the screens say what they show, only the
    /// focused Mac dials.
    @Test func onlyTheFocusedMacDialsAtLaunch() async {
        let key = "cmuxMobile.live.mac.t-multimac"
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let store = emptyStore()
        let dialer = PerMacDialer()
        let live = coordinator(store: store, dialer: dialer)
        defer { live.stop() }
        await settle { store.macConnection["m1"] == .connected }
        await drain()
        #expect(dialer.dialCount("m1") == 1)
        #expect(dialer.dialCount("m2") == 0)
        // Retry on the second Mac opens its link without moving the focus.
        live.retry(macID: "m2")
        await settle { store.macConnection["m2"] == .connected }
        #expect(store.macConnection["m2"] == .connected)
        #expect(live.focusedMacID == "m1")
    }

    /// Review blocker: a chat tab id repeats across Macs; each Mac's chat is its own.
    @Test func chatsOfTwoMacsWithTheSameTabIDAreSeparate() {
        let sessions = AgentSessionDirectory()
        func summary(_ mac: String) -> AgentSessionSummary {
            AgentSessionSummary(id: "s3", name: "chat", harness: "claude", agentName: "Claude", cwd: "~", workspaceTitle: "w",
                                macName: mac, macID: mac)
        }
        let first = sessions.store(for: summary("m1"))
        let second = sessions.store(for: summary("m2"))
        #expect(first !== second)
        #expect(sessions.existingStore(id: "s3", macID: "m1") === first)
        sessions.invalidate(id: "s3", macID: "m2")
        #expect(sessions.existingStore(id: "s3", macID: "m1") === first)
        #expect(sessions.existingStore(id: "s3", macID: "m2") == nil)
    }

    /// Review major: a streamed browser tab opens on its own Mac's link, never
    /// the focused one, and same-id tabs of two Macs are two pages.
    @Test func browserTabsStreamFromTheirOwnMac() {
        let directory = StreamedBrowserDirectory()
        directory.opener = { nil }
        directory.macOpener = { _ in nil }
        let first = directory.model(tab: "s9", url: nil, macID: "m1")
        let second = directory.model(tab: "s9", url: nil, macID: "m2")
        #expect(first != nil && second != nil && first !== second)
        #expect(directory.model(tab: "s9", url: nil, macID: "m1") === first)
        directory.drop(tab: "s9", macID: "m2")
        #expect(directory.model(tab: "s9", url: nil, macID: "m1") === first)
        directory.reset()
    }
}
#endif

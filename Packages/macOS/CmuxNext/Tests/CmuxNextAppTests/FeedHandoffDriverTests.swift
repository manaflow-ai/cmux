@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextSettings
import Foundation
import Testing

/// Notifications migration steps 2 and 3 (plans/cmux-next/feed.md 9.1, B1 to
/// B7): the app drives the handoff of the daemon's local feed items to
/// FeedDO, rebuilds its queue from the daemon at launch (B3), lets only what
/// the settings allow leave the Mac, and reads moved items in the cloud when
/// an ack refuses them (B5).
@MainActor
struct FeedHandoffDriverTests {
    /// A fake local feed owner with the daemon's state machine
    /// (open -> handing_off -> moved). It survives a "relaunch": a new driver
    /// over the same daemon sees the same items.
    @MainActor
    final class Daemon {
        var items: [FeedLocalItem]
        var servesCapability = true
        var calls: [String] = []

        init(_ items: [FeedLocalItem]) { self.items = items }

        func client() -> FeedHandoffDriver.Daemon {
            FeedHandoffDriver.Daemon(
                serves: { [unowned self] in self.servesCapability },
                list: { [unowned self] state, unread in
                    self.calls.append("list \(state.rawValue)\(unread ? " unread" : "")")
                    return self.items.filter { $0.state == state && (!unread || $0.isUnread) }
                },
                begin: { [unowned self] id in
                    self.calls.append("begin \(id)")
                    return try self.transition(id, from: .open, to: .handingOff, home: nil)
                },
                done: { [unowned self] id, home in
                    self.calls.append("done \(id) \(home)")
                    return try self.transition(id, from: .handingOff, to: .moved, home: home)
                })
        }

        private func transition(_ id: String, from: FeedLocalItem.State, to: FeedLocalItem.State, home: String?) throws -> FeedLocalItem {
            guard let index = items.firstIndex(where: { $0.id == id }) else {
                throw DaemonError.command(cmd: "feed-local", message: "not found", code: "not_found")
            }
            if items[index].state == to { return items[index] }
            guard items[index].state == from else {
                throw DaemonError.command(cmd: "feed-local", message: "bad state", code: "feed.invalid_state")
            }
            items[index].state = to
            items[index].home = home
            return items[index]
        }

        func state(_ id: String) -> FeedLocalItem.State? { items.first { $0.id == id }?.state }
    }

    /// A fake FeedDO: records ops; can lose the reply of the next adopt (the
    /// owner committed, the app never heard back).
    @MainActor
    final class Owner {
        var calls: [(op: String, key: String, params: [String: Any])] = []
        var loseNextAdoptReply = false
        var refuse: String?

        func handle(_ body: [String: Any]) async throws -> [String: Any] {
            let op = body["op"] as? String ?? ""
            let params = body["params"] as? [String: Any] ?? [:]
            calls.append((op, body["idempotency_key"] as? String ?? "", params))
            if op == "feed.adopt" {
                if let refuse { throw FeedServiceError.owner(code: refuse, message: "") }
                if loseNextAdoptReply {
                    loseNextAdoptReply = false
                    throw URLError(.networkConnectionLost)
                }
                return ["ok": true, "value": ["item": params["item"] as Any]]
            }
            return ["ok": true]
        }

        var adopts: [(key: String, item: [String: Any])] {
            calls.filter { $0.op == "feed.adopt" }.map { ($0.key, $0.params["item"] as? [String: Any] ?? [:]) }
        }
        var adoptedTitles: [String] { adopts.map { $0.item["title"] as? String ?? "" } }
        var reads: [[String]] { calls.filter { $0.op == "feed.read" }.map { $0.params["items"] as? [String] ?? [] } }
    }

    static let install = "inst-mac-1"
    /// 2026-10-03 12:00 UTC.
    static let noon: UInt64 = 1_791_028_800_000

    private static func item(_ id: String, source: String = "agent", title: String? = nil, body: String = "body",
                             workspace: String = "ws_1", at: UInt64 = noon, state: FeedLocalItem.State = .open) -> FeedLocalItem {
        FeedLocalItem(id: id, dedupeKey: "notify:S:\(id)", title: title ?? "Title \(id)", body: body, source: source,
                      context: .init(workspace: workspace, tab: "tab_\(id)", terminal: "term_\(id)"),
                      createdAtMs: at, state: state)
    }

    private func driver(_ daemon: Daemon, _ owner: Owner, prefs: NotificationPreferences = NotificationPreferences(),
                        muted: Set<String> = [], signedIn: Bool = true, install: String? = install,
                        enabled: Bool = true) -> FeedHandoffDriver {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        return FeedHandoffDriver(
            enabled: enabled,
            daemon: daemon.client(),
            owner: { _, body in try await owner.handle(body) },
            isSignedIn: { signedIn },
            installID: { install },
            policy: { FeedHandoffPolicy(preferences: prefs, mutedWorkspaces: muted, calendar: utc) },
            now: { Date(timeIntervalSince1970: Double(Self.noon) / 1000 + 60) })
    }

    // MARK: (a) B3: the handoff queue is rebuilt from the daemon, never from memory

    @Test func handingOffItemsAtLaunchAreAdoptedWithTheirKeyThenMarkedDone() async {
        let daemon = Daemon([Self.item("feeditem_1", state: .handingOff)])
        let owner = Owner()
        let driver = driver(daemon, owner)
        driver.run()
        await driver.drain()
        #expect(owner.adopts.map { $0.key } == ["adopt:feeditem_1"])
        #expect(!daemon.calls.contains("begin feeditem_1"), "a frozen item is not begun again")
        #expect(daemon.calls.contains("done feeditem_1 cloud"))
        #expect(daemon.state("feeditem_1") == .moved)
        let first = daemon.calls.firstIndex(of: "list handing_off")
        let open = daemon.calls.firstIndex(of: "list open unread")
        #expect(first != nil && open != nil && first! < open!, "handing_off items go first")
    }

    @Test func aLostAdoptReplyIsRetriedWithTheSameKeyAfterARelaunch() async {
        let daemon = Daemon([Self.item("feeditem_2")])
        let owner = Owner()
        owner.loseNextAdoptReply = true
        let first = driver(daemon, owner)
        first.run()
        await first.drain()
        #expect(daemon.state("feeditem_2") == .handingOff, "a send that may have committed never unfreezes")
        #expect(!daemon.calls.contains { $0.hasPrefix("done") })

        // Kill and relaunch: a new driver, the same daemon.
        let relaunched = driver(daemon, owner)
        relaunched.run()
        await relaunched.drain()
        #expect(owner.adopts.map { $0.key } == ["adopt:feeditem_2", "adopt:feeditem_2"])
        let ids = owner.adopts.map { $0.item["id"] as? String }
        #expect(ids[0] != nil && ids[0] == ids[1], "the cloud id is derived, so a retry names the same item")
        #expect(daemon.state("feeditem_2") == .moved)
    }

    @Test func theAdoptBodyIsAFullCloudItemHomedOnThisInstall() throws {
        let item = Self.item("feeditem_a1", body: "token ghp_abcdefghijklmnopqrstuvwxyz0123")
        let body = FeedHandoffDriver.adoptBody(item, install: Self.install, content: ("T", item.body),
                                               now: Date(timeIntervalSince1970: Double(Self.noon) / 1000 + 60))
        #expect(body["op"] as? String == "feed.adopt")
        #expect(body["idempotency_key"] as? String == "adopt:feeditem_a1")
        let cloud = try #require((body["params"] as? [String: Any])?["item"] as? [String: Any])
        let id = try #require(cloud["id"] as? String)
        #expect(id.range(of: #"^fi_[a-z0-9]{20}$"#, options: .regularExpression) != nil)
        #expect(id == FeedHandoffDriver.cloudID(install: Self.install, local: "feeditem_a1"))
        #expect(id != FeedHandoffDriver.cloudID(install: "inst-other", local: "feeditem_a1"))
        #expect(cloud["home"] as? String == "local:\(Self.install)")
        #expect(cloud["state"] as? String == "open")
        #expect(cloud["dedupe_key"] as? String == "notify:S:feeditem_a1")
        #expect((cloud["poster"] as? [String: Any])?["install"] as? String == Self.install)
        #expect((cloud["poster"] as? [String: Any])?["scope"] as? String == "inst:\(Self.install)")
        #expect(!(cloud["body"] as? String ?? "").contains("ghp_"), "text is scrubbed before it leaves the Mac")
    }

    // MARK: (b) only what the settings and the alert policy allow reaches FeedDO

    @Test func onlyEligibleItemsAreHandedOff() async {
        let daemon = Daemon([
            Self.item("agent", source: "agent"),
            Self.item("cli", source: "cli"),
            Self.item("term", source: "terminal"),
            Self.item("muted", source: "agent", workspace: "ws_muted"),
            Self.item("quiet", source: "agent", at: Self.noon - 11 * 3_600_000), // 01:00 UTC
        ])
        let owner = Owner()
        var prefs = NotificationPreferences()
        prefs.quietHours = QuietHours(start: 0, end: 6 * 60)
        let driver = driver(daemon, owner, prefs: prefs, muted: ["ws_muted"])
        driver.run()
        await driver.drain()
        #expect(Set(owner.adopts.map { $0.key }) == ["adopt:agent", "adopt:cli"])
        for kept in ["term", "muted", "quiet"] {
            #expect(!daemon.calls.contains("begin \(kept)"), "\(kept) is never handed off")
            #expect(daemon.state(kept) == .open)
        }
    }

    @Test func terminalMirrorModesDecideTheText() async {
        for (mode, expected) in [(FeedTerminalMirror.off, nil), (.title, ""), (.full, "out")] as [(FeedTerminalMirror, String?)] {
            let daemon = Daemon([Self.item("t", source: "terminal", title: "Done", body: "out")])
            let owner = Owner()
            var prefs = NotificationPreferences()
            prefs.feedMirror.terminal = mode
            let driver = driver(daemon, owner, prefs: prefs)
            driver.run()
            await driver.drain()
            #expect(owner.adopts.first.map { $0.item["body"] as? String } == expected.map { Optional($0) }, "\(mode)")
            #expect(owner.adoptedTitles == (expected == nil ? [] : ["Done"]))
        }
    }

    @Test func agentsOffKeepsAgentItemsLocal() async {
        let daemon = Daemon([Self.item("agent", source: "agent")])
        let owner = Owner()
        var prefs = NotificationPreferences()
        prefs.feedMirror.agents = false
        let driver = driver(daemon, owner, prefs: prefs)
        driver.run()
        await driver.drain()
        #expect(owner.calls.isEmpty)
        #expect(daemon.state("agent") == .open)
    }

    @Test func aRefusedAdoptLeavesTheItemHandingOff() async {
        let daemon = Daemon([Self.item("a"), Self.item("b")])
        let owner = Owner()
        owner.refuse = "validation.invalid"
        let driver = driver(daemon, owner)
        driver.run()
        await driver.drain()
        #expect(owner.adopts.count == 2, "an owner refusal of one item does not stop the others")
        #expect(daemon.state("a") == .handingOff)
        #expect(daemon.state("b") == .handingOff)
    }

    // MARK: (c) B5: a refused moved item is read in the cloud

    @Test func refusedMovedItemsAreReadInTheCloudInOneCall() async throws {
        let data = Data(#"""
        {"surface": 3, "cleared": true, "acknowledged": [],
         "refused": [{"item": "feeditem_m1", "code": "owner.unreachable", "retryable": true},
                     {"item": "feeditem_h1", "code": "feed.moving", "retryable": true},
                     {"item": "feeditem_m2", "code": "owner.unreachable", "retryable": true}]}
        """#.utf8)
        let reply = try JSONDecoder().decode(AckTabNotificationsRequest.Response.self, from: data)
        let owner = Owner()
        let driver = driver(Daemon([]), owner)
        driver.acknowledged(reply.refused ?? [])
        await driver.drain()
        #expect(owner.reads == [["feeditem_m1", "feeditem_m2"].map { FeedHandoffDriver.cloudID(install: Self.install, local: $0) }])
        #expect(owner.calls.allSatisfy { $0.op == "feed.read" })
    }

    @Test func movedReadsNeverQueueWhileSignedOut() async {
        let owner = Owner()
        let driver = driver(Daemon([]), owner, signedIn: false)
        driver.acknowledged([.init(item: "feeditem_m1", code: "owner.unreachable")])
        await driver.drain()
        #expect(owner.calls.isEmpty)
    }

    @Test func anAckDuringTheHandoffReadsTheItemOnceItMoved() async {
        let daemon = Daemon([Self.item("feeditem_h1", state: .handingOff)])
        let owner = Owner()
        let driver = driver(daemon, owner)
        driver.acknowledged([.init(item: "feeditem_h1", code: "feed.moving")])
        driver.run()
        await driver.drain()
        #expect(daemon.state("feeditem_h1") == .moved)
        #expect(owner.reads == [[FeedHandoffDriver.cloudID(install: Self.install, local: "feeditem_h1")]])
    }

    // MARK: (d) without feed-local-owner-v1 the step-1 bridge stays

    @Test func withoutTheCapabilityTheDriverIsOffAndTheBridgeStays() async {
        let daemon = Daemon([Self.item("a")])
        daemon.servesCapability = false
        let owner = Owner()
        let driver = driver(daemon, owner)
        #expect(!driver.isActive)
        driver.run()
        await driver.drain()
        #expect(daemon.calls.isEmpty)
        #expect(owner.calls.isEmpty)
        #expect(NotificationCenterService.feedPath(driver: driver) == .bridge)
        #expect(NotificationCenterService.feedPath(driver: nil) == .bridge)
        daemon.servesCapability = true
        #expect(NotificationCenterService.feedPath(driver: driver) == .handoff)
    }

    @Test func theDriverNeedsASignInAndAnInstallCredential() {
        let daemon = Daemon([])
        #expect(driver(daemon, Owner()).isActive)
        #expect(!driver(daemon, Owner(), signedIn: false).isActive)
        #expect(!driver(daemon, Owner(), install: nil).isActive)
    }

    @Test func shippedBuildsKeepTheDriverOffUntilP8Slice3() async {
        #expect(!FeedHandoffDriver.isEnabledByDefault)
        let daemon = Daemon([Self.item("a")])
        let owner = Owner()
        let off = driver(daemon, owner, enabled: false)
        #expect(!off.isActive)
        #expect(NotificationCenterService.feedPath(driver: off) == .bridge)
        off.run()
        await off.drain()
        #expect(daemon.calls.isEmpty)
        #expect(owner.calls.isEmpty)
    }
}

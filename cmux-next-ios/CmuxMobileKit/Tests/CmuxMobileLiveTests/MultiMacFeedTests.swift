import CmuxAgentQuestion
import CmuxMobileAgentChat
import CmuxMobileFeed
import CmuxMobileModel
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

// The coordinator is iOS-only: these run in the iOS simulator test pass.
#if os(iOS)
/// The Feed answers on the Mac whose agent asked (user report 2026-10-21: a
/// Codex "Needs permission" card from the second Mac said "Not connected to
/// your Mac. Nothing was sent." while both Macs read "Connected").
@MainActor
@Suite(.serialized) struct MultiMacFeedTests {
    let host = "svc-\(UUID().uuidString.prefix(8).lowercased()).cmuxMobile.test"
    let userID = "user-\(UUID().uuidString)"
    static let teamKey = "cmuxMobile.live.mac.t-multimac-feed"

    /// What each Mac's acpmux was asked to do, by Mac.
    final class Answers: @unchecked Sendable {
        private let lock = NSLock()
        private var byMac: [String: [String]] = [:]
        func append(_ mac: String, _ line: String) { lock.withLock { byMac[mac, default: []].append(line) } }
        func of(_ mac: String) -> [String] { lock.withLock { byMac[mac] ?? [] } }
    }

    /// Each Mac's acpmux: one Codex session `sess-<mac>` waiting on permission
    /// `perm-<mac>`; a permission answer is recorded under its Mac.
    static func acpmux(_ answers: Answers) -> @Sendable (String, Data) -> [Data] {
        { mac, data in
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = object["method"] as? String else { return [] }
            let id = object["id"].map { "\($0)" } ?? "null"
            func reply(_ result: String) -> Data { Data(#"{"jsonrpc":"2.0","id":\#(id),"result":\#(result)}"#.utf8) }
            switch method {
            case "initialize":
                return [reply(#"{"protocolVersion":1}"#)]
            case "_acpmux/watch":
                return [reply(#"{"sessions":[{"sessionId":"sess-\#(mac)","name":"Codex","harness":"codex","cwd":"/tmp/\#(mac)","status":"waiting","pendingPermissions":1,"lastSeq":3}]}"#)]
            case "_acpmux/events":
                return [reply(#"{"events":[{"sessionId":"sess-\#(mac)","seq":3,"at":3,"dir":"mux","kind":"permission_request","msg":{"permissionId":"perm-\#(mac)","request":{"toolCall":{"toolCallId":"c","title":"git push","kind":"execute"},"options":[{"optionId":"allow","name":"Allow once","kind":"allow_once"},{"optionId":"deny","name":"Deny","kind":"reject_once"}]}}}]}"#)]
            case "_acpmux/permission_respond":
                let params = object["params"] as? [String: Any]
                answers.append(mac, "\(params?["sessionId"] as? String ?? "-") \(params?["permissionId"] as? String ?? "-") \(params?["optionId"] as? String ?? "-")")
                return [reply("{}")]
            default:
                return [reply("{}")]
            }
        }
    }

    func coordinator(store: AppStore, feed: FeedStore, dialer: PerMacDialer) -> LiveCoordinator {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-mobile-multimac-feed-\(UUID().uuidString)")
        let snapshots = LiveSnapshotStore(directory: directory)
        let saved = Date(timeIntervalSince1970: 1_000)
        snapshots.save(LiveSnapshot(
            teamID: "t-multimac-feed", teamName: "One",
            macs: [MacDevice(id: "m1", name: "Aziz's MacBook Pro", isOnline: true),
                   MacDevice(id: "m2", name: "Abdulaziz's MacBook Pro (2)", isOnline: true)],
            linkedMacID: "m1",
            workspaces: ["m1": .init(workspaces: [], savedAt: saved), "m2": .init(workspaces: [], savedAt: saved)]
        ), accountID: userID)
        snapshots.flush()
        return LiveCoordinator(
            store: store,
            api: LiveAPI(baseURL: URL(string: "https://\(host)")!, session: ServiceStub.session()) { _ in "token" },
            identity: DeviceIdentity(link: UUID().uuidString, presence: UUID().uuidString),
            userID: userID, deviceName: "iPhone", transport: .wireGuard, dialer: dialer,
            feedStore: feed, snapshots: snapshots
        )
    }

    func emptyStore() -> AppStore {
        AppStore(teams: [], activeTeamID: "", workspaces: [], feed: [], tabMemory: .inMemory())
    }

    func settle(_ done: () -> Bool) async {
        for _ in 0..<3000 where !done() { try? await Task.sleep(for: .milliseconds(1)) }
    }

    func deny(_ feed: FeedStore, _ id: String) throws {
        let item = try #require(feed.item(id: id))
        guard case .permission(let request) = item.kind else {
            Issue.record("\(id) is not a permission")
            return
        }
        let option = try #require(request.options.first { !$0.isAllow })
        feed.respond(id, option: option)
    }

    /// The Feed keeps a way to answer for as long as the coordinator lives.
    /// Its actions were made and dropped at once (a weak reference), so every
    /// inline answer failed with "Not connected to your Mac. Nothing was sent."
    @Test func theFeedCanAnswerWhileSignedIn() {
        UserDefaults.standard.removeObject(forKey: Self.teamKey)
        defer { UserDefaults.standard.removeObject(forKey: Self.teamKey) }
        let feed = FeedStore(items: [])
        let live = coordinator(store: emptyStore(), feed: feed, dialer: PerMacDialer())
        defer { live.stop() }
        #expect(feed.actions != nil)
    }

    @Test func silentTerminalLedgerHasABoundedRequestAndFeedStillRefreshes() async throws {
        UserDefaults.standard.removeObject(forKey: Self.teamKey)
        defer { UserDefaults.standard.removeObject(forKey: Self.teamKey) }
        let feed = FeedStore(items: [])
        let live = coordinator(store: emptyStore(), feed: feed,
                               dialer: PerMacDialer(acpmux: Self.acpmux(Answers()), silentNotifications: true))
        defer { live.stop() }
        live.showing(macIDs: ["m1"])
        #expect(await live.waitUntil(within: .seconds(3)) { live.sessions["m1"]?.acpmux.isReady == true })
        let session = try #require(live.sessions["m1"])
        session.terminalFeed.requestDeadline = .milliseconds(20)
        let request = try #require(session.terminalFeed.request)
        do {
            _ = try await request("list-notifications", ["limit": 100], session.workspaces.connectionSerial)
            Issue.record("The silent ledger unexpectedly replied")
        } catch let error as LinkError {
            #expect(error.code == DaemonClient.replyTimeout)
        }
        await feed.retry { await live.reconnectFeeds() }
        #expect(feed.refreshError == nil)
        #expect(session.acpmux.isReady)
    }

    @Test func feedRecoverySkipsSleepingMacsAndStartsOnlineMacsTogether() async {
        UserDefaults.standard.removeObject(forKey: Self.teamKey)
        defer { UserDefaults.standard.removeObject(forKey: Self.teamKey) }
        let store = emptyStore()
        let live = coordinator(store: store, feed: FeedStore(items: []), dialer: PerMacDialer())
        defer { live.stop() }
        store.teams[0].macs.append(MacDevice(id: "sleeping", name: "Demo sleeping Mac", isOnline: false))
        let (entered, record) = AsyncStream<String>.makeStream()
        let (release, resume) = AsyncStream<Void>.makeStream()
        var started = Set<String>()
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            record.finish()
            resume.finish()
        }
        defer { deadline.cancel() }
        let work = Task { @MainActor in
            await live.reconnectFeeds { macID in
                started.insert(macID)
                record.yield(macID)
                // Both calls must enter before either can complete.
                if macID == "m1" { for await _ in release { break } }
            }
            record.finish()
        }
        for await _ in entered {
            if started.count == 2 { break }
        }
        #expect(started == ["m1", "m2"])
        resume.yield(())
        resume.finish()
        await work.value
    }

    @Test func retryReopensFailedFeedChannelOnConnectedMac() async throws {
        UserDefaults.standard.removeObject(forKey: Self.teamKey)
        defer { UserDefaults.standard.removeObject(forKey: Self.teamKey) }
        let feed = FeedStore(items: [])
        let store = emptyStore()
        let dialer = PerMacDialer(acpmux: Self.acpmux(Answers()))
        let live = coordinator(store: store, feed: feed, dialer: dialer)
        defer { live.stop() }
        live.showing(macIDs: ["m1"])
        #expect(await live.waitUntil(within: .seconds(3)) { live.sessions["m1"]?.acpmux.isReady == true })
        let session = try #require(live.sessions["m1"])
        let link = try #require(session.currentLink)
        let dials = dialer.dialCount("m1")
        let channel = try await link.openChannel(service: "acpmux", args: [:])
        await session.acpmux.bind(channel)
        #expect(session.acpmux.isReady)
        // End the channel's receive stream while its Mac link stays connected.
        // Do not reset the hub or inject a diagnostic: teardown must do that.
        await channel.close(code: "eof", reason: "remote closed")
        #expect(await live.waitUntil(within: .seconds(3)) { !session.acpmux.isReady })
        #expect(session.acpmux.lastError != nil)
        await feed.refresh()
        #expect(feed.refreshError != nil)

        await feed.retry { await live.reconnectFeed(macID: "m1") }

        #expect(session.currentLink === link)
        #expect(dialer.dialCount("m1") == dials)
        #expect(session.acpmux.isReady)
        #expect(session.chatsError == nil)
        #expect(feed.refreshError == nil)
        #expect(feed.item(id: "ask-perm-m1") != nil)
    }

    /// The user's report: the second Mac's agent asks, the first Mac is the
    /// chosen one, and both are connected. Deny reaches the second Mac only.
    @Test func anAskFromTheOtherMacIsAnsweredOnThatMac() async throws {
        UserDefaults.standard.removeObject(forKey: Self.teamKey)
        defer { UserDefaults.standard.removeObject(forKey: Self.teamKey) }
        let answers = Answers()
        let feed = FeedStore(items: [])
        let store = emptyStore()
        let live = coordinator(store: store, feed: feed, dialer: PerMacDialer(acpmux: Self.acpmux(answers)))
        defer { live.stop() }
        // The Feed shows every Mac.
        live.showing(macIDs: nil)
        await settle { feed.item(id: "ask-perm-m1") != nil && feed.item(id: "ask-perm-m2") != nil }
        #expect(live.focusedMacID == "m1")
        try deny(feed, "ask-perm-m2")
        await settle { !answers.of("m2").isEmpty || feed.item(id: "ask-perm-m2")?.error != nil }
        #expect(feed.item(id: "ask-perm-m2")?.error == nil)
        #expect(feed.item(id: "ask-perm-m2")?.resolution == "Denied")
        #expect(answers.of("m2") == ["sess-m2 perm-m2 deny"])
        #expect(answers.of("m1").isEmpty)
    }

    /// An ask this launch never read from its Mac (its Mac's feed does not own
    /// it): the answer links that Mac, reads its asks again and answers there.
    @Test func anAskNoFeedOwnsIsReadAgainOnItsMac() async throws {
        UserDefaults.standard.removeObject(forKey: Self.teamKey)
        defer { UserDefaults.standard.removeObject(forKey: Self.teamKey) }
        let answers = Answers()
        let feed = FeedStore(items: [])
        let store = emptyStore()
        let dialer = PerMacDialer(acpmux: Self.acpmux(answers))
        let live = coordinator(store: store, feed: feed, dialer: dialer)
        defer { live.stop() }
        live.showing(macIDs: ["m1"])
        await settle { feed.item(id: "ask-perm-m1") != nil }
        #expect(dialer.dialCount("m2") == 0)
        let request = ACPPermissionRequest(
            id: "perm-m2", toolCall: ACPToolCall(id: "c", title: "git push", kind: .execute),
            options: [ACPPermissionOption(id: "allow", name: "Allow once", kind: .allowOnce),
                      ACPPermissionOption(id: "deny", name: "Deny", kind: .rejectOnce)])
        var item = FeedItem(id: "ask-perm-m2", kind: .permission(request), workspaceID: "", tabID: "sess-m2", agentName: "Codex",
                            harness: "codex", workspaceTitle: "m2", markdown: "git push", quote: nil, createdAt: Date())
        item.macID = "m2"
        feed.upsert(item, atTop: true)
        try deny(feed, "ask-perm-m2")
        await settle { !answers.of("m2").isEmpty || feed.item(id: "ask-perm-m2")?.error != nil }
        #expect(feed.item(id: "ask-perm-m2")?.error == nil)
        #expect(answers.of("m2") == ["sess-m2 perm-m2 deny"])
        #expect(dialer.dialCount("m2") == 1)
        #expect(answers.of("m1").isEmpty)
    }

    /// An ask whose Mac's link went idle (nothing showed that Mac for a while)
    /// opens that Mac's link and answers there, instead of failing.
    @Test func anAnswerOpensTheIdleLinkOfItsMac() async throws {
        UserDefaults.standard.removeObject(forKey: Self.teamKey)
        defer { UserDefaults.standard.removeObject(forKey: Self.teamKey) }
        let answers = Answers()
        let feed = FeedStore(items: [])
        let store = emptyStore()
        let dialer = PerMacDialer(acpmux: Self.acpmux(answers))
        let live = coordinator(store: store, feed: feed, dialer: dialer)
        defer { live.stop() }
        live.linkPolicy = MacLinkPolicy(idleAfter: .milliseconds(200))
        live.showing(macIDs: nil)
        await settle { feed.item(id: "ask-perm-m2") != nil }
        // Only the first Mac is on screen now: the second Mac's link closes.
        live.showing(macIDs: ["m1"])
        await settle { store.macConnection["m2"] == nil }
        #expect(store.macConnection["m2"] == nil)
        #expect(dialer.dialCount("m2") == 1)
        try deny(feed, "ask-perm-m2")
        await settle { !answers.of("m2").isEmpty || feed.item(id: "ask-perm-m2")?.error != nil }
        #expect(feed.item(id: "ask-perm-m2")?.error == nil)
        #expect(answers.of("m2") == ["sess-m2 perm-m2 deny"])
        #expect(dialer.dialCount("m2") == 2)
        #expect(answers.of("m1").isEmpty)
    }
}
#endif

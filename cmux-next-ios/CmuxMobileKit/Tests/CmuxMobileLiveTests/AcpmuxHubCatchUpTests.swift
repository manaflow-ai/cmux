import CmuxMobileAgentChat
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive
#if canImport(CmuxMobileLinkFFI)
import CmuxMobileLinkFFI
#endif

/// The one-request catch-up's chat list and chat pages go into the hub by its own paths
/// (`AcpmuxHub+CatchUp.swift`): a list follow changes the rows, a newest-first page shows no
/// hole and pages older records on scroll, a cut chat keeps what it holds, and with the
/// setting off no Mac is asked.
@MainActor
@Suite(.timeLimit(.minutes(2))) struct AcpmuxHubCatchUpTests {
    typealias Chat = ChatOpenSnapshotLiveTests
    typealias Reattach = ReattachCatchUpLiveTests

    static func json(_ text: String) -> JSONValue {
        try! JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    nonisolated static func row(_ id: String, name: String) -> String {
        #"{"sessionId":"\#(id)","name":"\#(name)","harness":"codex","cwd":"/tmp/w","status":"idle"}"#
    }

    /// The attach result for turns `turns`, newest first as the Mac sends a first screenful: it
    /// reads to the log's end (`pageThrough`, a current Mac), so no forward read is needed.
    static func page(turns: Range<Int>, hasMore: Bool) -> String {
        let records = turns.flatMap(Chat.turnRecords).joined(separator: ",")
        return #"{"session":{"sessionId":"s1","status":"idle","pending":[]},"hasMore":\#(hasMore),"lastSeq":\#(turns.upperBound * 5),"pageThrough":\#(turns.upperBound * 5),"events":[\#(records)]}"#
    }

    /// A Mac over turns `0..<total`: an attach after a seq reads to the end, `_acpmux/events`
    /// pages forward (`afterSeq`) or backward (`beforeSeq`, 10 turns at a time).
    nonisolated static func mac(total: Int) -> MockMacLink {
        let log = Reattach.log(turns: total)
        return MockMacLink { _, data in
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = object["method"] as? String else { return [] }
            let id = object["id"].map { "\($0)" } ?? "null"
            let params = object["params"] as? [String: Any]
            let after = (params?["afterSeq"] as? NSNumber)?.intValue ?? 0
            switch method {
            case "initialize": return [Reattach.reply(id, #"{"protocolVersion":1}"#)]
            case "_acpmux/watch": return [Reattach.reply(id, #"{"sessions":[\#(row("s1", name: "Fix"))]}"#)]
            case "_acpmux/attach":
                let records = log[min(after, log.count)...].joined(separator: ",")
                return [Reattach.reply(id, #"{"session":{"sessionId":"s1","status":"idle","pending":[]},"hasMore":false,"lastSeq":\#(log.count),"events":[\#(records)]}"#)]
            case "_acpmux/events":
                if let before = (params?["beforeSeq"] as? NSNumber)?.intValue {
                    let end = max(0, (before - 1) / 5)
                    let start = max(0, end - 10)
                    let records = (start..<end).flatMap(Chat.turnRecords).joined(separator: ",")
                    return [Reattach.reply(id, #"{"hasMore":\#(start > 0),"events":[\#(records)]}"#)]
                }
                let (records, more) = Reattach.page(log, after: after, limit: 50)
                return [Reattach.reply(id, #"{"hasMore":\#(more),"events":[\#(records)]}"#)]
            default:
                return [Reattach.reply(id, "{}")]
            }
        }
    }

    @Test func chatListFollowIsApplied() async {
        let hub = AcpmuxHub()
        await hub.applyCatchUp(chatList: Self.json(#"{"sessions":[\#(Self.row("s1", name: "Fix")),\#(Self.row("s2", name: "Old"))]}"#), pages: [])
        #expect(Set(hub.sessions.keys) == ["s1", "s2"])
        var loaded: [[AcpmuxSession]] = []
        hub.onWatchEvent = { event in
            if case .sessionsLoaded(let rows) = event { loaded.append(rows) }
        }
        let follow = #"{"follow":true,"listEpoch":1,"listSeq":7,"more":false,"gone":[{"sessionId":"s2"}],"sessions":[\#(Self.row("s1", name: "Renamed")),\#(Self.row("s3", name: "New"))]}"#
        let applied = await hub.applyCatchUp(chatList: Self.json(follow), pages: [])
        #expect(applied.isEmpty)
        #expect(Set(hub.sessions.keys) == ["s1", "s3"])
        #expect(hub.sessions["s1"]?.name == "Renamed")
        #expect(loaded.count == 1)
        // The same follow again changes nothing and says nothing.
        await hub.applyCatchUp(chatList: Self.json(follow), pages: [])
        #expect(loaded.count == 1)
    }

    @Test func newestPageShowsNoHoleAndPagesOlderOnScroll() async throws {
        let hub = AcpmuxHub()
        let source = hub.source(sessionID: "s1", summary: Chat.summary)
        let store = AgentChatStore(source: source)
        #expect(hub.catchUpChats().map(\.sessionID) == ["s1"])
        // The wake's reply: the newest screenful (turns 30..39) of 40, older ones on scroll.
        let applied = await hub.applyCatchUp(chatList: nil, pages: [("s1", Self.json(Self.page(turns: 30..<40, hasMore: true)))])
        #expect(applied == ["s1"])
        await Chat.waitUntil { store.turns.count == 10 }
        #expect(store.turns.first?.id == "t30")
        #expect(store.turns.last?.id == "t39")
        #expect(store.gapBeforeTurnID == nil)
        #expect(store.hasEarlierHistory)
        #expect(hub.catchUpChats().first?.lastSeq == 200)
        // The link comes up: the attach reads on from seq 200, and a scroll pages older.
        await hub.bind(try await Self.mac(total: 40).openChannel(service: "acpmux", args: [:]))
        source.loadEarlierHistory()
        await Chat.waitUntil { store.turns.count == 20 }
        #expect(store.turns.first?.id == "t20")
        #expect(store.gapBeforeTurnID == nil)
    }

    @Test func pagePastKeptRecordsFillsTheGap() async throws {
        // The chat holds turns 0..39 from an open; the link drops and the Mac runs to turn 59.
        let first = try await Self.mac(total: 40).openChannel(service: "acpmux", args: [:])
        let hub = AcpmuxHub()
        await hub.bind(first)
        let store = AgentChatStore(source: hub.source(sessionID: "s1", summary: Chat.summary))
        await Chat.waitUntil { store.turns.count == 40 }
        await hub.bind(nil)
        // The wake's page: the newest screenful (55..59), records 201..275 not in it.
        let applied = await hub.applyCatchUp(chatList: nil, pages: [("s1", Self.json(Self.page(turns: 55..<60, hasMore: true)))])
        #expect(applied == ["s1"])
        await hub.bind(try await Self.mac(total: 60).openChannel(service: "acpmux", args: [:]))
        await Chat.waitUntil { store.turns.count == 60 && store.gapBeforeTurnID == nil }
        #expect(store.turns.map(\.id) == (0..<60).map { "t\($0)" })
    }

    @Test func cutChatKeepsItsRecords() async throws {
        let hub = AcpmuxHub()
        await hub.bind(try await Self.mac(total: 40).openChannel(service: "acpmux", args: [:]))
        let store = AgentChatStore(source: hub.source(sessionID: "s1", summary: Chat.summary))
        await Chat.waitUntil { store.turns.count == 40 }
        await hub.bind(nil)
        // A cut chat brings no page: nothing applies, and what the chat holds stays.
        #expect(await hub.applyCatchUp(chatList: nil, pages: []).isEmpty)
        #if canImport(CmuxMobileLinkFFI)
        let named = CatchUpChatPage(sessionId: "s1", pageJson: Self.page(turns: 55..<60, hasMore: true),
                                    throughSeq: 300, hasMore: true, olderBefore: 276)
        let applied = await hub.applyCatchUp(chatListJSON: nil, chats: [named],
                                             cut: [CatchUpCut(name: "chats:s1", reason: "budget")])
        #expect(applied.isEmpty)
        #endif
        #expect(store.turns.count == 40)
        #expect(store.turns.last?.id == "t39")
        #expect(hub.catchUpChats().first?.lastSeq == 200)
    }

    // `MacCatchUps` lives behind `canImport(CmuxMobileLinkFFI)`; plain `swift test` on macOS has no FFI.
    #if canImport(CmuxMobileLinkFFI)
    @Test func settingOffAsksNoMac() {
        let defaults = UserDefaults(suiteName: "AcpmuxHubCatchUpTests.\(UUID().uuidString)")!
        #expect(MacCatchUps.macsToCatchUp(served: ["mac-a", "mac-b"], defaults: defaults).isEmpty)
        defaults.set(true, forKey: MacCatchUps.enabledKey)
        #expect(MacCatchUps.macsToCatchUp(served: ["mac-a", "mac-b", "mac-a"], defaults: defaults) == ["mac-a", "mac-b"])
    }
    #endif
}

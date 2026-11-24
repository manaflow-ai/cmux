import CmuxMobileAgentChat
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

/// A chat open when the link comes up writes its `_acpmux/attach` right behind `initialize` and
/// the first watch page, before either answered (`AcpmuxHub+EarlyAttach.swift`), and opens
/// correctly on every Mac: one that folds `alsoKinds` in, one from before it that serves the sudo
/// card's kinds (its early page is kept; the sudo cards are read after it), and one that
/// serves neither.
@MainActor
@Suite(.timeLimit(.minutes(2))) struct AcpmuxEarlyAttachTests {
    typealias Chat = ChatOpenSnapshotLiveTests

    /// Every request's method and params, in the order the Mac read them.
    final class Wire: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [(String, [String: Any])] = []
        func append(_ method: String, _ params: [String: Any]) { lock.withLock { seen.append((method, params)) } }
        var methods: [String] { lock.withLock { seen.map(\.0) } }
        var attaches: [[String: Any]] { lock.withLock { seen.filter { $0.0 == "_acpmux/attach" }.map(\.1) } }
    }

    /// A Mac's acpmux whose `initialize` lists `capabilities`; `folds` says it takes `alsoKinds`.
    /// `live`: a turn the agent finishes right after the first attach's page, streamed on it.
    nonisolated static func mac(_ wire: Wire, capabilities: [String], live: Bool = false) -> MockMacLink {
        MockMacLink { _, data in
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = object["method"] as? String else { return [] }
            let id = object["id"].map { "\($0)" } ?? "null"
            wire.append(method, object["params"] as? [String: Any] ?? [:])
            func reply(_ result: String) -> Data { Data(#"{"jsonrpc":"2.0","id":\#(id),"result":\#(result)}"#.utf8) }
            switch method {
            case "initialize":
                let caps = capabilities.map { #""\#($0)""# }.joined(separator: ",")
                return [reply(#"{"protocolVersion":1,"_meta":{"acpmux":{"capabilities":[\#(caps)]}}}"#)]
            case "_acpmux/watch":
                return [reply(#"{"sessions":[{"sessionId":"s1","name":"Fix","harness":"codex","cwd":"/tmp/w","status":"idle"}]}"#)]
            case "_acpmux/attach":
                let history = (0..<Chat.turns).flatMap(Chat.turnRecords).joined(separator: ",")
                let page = reply(#"{"session":{"sessionId":"s1","status":"idle","pending":[]},"hasMore":false,"lastSeq":\#(Chat.turns * 5),"events":[\#(history)]}"#)
                // A re-attach from the page's end (an early page that lacked the sudo cards)
                // reads only what came after it: nothing here.
                if let after = (object["params"] as? [String: Any])?["afterSeq"] as? Int, after >= Chat.turns * 5 {
                    return [reply(#"{"session":{"sessionId":"s1","status":"idle","pending":[]},"hasMore":false,"lastSeq":\#(Chat.turns * 5),"events":[]}"#)]
                }
                guard live, wire.attaches.count == 1 else { return [page] }
                let stream = Chat.turnRecords(Chat.turns).map { Data(#"{"jsonrpc":"2.0","method":"_acpmux/event","params":\#($0)}"#.utf8) }
                return [page] + stream
            case "_acpmux/events":
                return [reply(#"{"events":[],"hasMore":false}"#)]
            default:
                return [reply("{}")]
            }
        }
    }

    /// Opens chat s1 cold: the chat is on screen before the link is up, and the pairing passes
    /// only once the Mac read an attach (or after 5 s, which the old order needed: its attach
    /// waited for `initialize`'s answer, held behind the pairing).
    static func coldOpen(capabilities: [String], live: Bool = false, turns: Int = Chat.turns) async throws -> (Wire, AgentChatStore, AcpmuxHub, attachBeforePairing: Bool) {
        let wire = Wire()
        let hub = AcpmuxHub()
        let source = hub.source(sessionID: "s1", summary: Chat.summary)
        let store = AgentChatStore(source: source)
        let channel = try await Self.mac(wire, capabilities: capabilities, live: live).openChannel(service: "acpmux", args: [:])
        let before = SawAttach()
        await hub.bind(channel, until: {
            var end = AwakeDeadline(.seconds(5))
            while !wire.methods.contains("_acpmux/attach"), end.hasTimeLeft() {
                try? await Task.sleep(for: .milliseconds(2)) // test: the pairing passes once the Mac read the attach
            }
            before.saw = wire.methods.contains("_acpmux/attach")
            return true
        })
        await Chat.waitUntil { store.turns.count == turns }
        return (wire, store, hub, before.saw)
    }

    final class SawAttach: @unchecked Sendable { var saw = false }

    static let elevation = AcpmuxSessionSource.elevationCapability
    static let folds = AcpmuxHub.alsoKindsCapability

    /// A new Mac: one attach, written behind `initialize` and the watch, its page the chat's.
    @Test func aNewMacOpensTheChatInTheFirstRoundTrip() async throws {
        let (wire, store, hub, early) = try await Self.coldOpen(capabilities: [Self.elevation, Self.folds])
        defer { withExtendedLifetime(hub) {} }
        #expect(early, "the attach waited for initialize's answer")
        #expect(Array(wire.methods.prefix(3)) == ["initialize", "_acpmux/watch", "_acpmux/attach"])
        #expect(wire.attaches.count == 1)
        #expect((wire.attaches.first?["alsoKinds"] as? [String]) == ["elevation_request", "elevation_decision"])
        #expect((wire.attaches.first?["kinds"] as? [Any])?.count == AcpmuxSessionSource.chatKinds.arrayValue?.count)
        #expect(store.turns.count == Chat.turns)
    }

    /// A Mac from before `alsoKinds` that serves the sudo card: its early page left those kinds
    /// out. The page is kept; the chat attaches again with them from the page's end (it widens
    /// the stream and reads nothing older), and reads only the sudo-card records, not the page.
    @Test func anOlderMacWithSudoCardsKeepsThePageAndReadsOnlyItsCards() async throws {
        let (wire, store, hub, early) = try await Self.coldOpen(capabilities: [Self.elevation])
        defer { withExtendedLifetime(hub) {} }
        #expect(early)
        await Chat.waitUntil { wire.attaches.count == 2 }
        #expect(wire.attaches.count == 2)
        let again = try #require(wire.attaches.last)
        #expect(again["afterSeq"] as? Int == Chat.turns * 5)
        #expect(again["maxBytes"] == nil)
        #expect((again["kinds"] as? [String])?.suffix(2) == ["elevation_request", "elevation_decision"])
        #expect(wire.methods.contains("_acpmux/events"))
        #expect(store.turns.count == Chat.turns)
    }

    /// A turn the agent streams after the early page, before the pairing passed, is shown: the
    /// chat holds it until the page is applied, as it does during any attach.
    @Test func aTurnStreamedBeforeTheLinkIsReadyIsKept() async throws {
        let (wire, store, hub, early) = try await Self.coldOpen(capabilities: [Self.elevation, Self.folds], live: true, turns: Chat.turns + 1)
        defer { withExtendedLifetime(hub) {} }
        #expect(early)
        #expect(wire.attaches.count == 1)
        #expect(store.turns.count == Chat.turns + 1)
    }

    /// A Mac from before both: the early page reads what a later attach would, and is used.
    @Test func anOlderMacWithoutSudoCardsUsesTheEarlyPage() async throws {
        let (wire, store, hub, early) = try await Self.coldOpen(capabilities: [])
        defer { withExtendedLifetime(hub) {} }
        #expect(early)
        #expect(wire.attaches.count == 1)
        #expect(store.turns.count == Chat.turns)
    }

    /// A chat opened after the list is up attaches as before: nothing is written early.
    @Test func aChatOpenedOnceReadyAttachesAsBefore() async throws {
        let wire = Wire()
        let hub = AcpmuxHub()
        await hub.bind(try await Self.mac(wire, capabilities: [Self.elevation, Self.folds]).openChannel(service: "acpmux", args: [:]))
        let store = AgentChatStore(source: hub.source(sessionID: "s1", summary: Chat.summary))
        await Chat.waitUntil { store.turns.count == Chat.turns }
        #expect(wire.attaches.count == 1)
        #expect(wire.attaches.first?["alsoKinds"] == nil)
        #expect((wire.attaches.first?["kinds"] as? [String])?.suffix(2) == ["elevation_request", "elevation_decision"])
        #expect(hub.earlyAttaches.isEmpty)
    }
}

import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The page host's chat tails at the ops the page calls (`chat.tail`, `chat.tail.get`): a chat
/// another tab read opens drawn instead of blank, and the bounds that keep this from becoming
/// somewhere a transcript lives.
@Suite(.serialized)
@MainActor
struct ChatTailCacheTests {
    static let context = PageCallContext(page: PageDescriptor.agent.id)

    /// A page tail of `count` records, as the page's own shape.
    static func tail(_ count: Int, exhausted: Bool = false, mark: String = "a") -> [String: Any] {
        [
            "events": (1...max(1, count)).map { ["seq": $0, "kind": "user_message", "msg": ["text": "\(mark)\($0)"]] },
            "historyExhausted": exhausted,
            "queue": [],
            "configSeq": 0,
            "usageFromSeq": 0,
        ]
    }

    /// What the page host answers the page (`AgentPageProvider.tail`): `ok` and the value, or
    /// `ok: false` for a request it refuses or an op that is not this store's.
    static func bridge(_ method: String, _ params: [String: Any]) -> [String: Any] {
        guard AgentPaneTailCache.handles(method: method), let json = JSONValue(foundation: params) else { return ["ok": false] }
        guard let value = try? AgentPageProvider.tail(method, params: json, op: AgentPageOps.namespace + method)
        else { return ["ok": false] }
        return ["ok": true, "value": value.foundationObject]
    }

    static func value(_ reply: [String: Any]) -> Any? {
        #expect(reply["ok"] as? Bool == true, "the host refused the request: \(reply)")
        return reply["value"]
    }

    /// The records of a tail the host answered, by their `seq`.
    static func seqs(_ answered: Any?) -> [Int] {
        guard let object = answered as? [String: Any], let events = object["events"] as? [[String: Any]] else { return [] }
        return events.compactMap { $0["seq"] as? Int }
    }

    @Test func aChatAnotherTabReadIsHandedBackToANewPage() throws {
        defer { AgentPaneTailCache.shared.clear() }
        AgentPaneTailCache.shared.clear()

        // Nothing read yet: a new tab is told there is no tail and opens from acpmux.
        #expect(Self.value(Self.bridge("chat.tail.get", ["sessionId": "s-1"])) is NSNull)

        // One tab reads the chat and hands its tail over; another asks for it before it attaches.
        _ = Self.value(Self.bridge("chat.tail", ["sessionId": "s-1", "tail": Self.tail(3)]))
        #expect(Self.seqs(Self.value(Self.bridge("chat.tail.get", ["sessionId": "s-1"]))) == [1, 2, 3])
        // Another chat's tail is not this chat's.
        #expect(Self.value(Self.bridge("chat.tail.get", ["sessionId": "s-2"])) is NSNull)

        // The page read on, so what it hands over now replaces what it handed over before.
        _ = Self.value(Self.bridge("chat.tail", ["sessionId": "s-1", "tail": Self.tail(5, mark: "b")]))
        #expect(Self.seqs(Self.value(Self.bridge("chat.tail.get", ["sessionId": "s-1"]))) == [1, 2, 3, 4, 5])

        // A page that no longer stands behind the transcript (its attach failed, the chat was
        // purged) says so, and the next tab opens cold rather than on rows nothing backs.
        _ = Self.value(Self.bridge("chat.tail", ["sessionId": "s-1"]))
        #expect(Self.value(Self.bridge("chat.tail.get", ["sessionId": "s-1"])) is NSNull)
    }

    /// The bound that keeps #23064 from coming back on this side: a tail over the cap is refused
    /// WHOLE. Cutting one and keeping its `historyExhausted` would tell the next page the chat has
    /// no older turns, and the reader could not scroll up to them.
    @Test func aTailOverTheCapIsRefusedWholeAndNeverCut() throws {
        defer { AgentPaneTailCache.shared.clear() }
        AgentPaneTailCache.shared.clear()
        _ = Self.value(Self.bridge("chat.tail", ["sessionId": "s-1", "tail": Self.tail(10, exhausted: true)]))

        let over = Self.tail(AgentPaneTailCache.events + 1, exhausted: true, mark: "c")
        _ = Self.value(Self.bridge("chat.tail", ["sessionId": "s-1", "tail": over]))
        // Not cut to the cap, and not the older tail either: nothing is kept for that chat.
        #expect(Self.value(Self.bridge("chat.tail.get", ["sessionId": "s-1"])) is NSNull)

        // Exactly the cap is kept, whole.
        let full = Self.tail(AgentPaneTailCache.events, mark: "d")
        _ = Self.value(Self.bridge("chat.tail", ["sessionId": "s-2", "tail": full]))
        #expect(Self.seqs(Self.value(Self.bridge("chat.tail.get", ["sessionId": "s-2"]))).count == AgentPaneTailCache.events)

        // A tail with no records is not a tail.
        _ = Self.value(Self.bridge("chat.tail", ["sessionId": "s-3", "tail": ["events": [], "historyExhausted": false]]))
        #expect(Self.value(Self.bridge("chat.tail.get", ["sessionId": "s-3"])) is NSNull)
    }

    /// What is held is bounded, so this cannot become a place every chat of a long day lives.
    @Test func onlyTheMostRecentChatsAreKept() throws {
        defer { AgentPaneTailCache.shared.clear() }
        AgentPaneTailCache.shared.clear()
        for chat in 1...(AgentPaneTailCache.chats + 4) {
            _ = Self.value(Self.bridge("chat.tail", ["sessionId": "s-\(chat)", "tail": Self.tail(2)]))
        }
        // The four oldest are gone; the cap's worth of newest are there.
        for chat in 1...4 {
            #expect(Self.value(Self.bridge("chat.tail.get", ["sessionId": "s-\(chat)"])) is NSNull)
        }
        for chat in 5...(AgentPaneTailCache.chats + 4) {
            #expect(Self.seqs(Self.value(Self.bridge("chat.tail.get", ["sessionId": "s-\(chat)"]))) == [1, 2])
        }
        // Reading a chat again makes it the most recent, so it outlives chats remembered after it.
        _ = Self.value(Self.bridge("chat.tail", ["sessionId": "s-5", "tail": Self.tail(2)]))
        _ = Self.value(Self.bridge("chat.tail", ["sessionId": "s-99", "tail": Self.tail(2)]))
        #expect(Self.seqs(Self.value(Self.bridge("chat.tail.get", ["sessionId": "s-5"]))) == [1, 2])
    }

    /// Signing out drops them with the rest of the session's state (CloudService.signOut), which
    /// is the whole of forgetting them, because none of it is on disk.
    @Test func signingOutForgetsEveryTail() throws {
        defer { AgentPaneTailCache.shared.clear() }
        AgentPaneTailCache.shared.clear()
        _ = Self.value(Self.bridge("chat.tail", ["sessionId": "s-1", "tail": Self.tail(3)]))
        _ = Self.value(Self.bridge("chat.tail", ["sessionId": "s-2", "tail": Self.tail(3)]))
        AgentPaneTailCache.shared.clear()
        #expect(Self.value(Self.bridge("chat.tail.get", ["sessionId": "s-1"])) is NSNull)
        #expect(Self.value(Self.bridge("chat.tail.get", ["sessionId": "s-2"])) is NSNull)
    }

    /// Every page reads and writes the one store: written through the op's answer, read through the
    /// provider's call, and the other way.
    @Test func everyPageSharesTheOneStore() async throws {
        defer { AgentPaneTailCache.shared.clear() }
        AgentPaneTailCache.shared.clear()
        let provider = AgentPageProvider(mainWork: AgentPaneMainThread.standalone().mainWork) { _ in nil }

        _ = Self.value(Self.bridge("chat.tail", ["sessionId": "s-1", "tail": Self.tail(3)]))
        let onPageHost = try await provider.call(
            AgentPageOps.namespace + "chat.tail.get", params: .object(["sessionId": .string("s-1")]), context: Self.context)
        guard case .object(let fields) = onPageHost, case .array(let events)? = fields["events"] else {
            Issue.record("the provider answered no tail for a chat another page kept: \(onPageHost)")
            return
        }
        #expect(events.count == 3)

        _ = try await provider.call(
            AgentPageOps.namespace + "chat.tail",
            params: .object(["sessionId": .string("s-2"), "tail": JSONValue(foundation: Self.tail(4))!]),
            context: Self.context)
        #expect(Self.seqs(Self.value(Self.bridge("chat.tail.get", ["sessionId": "s-2"]))).count == 4)
    }

    /// The page host branches on ``AgentPaneTailCache/handles(method:)``, and it names its two ops
    /// rather than matching the `chat.tail` prefix. The op takes anything that is not `.get` as a
    /// write, so a later `chat.tail.forget` matched by prefix would have ERASED the chat's tail
    /// instead of being refused. The same reason `AgentPaneScrollAnchors` names its ops, one line
    /// above this branch in `AgentPageProvider`.
    @Test func onlyTheTwoOpsThisStoreServesAreTakenAsItsOwn() throws {
        #expect(AgentPaneTailCache.handles(method: "chat.tail"))
        #expect(AgentPaneTailCache.handles(method: "chat.tail.get"))
        #expect(!AgentPaneTailCache.handles(method: "chat.tail.forget"))
        #expect(!AgentPaneTailCache.handles(method: "chat.tail.anything"))
        #expect(!AgentPaneTailCache.handles(method: "chat.tailgate"))
        #expect(!AgentPaneTailCache.handles(method: "chat.scrollAnchor"))
    }

    @Test func aRequestWithoutAChatIsRefused() throws {
        defer { AgentPaneTailCache.shared.clear() }
        #expect(Self.bridge("chat.tail.get", [:])["ok"] as? Bool == false)
        #expect(Self.bridge("chat.tail", ["sessionId": ""])["ok"] as? Bool == false)
        #expect(Self.bridge("chat.tail.forget", ["sessionId": "s-1"])["ok"] as? Bool == false)
    }

    /// A tail too large to keep is refused whole, so this never becomes megabytes of a person's
    /// text held per chat. The page bounds what it hands over, but the bound has to hold here too:
    /// a page that bounds wrongly, or not at all, is the case this is for.
    ///
    /// The bytes are in the `queue` rather than the records, which is the hole this closes: a
    /// queued prompt carries its whole text, and no record count bounds it.
    @Test func aTailTooLargeToKeepIsRefusedAndDropsWhatWasKept() throws {
        defer { AgentPaneTailCache.shared.clear() }
        _ = Self.bridge("chat.tail", ["sessionId": "s-9", "tail": Self.tail(3)])
        #expect(Self.seqs(Self.value(Self.bridge("chat.tail.get", ["sessionId": "s-9"]))).count == 3)

        var huge = Self.tail(2)
        huge["queue"] = [["id": "q-1", "prompt": String(repeating: "p", count: AgentPaneTailCache.bytes + 1)]]
        #expect(Self.bridge("chat.tail", ["sessionId": "s-9", "tail": huge])["ok"] as? Bool == true,
                "the host refuses the tail, not the request")
        // Refused, and the older tail is gone: the page has read on, so what it kept is stale.
        #expect(Self.value(Self.bridge("chat.tail.get", ["sessionId": "s-9"])) is NSNull)
    }
}

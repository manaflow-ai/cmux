@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import Foundation
import Testing

/// ``ChromiumPageHostBridge`` on the page channel. Each post carries the URL of the document that
/// sent it (the relay's stamp); the bridge judges a post only while that document is the committed one, and the
/// handlers of the page's messages start in post order.
@MainActor
struct ChromiumPageHostChannelTests {
    private static let pageA = URL(string: "cmux-page://test.plain/index.html")!
    private static let pageB = URL(string: "cmux-page://other.page/index.html")!
    private static let descriptorA = PageDescriptor(id: "test.plain", resource: "plain", processGroup: .solo, namespaces: [])

    /// A page channel post of the committed document needs no sender probe: the call costs no DevTools round trip,
    /// and its reply goes into the main frame for that document.
    @Test func aPageChannelCallNeedsNoSenderProbe() async throws {
        let page = FakeChromiumPage()
        let bridge = ChromiumPageHostBridge(page: page)
        var received: PageHostMessage?
        bridge.install { message in
            received = message
            return ["ok": true]
        }
        #expect(bridge.documentCommitted(Self.pageA).isEmpty)
        let resolve = ChromiumPageHostWire.resolveExpression(seq: 3, reply: ["ok": true], document: "d1")
        let answered: Bool? = await PageTestWait.value("reply") { done in
            page.onCall = { if page.calls.contains(where: { ($0.params["expression"] as? String)?.contains(resolve) == true }) { done(true) } }
            bridge.receive(pageHostPost: Self.text(["name": "cmuxPage", "seq": 3, "doc": "d1", "body": ["op": "draft"]]), sender: Self.pageA)
        }
        #expect(answered == true)
        let message = try #require(received)
        #expect(message.frameURL == Self.pageA && message.isMainFrame)
        #expect(page.calls.count == 1, "only the reply went to the page: \(page.calls.map(\.method))")
        #expect(page.calls.first?.params["contextId"] == nil, "the reply goes to the main frame")
    }

    /// The posts of one task arrive as one array: every handler starts in post order. A fire-and-forget message
    /// before the first call runs in the post's own turn; the messages after a call wait for it to start.
    @Test func aBatchedPostStartsEveryHandlerInPostOrder() async throws {
        let page = FakeChromiumPage()
        let bridge = ChromiumPageHostBridge(page: page, fireAndForget: ["cmuxPagePainted"])
        _ = bridge.documentCommitted(Self.pageA)
        var log: [String] = []
        bridge.onMessage = { name, body in log.append("\(name) \(body)") }
        bridge.install { message in
            log.append((message.body as? [String: Any])?["op"] as? String ?? "?")
            return nil
        }
        let batch = "[" + [Self.text(["name": "cmuxPagePainted", "body": 1]),
                           Self.text(["name": "cmuxPage", "seq": 1, "body": ["op": "a"]]),
                           Self.text(["name": "cmuxPagePainted", "body": 2]),
                           Self.text(["name": "cmuxPage", "seq": 2, "body": ["op": "b"]])].joined(separator: ",") + "]"
        bridge.receive(pageHostPost: batch, sender: Self.pageA)
        #expect(log == ["cmuxPagePainted 1"], "only the head fire-and-forget message runs in the post's turn")
        let both: Bool? = await PageTestWait.value("calls") { done in
            page.onCall = { if bridge.answered == 2 { done(true) } }
        }
        #expect(both == true)
        #expect(log == ["cmuxPagePainted 1", "a", "cmuxPagePainted 2", "b"])
    }

    /// A batch of [call, fire-and-forget, call] (a composer draft write, a report, a send): the call's handler starts
    /// before the message after it, the second call starts after both, and a call whose handler suspends holds back
    /// no other: the second one answers first.
    @Test func aCallStartsBeforeTheMessagesAfterItAndRunsBesideThem() async throws {
        let page = FakeChromiumPage()
        let bridge = ChromiumPageHostBridge(page: page, fireAndForget: ["cmuxPagePainted"])
        _ = bridge.documentCommitted(Self.pageA)
        var log: [String] = []
        var release: CheckedContinuation<Void, Never>?
        bridge.onMessage = { name, _ in log.append(name) }
        bridge.install { message in
            let op = (message.body as? [String: Any])?["op"] as? String ?? "?"
            log.append("start " + op)
            if op == "draft" { await withCheckedContinuation { release = $0 } } else { await Task.yield() }
            log.append("end " + op)
            return nil
        }
        let batch = "[" + [Self.text(["name": "cmuxPage", "seq": 1, "body": ["op": "draft"]]),
                           Self.text(["name": "cmuxPagePainted", "body": 1]),
                           Self.text(["name": "cmuxPage", "seq": 2, "body": ["op": "send"]])].joined(separator: ",") + "]"
        bridge.receive(pageHostPost: batch, sender: Self.pageA)
        #expect(log.isEmpty, "a handler started before the call before it")
        let sent: Bool? = await PageTestWait.value("send") { done in
            page.onCall = { if bridge.answered == 1 { done(true) } }
        }
        #expect(sent == true)
        #expect(log == ["start draft", "cmuxPagePainted", "start send", "end send"])
        let drafted: Bool? = await PageTestWait.value("draft") { done in
            page.onCall = { if bridge.answered == 2 { done(true) } }
            release?.resume()
        }
        #expect(drafted == true)
        #expect(log.last == "end draft")
    }

    /// A post before its cmux page's commit is heard (the commit's event and the post come on different pipes) waits
    /// for that commit, past the initial `about:blank` one. The commit hands the held posts back, and they are
    /// delivered only at ``ChromiumPageHostBridge/replay(_:)`` (after the view reset for the new document), in
    /// order, with no sender probe; a later commit hands back nothing.
    @Test func aPostBeforeTheCommitWaitsForIt() {
        let page = FakeChromiumPage()
        let bridge = ChromiumPageHostBridge(page: page, fireAndForget: ["cmuxPagePainted"])
        var heard: [String] = []
        bridge.onMessage = { name, body in heard.append("\(name) \(body)") }
        bridge.receive(pageHostPost: Self.text(["name": "cmuxPagePainted", "body": 1]), sender: Self.pageA)
        #expect(bridge.documentCommitted(URL(string: "about:blank")).isEmpty)
        bridge.receive(pageHostPost: Self.text(["name": "cmuxPagePainted", "body": 2]), sender: Self.pageA)
        #expect(heard.isEmpty, "a post was judged before its document's commit")
        let held = bridge.documentCommitted(Self.pageA)
        #expect(heard.isEmpty, "a held post was delivered before the view took the commit")
        bridge.replay(held)
        #expect(heard == ["cmuxPagePainted 1", "cmuxPagePainted 2"])
        #expect(bridge.documentCommitted(Self.pageA).isEmpty)
        #expect(heard.count == 2)
        #expect(page.calls.isEmpty, "a DevTools call: \(page.calls.map(\.method))")
    }

    /// While page A is committed, a post of page B (sent before B's commit is heard, or still in flight after the
    /// page host sent B away and A came back) is not judged as A: it waits, and B's own commit judges it as B, which
    /// A's trust does not cover; a cmux page's commit drops the held posts of every other document.
    @Test func aPostOfAnotherDocumentIsNeverJudgedAsTheCommittedOne() async throws {
        let page = FakeChromiumPage()
        let bridge = ChromiumPageHostBridge(page: page, fireAndForget: ["cmuxPagePainted"])
        var heard = 0
        bridge.onMessage = { _, _ in heard += 1 }
        var received: [PageHostMessage] = []
        bridge.install { message in
            received.append(message)
            return nil
        }
        _ = bridge.documentCommitted(Self.pageA)
        bridge.receive(pageHostPost: Self.text(["name": "cmuxPagePainted", "body": 1]), sender: Self.pageB)
        bridge.receive(pageHostPost: Self.text(["name": "cmuxPage", "seq": 1, "body": [:]]), sender: Self.pageB)
        #expect(heard == 0, "page B's post was judged while page A is committed")
        let held = bridge.documentCommitted(Self.pageB)
        #expect(held.count == 2)
        let answered: Bool? = await PageTestWait.value("B's call") { done in
            page.onCall = { if bridge.answered == 1 { done(true) } }
            bridge.replay(held)
        }
        #expect(answered == true && heard == 1)
        let message = try #require(received.first)
        #expect(message.frameURL == Self.pageB, "the message is B's own")
        #expect(!PageHostTrust.isTrusted(message, page: Self.descriptorA))
        // The page host sends B away and A comes back: B's late posts never reach A's handlers.
        _ = bridge.documentCommitted(Self.pageA)
        bridge.receive(pageHostPost: Self.text(["name": "cmuxPagePainted", "body": 2]), sender: Self.pageB)
        #expect(bridge.documentCommitted(Self.pageA).isEmpty, "a gone document's post was handed back")
        #expect(heard == 1)
    }

    /// The page's own `pushState` or fragment change keeps its document: its posts are judged by their own URL.
    @Test func aPostAfterTheDocumentChangedItsOwnURLIsItsOwn() throws {
        let page = FakeChromiumPage()
        let bridge = ChromiumPageHostBridge(page: page, fireAndForget: ["cmuxPagePainted"])
        var heard = 0
        bridge.onMessage = { _, _ in heard += 1 }
        _ = bridge.documentCommitted(Self.pageA)
        let moved = try #require(URL(string: "cmux-page://TEST.plain/settings?tab=1#/keys"))
        bridge.receive(pageHostPost: Self.text(["name": "cmuxPagePainted", "body": 1]), sender: moved)
        #expect(heard == 1)
        #expect(PageHostTrust.isTrusted(PageHostMessage(frameURL: moved, isMainFrame: true, body: 1), page: Self.descriptorA))
    }

    /// One bad message refuses the whole post.
    @Test func aPostWithABadMessageIsRefusedWhole() {
        let page = FakeChromiumPage()
        let bridge = ChromiumPageHostBridge(page: page, fireAndForget: ["cmuxPagePainted"])
        _ = bridge.documentCommitted(Self.pageA)
        var heard = 0
        bridge.onMessage = { _, _ in heard += 1 }
        bridge.receive(pageHostPost: "[" + Self.text(["name": "cmuxPagePainted", "body": 1]) + #",{"name":"cmuxPage","seq":0,"body":1}]"#,
                       sender: Self.pageA)
        bridge.receive(pageHostPost: "[]", sender: Self.pageA)
        #expect(heard == 0)
        #expect(page.calls.isEmpty)
    }

    private static func text(_ object: [String: Any]) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(), as: UTF8.self)
    }
}

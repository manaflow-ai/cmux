@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import Foundation
import Testing

/// NIGHTLY 2026-10-29: every raw DevTools event of a Chromium-hosted page reached the page's main
/// actor, which scanned it whole three times (`String.contains` for the binding name and for two
/// document events) and parsed each binding call and its payload there. Now the method and binding
/// name come from the message's bytes, and a binding call is parsed off the main actor.
@MainActor
struct ChromiumPageHostBridgeCostTests {
    /// The main-actor time a burst of a page's ordinary events may cost the page.
    static let eventsBudget: Duration = .milliseconds(10)
    /// The main-actor time one large page post may cost before it is parsed.
    static let largePostBudget: Duration = .milliseconds(5)

    @Test func aPagesOrdinaryEventsCostItsMainActorAlmostNothing() {
        let page = FakeChromiumPage()
        let bridge = ChromiumPageHostBridge(page: page)
        let preview = String(repeating: "abcdefghij", count: 3_200)
        let console = #"{"method":"Runtime.consoleAPICalled","params":{"args":[{"type":"string","value":"\#(preview)"}],"executionContextId":3,"type":"log"}}"#
        let reply = #"{"id":1073741901,"result":{"result":{"type":"string","value":"\#(preview)"}}}"#
        let events = Array(repeating: [console, reply], count: 20).flatMap { $0 }

        var documentEvents = 0
        let elapsed = ContinuousClock().measure {
            for json in events {
                // PageWebView.chromiumEvent's order: the bridge, then the document events.
                if !bridge.receive(devToolsMessage: json), ChromiumPageHostWire.documentEvent(json) != nil { documentEvents += 1 }
            }
        }

        #expect(documentEvents == 0)
        #expect(page.calls.isEmpty)
        #expect(elapsed < Self.eventsBudget, "\(events.count) events took \(elapsed) on the main actor (budget \(Self.eventsBudget))")
    }

    @Test func aLargePostIsParsedOffTheMainActorAndStillAnswered() async {
        let page = FakeChromiumPage()
        let bridge = ChromiumPageHostBridge(page: page)
        var received: PageHostMessage?
        bridge.install { message in
            received = message
            return nil
        }
        let rows = (0..<20_000).map { ["id": $0, "text": "row \($0) of a long transcript"] as [String: Any] }
        let post = Self.chromiumBindingCall(["name": "cmuxPage", "seq": 1, "body": ["op": "rows", "rows": rows]])

        var taken = false
        var elapsed: Duration = .zero
        let answered: Bool? = await PageTestWait.value("answer") { done in
            page.onCall = { if received != nil { done(true) } }
            elapsed = ContinuousClock().measure { taken = bridge.receive(devToolsMessage: post) }
        }

        #expect(taken)
        #expect(answered == true)
        #expect(((received?.body as? [String: Any])?["rows"] as? [Any])?.count == rows.count)
        #expect(elapsed < Self.largePostBudget, "a \(post.utf8.count / 1024) KiB post took \(elapsed) on the main actor (budget \(Self.largePostBudget))")
    }

    /// A binding call as Chromium writes it: `method` first, then `params`.
    static func chromiumBindingCall(_ payload: [String: Any], context: Int = 9) -> String {
        let text = String(decoding: try! JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        let params: [String: Any] = ["name": ChromiumPageHostBridge.bindingName, "payload": text, "executionContextId": context]
        return #"{"method":"Runtime.bindingCalled","params":"# + String(decoding: try! JSONSerialization.data(withJSONObject: params), as: UTF8.self) + "}"
    }
}

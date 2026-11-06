import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextPages

/// A page posts any JSON number as an envelope id or subscription id (`Infinity` or `1e30` are
/// valid script values). `UInt64(_:)` traps on those, which aborted the whole app.
@MainActor
struct PageRouterWireIdTests {
    private func router() -> PageRouter {
        PageRouter(descriptor: PageDescriptor(id: "cmux.test", resource: "test", namespaces: []), routes: [])
    }

    @Test(arguments: [Double.infinity, -Double.infinity, Double.nan, 1e30, 18_446_744_073_709_551_616.0, -1, 0, 7])
    func cancelAndUnsubWithAnyNumberAnswerNothingAndDoNotTrap(value: Double) async {
        let page = router()
        let cancel = await page.handle(["t": "cancel", "id": .number(value)])
        #expect(cancel == .null)
        let unsubscribe = await page.handle(["t": "unsub", "sub": .number(value)])
        #expect(unsubscribe == .null)
    }

    @Test(arguments: [1e30, 9_007_199_254_740_992.0, 1.5, 0, -1, Double.infinity, Double.nan])
    func aCallOrSubWithAnInvalidIdIsRefusedAsABadMessageAndNeverRuns(value: Double) async {
        let page = router()
        for envelope: JSONValue in [
            ["t": "call", "id": .number(value), "op": "cmux.nothing.here", "params": [:]],
            ["t": "sub", "id": .number(value), "stream": "cmux.nothing.here"],
        ] {
            let reply = await page.handle(envelope)
            #expect(reply["t"]?.stringValue == "err")
            #expect(reply["code"]?.stringValue == "cmux.protocol.bad_message")
        }
    }

    @Test func aWholeIdUpToTheJsonSafeLimitIsAnId() {
        #expect(PageRouter.wireID(1) == 1)
        #expect(PageRouter.wireID(9_007_199_254_740_991) == 9_007_199_254_740_991)
        #expect(PageRouter.wireID(0) == nil)
        #expect(PageRouter.wireID(2.5) == nil)
    }
}

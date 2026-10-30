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

    @Test func aCallWithAHugeIdIsRefusedWithoutTrapping() async {
        let page = router()
        let reply = await page.handle(["t": "call", "id": .number(1e30), "op": "cmux.nothing.here", "params": [:]])
        #expect(reply["t"]?.stringValue == "err")
    }
}

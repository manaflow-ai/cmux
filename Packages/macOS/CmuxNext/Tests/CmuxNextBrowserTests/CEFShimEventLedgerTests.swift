@testable import CmuxNextBrowser
import Testing

/// The app's main thread at idle (cmux20-bench, 2026-11-25, step a68e49e3): 0.58 wakes/s were Chromium's I/O thread
/// asking the main thread for work, and a trace named the messages it forwarded: DevTools protocol messages from a
/// renderer (`blink.mojom.DevToolsSessionHost`, 0.9/s). Bench builds put each shim event the main thread takes in the
/// wake ledger by kind, a DevTools message by its method, so `debug.wakeups` names what a page's session sends.
@Suite struct CEFShimEventLedgerTests {
    @Test func aDevToolsEventIsNamedByItsMethod() {
        let event = CEFShimEvent(kind: 32, browser: 3, request: 0, a: 0, b: 0,
                                 s1: #"{"method":"Page.frameStoppedLoading","params":{}}"#, s2: "")
        #expect(event.ledgerReason == "devTools Page.frameStoppedLoading")
    }

    @Test func aDevToolsReplyIsNamedAsOne() {
        let event = CEFShimEvent(kind: 32, browser: 3, request: 0, a: 0, b: 0, s1: #"{"id":1073741825,"result":{}}"#, s2: "")
        #expect(event.ledgerReason == "devTools reply")
    }

    /// cmux20-bench, 2026-11-25 (step bf7a2a1f): 0.24 binding calls/s and 0.38 DevTools results/s at idle, with no
    /// page timer of its own in sight. A page host call names its op (pageClient.ts's `{t: "call", op}`, JSON in the
    /// binding's string payload), so the ledger says which page op it was.
    @Test func aPageHostBindingCallIsNamedByItsOp() {
        let json = #"{"method":"Runtime.bindingCalled","params":{"name":"__cmuxPageHost","payload":"{\"name\":\"cmuxPage\",\"body\":{\"t\":\"call\",\"id\":7,\"op\":\"cmux.page.heartbeat\",\"params\":{\"handled\":0}}}","executionContextId":3}}"#
        let event = CEFShimEvent(kind: 32, browser: 3, request: 0, a: 0, b: 0, s1: json, s2: "")
        #expect(event.ledgerReason == "devTools Runtime.bindingCalled __cmuxPageHost cmux.page.heartbeat")
    }

    @Test func aBindingCallWithNoOpIsNamedByItsBinding() {
        let json = #"{"method":"Runtime.bindingCalled","params":{"name":"cmuxMedia","payload":"{}","executionContextId":3}}"#
        let event = CEFShimEvent(kind: 32, browser: 3, request: 0, a: 0, b: 0, s1: json, s2: "")
        #expect(event.ledgerReason == "devTools Runtime.bindingCalled cmuxMedia")
    }

    /// The same step: 0.38 DevTools results/s at idle are replies to calls the app sends itself. Bench builds record
    /// each call at the send, by method, and a `Runtime.evaluate` by the name its expression starts with (a page push
    /// is `__cmuxPageHostResolve(...)`, a script batch a function name).
    @Test func aDevToolsCallIsNamedByItsMethod() {
        #expect(CEFDevToolsLedger.reason(method: "Page.getFrameTree", encodedParams: "{}") == "devTools call Page.getFrameTree")
    }

    @Test func anEvaluateCallIsNamedByTheStartOfItsExpression() {
        let params = #"{"expression":"__cmuxPageHostResolve(12, {\"ok\":true})","contextId":3,"silent":true}"#
        #expect(CEFDevToolsLedger.reason(method: "Runtime.evaluate", encodedParams: params)
            == "devTools call Runtime.evaluate __cmuxPageHostResolve")
        let long = #"{"expression":"globalThis.__cmuxInputReadyResend?.();"}"#
        #expect(CEFDevToolsLedger.reason(method: "Runtime.evaluate", encodedParams: long)
            == "devTools call Runtime.evaluate globalThis.__cmuxInputReadyResend")
        #expect(CEFDevToolsLedger.reason(method: "Runtime.evaluate", encodedParams: "{}") == "devTools call Runtime.evaluate")
    }

    @Test func otherEventsAreNamedByTheirCase() {
        let event = CEFShimEvent(kind: 52, browser: 3, request: 9, a: 1, b: 0, s1: "example.com", s2: "r")
        #expect(event.ledgerReason == "authPrompt")
        #expect(CEFShimEvent(kind: 9999, browser: 0, request: 0, a: 0, b: 0, s1: "", s2: "").ledgerReason == "unknown 9999")
    }
}

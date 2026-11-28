import Foundation
import CmuxNextSettings
import Testing
@testable import CmuxNextPages

@MainActor
struct PageScriptPipelineTests {
    private actor RenderGate {
        var started = false
        var startedWaiter: CheckedContinuation<Void, Never>?
        var releaseWaiter: CheckedContinuation<Void, Never>?

        func waitUntilStarted() async {
            if started { return }
            await withCheckedContinuation { startedWaiter = $0 }
        }

        func wait() async {
            started = true
            startedWaiter?.resume()
            startedWaiter = nil
            await withCheckedContinuation { releaseWaiter = $0 }
        }

        func release() {
            releaseWaiter?.resume()
            releaseWaiter = nil
        }
    }

    @Test func resetDropsInFlightBeforeLaterQueuedEnvelope() async {
        let gate = RenderGate()
        var drops: [String] = []
        let pipeline = PageScriptPipeline(evaluate: { _ in }, render: { envelope in
            await gate.wait()
            return PageRouter.receiveText(envelope)
        })
        let large = JSONValue.string(String(repeating: "x", count: 20_000))
        pipeline.send(large) { drops.append("first") }
        await gate.waitUntilStarted()
        pipeline.send(.string("later")) { drops.append("second") }

        pipeline.reset()
        #expect(drops == ["first", "second"])
        await gate.release()
    }

    @Test func resetOpensAnInFlightGate() async {
        let pipeline = PageScriptPipeline(evaluate: { _ in })
        pipeline.send(JSONValue.string(String(repeating: "x", count: 20_000)))
        let gate = pipeline.gate(always: true)
        let reached = await Task { await gate?.reached(); return true }.value
        #expect(reached)
        let opened = Task { await gate?.opened(); return true }
        pipeline.reset()
        #expect(await opened.value)
    }

    /// RFD 0062: the pipeline hands each envelope on as its JSON text, the argument of the one
    /// fixed ``PageRouter/receiveBody``, never as a new script text.
    @Test func deliversTheEnvelopeAsJSONText() throws {
        var delivered: [String] = []
        let pipeline = PageScriptPipeline(evaluate: { delivered.append($0) })
        let envelope: JSONValue = ["t": "ev", "id": 3, "data": "a\u{2028}\"b\n"]
        pipeline.send(envelope)
        #expect(delivered == [PageRouter.receiveText(envelope)])
        let parsed = try #require(try JSONSerialization.jsonObject(with: Data(delivered[0].utf8)) as? [String: Any])
        #expect(parsed["data"] as? String == "a\u{2028}\"b\n")
        #expect(PageRouter.receiveScript(envelope) == PageRouter.receiveScript(text: delivered[0]))
        #expect(PageRouter.receiveBody.contains("JSON.parse(envelope)"))
    }

    private final class ScriptBridge: PageHostBridge {
        let engine = PageHostEngine.webKit
        var scripts: [String] = []
        func install(_ handler: @escaping PageHostHandler) {}
        func evaluate(_ script: String) { scripts.append(script) }
        func uninstall() {}
    }

    /// An engine with no argument call (Chromium) runs the same body with the text inlined.
    @Test func defaultArgumentCallInlinesTheText() {
        let bridge = ScriptBridge()
        bridge.evaluate("f(JSON.parse(batch));", argument: "batch", text: "{\"a\":\"\\\"\"}")
        #expect(bridge.scripts == [#"((batch) => { f(JSON.parse(batch)); })("{\"a\":\"\\\"\"}");"#])
        bridge.receive("{\"t\":\"ev\"}")
        #expect(bridge.scripts.last == #"window.__cmuxPageReceive && window.__cmuxPageReceive({"t":"ev"});"#)
    }
}

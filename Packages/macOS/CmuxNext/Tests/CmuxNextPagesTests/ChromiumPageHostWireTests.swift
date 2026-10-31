@testable import CmuxNextPages
import Foundation
import Testing

/// The DevTools messages the Chromium page host reads and writes (``ChromiumPageHostWire``).
struct ChromiumPageHostWireTests {
    @Test func aBindingCallCarriesItsNamePayloadAndContext() throws {
        let event = #"{"method":"Runtime.bindingCalled","params":{"name":"__cmuxPageHost","payload":"{\"name\":\"cmuxPage\",\"seq\":3,\"body\":{\"op\":\"x\"}}","executionContextId":7}}"#
        let call = try #require(ChromiumPageHostWire.BindingCall(event: event))
        #expect(call.name == ChromiumPageHostBridge.bindingName)
        #expect(call.contextID == 7)
        let message = try #require(ChromiumPageHostWire.Message(payload: call.payload))
        #expect(message.name == PageHostTrust.handlerName)
        #expect(message.seq == 3)
        #expect((message.body as? [String: Any])?["op"] as? String == "x")
    }

    @Test func otherMessagesAreNotBindingCalls() {
        #expect(ChromiumPageHostWire.BindingCall(event: #"{"method":"Page.loadEventFired","params":{}}"#) == nil)
        #expect(ChromiumPageHostWire.BindingCall(event: "not json") == nil)
        #expect(ChromiumPageHostWire.Message(payload: #"{"name":"cmuxPage","seq":0,"body":1}"#) == nil)
        #expect(ChromiumPageHostWire.Message(payload: #"{"seq":1,"body":1}"#) == nil)
    }

    @Test func theSenderIsReadFromItsOwnContext() throws {
        let sender = try #require(ChromiumPageHostWire.Sender(
            evaluation: #"{"result":{"type":"object","value":["cmux-page://test.plain/index.html",true]}}"#))
        #expect(sender == ChromiumPageHostWire.Sender(url: URL(string: "cmux-page://test.plain/index.html"), isTop: true))
        #expect(ChromiumPageHostWire.Sender(evaluation: #"{"result":{"value":["x",true]},"exceptionDetails":{}}"#) == nil)
    }

    @Test func aReplyResolvesThePagePromiseWithJSON() {
        #expect(ChromiumPageHostWire.resolveExpression(seq: 4, reply: ["ok": true])
            == "globalThis.__cmuxPageHostResolve?.(4, {\"ok\":true});")
        #expect(ChromiumPageHostWire.resolveExpression(seq: 5, reply: nil) == "globalThis.__cmuxPageHostResolve?.(5, null);")
        #expect(ChromiumPageHostWire.resolveExpression(seq: 6, reply: Date()).contains("native.invalid_reply"))
    }

    @Test func mainFrameNavigationAndLoadAreDocumentEvents() {
        let main = ##"{"method":"Page.frameNavigated","params":{"frame":{"id":"A","url":"cmux-page://test.plain/","urlFragment":"#/x"}}}"##
        #expect(ChromiumPageHostWire.documentEvent(main) == .committed(URL(string: "cmux-page://test.plain/#/x")))
        let child = #"{"method":"Page.frameNavigated","params":{"frame":{"id":"B","parentId":"A","url":"about:blank"}}}"#
        #expect(ChromiumPageHostWire.documentEvent(child) == nil)
        #expect(ChromiumPageHostWire.documentEvent(#"{"method":"Page.loadEventFired","params":{"timestamp":1}}"#) == .finished)
        #expect(ChromiumPageHostWire.documentEvent(#"{"id":1073741825,"result":{"method":"Page.loadEventFired"}}"#) == nil)
    }

    @Test func onlyABooleanTrueEvaluationIsTrue() {
        #expect(ChromiumPageHostWire.evaluationIsTrue(#"{"result":{"type":"boolean","value":true}}"#))
        #expect(!ChromiumPageHostWire.evaluationIsTrue(#"{"result":{"type":"boolean","value":false}}"#))
        #expect(!ChromiumPageHostWire.evaluationIsTrue(#"{"result":{"type":"string","value":"true"}}"#))
    }

    @Test func webKitUserScriptsKeepTheirTimeAndFrameInChromium() {
        let scripts = PageChromiumDocumentScripts(scripts: [
            (source: "start()", atDocumentEnd: false, mainFrameOnly: true),
            (source: "end()", atDocumentEnd: true, mainFrameOnly: false),
        ])
        #expect(scripts.sources.count == 4)
        #expect(scripts.sources[0].contains("if (window !== window.top) return;"))
        #expect(scripts.sources[0].contains("start()"))
        #expect(!scripts.sources[1].contains("window.top"))
        #expect(scripts.sources[1].contains("DOMContentLoaded"))
        #expect(scripts.sources[2] == PageChromiumDocumentScripts.navigationScript)
        #expect(scripts.sources[3] == PageChromiumDocumentScripts.hostDropScript)
    }
}

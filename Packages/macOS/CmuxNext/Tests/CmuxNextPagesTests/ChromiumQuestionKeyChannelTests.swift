@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import Foundation
import JavaScriptCore
import Testing

@MainActor
struct ChromiumQuestionKeyChannelTests {
    private static let target = PageQuestionKeyTarget(sessionID: "session-one", permissionID: "question-one")
    private static let url = "cmux-page://cmux.agent/index.html"

    private func page() -> FakeChromiumPage {
        let page = FakeChromiumPage()
        page.senderURL = Self.url
        page.answer = { method, _ in
            switch method {
            case "Page.getFrameTree": #"{"frameTree":{"frame":{"id":"main","url":"\#(Self.url)"}}}"#
            case "Page.createIsolatedWorld": #"{"executionContextId":73}"#
            default: nil
            }
        }
        return page
    }

    private func install(_ channel: ChromiumQuestionKeyChannel, page: FakeChromiumPage,
                         received: @escaping (PageQuestionKeyTarget) -> Void) async throws -> (binding: String, source: String) {
        let installed: Bool? = await PageTestWait.value("private question listener") { done in
            page.onCall = {
                if page.calls.contains(where: { ($0.params["expression"] as? String)?.contains("const nonce =") == true }) { done(true) }
            }
            channel.bind(Self.target, received: received)
        }
        #expect(installed == true)
        page.onCall = nil
        let binding = try #require(page.calls.last(where: { $0.method == "Runtime.addBinding" })?.params["name"] as? String)
        let source = try #require(page.calls.last(where: { ($0.params["expression"] as? String)?.contains("const nonce =") == true })?.params["expression"] as? String)
        return (binding, source)
    }

    private static func event(binding: String, payload: String, context: Int = 73) throws -> String {
        let object: [String: Any] = ["method": "Runtime.bindingCalled", "params": [
            "name": binding, "payload": payload, "executionContextId": context,
        ]]
        return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    /// Executes the actual isolated-world listener against a tiny DOM model. CEF's real
    /// `isTrusted`/world boundary is covered separately by the hosted browser integration.
    private func scriptContext(binding: String, source: String) throws -> JSContext {
        let context = try #require(JSContext())
        context.evaluateScript("""
        var reports = [];
        var listener;
        class HTMLTextAreaElement {
          getClientRects() { return [{}]; }
          closest(selector) {
            if (selector === '.acpmux-question-other') return this.other ? {} : null;
            if (selector === '.acpmux-question') return this.card;
            return null;
          }
        }
        var card = {
          hidden: false,
          getClientRects() { return [{}]; },
          getAttribute(name) {
            if (name === 'data-cmux-question-session') return 'session-one';
            if (name === 'data-cmux-question-id') return 'question-one';
            return null;
          }
        };
        var field = new HTMLTextAreaElement(); field.other = true; field.card = card;
        var composer = new HTMLTextAreaElement(); composer.other = false;
        var document = {
          activeElement: field,
          addEventListener(name, callback) { listener = callback; },
          removeEventListener(name, callback) { if (listener === callback) listener = undefined; }
        };
        globalThis[\(ChromiumPageHostWire.jsonString(binding))] = (payload) => reports.push(payload);
        function press(changes = {}) {
          listener?.({isTrusted:true, repeat:false, isComposing:false, keyCode:13, key:'Enter',
            shiftKey:false, ctrlKey:false, altKey:false, target:document.activeElement, ...changes});
        }
        """)
        context.evaluateScript(source)
        #expect(context.exception == nil)
        return context
    }

    @Test func aMainWorldCallCannotSpendAnOrdinaryComposerReturn() async throws {
        let page = page()
        let channel = ChromiumQuestionKeyChannel(page: page, owns: { $0?.absoluteString == Self.url })
        var accepted: [PageQuestionKeyTarget] = []
        let installed = try await install(channel, page: page) { accepted.append($0) }
        let isolated = try scriptContext(binding: installed.binding, source: installed.source)
        isolated.evaluateScript("document.activeElement = composer; press();")
        #expect(isolated.evaluateScript("reports.length").toInt32() == 0)
        #expect(channel.receive(try Self.event(binding: installed.binding, payload: "forged", context: 9)))
        #expect(accepted.isEmpty)
        // Even guessing the isolated secret cannot turn a page-world call into a private one.
        isolated.evaluateScript("document.activeElement = field; press();")
        let nonce = try #require(isolated.evaluateScript("reports[0]").toString())
        #expect(channel.receive(try Self.event(binding: installed.binding, payload: nonce, context: 9)))
        #expect(accepted.isEmpty)
        #expect(channel.receive(try Self.event(binding: installed.binding, payload: nonce)))
        #expect(accepted == [Self.target])
        #expect(!channel.receive(try Self.event(binding: installed.binding, payload: nonce)))
        #expect(accepted.count == 1)
        channel.invalidate()
    }

    @Test func onlyOneTrustedReturnOnTheMatchingPendingOtherFieldReports() async throws {
        let page = page()
        let channel = ChromiumQuestionKeyChannel(page: page, owns: { $0?.absoluteString == Self.url })
        let installed = try await install(channel, page: page) { _ in }
        let isolated = try scriptContext(binding: installed.binding, source: installed.source)
        isolated.evaluateScript("""
        press({isTrusted:false}); press({repeat:true}); press({isComposing:true});
        press({keyCode:229}); press({shiftKey:true}); press({ctrlKey:true}); press({altKey:true});
        card.hidden = true; press(); card.hidden = false;
        const correct = card.getAttribute;
        card.getAttribute = () => 'question-two'; press(); card.getAttribute = correct;
        """)
        #expect(isolated.evaluateScript("reports.length").toInt32() == 0)
        isolated.evaluateScript("press(); press();")
        #expect(isolated.evaluateScript("reports.length").toInt32() == 1)
        channel.invalidate()
    }

    @Test func nativeInvalidationAndContextDeathRefuseOldProofs() async throws {
        for invalidation in ["native", "cleared", "destroyed"] {
            let page = page()
            let channel = ChromiumQuestionKeyChannel(page: page, owns: { $0?.absoluteString == Self.url })
            var accepted = false
            let installed = try await install(channel, page: page) { _ in accepted = true }
            let isolated = try scriptContext(binding: installed.binding, source: installed.source)
            isolated.evaluateScript("press()")
            let nonce = try #require(isolated.evaluateScript("reports[0]").toString())
            switch invalidation {
            case "native": channel.invalidate()
            case "cleared": channel.receive(#"{"method":"Runtime.executionContextsCleared","params":{}}"#)
            default: channel.receive(#"{"method":"Runtime.executionContextDestroyed","params":{"executionContextId":73}}"#)
            }
            #expect(!channel.receive(try Self.event(binding: installed.binding, payload: nonce)))
            #expect(!accepted)
        }
    }

    @Test func anOlderSetupCannotReplaceTheNewerPrivateListener() throws {
        let older = PageQuestionKeyScript.source(target: Self.target, nonce: "old", binding: "oldBinding", generation: 1)
        let newer = PageQuestionKeyScript.source(target: Self.target, nonce: "new", binding: "newBinding", generation: 2)
        let isolated = try scriptContext(binding: "newBinding", source: newer)
        isolated.evaluateScript("globalThis.oldBinding = () => { throw Error('old proof'); }")
        isolated.evaluateScript(older)
        isolated.evaluateScript("press()")
        #expect(isolated.exception == nil)
        #expect(isolated.evaluateScript("reports.join(',')").toString() == "new")
    }
}

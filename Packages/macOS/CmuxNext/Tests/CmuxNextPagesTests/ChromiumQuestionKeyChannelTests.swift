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
                         targets: [PageQuestionKeyTarget]? = nil,
                         received: @escaping (PageQuestionKeySnapshot) -> Void) async throws -> (binding: String, source: String) {
        let installed: Bool? = await PageTestWait.value("private question listener") { done in
            page.onCall = {
                if page.calls.contains(where: { ($0.params["expression"] as? String)?.contains("const nonce =") == true }) { done(true) }
            }
            channel.bind(targets ?? [Self.target], received: received)
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
        var observers = [];
        const initialReply = '{"optionId":"allow","answers":{"Question":"My answer"}}';
        class Element {
          constructor() { this.attrs = {}; this.listeners = {}; this.parentNode = null; this.hidden = false; }
          get isConnected() { return this === document || !!this.parentNode?.isConnected; }
          getClientRects() { return this.isConnected && !this.hidden ? [{}] : []; }
          getAttribute(name) { return this.attrs[name] ?? null; }
          contains(other) { for (let node = other; node; node = node.parentNode) if (node === this) return true; return false; }
          addEventListener(name, callback) { this.listeners[name] = callback; }
          removeEventListener(name, callback) { if (this.listeners[name] === callback) delete this.listeners[name]; }
        }
        class HTMLTextAreaElement extends Element {
          closest(selector) {
            if (selector === '.acpmux-question-other[data-row-editing="true"]')
              return this === field && other.getAttribute('data-row-editing') === 'true' ? other : null;
            if (selector === '.acpmux-question') return this === field ? card : null;
            return null;
          }
        }
        class MutationObserver {
          constructor(callback) { this.callback = callback; this.nodes = new Map(); this.records = []; observers.push(this); }
          observe(node, options) { this.nodes.set(node, options); }
          disconnect() { this.nodes.clear(); this.records = []; }
          takeRecords() { const records = this.records; this.records = []; return records; }
        }
        function mutation(record) {
          for (const observer of observers) {
            const options = observer.nodes.get(record.target);
            if (record.type === 'attributes' ? options?.attributes && options.attributeFilter.includes(record.attributeName) : options?.childList)
              observer.records.push(record);
          }
        }
        function attribute(node, name, value) {
          node.attrs[name] = value;
          mutation({type:'attributes', target:node, attributeName:name});
        }
        function detach(node) {
          const parent = node.parentNode; node.parentNode = null;
          mutation({type:'childList', target:parent, removedNodes:[node]});
        }
        function focus(node) {
          document.activeElement?.listeners.focusout?.();
          document.activeElement = node;
        }
        var document = {
          parentNode:null, isConnected:true, activeElement:null,
          addEventListener(name, callback) { listener = callback; },
          removeEventListener(name, callback) { if (listener === callback) listener = undefined; }
        };
        var card = new Element(); card.parentNode = document;
        card.attrs = {'data-cmux-question-session':'session-one', 'data-cmux-question-id':'question-one',
          'data-cmux-question-enter-reply':initialReply};
        var other = new Element(); other.parentNode = card; other.attrs['data-row-editing'] = 'true';
        var field = new HTMLTextAreaElement(); field.parentNode = other; field.value = 'My answer';
        var composer = new HTMLTextAreaElement(); composer.parentNode = document;
        document.activeElement = field;
        globalThis[\(ChromiumPageHostWire.jsonString(binding))] = (payload) => reports.push(payload);
        function press(changes = {}) {
          const target = changes.target ?? document.activeElement;
          const path = []; for (let node = target; node; node = node.parentNode) path.push(node);
          listener?.({isTrusted:true, repeat:false, isComposing:false, keyCode:13, key:'Enter',
            shiftKey:false, ctrlKey:false, altKey:false, target, composedPath:() => path, ...changes});
        }
        function reply(answer, annotations) {
          const value = {optionId:'allow', answers:{Question:answer}};
          if (annotations !== undefined) value.annotations = annotations;
          attribute(card, 'data-cmux-question-enter-reply', JSON.stringify(value));
        };
        """)
        context.evaluateScript(source)
        #expect(context.exception == nil)
        return context
    }

    private func redeemIn(_ context: JSContext, page: FakeChromiumPage) {
        let answer = page.answer
        page.answer = { method, params in
            if method == "Runtime.evaluate", let expression = params["expression"] as? String,
               expression.hasPrefix("globalThis["), expression.contains("_redeem") {
                let accepted = context.evaluateScript(expression)?.toBool() ?? false
                return #"{"result":{"type":"boolean","value":\#(accepted)}}"#
            }
            return answer?(method, params)
        }
    }

    @Test func aMainWorldCallCannotSpendAnOrdinaryComposerReturn() async throws {
        let page = page()
        let channel = ChromiumQuestionKeyChannel(page: page, owns: { $0?.absoluteString == Self.url })
        var accepted: [PageQuestionKeySnapshot] = []
        let installed = try await install(channel, page: page) { accepted.append($0) }
        let isolated = try scriptContext(binding: installed.binding, source: installed.source)
        redeemIn(isolated, page: page)
        isolated.evaluateScript("document.activeElement = composer; press();")
        #expect(isolated.evaluateScript("reports.length").toInt32() == 0)
        #expect(channel.receive(try Self.event(binding: installed.binding, payload: "forged", context: 9)))
        #expect(accepted.isEmpty)
        // Even guessing the isolated secret cannot turn a page-world call into a private one.
        isolated.evaluateScript("document.activeElement = field; press();")
        let nonce = try #require(isolated.evaluateScript("reports[0]").toString())
        #expect(channel.receive(try Self.event(binding: installed.binding, payload: nonce, context: 9)))
        #expect(accepted.isEmpty)
        let wrong = try #require(isolated.evaluateScript("JSON.stringify({...JSON.parse(reports[0]), nonce:'wrong'})").toString())
        #expect(channel.receive(try Self.event(binding: installed.binding, payload: wrong)))
        #expect(accepted.isEmpty)
        #expect(channel.receive(try Self.event(binding: installed.binding, payload: nonce)))
        #expect(accepted.map(\.target) == [Self.target])
        let snapshot = try #require(accepted.first)
        #expect(await channel.redeem(snapshot))
        #expect(!(await channel.redeem(snapshot)))
        #expect(channel.receive(try Self.event(binding: installed.binding, payload: nonce)))
        #expect(accepted.count == 1)
        channel.invalidate()
    }

    @Test func onlyTrustedReturnsOnTheMatchingPendingOtherFieldReport() async throws {
        let page = page()
        let channel = ChromiumQuestionKeyChannel(page: page, owns: { $0?.absoluteString == Self.url })
        let installed = try await install(channel, page: page) { _ in }
        let isolated = try scriptContext(binding: installed.binding, source: installed.source)
        isolated.evaluateScript("""
        press({isTrusted:false}); press({repeat:true}); press({isComposing:true});
        press({keyCode:229}); press({shiftKey:true}); press({ctrlKey:true}); press({altKey:true});
        card.hidden = true; press(); card.hidden = false;
        card.attrs['data-cmux-question-id'] = 'question-two'; press(); card.attrs['data-cmux-question-id'] = 'question-one';
        """)
        #expect(isolated.evaluateScript("reports.length").toInt32() == 0)
        isolated.evaluateScript("press(); press();")
        #expect(isolated.evaluateScript("reports.length").toInt32() == 2)
        channel.invalidate()
    }

    @Test func anEmptyReturnThenAnEditedAnswerUsesTwoDistinctKeysWithoutRebinding() async throws {
        let page = page()
        let channel = ChromiumQuestionKeyChannel(page: page, owns: { $0?.absoluteString == Self.url })
        var snapshots: [PageQuestionKeySnapshot] = []
        let installed = try await install(channel, page: page) { snapshots.append($0) }
        let isolated = try scriptContext(binding: installed.binding, source: installed.source)
        redeemIn(isolated, page: page)
        isolated.evaluateScript("field.value = ''; reply(''); press();")
        let first = try #require(isolated.evaluateScript("reports[0]").toString())
        #expect(channel.receive(try Self.event(binding: installed.binding, payload: first)))
        isolated.evaluateScript("field.value = 'My answer'; reply('My answer'); press();")
        let second = try #require(isolated.evaluateScript("reports[1]").toString())
        #expect(first != second)
        #expect(channel.receive(try Self.event(binding: installed.binding, payload: second)))
        #expect(snapshots.count == 2)
        #expect(channel.receive(try Self.event(binding: installed.binding, payload: first)))
        #expect(snapshots.count == 2, "the empty key cannot be replayed to grant the edited answer")
        #expect(!(await channel.redeem(snapshots[0])))
        #expect(await channel.redeem(snapshots[1]))
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

    @Test(arguments: [
        "focus(composer); focus(field);",
        "attribute(card, 'data-cmux-question-id', 'another'); attribute(card, 'data-cmux-question-id', 'question-one');",
        "attribute(card, 'data-cmux-question-session', 'another'); attribute(card, 'data-cmux-question-session', 'session-one');",
        "reply('replacement'); reply('My answer');",
        "attribute(other, 'data-row-editing', 'false'); attribute(other, 'data-row-editing', 'true');",
        "detach(field); field.parentNode = other;",
        "detach(card); card.parentNode = document;",
    ])
    func delayedChangesRevokeTheOldSnapshotEvenWhenTheStateIsRestored(_ change: String) async throws {
        let page = page()
        let channel = ChromiumQuestionKeyChannel(page: page, owns: { $0?.absoluteString == Self.url })
        var snapshots: [PageQuestionKeySnapshot] = []
        let installed = try await install(channel, page: page) { snapshots.append($0) }
        let isolated = try scriptContext(binding: installed.binding, source: installed.source)
        redeemIn(isolated, page: page)
        isolated.evaluateScript("press()")
        let first = try #require(isolated.evaluateScript("reports[0]").toString())
        channel.receive(try Self.event(binding: installed.binding, payload: first))
        let old = try #require(snapshots.first)
        isolated.evaluateScript(change)
        #expect(!(await channel.redeem(old)))
        #expect(!(await channel.redeem(old)), "a refused ticket is still spent")
        isolated.evaluateScript("press()")
        let next = try #require(isolated.evaluateScript("reports[1]").toString())
        channel.receive(try Self.event(binding: installed.binding, payload: next))
        let fresh = try #require(snapshots.last)
        #expect(await channel.redeem(fresh), "the same pending question accepts a new genuine key")
        #expect(isolated.exception == nil)
        channel.invalidate()
    }

    @Test func aSnapshotBelongsOnlyToItsIssuingPageAndChannel() async throws {
        let page = page()
        let channel = ChromiumQuestionKeyChannel(page: page, owns: { $0?.absoluteString == Self.url })
        var snapshot: PageQuestionKeySnapshot?
        let installed = try await install(channel, page: page) { snapshot = $0 }
        let isolated = try scriptContext(binding: installed.binding, source: installed.source)
        redeemIn(isolated, page: page)
        isolated.evaluateScript("press()")
        let report = try #require(isolated.evaluateScript("reports[0]").toString())
        channel.receive(try Self.event(binding: installed.binding, payload: report))
        let captured = try #require(snapshot)
        let other = ChromiumQuestionKeyChannel(page: self.page(), owns: { _ in true })
        #expect(!(await other.redeem(captured)))
        #expect(await channel.redeem(captured))
        #expect(!(await channel.redeem(captured)))
        channel.invalidate()
    }

    @Test func replyEnvelopePreservesAnnotationsAndRejectsIdentityOverrides() async throws {
        let page = page()
        let channel = ChromiumQuestionKeyChannel(page: page, owns: { $0?.absoluteString == Self.url })
        var snapshots: [PageQuestionKeySnapshot] = []
        let installed = try await install(channel, page: page) { snapshots.append($0) }
        let isolated = try scriptContext(binding: installed.binding, source: installed.source)
        redeemIn(isolated, page: page)
        isolated.evaluateScript("attribute(card, 'data-cmux-question-enter-reply', JSON.stringify({optionId:'allow', answers:{}, sessionId:'another'})); press();")
        #expect(isolated.evaluateScript("reports.length").toInt32() == 0)
        for (index, argument) in ["undefined", "{}", "{Question:{preview:'Plan',notes:'Keep the quote'}}"].enumerated() {
            isolated.evaluateScript("reply('My answer', \(argument)); press();")
            let report = try #require(isolated.evaluateScript("reports[\(index)]").toString())
            channel.receive(try Self.event(binding: installed.binding, payload: report))
            let captured = try #require(snapshots.last)
            #expect(captured.replyJSON.contains("\"annotations\"") == (index != 0))
            if index == 1 { #expect(captured.replyJSON.contains("\"annotations\":{}")) }
            #expect(await channel.redeem(captured))
        }
        channel.invalidate()
    }

    @Test func anOlderSetupCannotReplaceTheNewerPrivateListener() throws {
        let older = PageQuestionKeyScript.source(targets: [Self.target], nonce: "old", binding: "oldBinding", generation: 1)
        let newer = PageQuestionKeyScript.source(targets: [Self.target], nonce: "new", binding: "newBinding", generation: 2)
        let isolated = try scriptContext(binding: "newBinding", source: newer)
        isolated.evaluateScript("globalThis.oldBinding = () => { throw Error('old proof'); }")
        isolated.evaluateScript(older)
        isolated.evaluateScript("press()")
        #expect(isolated.exception == nil)
        #expect(isolated.evaluateScript("JSON.parse(reports[0]).nonce").toString() == "new")
    }

    @Test func theOriginalCardSelectsAnyApprovedTargetWithoutDictionaryOrderOrRebinding() async throws {
        let page = page()
        let channel = ChromiumQuestionKeyChannel(page: page, owns: { $0?.absoluteString == Self.url })
        let second = PageQuestionKeyTarget(sessionID: "session-one", permissionID: "question-two")
        var snapshots: [PageQuestionKeySnapshot] = []
        let installed = try await install(channel, page: page, targets: [Self.target, second]) { snapshots.append($0) }
        let isolated = try scriptContext(binding: installed.binding, source: installed.source)
        redeemIn(isolated, page: page)
        isolated.evaluateScript("card.attrs['data-cmux-question-id'] = 'question-two'; press();")
        let report = try #require(isolated.evaluateScript("reports[0]").toString())
        channel.receive(try Self.event(binding: installed.binding, payload: report))
        let captured = try #require(snapshots.first)
        #expect(captured.target == second, "the visible oldest card need not be first in the native dictionary")
        let calls = page.calls.count
        channel.bind([second, Self.target]) { snapshots.append($0) }
        #expect(page.calls.count == calls, "unchanged membership preserves the private listener and pending snapshot")
        #expect(await channel.redeem(captured))
        isolated.evaluateScript("attribute(card, 'data-cmux-question-id', 'unapproved'); press();")
        #expect(isolated.evaluateScript("reports.length").toInt32() == 1)
        isolated.evaluateScript("attribute(card, 'data-cmux-question-id', 'question-two'); press();")
        let next = try #require(isolated.evaluateScript("reports[1]").toString())
        channel.receive(try Self.event(binding: installed.binding, payload: next))
        let stale = try #require(snapshots.last)
        channel.bind([Self.target]) { _ in }
        #expect(!(await channel.redeem(stale)), "a collection change revokes the old proof synchronously")
        channel.invalidate()
    }

    @Test func installingBeforeTheOtherFieldMountsStillAcceptsALaterGenuineKey() async throws {
        let page = page()
        let channel = ChromiumQuestionKeyChannel(page: page, owns: { $0?.absoluteString == Self.url })
        var captured: PageQuestionKeySnapshot?
        let installed = try await install(channel, page: page) { captured = $0 }
        let isolated = try scriptContext(binding: installed.binding, source: installed.source)
        redeemIn(isolated, page: page)
        isolated.evaluateScript("field.parentNode = null; press();")
        #expect(isolated.evaluateScript("reports.length").toInt32() == 0)
        isolated.evaluateScript("field.parentNode = other; press();")
        let report = try #require(isolated.evaluateScript("reports[0]").toString())
        channel.receive(try Self.event(binding: installed.binding, payload: report))
        let snapshot = try #require(captured)
        #expect(await channel.redeem(snapshot))
        channel.invalidate()
    }
}

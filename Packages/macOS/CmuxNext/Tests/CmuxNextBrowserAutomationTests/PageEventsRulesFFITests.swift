import Security
import Foundation
import Testing
@testable import CmuxNextBrowserAutomation
import CmuxNextBrowserCore

/// The console, dialog and cookie backup key rules answered by Rust (cmux-browser-rules
/// `page_events.rs`) keep the events, texts and meanings the Swift copy had.
@MainActor
@Suite struct PageEventsRulesFFITests {
    @Test func consoleMessagesBecomeDriverEvents() {
        let log = PageConsole.event(["kind": "console", "type": "warning", "text": "careful"])
        #expect(log?.name == "console")
        #expect(log?.payload == ["type": .string("warning"), "text": .string("careful")])
        let failure = PageConsole.event(["kind": "pageerror", "message": "boom"])
        #expect(failure?.name == "pageerror")
        #expect(failure?.payload == ["message": .string("boom"), "stack": .string("boom")])
        let stacked = PageConsole.event(["kind": "pageerror", "message": "boom", "stack": "Error: boom\n at x"])
        #expect(stacked?.payload["stack"] == .string("Error: boom\n at x"))
    }

    @Test func otherConsoleMessagesAreDropped() {
        #expect(PageConsole.event(["kind": "console", "type": "log"]) == nil)
        #expect(PageConsole.event(["kind": "other"]) == nil)
        #expect(PageConsole.event("text") == nil)
        #expect(PageConsole.event(["kind": "console", "type": "log", "text": NSObject()]) == nil)
    }

    @Test func dialogsAnAgentMaySeeAreDescribed() {
        #expect(DialogBroker.describe(.alert(message: "hi")) ?? ("", "", "x") == ("alert", "hi", ""))
        #expect(DialogBroker.describe(.confirm(message: "sure?")) ?? ("", "", "x") == ("confirm", "sure?", ""))
        #expect(DialogBroker.describe(.textInput(message: "name?", defaultText: "d")) ?? ("", "", "") == ("prompt", "name?", "d"))
        #expect(DialogBroker.describe(.textInput(message: "name?", defaultText: nil)) ?? ("", "", "x") == ("prompt", "name?", ""))
    }

    @Test func thePersonsPromptsStayThePersons() {
        #expect(DialogBroker.describe(.credentials(host: "a.com", realm: nil)) == nil)
        #expect(DialogBroker.describe(.noAppForScheme(scheme: "zoommtg")) == nil)
        #expect(DialogBroker.describe(.openExternalApp(app: "Zoom", scheme: "zoommtg")) == nil)
    }

    private func respond(_ params: [String: Any], held: BrowserPromptKind?, resolved: Bool = false) -> DriverJSON? {
        var request: [String: Any] = ["params": params, "resolved": resolved]
        if let held { request["held"] = DialogBroker.wire(held) }
        return BrowserRulesFFI.call("dialog_respond", request)
    }

    @Test func respondAnswersAsTheSwiftCopyDid() {
        #expect(respond(["dialogId": "1", "accept": true, "promptText": "hi"], held: .textInput(message: "n", defaultText: "d"))
            == .object(["answer": .object(["kind": .string("text"), "text": .string("hi")])]))
        #expect(respond(["dialogId": "1", "accept": true], held: .textInput(message: "n", defaultText: "d"))
            == .object(["answer": .object(["kind": .string("text"), "text": .string("d")])]))
        #expect(respond(["dialogId": "1", "accept": true], held: .confirm(message: "c"))
            == .object(["answer": .object(["kind": .string("accept")])]))
        #expect(respond(["dialogId": "1"], held: .textInput(message: "n", defaultText: "d"))
            == .object(["answer": .object(["kind": .string("cancel")])]))
    }

    @Test func respondToAGoneDialogIsNotFound() {
        let gone = DriverJSON.object(["error": .object(["code": .string("not_found"), "message": .string("Dialog 7 is gone")])])
        #expect(respond(["dialogId": "7", "accept": true], held: nil) == gone)
        #expect(respond(["dialogId": "7", "accept": true], held: .alert(message: "a"), resolved: true) == gone)
        guard case .object(let reply)? = respond([:], held: nil), case .object(let error)? = reply["error"] else {
            Issue.record("no error for a missing dialogId")
            return
        }
        #expect(error["code"] == .string("invalid"))
    }

    @Test func cookieBackupKeyAnswers() throws {
        #expect(try CookieBackupKeyRules.readFound(errSecItemNotFound, length: nil) == false)
        #expect(try CookieBackupKeyRules.readFound(errSecSuccess, length: 32) == true)
        #expect(throws: CookieBackupError.self) { try CookieBackupKeyRules.readFound(errSecSuccess, length: 16) }
        do {
            _ = try CookieBackupKeyRules.readFound(errSecAuthFailed, length: nil)
            Issue.record("a refused read did not throw")
        } catch {
            #expect(error.message == "the cookie backup key could not be read from the Keychain (status \(errSecAuthFailed))")
        }
        #expect(try CookieBackupKeyRules.addStep(errSecSuccess) == "useFresh")
        #expect(try CookieBackupKeyRules.addStep(errSecDuplicateItem) == "readExisting")
        do {
            _ = try CookieBackupKeyRules.addStep(errSecAuthFailed)
            Issue.record("a refused add did not throw")
        } catch {
            #expect(error.message == "the cookie backup key could not be stored in the Keychain (status \(errSecAuthFailed))")
        }
        #expect(CookieBackupKeyRules.fileUsable(length: 32))
        #expect(!CookieBackupKeyRules.fileUsable(length: 0))
    }

    #if DEBUG
    @Test func fileKeyIsMadeOnceAndReused() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "cookie-key-\(UUID().uuidString)/key")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let first = try FileCookieBackupKey(url: url).key().withUnsafeBytes { Data($0) }
        let again = try FileCookieBackupKey(url: url).key().withUnsafeBytes { Data($0) }
        #expect(first.count == 32)
        #expect(first == again)
    }
    #endif
}

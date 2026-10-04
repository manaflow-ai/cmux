import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
import Foundation
import Testing

/// R96: JavaScript dialogs and HTTP sign-in are cmux dialogs on the asking
/// tab; permission requests stay in the prompt bar.
@MainActor
struct BrowserDialogTests {
    static func tab() -> (NSWindow, NSView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        window.contentView?.addSubview(view)
        return (window, view)
    }

    @Test func javaScriptDialogsNameTheOriginAndPermissionsStayInTheBar() throws {
        let alert = BrowserPrompt(kind: .alert(message: "Saved"), origin: "https://a.example") { _ in }
        let spec = try #require(BrowserPromptDialogs.spec(for: alert))
        #expect(spec.title.contains("https://a.example"))
        #expect(spec.lines == ["Saved"])
        let prompt = BrowserPrompt(kind: .textInput(message: "Name?", defaultText: "x"), origin: "https://a.example") { _ in }
        #expect(BrowserPromptDialogs.spec(for: prompt)?.fields == [.text("text", initial: "x")])
        let camera = BrowserPrompt(kind: .permission(.camera), origin: "https://a.example") { _ in }
        #expect(BrowserPromptDialogs.spec(for: camera) == nil)
    }

    @Test func aPressAnswersThePageAndADismissalDoesNot() throws {
        let host = CmuxDialogHeadlessHost()
        let center = CmuxDialogCenter(host: host)
        let dialogs = BrowserPromptDialogs(center: center)
        let (window, view) = Self.tab()
        _ = window
        var responses: [BrowserPromptResponse] = []
        let prompt = BrowserPrompt(kind: .textInput(message: "Name?", defaultText: "x"), origin: "https://a.example") { responses.append($0) }
        let bar = PromptBarView()
        dialogs.render(prompt, in: view, bar: bar)
        #expect(bar.isHidden)
        let shown = try #require(host.shown.first)
        host.closeScope(of: shown)
        #expect(responses.isEmpty && !prompt.isResolved, "a tab switch does not answer the page")
        dialogs.render(prompt, in: view, bar: bar)
        let id = try #require(center.records.first?.id)
        center.setValue(.text("ada"), for: "text", in: id)
        center.press(id, button: "ok")
        #expect(prompt.isResolved)
        if case .text(let text)? = responses.first { #expect(text == "ada") } else { Issue.record("no text answer") }
    }

    @Test func anAnswerFromAutomationClosesTheDialog() {
        let host = CmuxDialogHeadlessHost()
        let center = CmuxDialogCenter(host: host)
        let dialogs = BrowserPromptDialogs(center: center)
        let (window, view) = Self.tab()
        _ = window
        let prompt = BrowserPrompt(kind: .confirm(message: "Leave?"), origin: "https://a.example") { _ in }
        let bar = PromptBarView()
        dialogs.render(prompt, in: view, bar: bar)
        prompt.respond(.accept)
        dialogs.render(nil, in: view, bar: bar)
        #expect(center.records.isEmpty)
    }

    @Test func httpSignInWarnsWithoutEncryptionAndAfterAFailure() {
        let spec = BrowserHTTPAuth.spec(host: "intranet:8080", realm: "Staff", isSecure: false, failedBefore: true, user: "ada")
        #expect(spec.origin == "intranet:8080")
        #expect(spec.lines.count == 4, "message, realm, no encryption, wrong password")
        #expect(spec.fields.first == .text("user", initial: "ada", label: spec.fieldLabel("user")))
        let secure = BrowserHTTPAuth.spec(host: "a.example", realm: nil, isSecure: true, failedBefore: false, user: nil)
        #expect(secure.lines.count == 1)
    }

    @Test func httpSignInGivesASessionCredentialOrNone() {
        let signIn = CmuxDialogAnswer(button: "sign-in", role: .default, values: ["user": .text("ada"), "password": .text("pw")])
        let credential = BrowserHTTPAuth.credential(for: signIn)
        #expect(credential?.user == "ada" && credential?.password == "pw" && credential?.persistence == .forSession)
        #expect(BrowserHTTPAuth.credential(for: CmuxDialogAnswer(button: "cancel", role: .cancel)) == nil)
        #expect(BrowserHTTPAuth.asksUser(NSURLAuthenticationMethodHTTPBasic))
        #expect(!BrowserHTTPAuth.asksUser(NSURLAuthenticationMethodServerTrust))
    }
}

private extension CmuxDialogSpec {
    func fieldLabel(_ id: String) -> String? {
        for field in fields {
            if case .text(let fieldID, let label, _, _, _) = field, fieldID == id { return label }
        }
        return nil
    }
}

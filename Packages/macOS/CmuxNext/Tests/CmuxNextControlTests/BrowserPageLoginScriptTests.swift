import AppKit
@testable import CmuxNextControl
import CmuxNextSettings
import Foundation
import Testing
import WebKit

/// The `browser.page.fill_login` page scripts in a real WebKit page (cmux
/// https://github.com/manaflow-ai/cmux/issues/25830): which fields a login lands in on real login
/// shapes (one step, two steps, a header search box, a sign-up form), that a page on another host
/// gets nothing, and that the answer names no value.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2))) struct BrowserPageLoginScriptTests {
    static let host = "login.cmux.test"
    static let username = "ada@example.com"
    static let password = "hunter2-SECRET-pw"

    @MainActor final class Page: NSObject, WKNavigationDelegate {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 500), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        private var loaded: CheckedContinuation<Void, Never>?

        func load(_ html: String, scheme: String = "https") async {
            _ = NSApplication.shared
            window.contentView = webView
            webView.navigationDelegate = self
            await withCheckedContinuation { done in
                loaded = done
                webView.loadHTMLString(html, baseURL: URL(string: "\(scheme)://\(BrowserPageLoginScriptTests.host)/"))
            }
        }

        nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            MainActor.assumeIsolated {
                loaded?.resume()
                loaded = nil
            }
        }

        /// A page expression's value.
        func read(_ expression: String) async throws -> JSONValue {
            let text = try await webView.evaluateJavaScript("JSON.stringify(\(expression))") as? String
            guard let data = text?.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return .null }
            return JSONValue(foundation: object) ?? .null
        }

        func value(_ id: String) async throws -> String? {
            try await read("document.getElementById('\(id)').value").stringValue
        }

        /// A page expression's value, evaluated in an isolated content world as cmux's own login
        /// scripts run (`BrowserPageOperation.evaluateIsolated`).
        func readIsolated(_ expression: String) async throws -> JSONValue {
            let text = try await webView.evaluateJavaScript("JSON.stringify(\(expression))", in: nil,
                                                            contentWorld: .world(name: "cmux-login-test")) as? String
            guard let data = text?.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return .null }
            return JSONValue(foundation: object) ?? .null
        }

        /// The document's name as the probe gives it.
        func document() async throws -> String {
            try #require(try await readIsolated(BrowserPageScripts.documentProbe)["document"]?.stringValue)
        }
    }

    private func page(_ body: String, scheme: String = "https") async -> Page {
        let page = Page()
        await page.load("<!doctype html><html><body style=\"font: 14px sans-serif\">\(body)</body></html>", scheme: scheme)
        return page
    }

    private func fill(_ page: Page, host: String = host) async throws -> JSONValue {
        let script = BrowserPageScripts.fillLogin(host: host, document: try await page.document(), username: Self.username, password: Self.password)
        let answer = try await page.readIsolated(script)
        let text = String(describing: answer)
        #expect(!text.contains(Self.username) && !text.contains(Self.password), "the answer names no value")
        return answer
    }

    @Test func aOneStepLoginFillsTheUsernameBeforeThePasswordAndSubmits() async throws {
        let page = await page("""
        <header><input id="search" type="search" placeholder="Search"><input id="q" type="text" placeholder="Search people"></header>
        <form id="f" onsubmit="event.preventDefault(); window.sent = { u: this.u.value, p: this.p.value };">
          <input id="u" name="session_key" type="text" autocomplete="username">
          <input id="p" name="session_password" type="password" autocomplete="current-password">
          <button type="button">Show</button><button type="submit">Sign in</button>
        </form>
        """)
        let answer = try await fill(page)
        #expect(answer["value"]?["username"] == true)
        #expect(answer["value"]?["password"] == true)
        #expect(answer["at"]?["secret"] == true)
        #expect(try await page.value("u") == Self.username)
        #expect(try await page.value("p") == Self.password)
        #expect(try await page.value("search") == "")
        #expect(try await page.value("q") == "")
        let submitted = try await page.readIsolated(BrowserPageScripts.submitLogin(host: Self.host, document: try await page.document()))
        #expect(submitted["value"] == true)
        #expect(try await page.read("window.sent") == ["u": .string(Self.username), "p": .string(Self.password)])
    }

    @Test func aTwoStepLoginFillsTheUsernameAloneAndPressesNext() async throws {
        let page = await page("""
        <form onsubmit="event.preventDefault(); window.sent = true;">
          <input id="id" name="identifier" type="email">
          <input id="hiddenpw" type="password" style="display: none">
          <button type="submit">Next</button>
        </form>
        """)
        let answer = try await fill(page)
        #expect(answer["value"]?["username"] == true)
        #expect(answer["value"]?["password"] == false)
        #expect(try await page.value("id") == Self.username)
        #expect(try await page.value("hiddenpw") == "", "a hidden password field is never filled")
        #expect(try await page.readIsolated(BrowserPageScripts.submitLogin(host: Self.host, document: try await page.document()))["value"] == true)
        #expect(try await page.read("window.sent") == true)
    }

    @Test func thePasswordStepFillsThePasswordAlone() async throws {
        let page = await page("""
        <form><p>ada@example.com</p><input id="p" type="password" name="Passwd"><button>Next</button></form>
        """)
        let answer = try await fill(page)
        #expect(answer["value"]?["username"] == false)
        #expect(answer["value"]?["password"] == true)
        #expect(try await page.value("p") == Self.password)
    }

    @Test func aSearchBoxOrASignUpFormGetsNothing() async throws {
        let page = await page("""
        <input id="search" type="text" name="q" placeholder="Search">
        <form><input id="n" type="text" autocomplete="name"><input id="a" type="password" autocomplete="new-password">
        <input id="b" type="password" autocomplete="new-password"></form>
        """)
        let answer = try await fill(page)
        #expect(answer["value"]?["username"] == false)
        #expect(answer["value"]?["password"] == false)
        #expect(answer["value"]?["reason"] == "no_login_field")
        for id in ["search", "n", "a", "b"] { #expect(try await page.value(id) == "") }
    }

    @Test func aPageOnAnotherHostGetsNothing() async throws {
        let page = await page("""
        <form><input id="u" type="email"><input id="p" type="password"></form>
        """)
        let answer = try await fill(page, host: "linkedin.com")
        #expect(answer["value"]?["reason"] == "navigated")
        #expect(try await page.value("u") == "")
        #expect(try await page.value("p") == "")
    }

    @Test func aLoginInsideAShadowRootIsFound() async throws {
        let page = await page("""
        <div id="host"></div>
        <script>
          const root = document.getElementById('host').attachShadow({ mode: 'open' });
          root.innerHTML = '<form><input id="u" type="email" autocomplete="username"><input id="p" type="password"></form>';
        </script>
        """)
        let answer = try await fill(page)
        #expect(answer["value"]?["username"] == true)
        #expect(answer["value"]?["password"] == true)
        let shadow = "document.getElementById('host').shadowRoot"
        #expect(try await page.read("\(shadow).getElementById('u').value") == .string(Self.username))
        #expect(try await page.read("\(shadow).getElementById('p').value") == .string(Self.password))
    }

    @Test func aPlainHttpPageGetsNothingEvenOnTheRightHost() async throws {
        let page = await page("<form><input id=\"u\" type=\"email\"><input id=\"p\" type=\"password\"></form>", scheme: "http")
        let answer = try await fill(page)
        #expect(answer["value"]?["reason"] == "not_https")
        #expect(try await page.value("u") == "")
        #expect(try await page.value("p") == "")
    }

    @Test func anotherDocumentNameGetsNothing() async throws {
        let page = await page("<form><input id=\"u\" type=\"email\"><input id=\"p\" type=\"password\"></form>")
        let script = BrowserPageScripts.fillLogin(host: Self.host, document: "12.5", username: Self.username, password: Self.password)
        #expect(try await page.readIsolated(script)["value"]?["reason"] == "navigated")
        #expect(try await page.value("p") == "")
    }

    /// The blocker the isolated world closes: a page-world hook on the value setter (what an
    /// agent's eval could plant) never sees the values the fill sets.
    @Test func aPageWorldSetterHookNeverSeesTheValues() async throws {
        let page = await page("""
        <form><input id="u" type="email" autocomplete="username"><input id="p" type="password"></form>
        <script>
          window.caught = [];
          const d = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value');
          Object.defineProperty(HTMLInputElement.prototype, 'value', { configurable: true,
            get() { return d.get.call(this); }, set(v) { window.caught.push(v); d.set.call(this, v); } });
        </script>
        """)
        let answer = try await fill(page)
        #expect(answer["value"]?["password"] == true)
        #expect(try await page.read("window.caught") == [])
        #expect(try await page.value("p") == Self.password, "the page itself still reads the field")
    }

    @Test func theProbeNamesTheDocumentAndANavigationRenamesIt() async throws {
        let first = await page("<p>one</p>")
        let name = try await first.document()
        #expect(Double(name) != nil)
        #expect(try await first.document() == name, "the same document keeps its name")
        // A page-world override of the time origin does not reach the isolated world.
        _ = try await first.read("(() => { Object.defineProperty(Performance.prototype, 'timeOrigin', { get() { return 42; } }); return 1; })()")
        #expect(try await first.document() == name)
        let second = await page("<p>two</p>")
        #expect(try await second.document() != name)
    }
}

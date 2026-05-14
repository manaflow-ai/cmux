import AppKit
import Foundation
import Testing
import WebKit
@testable import CmuxBrowserEngine

@Suite("CmuxBrowserEngine")
struct CmuxBrowserEngineSuite {
    @Test("featureFlagKey is the cmux convention")
    func testFlagKey() {
        #expect(CmuxBrowserEngine.featureFlagKey == "cmux.browser.engine.chromium")
    }

    @Test("defaultKind respects the override")
    func testDefaultKindOverride() async {
        CmuxBrowserEngine.defaultKindOverride = .chromium
        #expect(CmuxBrowserEngine.defaultKind == .chromium)
        CmuxBrowserEngine.defaultKindOverride = .webKit
        #expect(CmuxBrowserEngine.defaultKind == .webKit)
        CmuxBrowserEngine.defaultKindOverride = nil
    }

    @Test("versionString surfaces the engine identity")
    func testVersionString() {
        let webKit = CmuxBrowserEngine.versionString(for: .webKit)
        #expect(webKit.contains("WebKit"))
        let chromium = CmuxBrowserEngine.versionString(for: .chromium)
        #expect(chromium.contains("Chromium"))
    }
}

@Suite("CmuxBrowserConfiguration")
struct CmuxBrowserConfigurationSuite {
    @Test("defaults match WKWebView defaults")
    func testDefaults() {
        let c = CmuxBrowserConfiguration()
        #expect(!c.allowsJavaScriptToOpenWindowsAutomatically)
        #expect(c.allowsInlineMediaPlayback)
        #expect(c.allowsPictureInPictureMediaPlayback)
        #expect(c.mediaTypesRequiringUserActionForPlayback == .none)
        #expect(c.customUserAgent == nil)
        #expect(c.applicationNameForUserAgent == nil)
        #expect(!c.suppressesIncrementalRendering)
        #expect(c.userContentController.userScripts.isEmpty)
        #expect(c.userContentController.messageHandlers.isEmpty)
    }

    @Test("engineKind tracks defaultKind at construction time")
    func testEngineKindFollowsDefault() async {
        CmuxBrowserEngine.defaultKindOverride = .chromium
        let c1 = CmuxBrowserConfiguration()
        #expect(c1.engineKind == .chromium)
        CmuxBrowserEngine.defaultKindOverride = .webKit
        let c2 = CmuxBrowserConfiguration()
        #expect(c2.engineKind == .webKit)
        CmuxBrowserEngine.defaultKindOverride = nil
    }
}

@Suite("CmuxUserContentController")
struct CmuxUserContentControllerSuite {
    @Test("adds and removes scripts")
    func testScripts() {
        let c = CmuxUserContentController()
        c.addUserScript(.init(source: "console.log(1)", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        c.addUserScript(.init(source: "console.log(2)", injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        #expect(c.userScripts.count == 2)
        c.removeAllUserScripts()
        #expect(c.userScripts.isEmpty)
    }

    @Test("registers and removes message handlers")
    func testHandlers() {
        final class H: CmuxScriptMessageHandler, @unchecked Sendable {
            func didReceive(_ message: CmuxScriptMessage) {}
        }
        let c = CmuxUserContentController()
        let h = H()
        c.add(h, name: "alpha")
        c.add(h, name: "beta")
        #expect(c.messageHandlers.count == 2)
        c.removeScriptMessageHandler(forName: "alpha")
        #expect(c.messageHandlers.count == 1)
        #expect(c.messageHandlers["beta"] != nil)
    }
}

@Suite("CmuxScriptMessageBody")
struct CmuxScriptMessageBodySuite {
    @Test("walks NSNumber Bool vs Int vs Double")
    func testNumberWalking() {
        switch CmuxScriptMessageBody.from(any: NSNumber(value: true)) {
        case .bool(let v): #expect(v == true)
        default: Issue.record("expected .bool from NSNumber(true)")
        }
        switch CmuxScriptMessageBody.from(any: NSNumber(value: 42)) {
        case .int(let v): #expect(v == 42)
        default: Issue.record("expected .int from NSNumber(42)")
        }
        switch CmuxScriptMessageBody.from(any: NSNumber(value: 1.5)) {
        case .double(let v): #expect(v == 1.5)
        default: Issue.record("expected .double from NSNumber(1.5)")
        }
    }

    @Test("walks nested array + dictionary")
    func testNested() {
        let value: [String: Any] = [
            "k": [1, "two", true],
            "nested": ["a": 1.25]
        ]
        let body = CmuxScriptMessageBody.from(any: value)
        guard case .dictionary(let dict) = body else {
            Issue.record("expected dictionary")
            return
        }
        guard case .array(let arr) = dict["k"]! else {
            Issue.record("expected array under k")
            return
        }
        #expect(arr.count == 3)
        if case .int(let v) = arr[0] { #expect(v == 1) } else { Issue.record("arr[0] != int") }
        if case .string(let v) = arr[1] { #expect(v == "two") } else { Issue.record("arr[1] != string") }
        if case .bool(let v) = arr[2] { #expect(v == true) } else { Issue.record("arr[2] != bool") }
        if case .dictionary(let nested) = dict["nested"]!,
           case .double(let v) = nested["a"]! {
            #expect(v == 1.25)
        } else {
            Issue.record("nested.a != double")
        }
    }

    @Test("handles NSNull as .null")
    func testNull() {
        if case .null = CmuxScriptMessageBody.from(any: NSNull()) {} else {
            Issue.record("expected .null from NSNull")
        }
    }
}

@Suite("CmuxBrowserView (WebKit backend)")
@MainActor
struct CmuxBrowserViewWebKitSuite {
    private func webKitConfig() -> CmuxBrowserConfiguration {
        let c = CmuxBrowserConfiguration()
        c.engineKind = .webKit
        return c
    }

    @Test("constructs with WebKit backend")
    func testConstruct() {
        let view = CmuxBrowserView(frame: NSRect(x: 0, y: 0, width: 100, height: 100),
                                   configuration: webKitConfig())
        #expect(view.engineDescription.contains("WebKit"))
        #expect(view.url == nil)
        // WKWebView returns an empty string for a never-loaded title;
        // expose that quirk explicitly rather than promoting empty → nil.
        #expect(view.title == nil || view.title?.isEmpty == true)
        #expect(!view.canGoBack)
        #expect(!view.canGoForward)
    }

    @Test("forwards customUserAgent to WKWebView")
    func testCustomUserAgent() {
        let view = CmuxBrowserView(frame: NSRect(x: 0, y: 0, width: 100, height: 100),
                                   configuration: webKitConfig())
        view.customUserAgent = "cmux-test/1.0"
        #expect(view.customUserAgent == "cmux-test/1.0")
        let backend = view.backend as? WebKitBrowserBackend
        #expect(backend != nil)
        #expect(backend?.webView.customUserAgent == "cmux-test/1.0")
    }

    @Test("loadHTMLString returns a CmuxNavigation handle")
    func testLoadHTMLReturnsHandle() {
        let view = CmuxBrowserView(frame: NSRect(x: 0, y: 0, width: 100, height: 100),
                                   configuration: webKitConfig())
        let a = view.loadHTMLString("<html><body>a</body></html>", baseURL: nil)
        let b = view.loadHTMLString("<html><body>b</body></html>", baseURL: nil)
        #expect(a != b)
    }

    @Test("evaluateJavaScript completes against a real WKWebView")
    func testEvaluateJavaScript() async throws {
        let view = CmuxBrowserView(frame: NSRect(x: 0, y: 0, width: 100, height: 100),
                                   configuration: webKitConfig())
        _ = view.loadHTMLString("<html><body><div id='x'>42</div></body></html>", baseURL: nil)
        // Poll up to 5 seconds for the element to appear, since
        // loadHTMLString completion timing under test parallelism is
        // not deterministic.
        let deadline = Date().addingTimeInterval(5)
        var value: Any?
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
            value = try? await view.evaluateJavaScript("document.getElementById('x')?.textContent ?? null")
            if let s = value as? String, s == "42" { break }
        }
        #expect(value as? String == "42")
    }
}

@Suite("CmuxBrowserView (Chromium backend stub)")
@MainActor
struct CmuxBrowserViewChromiumSuite {
    private func chromiumConfig() -> CmuxBrowserConfiguration {
        let c = CmuxBrowserConfiguration()
        c.engineKind = .chromium
        return c
    }

    @Test("Chromium backend reports correct version string")
    func testChromiumVersion() {
        let kind = CmuxBrowserEngine.Kind.chromium
        let s = CmuxBrowserEngine.versionString(for: kind)
        #expect(s.contains("Chromium"))
    }

    @Test("evaluateJavaScript on Chromium stub returns backendUnavailable")
    func testChromiumEvaluateUnavailable() async {
        let view = CmuxBrowserView(frame: NSRect(x: 0, y: 0, width: 100, height: 100),
                                   configuration: chromiumConfig())
        await withCheckedContinuation { continuation in
            view.evaluateJavaScript("1+1") { _, error in
                if let typed = error as? CmuxBrowserEngineError,
                   case .backendUnavailable(.chromium, _) = typed {
                    // ok
                } else {
                    Issue.record("expected backendUnavailable error, got \(String(describing: error))")
                }
                continuation.resume()
            }
        }
    }
}

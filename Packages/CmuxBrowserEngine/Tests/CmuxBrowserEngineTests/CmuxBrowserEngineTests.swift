import AppKit
import Combine
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

@Suite("CmuxBrowserState mirrors")
@MainActor
struct CmuxBrowserStateSuite {
    private func webKitConfig() -> CmuxBrowserConfiguration {
        let c = CmuxBrowserConfiguration()
        c.engineKind = .webKit
        return c
    }

    @Test("WebKit backend pushes title to state.title when navigation finishes")
    func testTitleMirror() async throws {
        let view = CmuxBrowserView(frame: NSRect(x: 0, y: 0, width: 100, height: 100),
                                   configuration: webKitConfig())
        _ = view.loadHTMLString("<html><head><title>cmux-title-fixture</title></head><body>x</body></html>", baseURL: nil)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
            if view.state.title == "cmux-title-fixture" { break }
        }
        #expect(view.state.title == "cmux-title-fixture")
    }

    @Test("pageZoom round-trips through CmuxBrowserView")
    func testPageZoom() {
        let view = CmuxBrowserView(frame: NSRect(x: 0, y: 0, width: 100, height: 100),
                                   configuration: webKitConfig())
        #expect(view.pageZoom == 1.0)
        view.pageZoom = 1.5
        #expect(view.pageZoom == 1.5)
        #expect(view.state.pageZoom == 1.5)
    }

    @Test("state.url emits via Combine when WKWebView loads")
    func testCombinePublisher() async throws {
        let view = CmuxBrowserView(frame: NSRect(x: 0, y: 0, width: 100, height: 100),
                                   configuration: webKitConfig())
        // Subscribe before the load to catch the transition.
        var received: [URL?] = []
        let cancellable = view.state.$url.sink { url in received.append(url) }
        defer { cancellable.cancel() }

        let target = URL(string: "data:text/html,<html></html>")!
        _ = view.load(target)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
            if received.contains(where: { $0 != nil }) { break }
        }
        #expect(received.contains(where: { $0 != nil }))
    }
}

@Suite("CmuxDataStore")
@MainActor
struct CmuxDataStoreSuite {
    @Test("default + nonPersistent produce distinct backing stores")
    func testDefaultVsNonPersistent() {
        let a = CmuxDataStore.default()
        let b = CmuxDataStore.nonPersistent()
        #expect(a.kind == .default)
        #expect(b.kind == .nonPersistent)
        #expect(a.wkStore !== b.wkStore)
        #expect(a.wkStore?.isPersistent == true)
        #expect(b.wkStore?.isPersistent == false)
    }

    @Test("forIdentifier round-trips the UUID")
    func testForIdentifier() {
        let id = UUID()
        let s = CmuxDataStore.forIdentifier(id)
        if case .persistent(let identifier) = s.kind {
            #expect(identifier == id)
        } else {
            Issue.record("expected .persistent kind")
        }
        #expect(s.wkStore != nil)
    }

    @Test("allDataTypes is a non-empty WebKit set")
    func testAllDataTypes() {
        let types = CmuxDataStore.allDataTypes()
        #expect(!types.isEmpty)
        // WKWebsiteDataTypeCookies is the most stable member of the set.
        #expect(types.contains("WKWebsiteDataTypeCookies"))
    }

    @Test("cookieStore is cached")
    func testCookieStoreIsCached() {
        let s = CmuxDataStore.default()
        let a = s.cookieStore
        let b = s.cookieStore
        #expect(a === b)
    }

    @Test("removeData succeeds against nonPersistent store")
    func testRemoveDataNonPersistent() async {
        let s = CmuxDataStore.nonPersistent()
        // Smoke test: WK's nonPersistent store accepts removeData for
        // any subset of types without erroring. We just await completion.
        await s.removeData(ofTypes: CmuxDataStore.allDataTypes(),
                           modifiedSince: .distantPast)
    }

    @Test("WebKit backend honors configuration.dataStore")
    func testConfigBindsDataStore() {
        let id = UUID()
        let store = CmuxDataStore.forIdentifier(id)
        let c = CmuxBrowserConfiguration()
        c.engineKind = .webKit
        c.dataStore = store
        let view = CmuxBrowserView(frame: NSRect(x: 0, y: 0, width: 100, height: 100),
                                   configuration: c)
        let backend = view.backend as? WebKitBrowserBackend
        #expect(backend?.webView.configuration.websiteDataStore === store.wkStore)
    }
}

@Suite("CmuxCookieStore")
@MainActor
struct CmuxCookieStoreSuite {
    @Test("set + read round-trips through nonPersistent store")
    func testSetAndRead() async throws {
        let s = CmuxDataStore.nonPersistent()
        let jar = s.cookieStore
        let probe = HTTPCookie(properties: [
            .name: "cmux_engine_probe",
            .value: "ok",
            .domain: "cmux.example",
            .path: "/",
        ])!
        await jar.setCookie(probe)
        let all = await jar.allCookies()
        let match = all.first(where: { $0.name == "cmux_engine_probe" })
        #expect(match != nil)
        #expect(match?.value == "ok")
    }

    @Test("delete removes a previously-set cookie")
    func testDelete() async {
        let s = CmuxDataStore.nonPersistent()
        let jar = s.cookieStore
        let cookie = HTTPCookie(properties: [
            .name: "cmux_engine_delete_me",
            .value: "v",
            .domain: "cmux-delete.example",
            .path: "/",
        ])!
        await jar.setCookie(cookie)
        await jar.deleteCookie(cookie)
        let all = await jar.allCookies()
        let stillThere = all.first(where: { $0.name == "cmux_engine_delete_me" })
        #expect(stillThere == nil)
    }

    @Test("observer fires on mutation")
    func testObserver() async throws {
        let s = CmuxDataStore.nonPersistent()
        let jar = s.cookieStore
        final class Counter: CmuxCookieStoreObserver, @unchecked Sendable {
            nonisolated(unsafe) var count = 0
            func cookiesDidChange(in store: CmuxCookieStore) { count += 1 }
        }
        let o = Counter()
        jar.addObserver(o)
        let cookie = HTTPCookie(properties: [
            .name: "cmux_engine_observer",
            .value: "v",
            .domain: "cmux-obs.example",
            .path: "/",
        ])!
        await jar.setCookie(cookie)
        // Observer fires asynchronously; poll briefly.
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
            if o.count > 0 { break }
        }
        #expect(o.count > 0)
        jar.removeObserver(o)
    }
}

@Suite("CmuxDownload")
@MainActor
struct CmuxDownloadSuite {
    @Test("constructs with a stable UUID and the original request")
    func testConstruct() {
        let req = URLRequest(url: URL(string: "https://cmux.example/file.bin")!)
        let d = CmuxDownload(wkDownload: nil, originalRequest: req)
        #expect(d.originalRequest?.url?.absoluteString == "https://cmux.example/file.bin")
        // UUID is fresh per instance
        let d2 = CmuxDownload(wkDownload: nil, originalRequest: nil)
        #expect(d.id != d2.id)
    }

    @Test("downloadDelegate is settable on CmuxBrowserView (WebKit backend)")
    func testDelegateAssign() {
        final class FakeDelegate: CmuxDownloadDelegate {
            func cmuxDownload(
                _ download: CmuxDownload,
                decideDestinationUsing response: URLResponse,
                suggestedFilename: String,
                completionHandler: @escaping (URL?) -> Void
            ) {
                completionHandler(nil)
            }
        }
        let c = CmuxBrowserConfiguration()
        c.engineKind = .webKit
        let view = CmuxBrowserView(frame: NSRect(x: 0, y: 0, width: 50, height: 50),
                                   configuration: c)
        let delegate = FakeDelegate()
        view.downloadDelegate = delegate
        #expect(view.downloadDelegate === delegate)
    }
}

@Suite("CmuxSnapshotConfiguration")
@MainActor
struct CmuxSnapshotConfigurationSuite {
    @Test("default config has WK-compatible defaults")
    func testDefaults() {
        let c = CmuxSnapshotConfiguration()
        #expect(c.rect == .zero)
        #expect(c.snapshotWidth == nil)
        #expect(c.afterScreenUpdates == true)
    }

    @Test("forwards rect + width to WKSnapshotConfiguration")
    func testForwarding() {
        let r = CGRect(x: 0, y: 0, width: 200, height: 100)
        let c = CmuxSnapshotConfiguration(rect: r, snapshotWidth: 800, afterScreenUpdates: false)
        let wk = c.makeWKConfiguration()
        #expect(wk.rect == r)
        #expect(wk.snapshotWidth?.doubleValue == 800)
        #expect(wk.afterScreenUpdates == false)
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

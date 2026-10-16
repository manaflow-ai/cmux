import AppKit
import Foundation
import Testing
import WebKit

@testable import CmuxBrowser

/// A Chromium page stand-in: answers DevTools methods from canned replies
/// and records every call, like the CEF page over the shim.
@MainActor
private final class ScriptedChromiumPage: BrowserPage {
    var isClosed = false
    private(set) var calls: [(method: String, params: [String: Any])] = []
    private(set) var evaluations: [(script: String, isAsync: Bool, world: BrowserPageScriptWorld)] = []
    private var replies: [String: [Result<String, BrowserEngineError>]] = [:]
    var evaluationResult: Result<NSNumber?, BrowserEngineError> = .success(nil)

    func reply(_ method: String, _ result: Result<String, BrowserEngineError>) {
        replies[method, default: []].append(result)
    }

    func methods() -> [String] { calls.map(\.method) }

    let engineKind = BrowserEngineKind.chromium
    let capabilities: BrowserEngineCapabilities = [.devToolsProtocol, .trustedInput, .snapshots]
    let presentation = BrowserPagePresentation.inView
    let contentView = NSView()
    var state = BrowserPageState()
    var events: AsyncStream<BrowserPageEvent> { AsyncStream { $0.finish() } }
    weak var uiDelegate: (any BrowserPageUIDelegate)?
    var pageZoom: Double = 1
    var isDevToolsVisible: Bool { false }
    var isMuted = false

    func load(_ request: URLRequest) {}
    func loadHTMLString(_ html: String, baseURL: URL?) {}
    func goBack() {}
    func goForward() {}
    func reload() {}
    func reloadFromOrigin() {}
    func stop() {}

    func evaluateJavaScript(_ script: String, in world: BrowserPageScriptWorld) async throws -> Any? {
        evaluations.append((script, false, world))
        return try evaluationResult.get()
    }

    func callAsyncJavaScript(
        _ body: String,
        arguments: [String: any Sendable],
        in world: BrowserPageScriptWorld
    ) async throws -> Any? {
        evaluations.append((body, true, world))
        return try evaluationResult.get()
    }

    func addUserScript(_ script: BrowserPageUserScript) {}
    func removeAllUserScripts() {}
    func showDevTools() {}
    func closeDevTools() {}

    func sendDevToolsProtocolMessage(method: String, params: Data?) async throws -> Data {
        if isClosed { throw BrowserEngineError.pageClosed }
        let decoded = params.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
        calls.append((method, decoded))
        guard var queue = replies[method], !queue.isEmpty else { return Data("{}".utf8) }
        let next = queue.removeFirst()
        replies[method] = queue
        return Data(try next.get().utf8)
    }

    func takeSnapshot(rect: CGRect?) async throws -> NSImage { throw BrowserEngineError.unsupported("snapshot") }
    func setFocused(_ focused: Bool) -> Bool { false }
    func setContentVisible(_ visible: Bool) {}
    func dispatchInput(_ event: BrowserPageInputEvent) async throws {}
    func exportRestoreState() -> BrowserPageRestoreState? { nil }
    func close() { isClosed = true }
}

@MainActor
@Suite("Browser page automation on a Chromium page")
struct ChromiumBrowserPageAutomationTests {
    @Test("Expressions and async bodies go through the page's own evaluation")
    func evaluateRoutesThroughPage() async throws {
        let page = ScriptedChromiumPage()
        page.evaluationResult = .success(NSNumber(value: 3))
        let automation = BrowserPageAutomation(page: page)

        let value = try await automation.evaluate("1 + 2", form: .expression, world: .page)
        _ = try await automation.evaluate("return 1;", form: .asyncFunctionBody, world: .automation)

        #expect((value as? NSNumber)?.intValue == 3)
        #expect(page.evaluations.map(\.isAsync) == [false, true])
        #expect(page.evaluations[1].world == .isolated("cmux-automation"))
        #expect(page.calls.isEmpty)
    }

    @Test("Document-start scripts enable the Page domain before registration")
    func documentStartScriptEnablesPageDomain() async throws {
        let page = ScriptedChromiumPage()
        let automation = BrowserPageAutomation(page: page)

        try await automation.addScriptOnNewDocument("window.__dfbInit = true;")

        #expect(page.methods() == [
            "Page.enable", "Page.addScriptToEvaluateOnNewDocument",
        ])
        #expect(page.calls[1].params["source"] as? String == "window.__dfbInit = true;")
    }

    @Test("A script exception keeps its message")
    func scriptException() async {
        let page = ScriptedChromiumPage()
        page.evaluationResult = .failure(.javaScript("ReferenceError: nope is not defined"))
        let automation = BrowserPageAutomation(page: page)

        await #expect(throws: BrowserAutomationPageError.javaScript("ReferenceError: nope is not defined")) {
            _ = try await automation.evaluate("nope", form: .expression, world: .page)
        }
    }

    @Test("A closed page reports unavailable")
    func closedPage() async {
        let page = ScriptedChromiumPage()
        page.close()
        let automation = BrowserPageAutomation(page: page)

        await #expect(throws: BrowserAutomationPageError.pageUnavailable(nil)) {
            _ = try await automation.captureViewportPNG()
        }
    }

    @Test("Screenshots decode Page.captureScreenshot's base64 PNG")
    func screenshotDecodes() async throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let page = ScriptedChromiumPage()
        page.reply("Page.captureScreenshot", .success(#"{"data":"\#(png.base64EncodedString())"}"#))

        #expect(try await BrowserPageAutomation(page: page).captureViewportPNG() == png)
        #expect(page.calls.first?.params["format"] as? String == "png")
    }

    @Test("Cookies read from Network.getAllCookies keep host-only and session semantics")
    func cookiesRead() async throws {
        let page = ScriptedChromiumPage()
        page.reply("Network.getAllCookies", .success(#"""
        {"cookies":[
          {"name":"host","value":"1","domain":"example.com","path":"/","expires":-1,"session":true,"secure":false,"httpOnly":false},
          {"name":"wide","value":"2","domain":".example.com","path":"/app","expires":2000000000,"session":false,"secure":true,"httpOnly":true}
        ]}
        """#))

        let cookies = try await BrowserPageAutomation(page: page).allCookies()

        #expect(cookies.count == 2)
        let host = try #require(cookies.first { $0.name == "host" })
        #expect(host.domain == "example.com")
        #expect(host.isSessionOnly)
        let wide = try #require(cookies.first { $0.name == "wide" })
        #expect(wide.domain == ".example.com")
        #expect(wide.path == "/app")
        #expect(wide.isSecure)
        #expect(wide.isHTTPOnly)
        #expect(wide.expiresDate == Date(timeIntervalSince1970: 2_000_000_000))
    }

    @Test("A host-only cookie is set by URL, a domain cookie by its dotted domain")
    func cookiesWrite() async throws {
        let page = ScriptedChromiumPage()
        let automation = BrowserPageAutomation(page: page)
        let hostOnly = try #require(HTTPCookie(properties: [
            .name: "a", .value: "1", .domain: "example.com", .path: "/", .secure: "TRUE",
        ]))
        let domain = try #require(HTTPCookie(properties: [
            .name: "b", .value: "2", .domain: ".example.com", .path: "/",
        ]))

        try await automation.setCookie(hostOnly)
        try await automation.setCookie(domain)
        try await automation.deleteCookie(domain)

        #expect(page.methods() == ["Network.setCookie", "Network.setCookie", "Network.deleteCookies"])
        #expect(page.calls[0].params["url"] as? String == "https://example.com/")
        #expect(page.calls[0].params["domain"] == nil)
        #expect(page.calls[1].params["domain"] as? String == ".example.com")
        #expect(page.calls[1].params["url"] == nil)
        #expect(page.calls[2].params["name"] as? String == "b")
    }

    @Test("A rejected cookie is an error, not a silent success")
    func cookieRejected() async throws {
        let page = ScriptedChromiumPage()
        page.reply("Network.setCookie", .success(#"{"success":false}"#))
        let cookie = try #require(HTTPCookie(properties: [.name: "a", .value: "1", .domain: "example.com", .path: "/"]))

        await #expect(throws: BrowserAutomationPageError.self) {
            try await BrowserPageAutomation(page: page).setCookie(cookie)
        }
    }

    @Test("Viewport overrides set and clear device metrics")
    func viewportOverride() async throws {
        let page = ScriptedChromiumPage()
        let automation = BrowserPageAutomation(page: page)
        #expect(automation.supportsViewportOverride)

        try await automation.setViewportOverride(width: 390, height: 844)
        try await automation.setViewportOverride(width: nil, height: nil)

        #expect(page.methods() == ["Emulation.setDeviceMetricsOverride", "Emulation.clearDeviceMetricsOverride"])
        #expect((page.calls[0].params["width"] as? NSNumber)?.intValue == 390)
        #expect((page.calls[0].params["height"] as? NSNumber)?.intValue == 844)
    }

    @Test("Geolocation and offline overrides use DevTools emulation")
    func emulation() async throws {
        let page = ScriptedChromiumPage()
        let automation = BrowserPageAutomation(page: page)
        let position = try #require(BrowserGeolocationOverride(latitude: 37.77, longitude: -122.42, accuracy: 5))

        page.reply("Page.addScriptToEvaluateOnNewDocument", .success(#"{"identifier":"7"}"#))
        let overrides = BrowserEmulationOverrides(geolocation: position, offline: true)
        let script = try await automation.applyEmulation(overrides)
        let cleared = try await automation.applyEmulation(BrowserEmulationOverrides(), replacingDocumentScript: script)

        #expect(script == "7")
        #expect(cleared == nil)
        #expect(page.methods() == [
            "Emulation.setGeolocationOverride", "Network.emulateNetworkConditions",
            "Network.setBlockedURLs", "Page.enable", "Page.addScriptToEvaluateOnNewDocument",
            "Emulation.clearGeolocationOverride", "Network.emulateNetworkConditions",
            "Network.setBlockedURLs",
            "Page.removeScriptToEvaluateOnNewDocument",
        ])
        #expect((page.calls[0].params["latitude"] as? NSNumber)?.doubleValue == 37.77)
        #expect(page.calls[1].params["offline"] as? Bool == true)
        #expect(page.calls[2].params["urlPatterns"] as? [String] == ["*"])
        // New documents get WebKit's emulation page script, so geolocation
        // answers from the override without a permission prompt.
        #expect(page.calls[4].params["source"] as? String == overrides.pageScript(dispatchesChangeEvents: false))
        #expect(page.calls[6].params["offline"] as? Bool == false)
        #expect(page.calls[7].params["urlPatterns"] as? [String] == [])
        #expect(page.calls[8].params["identifier"] as? String == "7")
        // The loaded document gets it too, both times (the second resets it).
        #expect(page.evaluations.map(\.script) == [
            overrides.pageScript(dispatchesChangeEvents: true),
            BrowserEmulationOverrides().pageScript(dispatchesChangeEvents: true),
        ])
        #expect(page.evaluations.allSatisfy { $0.world == .page })
    }

    @Test("Mouse steps and text insertion are trusted DevTools input")
    func mouseAndText() async throws {
        let page = ScriptedChromiumPage()
        let automation = BrowserPageAutomation(page: page)

        try await automation.dispatchMouse(.moved, x: 10, y: 20)
        try await automation.dispatchMouse(.pressed, x: 10, y: 20, button: .left, clickCount: 1, modifiers: [.shift])
        try await automation.dispatchMouse(.wheel, x: 10, y: 20, deltaY: 120)
        try await automation.insertText("héllo")

        #expect(page.methods() == [
            "Input.dispatchMouseEvent", "Input.dispatchMouseEvent", "Input.dispatchMouseEvent", "Input.insertText",
        ])
        #expect(page.calls[0].params["type"] as? String == "mouseMoved")
        #expect(page.calls[0].params["button"] as? String == "none")
        #expect(page.calls[1].params["type"] as? String == "mousePressed")
        #expect(page.calls[1].params["button"] as? String == "left")
        #expect((page.calls[1].params["clickCount"] as? NSNumber)?.intValue == 1)
        #expect((page.calls[1].params["modifiers"] as? NSNumber)?.intValue == 8)
        #expect((page.calls[2].params["deltaY"] as? NSNumber)?.doubleValue == 120)
        #expect(page.calls[3].params["text"] as? String == "héllo")
    }

    @Test("Key presses are trusted DevTools key events")
    func keyPress() async throws {
        let page = ScriptedChromiumPage()
        let automation = BrowserPageAutomation(page: page)
        #expect(automation.supportsTrustedKeys)
        let enter = try #require(BrowserKeyboardEvent(rawKey: "Enter"))

        try await automation.dispatchKey(enter, action: .press, modifiers: [])

        #expect(page.methods() == ["Input.dispatchKeyEvent", "Input.dispatchKeyEvent"])
        #expect(page.calls[0].params["type"] as? String == "keyDown")
        #expect(page.calls[0].params["text"] as? String == "\r")
        #expect((page.calls[0].params["windowsVirtualKeyCode"] as? NSNumber)?.intValue == 13)
        #expect(page.calls[1].params["type"] as? String == "keyUp")
    }
}

@MainActor
@Suite("Browser page automation on a WebKit page")
struct WebKitBrowserPageAutomationTests {
    @Test("WebKit pages evaluate through WKWebView and keep native key and viewport paths")
    func webKitRouting() async throws {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200), configuration: WKWebViewConfiguration())
        let automation = BrowserPageAutomation(page: WebKitBrowserPage(webView: webView))

        #expect(automation.engine == .webkit)
        #expect(!automation.supportsTrustedKeys)
        #expect(!automation.supportsViewportOverride)
        let value = try await automation.evaluate("return 6 * 7;", form: .asyncFunctionBody, world: .page)
        #expect((value as? NSNumber)?.intValue == 42)
        await #expect(throws: BrowserAutomationPageError.self) {
            _ = try await automation.evaluate("throw new Error('boom')", form: .expression, world: .page)
        }
    }

    @Test("WebKit cookies round-trip through the data store")
    func webKitCookies() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let automation = BrowserPageAutomation(page: WebKitBrowserPage(webView: webView))
        let cookie = try #require(HTTPCookie(properties: [
            .name: "k", .value: "v", .domain: "example.com", .path: "/",
        ]))

        try await automation.setCookie(cookie)
        #expect(try await automation.allCookies().contains { $0.name == "k" && $0.value == "v" })
        try await automation.deleteCookie(cookie)
        #expect(try await automation.allCookies().allSatisfy { $0.name != "k" })
    }
}

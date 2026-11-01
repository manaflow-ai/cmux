import AppKit
@testable import CmuxNextControl
import CmuxNextSettings
import Foundation
import Testing
import WebKit
import CmuxNextTestSupport

/// `browser.page.mouse|wheel|insert_text|key`: raw input at a point or on the focused element of
/// an app browser tab, which daemon `browser.input.mouse|wheel|text|key` route to for a page the
/// app draws (WebKit or CEF). The scripts run in a real WebKit page here; the page's listeners
/// record what it saw.
@MainActor @Suite(.closesItsWindows, .serialized, .timeLimit(.minutes(2))) struct BrowserPageRawInputTests {
    static let html = """
    <!doctype html><html><head><style>
      body { margin: 0; font: 14px sans-serif; }
      #btn { position: absolute; left: 20px; top: 20px; width: 120px; height: 40px; }
      #target { position: absolute; left: 200px; top: 20px; width: 100px; height: 100px; background: #eee; }
      #list { position: absolute; left: 20px; top: 160px; width: 200px; height: 100px; overflow: auto; }
      #list div { height: 1000px; }
      #locked { position: absolute; left: 260px; top: 160px; width: 200px; height: 100px; overflow: auto; }
      #locked div { height: 1000px; }
      #name { position: absolute; left: 20px; top: 300px; width: 200px; }
      #edit { position: absolute; left: 260px; top: 300px; width: 200px; height: 40px; }
    </style></head><body>
      <button id="btn">Go</button>
      <div id="target"></div>
      <div id="list"><div></div></div>
      <div id="locked"><div></div></div>
      <input id="name" type="text">
      <div id="edit" contenteditable="true"></div>
      <script>
        window.log = [];
        window.clicks = 0;
        const record = (e) => window.log.push({ type: e.type, id: e.target.id || e.target.tagName, button: e.button,
          detail: e.detail, shift: !!e.shiftKey, meta: !!e.metaKey, ctrl: !!e.ctrlKey, alt: !!e.altKey,
          key: e.key, inputType: e.inputType, data: e.data, deltaY: e.deltaY });
        for (const type of ['pointerdown', 'mousedown', 'pointerup', 'mouseup', 'click', 'dblclick', 'auxclick',
          'contextmenu', 'mouseover', 'mousemove', 'pointermove', 'wheel', 'keydown', 'keypress', 'keyup',
          'beforeinput', 'input']) {
          document.addEventListener(type, record, true);
        }
        document.getElementById('btn').addEventListener('click', () => { window.clicks += 1; });
        document.getElementById('locked').addEventListener('wheel', (e) => e.preventDefault(), { passive: false });
      </script>
    </body></html>
    """

    /// A real WebKit page; its reads come back as JSON text (Sendable) and decode here.
    @MainActor final class Page: NSObject, WKNavigationDelegate {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 500), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        private var loaded: CheckedContinuation<Void, Never>?

        func load() async {
            window.contentView = webView
            webView.navigationDelegate = self
            await withCheckedContinuation { done in
                loaded = done
                webView.loadHTMLString(BrowserPageRawInputTests.html, baseURL: nil)
            }
        }

        nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            MainActor.assumeIsolated {
                loaded?.resume()
                loaded = nil
            }
        }

        /// The JSON text of an expression's value.
        func json(_ expression: String) async throws -> String? {
            try await webView.evaluateJavaScript("JSON.stringify(\(expression))") as? String
        }

        /// The JSON text of what an async function body returns.
        func jsonAsync(_ body: String) async throws -> String? {
            try await webView.callAsyncJavaScript("return JSON.stringify(await (async () => { \(body) })());",
                                                  arguments: [:], in: nil, contentWorld: .page) as? String
        }

        nonisolated static func decode(_ text: String?) -> JSONValue {
            guard let data = text?.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return .null }
            return JSONValue(foundation: object) ?? .null
        }

        /// A page expression's value, for the test's own reads.
        func read(_ expression: String) async throws -> JSONValue { Self.decode(try await json(expression)) }

        /// The middle of `#id` in viewport CSS px.
        func center(_ id: String) async throws -> (x: Double, y: Double) {
            let rect = try await read("(() => { const r = document.getElementById('\(id)').getBoundingClientRect(); return { x: r.left + r.width / 2, y: r.top + r.height / 2 }; })()")
            return (rect["x"]?.doubleValue ?? -1, rect["y"]?.doubleValue ?? -1)
        }

        func events(_ type: String) async throws -> [JSONValue] {
            try await read("window.log.filter((e) => e.type === '\(type)')").arrayValue ?? []
        }

        func clearLog() async throws { _ = try await json("(window.log = [], 0)") }
    }

    /// The page as the app's engine runs it: `.evaluate` is one expression, its value the answer's `value`.
    struct WebPageEngine: BrowserPageEngine {
        let page: Page

        func run(_ operation: BrowserPageOperation, tabID: String, url: String?) async throws -> JSONValue {
            switch operation {
            case .evaluate(let script):
                return ["value": Page.decode(try await page.json(script))]
            case .evaluateAsync(let body):
                return ["value": Page.decode(try await page.jsonAsync(body))]
            default:
                return [:]
            }
        }
    }

    private func install() async -> (ControlRouter, Page) {
        _ = NSApplication.shared
        let router = ControlRouter(identity: testIdentity(), executor: RecordingExecutor(), configuration: .loadTolerant)
        let page = Page()
        await page.load()
        BrowserPageService(engine: WebPageEngine(page: page)).install(on: router)
        var snapshot = ControlSnapshot.sample()
        let tab = ControlTabInfo(id: "tab_0123abcd", surface: "12", kind: "browser", title: "Input", url: "about:blank")
        snapshot.topology.workspaces[0].screens[0].panes[0].tabs.append(tab)
        router.snapshots.publish { $0 = snapshot }
        return (router, page)
    }

    private func call(_ router: ControlRouter, _ verb: String, _ params: [String: JSONValue]) async -> Result<JSONValue, ControlError> {
        var params = params
        params["tab"] = "tab_0123abcd"
        return await router.handle(ControlRequest(method: "browser.page." + verb, params: params))
    }

    @Test func aMouseDownAndUpOnAButtonClicksIt() async throws {
        let (router, page) = await install()
        defer { page.window.closeAfterTest() }
        let at = try await page.center("btn")
        _ = try await call(router, "mouse", ["kind": "down", "x": .number(at.x), "y": .number(at.y)]).get()
        _ = try await call(router, "mouse", ["kind": "up", "x": .number(at.x), "y": .number(at.y)]).get()
        #expect(try await page.read("window.clicks") == 1)
        let order = try await page.read("window.log.map((e) => e.type)").arrayValue?.compactMap(\.stringValue) ?? []
        #expect(order.filter { ["pointerdown", "mousedown", "pointerup", "mouseup", "click"].contains($0) }
            == ["pointerdown", "mousedown", "pointerup", "mouseup", "click"])
        #expect(try await page.events("click").first?["id"] == "btn")
    }

    @Test func aDoubleClickCountsTwoAndFiresDblclick() async throws {
        let (router, page) = await install()
        defer { page.window.closeAfterTest() }
        let at = try await page.center("target")
        _ = try await call(router, "mouse", ["kind": "down", "x": .number(at.x), "y": .number(at.y), "click_count": 2]).get()
        _ = try await call(router, "mouse", ["kind": "up", "x": .number(at.x), "y": .number(at.y), "click_count": 2]).get()
        #expect(try await page.events("mousedown").first?["detail"] == 2)
        #expect(try await page.events("dblclick").count == 1)
    }

    @Test func theRightButtonOpensAContextMenuEventAndClicksNothing() async throws {
        let (router, page) = await install()
        defer { page.window.closeAfterTest() }
        let at = try await page.center("btn")
        _ = try await call(router, "mouse", ["kind": "down", "x": .number(at.x), "y": .number(at.y), "button": "right"]).get()
        _ = try await call(router, "mouse", ["kind": "up", "x": .number(at.x), "y": .number(at.y), "button": "right"]).get()
        #expect(try await page.events("mousedown").first?["button"] == 2)
        #expect(try await page.events("contextmenu").count == 1)
        #expect(try await page.events("auxclick").count == 1)
        #expect(try await page.read("window.clicks") == 0)
    }

    @Test func aMoveHoversTheElementUnderThePoint() async throws {
        let (router, page) = await install()
        defer { page.window.closeAfterTest() }
        let at = try await page.center("target")
        _ = try await call(router, "mouse", ["kind": "move", "x": .number(at.x), "y": .number(at.y)]).get()
        #expect(try await page.events("mouseover").first?["id"] == "target")
        #expect(try await page.events("mousemove").first?["id"] == "target")
        try await page.clearLog()
        _ = try await call(router, "mouse", ["kind": "move", "x": .number(at.x + 1), "y": .number(at.y)]).get()
        #expect(try await page.events("mouseover").isEmpty, "the same element is not entered twice")
    }

    @Test func mouseEventsCarryTheirModifiers() async throws {
        let (router, page) = await install()
        defer { page.window.closeAfterTest() }
        let at = try await page.center("target")
        _ = try await call(router, "mouse", ["kind": "down", "x": .number(at.x), "y": .number(at.y),
                                             "modifiers": ["shift", "meta"]]).get()
        let down = try #require(try await page.events("mousedown").first)
        #expect(down["shift"] == true)
        #expect(down["meta"] == true)
        #expect(down["ctrl"] == false)
    }

    @Test func aWheelAtAPointScrollsTheBoxUnderIt() async throws {
        let (router, page) = await install()
        defer { page.window.closeAfterTest() }
        let list = try await page.center("list")
        _ = try await call(router, "wheel", ["x": .number(list.x), "y": .number(list.y), "dx": 0, "dy": 120]).get()
        #expect(try await page.events("wheel").first?["deltaY"] == 120)
        #expect(try await page.read("document.getElementById('list').scrollTop") == 120)
        let locked = try await page.center("locked")
        _ = try await call(router, "wheel", ["x": .number(locked.x), "y": .number(locked.y), "dx": 0, "dy": 120]).get()
        #expect(try await page.read("document.getElementById('locked').scrollTop") == 0, "a page that cancels the wheel keeps its place")
    }

    @Test func insertTextGoesIntoTheFocusedField() async throws {
        let (router, page) = await install()
        defer { page.window.closeAfterTest() }
        _ = try await call(router, "focus", ["selector": "#name"]).get()
        _ = try await call(router, "insert_text", ["text": "hello"]).get()
        _ = try await call(router, "insert_text", ["text": " world"]).get()
        #expect(try await page.read("document.getElementById('name').value") == "hello world")
        let input = try #require(try await page.events("input").first)
        #expect(input["inputType"] == "insertText")
        #expect(input["data"] == "hello")
        _ = try await call(router, "focus", ["selector": "#edit"]).get()
        _ = try await call(router, "insert_text", ["text": "rich"]).get()
        #expect(try await page.read("document.getElementById('edit').textContent") == "rich")
    }

    @Test func insertTextWithNoFocusedFieldIsRefused() async throws {
        let (router, page) = await install()
        defer { page.window.closeAfterTest() }
        _ = try await page.json("(document.activeElement && document.activeElement.blur(), 0)")
        #expect(await call(router, "insert_text", ["text": "x"]).failure?.code == "not_editable")
    }

    @Test func keyDownAndUpAreSeparateAndCarryModifiers() async throws {
        let (router, page) = await install()
        defer { page.window.closeAfterTest() }
        _ = try await call(router, "focus", ["selector": "#name"]).get()
        _ = try await call(router, "key", ["key": "k", "kind": "down", "modifiers": ["meta"]]).get()
        let down = try #require(try await page.events("keydown").first)
        #expect(down["key"] == "k")
        #expect(down["meta"] == true)
        #expect(try await page.events("keyup").isEmpty)
        _ = try await call(router, "key", ["key": "k", "kind": "up", "modifiers": ["meta"]]).get()
        #expect(try await page.events("keyup").count == 1)
        #expect(try await page.read("document.getElementById('name').value") == "", "a shortcut types nothing")
    }

    @Test func aShiftedKeyPressTypesItsCharacter() async throws {
        let (router, page) = await install()
        defer { page.window.closeAfterTest() }
        _ = try await call(router, "focus", ["selector": "#name"]).get()
        _ = try await call(router, "key", ["key": "A", "kind": "press", "modifiers": ["shift"]]).get()
        #expect(try await page.read("document.getElementById('name').value") == "A")
        #expect(try await page.events("keypress").first?["shift"] == true)
    }

    @Test func badParamsAreRefused() async throws {
        let (router, page) = await install()
        defer { page.window.closeAfterTest() }
        #expect(await call(router, "mouse", ["kind": "down", "y": 1]).failure?.code == "invalid_params")
        #expect(await call(router, "mouse", ["kind": "drag", "x": 1, "y": 1]).failure?.code == "invalid_params")
        #expect(await call(router, "mouse", ["kind": "down", "x": 1, "y": 1, "button": "thumb"]).failure?.code == "invalid_params")
        #expect(await call(router, "mouse", ["kind": "down", "x": 1, "y": 1, "modifiers": ["hyper"]]).failure?.code == "invalid_params")
        #expect(await call(router, "wheel", ["x": 1, "y": 1]).failure?.code == "invalid_params")
        #expect(await call(router, "key", ["key": "a", "kind": "hold"]).failure?.code == "invalid_params")
        #expect(await call(router, "insert_text", [:]).failure?.code == "invalid_params")
    }
}

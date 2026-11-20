import AppKit
@testable import CmuxNextControl
import CmuxNextSettings
import Foundation
import Testing
import WebKit
import CmuxNextTestSupport

/// `browser.page.snapshot`: the agent's page outline (`- role "name" [ref=eN]`) as real sites need it.
/// Accessible names from images, SVG titles, labels and `aria-labelledby`; open shadow roots and
/// same-origin frames walked, with refs that click there; `cursor: pointer` clickables; control
/// state; select options; and offscreen refs marked. The scripts run in a real WebKit page.
@MainActor @Suite(.closesItsWindows, .serialized, .timeLimit(.minutes(2))) struct BrowserPageSnapshotTests {
    static let html = """
    <!doctype html><html><head><title>Snapshot</title><style>
      body { margin: 0; font: 14px sans-serif; }
      .votearrow { width: 10px; height: 10px; background: #999; }
      #far { position: absolute; left: 10px; top: 3000px; }
    </style></head><body>
      <a id="up" href="#up"><div class="votearrow" title="upvote"></div></a>
      <button id="imgbtn"><img alt="Search icon" width="10" height="10" src="data:image/gif;base64,R0lGODlhAQABAIAAAP///wAAACH5BAEAAAAALAAAAAABAAEAAAICRAEAOw=="></button>
      <a id="svglink" href="#settings"><svg width="10" height="10"><title>Settings</title><rect width="10" height="10"></rect></svg></a>
      <button id="childlabel"><span aria-label="Close dialog"></span></button>
      <span id="lbl">Delete item</span><button id="labelled" aria-labelledby="lbl">X</button>
      <label for="email">Email address</label><input id="email" type="email">
      <label>Remember me <input id="remember" type="checkbox" checked></label>
      <input id="news" type="checkbox">
      <input id="go" type="submit" value="Send now">
      <input id="pw" type="password" value="hunter2secret">
      <button id="off" disabled>Disabled one</button>
      <button id="menu" aria-expanded="false">Menu</button>
      <div id="ariacheck" role="checkbox" aria-checked="true" tabindex="0">Aria box</div>
      <label>Size <select id="size"><option>Small</option><option selected>Medium</option><option>Large</option></select></label>
      <select id="many" aria-label="Many"></select>
      <div id="pointer" style="cursor: pointer">Pointer card <span id="pointerinner">inner</span></div>
      <div id="editor" contenteditable="true" aria-label="Notes" style="min-height: 20px"></div>
      <div id="host"></div>
      <iframe id="frame" srcdoc="<button id='inner' onclick='parent.hits.push(&quot;frame&quot;)'>Frame button</button>"></iframe>
      <button id="far">Far away</button>
      <script>
        window.hits = [];
        const shadow = document.getElementById('host').attachShadow({ mode: 'open' });
        shadow.innerHTML = '<button id="shadowbtn">Shadow button</button>';
        shadow.getElementById('shadowbtn').addEventListener('click', () => window.hits.push('shadow'));
        document.getElementById('pointer').addEventListener('click', () => window.hits.push('pointer'));
        const many = document.getElementById('many');
        for (let i = 1; i <= 25; i++) { const o = document.createElement('option'); o.value = 'v' + i; o.textContent = 'Choice ' + i; many.appendChild(o); }
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
            _ = NSApplication.shared
            window.contentView = webView
            webView.navigationDelegate = self
            await withCheckedContinuation { done in
                loaded = done
                // A real origin, so the srcdoc frame is same-origin and readable.
                webView.loadHTMLString(BrowserPageSnapshotTests.html, baseURL: URL(string: "https://snapshot.cmux.test/"))
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
    }

    /// The fixture's elements, by the expression that reaches each.
    static func top(_ id: String) -> String { "document.getElementById('\(id)')" }
    static let inShadow = "document.getElementById('host').shadowRoot.getElementById('shadowbtn')"
    static let inFrame = "document.getElementById('frame').contentDocument.getElementById('inner')"

    private func loaded() async -> Page {
        let page = Page()
        await page.load()
        return page
    }

    private func snapshot(_ page: Page, interactive: Bool = false) async throws -> String {
        let value = try await page.read(BrowserPageScripts.snapshot(selector: nil, maxDepth: 12, interactiveOnly: interactive))
        return try #require(value["snapshot"]?.stringValue)
    }

    /// The ref the last snapshot gave the element `expression` reaches.
    private func ref(_ page: Page, _ expression: String) async throws -> String {
        let value = try await page.read("(() => { const e = \(expression); return e ? e.getAttribute('data-cmux-ref') : null; })()")
        return try #require(value.stringValue, "no ref on \(expression)")
    }

    /// The snapshot line of the element `expression` reaches.
    private func line(_ page: Page, _ outline: String, _ expression: String) async throws -> String {
        let ref = try await self.ref(page, expression)
        let found = outline.split(separator: "\n").map(String.init).first { $0.contains("[ref=\(ref)]") }
        return try #require(found, "no line for \(ref) in\n\(outline)")
    }

    @Test func namesComeFromImagesSvgTitlesChildLabelsAndLabels() async throws {
        let page = await loaded()
        defer { page.window.closeAfterTest() }
        let outline = try await snapshot(page)
        #expect(try await line(page, outline, Self.top("up")).contains("- link \"upvote\""))
        #expect(try await line(page, outline, Self.top("imgbtn")).contains("- button \"Search icon\""))
        #expect(try await line(page, outline, Self.top("svglink")).contains("- link \"Settings\""))
        #expect(try await line(page, outline, Self.top("childlabel")).contains("- button \"Close dialog\""))
        #expect(try await line(page, outline, Self.top("labelled")).contains("- button \"Delete item\""))
        #expect(try await line(page, outline, Self.top("email")).contains("- textbox \"Email address\""))
        #expect(try await line(page, outline, Self.top("remember")).contains("- checkbox \"Remember me\""))
        #expect(try await line(page, outline, Self.top("go")).contains("- button \"Send now\""))
        #expect(try await line(page, outline, Self.top("editor")).contains("- textbox \"Notes\""))
    }

    @Test func aPasswordValueNeverAppears() async throws {
        let page = await loaded()
        defer { page.window.closeAfterTest() }
        let outline = try await snapshot(page)
        #expect(try await line(page, outline, Self.top("pw")).contains("- textbox"))
        #expect(!outline.contains("hunter2secret"))
    }

    @Test func shadowRootAndFrameButtonsAppearAndTheirRefsClick() async throws {
        let page = await loaded()
        defer { page.window.closeAfterTest() }
        let outline = try await snapshot(page, interactive: true)
        #expect(try await line(page, outline, Self.inShadow).contains("- button \"Shadow button\""))
        #expect(try await line(page, outline, Self.inFrame).contains("- button \"Frame button\""))
        for expression in [Self.inShadow, Self.inFrame] {
            let ref = try await self.ref(page, expression)
            let clicked = try await page.read(BrowserPageScripts.click("@" + ref, nil))
            #expect(clicked["value"] == true, "click \(ref): \(clicked)")
            let found = try await page.read(BrowserPageScripts.wrap(BrowserPageScripts.find(ref) + "return { value: el.textContent };"))
            #expect(found["value"]?.stringValue?.isEmpty == false, "find \(ref): \(found)")
        }
        #expect(try await page.read("window.hits") == ["shadow", "frame"])
    }

    @Test func aPointerCursorMakesAClickableOnce() async throws {
        let page = await loaded()
        defer { page.window.closeAfterTest() }
        let outline = try await snapshot(page, interactive: true)
        let card = try await line(page, outline, Self.top("pointer"))
        #expect(card.contains("\"Pointer card inner\""))
        #expect(card.contains("[cursor=pointer]"))
        let inner = try await page.read("\(Self.top("pointerinner")).getAttribute('data-cmux-ref')")
        #expect(inner == .null, "a child that only inherits the pointer is not its own clickable")
        let ref = try await self.ref(page, Self.top("pointer"))
        #expect(try await page.read(BrowserPageScripts.click(ref, nil))["value"] == true)
        #expect(try await page.read("window.hits") == ["pointer"])
    }

    @Test func controlsShowTheirState() async throws {
        let page = await loaded()
        defer { page.window.closeAfterTest() }
        let outline = try await snapshot(page)
        #expect(try await line(page, outline, Self.top("remember")).contains("[checked]"))
        #expect(try await line(page, outline, Self.top("news")).contains("[checked=false]"))
        #expect(try await line(page, outline, Self.top("ariacheck")).contains("- checkbox \"Aria box\" [checked]"))
        #expect(try await line(page, outline, Self.top("off")).contains("[disabled]"))
        #expect(try await line(page, outline, Self.top("menu")).contains("[expanded=false]"))
        let up = try await line(page, outline, Self.top("up"))
        #expect(!up.contains("[disabled]"))
    }

    @Test func aSelectShowsItsValueAndListsItsOptions() async throws {
        let page = await loaded()
        defer { page.window.closeAfterTest() }
        let outline = try await snapshot(page, interactive: true)
        let lines = outline.split(separator: "\n").map(String.init)
        let size = try await line(page, outline, Self.top("size"))
        #expect(size.contains("- combobox \"Size\""))
        #expect(size.hasSuffix(": Medium"))
        let start = try #require(lines.firstIndex(of: size))
        let options = lines[(start + 1)...].prefix(3)
        #expect(options.map { $0.contains("- option \"Small\"") } == [true, false, false])
        #expect(options.dropFirst().first?.contains("- option \"Medium\" [selected]") == true)
        #expect(options.last?.contains("- option \"Large\"") == true)

        let many = try await line(page, outline, Self.top("many"))
        let manyStart = try #require(lines.firstIndex(of: many))
        let listed = lines[(manyStart + 1)...].prefix { $0.contains("- option") }
        #expect(listed.count == 20)
        let more = try #require(lines.dropFirst(manyStart + 21).first, "no line after the listed options")
        #expect(more.contains("5 more"))
    }

    @Test func refsOutsideTheViewportAreMarked() async throws {
        let page = await loaded()
        defer { page.window.closeAfterTest() }
        let outline = try await snapshot(page)
        #expect(try await line(page, outline, Self.top("far")).contains("[offscreen]"))
        let up = try await line(page, outline, Self.top("up"))
        #expect(!up.contains("[offscreen]"))
    }

    @Test func aNewSnapshotRetiresOldRefsEverywhere() async throws {
        let page = await loaded()
        defer { page.window.closeAfterTest() }
        _ = try await snapshot(page)
        let first = try await ref(page, Self.inFrame)
        _ = try await snapshot(page, interactive: true)
        let second = try await ref(page, Self.inFrame)
        let tagged = try await page.read("document.getElementById('frame').contentDocument.querySelectorAll('[data-cmux-ref]').length")
        #expect(tagged == 1)
        #expect(first.hasPrefix("e") && second.hasPrefix("e"))
    }
}

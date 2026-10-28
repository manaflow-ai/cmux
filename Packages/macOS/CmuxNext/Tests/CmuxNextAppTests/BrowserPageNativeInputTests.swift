import AppKit
@testable import CmuxNextApp
import CmuxNextBrowser
@testable import CmuxNextControl
@testable import CmuxNextDaemon
import CmuxNextSettings
import Foundation
import Testing

/// The control socket's JSON (CmuxNextDaemon has its own `JSONValue`).
typealias NativeInputJSON = CmuxNextSettings.JSONValue

/// `browser.page.mouse|wheel|insert_text|key` on an app browser tab are native input: real AppKit
/// events to the tab's web view, so the page sees trusted events (`isTrusted`) and the browser runs
/// its default actions (Tab moves focus, a held button drags). Agents drive real sites, which check
/// both. Page events stay only as the fallback when the page has no engine view (not in a window).
/// These run the app's own engine (`AppBrowserPageEngine`) on a real WebKit page.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2))) struct BrowserPageNativeInputTests {
    static let tabID = "tab_0123456789abcdef0123456789abcdef"
    static let html = """
    <!doctype html><title>native</title><style>
      body { margin: 0; font: 14px sans-serif; }
      #a { position: absolute; left: 20px; top: 20px; width: 160px; }
      #b { position: absolute; left: 20px; top: 60px; width: 160px; }
      #btn { position: absolute; left: 220px; top: 20px; width: 120px; height: 40px; }
      #list { position: absolute; left: 20px; top: 120px; width: 200px; height: 100px; overflow: auto; }
      #list div { height: 1000px; }
      #text { position: absolute; left: 20px; top: 260px; margin: 0; font: 20px monospace; white-space: nowrap; }
    </style>
    <input id="a"><input id="b"><button id="btn">Go</button><div id="list"><div></div></div>
    <p id="text">alpha bravo charlie delta</p>
    <script>
      window.log = []; window.clicks = 0;
      for (const type of ['mousedown', 'mouseup', 'click', 'mousemove', 'wheel', 'keydown', 'keyup', 'input']) {
        document.addEventListener(type, (e) => window.log.push({ type, trusted: e.isTrusted, buttons: e.buttons,
          id: e.target.id || e.target.tagName || '', key: e.key, x: e.clientX, y: e.clientY }), true);
      }
      document.getElementById('btn').addEventListener('click', () => { window.clicks += 1; });
    </script>
    """

    final class Fixture {
        let services: AppServices
        let router: ControlRouter
        let page: WebKitTab
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: false)
        let folder: URL

        init() async throws {
            _ = NSApplication.shared
            services = AppServices(environment: AppEnvironment.current([:]))
            let tab = TabSnapshot(surface: 1, tabResourceID: ResourceID(rawValue: BrowserPageNativeInputTests.tabID),
                                  kind: .browser, url: "about:blank")
            let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [PaneSnapshot(id: 1, tabs: [tab])])
            services.daemon.store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [screen])]))

            folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("cn-native-input-\(UUID().uuidString.prefix(8).lowercased())", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("page.html")
            try BrowserPageNativeInputTests.html.write(to: url, atomically: true, encoding: .utf8)
            page = services.cache.webKit.makeWebKitTab()
            _ = services.cache.install(page, for: BrowserPageNativeInputTests.tabID)
            window.isReleasedWhenClosed = false
            window.contentView = page.contentView
            window.orderFrontRegardless()
            page.load(url)

            router = ControlRouter(identity: ControlIdentity(version: "1.0", build: "1", bundleID: "com.cmuxterm.app.debug.test", tag: "test",
                                                             processID: getpid()),
                                   executor: RegistryControlBridge(registry: services.registry), settings: nil,
                                   configuration: ControlRouter.Configuration(requestDeadline: .seconds(30)))
            BrowserPageService(engine: AppBrowserPageEngine(services: services)).install(on: router)
            var snapshot = ControlSnapshot()
            var topology = ControlTopology()
            topology.isLoaded = true
            let info = ControlTabInfo(id: BrowserPageNativeInputTests.tabID, surface: "1", kind: "browser", title: "native", url: url.absoluteString)
            let pane = ControlPaneInfo(id: "pane-1", handle: "1", selectedTabID: info.id, tabs: [info])
            topology.workspaces = [ControlWorkspaceInfo(id: "ws-1", handle: "1", name: "w",
                                                        screens: [ControlScreenInfo(id: "screen-1", handle: "1", panes: [pane])])]
            snapshot.topology = topology
            router.snapshots.publish { $0 = snapshot }
            try await until("the page loads") { try await self.read("document.readyState === 'complete' && document.title") == "native" }
        }

        func call(_ verb: String, _ params: [String: NativeInputJSON]) async throws -> NativeInputJSON {
            var params = params
            params["tab"] = .string(BrowserPageNativeInputTests.tabID)
            return try await router.handle(ControlRequest(method: "browser.page." + verb, params: params)).get()
        }

        func read(_ expression: String) async throws -> NativeInputJSON {
            let value = try await page.evaluate("JSON.parse(JSON.stringify(\(expression)))", world: .page, gesture: .agent)
            return NativeInputJSON(foundation: value.foundationValue) ?? .null
        }

        func center(_ id: String) async throws -> (x: NativeInputJSON, y: NativeInputJSON) {
            let rect = try await read("(() => { const r = document.getElementById('\(id)').getBoundingClientRect(); return { x: r.left + r.width / 2, y: r.top + r.height / 2 }; })()")
            return (rect["x"] ?? .null, rect["y"] ?? .null)
        }

        func events(_ type: String) async throws -> [NativeInputJSON] {
            try await read("window.log.filter((e) => e.type === '\(type)')").arrayValue ?? []
        }

        func until(_ what: @autoclosure () -> String, _ condition: () async throws -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(10)
            while !((try? await condition()) ?? false), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(25)) }
            let log = (try? await read("window.log").compactText) ?? ""
            try #require(try await condition(), "\(what()) never happened; the page saw \(log)")
        }

        func close() {
            services.cache.release(BrowserPageNativeInputTests.tabID)
            window.orderOut(nil)
            try? FileManager.default.removeItem(at: folder)
        }
    }

    @Test func tabMovesFocusToTheNextFieldWithATrustedKey() async throws {
        let fixture = try await Fixture()
        defer { fixture.close() }
        _ = try await fixture.call("focus", ["selector": "#a"])
        let result = try await fixture.call("key", ["key": "Tab", "kind": "press"])
        #expect(result["native"] == true)
        try await fixture.until("Tab moved focus to #b") { try await fixture.read("document.activeElement.id") == "b" }
        let down = try #require(try await fixture.events("keydown").first)
        #expect(down["key"] == "Tab")
        #expect(down["trusted"] == true)
    }

    @Test func aClickIsTrusted() async throws {
        let fixture = try await Fixture()
        defer { fixture.close() }
        let at = try await fixture.center("btn")
        let result = try await fixture.call("mouse", ["kind": "click", "x": at.x, "y": at.y])
        #expect(result["native"] == true)
        try await fixture.until("the button was clicked") { try await fixture.read("window.clicks") == 1 }
        #expect(try await fixture.events("click").first?["trusted"] == true)
        #expect(try await fixture.events("mousedown").first?["trusted"] == true)
    }

    /// A move with the button held is a drag: it selects the text it crosses.
    @Test func aMoveWithTheButtonHeldDragsASelection() async throws {
        let fixture = try await Fixture()
        defer { fixture.close() }
        let box = try await fixture.read("(() => { const r = document.getElementById('text').getBoundingClientRect(); return { left: r.left, right: r.right, y: r.top + r.height / 2 }; })()")
        let left = (box["left"]?.doubleValue ?? 0) + 2, right = (box["right"]?.doubleValue ?? 0) - 2, y = box["y"]?.doubleValue ?? 0
        _ = try await fixture.call("mouse", ["kind": "down", "x": .number(left), "y": .number(y)])
        _ = try await fixture.call("mouse", ["kind": "move", "x": .number((left + right) / 2), "y": .number(y)])
        _ = try await fixture.call("mouse", ["kind": "move", "x": .number(right), "y": .number(y)])
        _ = try await fixture.call("mouse", ["kind": "up", "x": .number(right), "y": .number(y)])
        try await fixture.until("the drag selected the text") {
            (try await fixture.read("String(window.getSelection())").stringValue ?? "").contains("bravo charlie")
        }
        #expect(try await fixture.events("mousemove").contains { $0["trusted"] == true })
    }

    @Test func insertedTextIsTrustedTyping() async throws {
        let fixture = try await Fixture()
        defer { fixture.close() }
        _ = try await fixture.call("focus", ["selector": "#a"])
        let result = try await fixture.call("insert_text", ["text": "hello"])
        #expect(result["native"] == true)
        try await fixture.until("the text reached #a") { try await fixture.read("document.getElementById('a').value") == "hello" }
        #expect(try await fixture.events("input").first?["trusted"] == true)
    }

    /// A wheel scrolls the box under the point once. Where the window can refresh (on a screen,
    /// not occluded) it is a trusted native wheel only; where it cannot (the headless test Macs have
    /// no screen) WebKit would hold a native wheel, so the page-event wheel runs instead, decided
    /// before anything is sent.
    @Test func aWheelScrollsTheBoxUnderThePointOnce() async throws {
        let fixture = try await Fixture()
        defer { fixture.close() }
        let at = try await fixture.center("list")
        let refreshes = fixture.window.screen != nil
        let result = try await fixture.call("wheel", ["x": at.x, "y": at.y, "dy": 120])
        try await fixture.until("the list scrolled") {
            (try await fixture.read("document.getElementById('list').scrollTop").doubleValue ?? 0) > 0
        }
        let wheels = try await fixture.events("wheel")
        #expect(wheels.count == 1, "\(wheels)")
        #expect(result["native"] == .bool(refreshes))
        #expect(wheels.first?["trusted"] == .bool(refreshes))
    }

    /// An occluded window still on a screen (an agent's background tab) gets the native wheel:
    /// WebKit delivers it there, so the page sees one trusted wheel. Needs a host with a display.
    @Test(.enabled(if: !NSScreen.screens.isEmpty, "needs a display"))
    func anOccludedWindowOnAScreenGetsOneTrustedNativeWheel() async throws {
        let fixture = try await Fixture()
        defer { fixture.close() }
        try #require(fixture.window.screen != nil)
        let cover = NSWindow(contentRect: fixture.window.frame.insetBy(dx: -40, dy: -40), styleMask: [.borderless],
                             backing: .buffered, defer: false)
        cover.isReleasedWhenClosed = false
        cover.isOpaque = true
        cover.backgroundColor = .black
        cover.level = .floating
        cover.orderFrontRegardless()
        defer { cover.orderOut(nil) }
        try await fixture.until("the window is occluded") { !fixture.window.occlusionState.contains(.visible) }
        let at = try await fixture.center("list")
        let result = try await fixture.call("wheel", ["x": at.x, "y": at.y, "dy": 120])
        #expect(result["native"] == true)
        try await fixture.until("the list scrolled") {
            (try await fixture.read("document.getElementById('list').scrollTop").doubleValue ?? 0) > 0
        }
        let wheels = try await fixture.events("wheel")
        #expect(wheels.count == 1, "\(wheels)")
        #expect(wheels.first?["trusted"] == true)
    }

    /// A window on no screen cannot refresh: the wheel is page events at once (no wait for WebKit),
    /// and the box scrolls exactly once, by the wheel's delta.
    @Test func aWheelOnAWindowOffEveryScreenScrollsOnceAtOnce() async throws {
        let fixture = try await Fixture()
        defer { fixture.close() }
        // A borderless window: AppKit keeps a titled one on a screen.
        fixture.window.styleMask = [.borderless]
        fixture.window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
        try #require(fixture.window.screen == nil)
        let at = try await fixture.center("list")
        let started = ContinuousClock.now
        let result = try await fixture.call("wheel", ["x": at.x, "y": at.y, "dy": 120])
        let took = ContinuousClock.now - started
        #expect(result["native"] == false)
        #expect(took < .milliseconds(800), "the wheel waited \(took) for WebKit")
        #expect(try await fixture.read("document.getElementById('list').scrollTop") == 120)
        #expect(try await fixture.events("wheel").count == 1)
    }

    /// A page with no engine view (its web view is in no window) still takes the input, as page
    /// events: the click lands, untrusted, and the answer says so.
    @Test func aPageInNoWindowFallsBackToPageEvents() async throws {
        let fixture = try await Fixture()
        defer { fixture.close() }
        fixture.window.contentView = nil
        let at = try await fixture.center("btn")
        let result = try await fixture.call("mouse", ["kind": "click", "x": at.x, "y": at.y])
        #expect(result["native"] == false)
        #expect(try await fixture.read("window.clicks") == 1)
        #expect(try await fixture.events("click").first?["trusted"] == false)
    }
}

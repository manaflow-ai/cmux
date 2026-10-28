#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextCompat
import CmuxNextDesign
@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import CmuxNextSettings
import Foundation
import Testing

/// `debug.webui`: the census names every page with its engine, state and renderer,
/// attributes each Chromium helper to what it runs, and counts what reaches a page only while it is
/// hidden. A parked spare is hidden to the person (Chrome counts no spare renderer as visible).
@MainActor
struct DebugWebUITests {
    private let root: URL
    private let descriptor = PageDescriptor(id: "test.webui-census", resource: "webui-census", processGroup: .solo, namespaces: [])

    /// The keys of a page row, as WebUICensus documents them.
    static let pageKeys: Set<String> = [
        "page", "instance", "engine", "group", "state", "engine_visible", "hidden_for_s", "keep_reasons", "spare",
        "pooled", "window_number", "browser_id", "renderer_clients", "renderer_pids", "webkit_pid",
        "deliveries_while_hidden", "pushes_while_hidden",
    ]

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("webui-census-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<!doctype html><title>Page</title>".utf8).write(to: root.appendingPathComponent("index.html"))
    }

    private func makeHost(_ hosting: FakeChromiumHosting?) -> WebUIHost {
        WebUIHost(chromium: hosting, openPanel: nil,
                  memory: QuietMemoryRegistry(),
                  deadlines: LifecycleDeadlineRig.never)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    private func census(_ host: WebUIHost, newTabSpare: PageWebView? = nil, spareClients: [Int32] = [],
                        browserTabs: [WebUICensus.Host] = []) -> WebUICensus {
        WebUICensus(pages: host.registry.pages(), registry: host.registry, newTabSpare: newTabSpare,
                    spareWindows: [WebUICensus.Host(name: "cef_window", state: "live", rendererClients: spareClients)],
                    browserTabs: browserTabs,
                    rendererProcess: { _ in (browserID: 7, clients: [3]) }, webKitPID: { _ in 4242 })
    }

    private func firstRow(_ host: WebUIHost) throws -> JSONValue {
        try #require(census(host).report(helpers: [])["pages"]?.arrayValue?.first)
    }

    private func keepReasons(_ row: JSONValue) -> [String] {
        row["keep_reasons"]?.arrayValue?.compactMap(\.stringValue) ?? []
    }

    @Test func deliveriesAndPushesCountOnlyWhileHidden() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let host = makeHost(nil)
        let view = try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [])))
        defer { host.close(view) }
        let reply = await view.router.handle(["t": "sub", "id": 1, "stream": .string(PageNativeOp.pagePopup)])
        #expect(reply["t"]?.stringValue == "ok")

        // A page in no window is hidden: what reaches it counts (from zero: the load may have pushed).
        #expect(view.census.hidden)
        view.resetCensusCounters()
        view.router.publishPopup(["type": "a"])
        view.evaluate("void 0")
        #expect(view.census.deliveriesWhileHidden == 1)
        #expect(view.census.pushesWhileHidden == 1)

        // Shown: nothing counts, and it has been hidden for no time.
        let shown = makeWindow()
        shown.contentView?.addSubview(view)
        #expect(!view.census.hidden)
        #expect(view.census.hiddenForSeconds == nil)
        view.router.publishPopup(["type": "b"])
        view.evaluate("void 0")
        #expect(view.census.deliveriesWhileHidden == 1)
        #expect(view.census.pushesWhileHidden == 1)

        // Hidden in its window (another tab took the pane): it counts again.
        view.isHidden = true
        #expect(view.census.hidden)
        #expect(view.census.hiddenForSeconds != nil)
        view.router.publishPopup(["type": "c"])
        #expect(view.census.deliveriesWhileHidden == 2)

        view.resetCensusCounters()
        #expect(view.census.deliveriesWhileHidden == 0)
        #expect(view.census.pushesWhileHidden == 0)
    }

    /// `hidden_for_s` reads the page's clock from the moment it was hidden; showing it clears it.
    @Test func hiddenForSecondsCountsFromTheHide() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let host = makeHost(nil)
        let view = try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [])))
        defer { host.close(view) }
        var clock = Date(timeIntervalSince1970: 1_000)
        view.now = { clock }
        let window = makeWindow()
        window.contentView?.addSubview(view)
        #expect(view.census.hiddenForSeconds == nil)

        view.isHidden = true
        clock += 42
        #expect(view.census.hiddenForSeconds == 42)
        let row = try #require(census(host).report(helpers: [])["pages"]?.arrayValue?.first)
        #expect(row["hidden_for_s"]?.doubleValue == 42)
        #expect(row["state"]?.stringValue == "hidden")

        view.isHidden = false
        #expect(view.census.hiddenForSeconds == nil)
    }

    /// A spare parked in a window is visible to its engine but hidden to the person: no `visible`
    /// keep reason, and what reaches it counts. Taken into the window, it shows.
    @Test func aParkedSpareIsHiddenAndItsPushesCount() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let host = makeHost(nil)
        let view = try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [])))
        defer { host.close(view) }
        let window = makeWindow()
        let parking = PagePreloadParkingView(frame: .zero)
        window.contentView?.addSubview(parking)
        parking.addSubview(view)

        #expect(view.census.engineVisible)
        #expect(view.census.hidden)
        view.resetCensusCounters()
        view.evaluate("void 0")
        #expect(view.census.pushesWhileHidden == 1)
        let row = try #require(census(host).report(helpers: [])["pages"]?.arrayValue?.first)
        #expect(row["state"]?.stringValue == "hidden")
        #expect(row["engine_visible"] == .bool(true))
        #expect(row["spare"]?.stringValue == "page_preload")
        #expect(row["hidden_for_s"] != .null)
        #expect(!keepReasons(row).contains("visible"))
        #expect(row["pushes_while_hidden"]?.doubleValue == 1)

        // Claimed into the window (same window: no window move, only the parking view lets it go).
        window.contentView?.addSubview(view)
        #expect(!view.census.hidden)
        view.evaluate("void 0")
        #expect(view.census.pushesWhileHidden == 1)
        let shown = try #require(census(host).report(helpers: [])["pages"]?.arrayValue?.first)
        #expect(shown["state"]?.stringValue == "visible")
        #expect(shown["spare"] == .null)
        #expect(keepReasons(shown).contains("visible"))
    }

    /// A page whose subview is its window's first responder is kept as `focused`.
    @Test func aPageHoldingTheFirstResponderIsFocused() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let host = makeHost(nil)
        let view = try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [])))
        defer { host.close(view) }
        let window = makeWindow()
        window.contentView?.addSubview(view)
        let unfocused = try firstRow(host)
        #expect(!keepReasons(unfocused).contains("focused"))

        let target = FocusTarget(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        view.addSubview(target)
        #expect(window.makeFirstResponder(target))
        let focused = try firstRow(host)
        #expect(keepReasons(focused).contains("focused"))
    }

    @Test func aChromiumPageRowNamesItsRendererAndTheHelperNamesThePage() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let host = makeHost(FakeChromiumHosting())
        let view = try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [])))
        defer { host.close(view) }
        await view.chromiumStart?.value
        let instance = host.registry.instance(of: view)

        let report = census(host, spareClients: [9], browserTabs: [WebUICensus.Host(name: "tab-1", rendererClients: [11])])
            .report(helpers: [
                WebUICensus.Helper(pid: 100, kind: "renderer", rendererClientID: 3),
                WebUICensus.Helper(pid: 101, kind: "extension_renderer", rendererClientID: nil),
                WebUICensus.Helper(pid: 102, kind: "renderer", rendererClientID: 9),
                WebUICensus.Helper(pid: 103, kind: "renderer", rendererClientID: 11),
                WebUICensus.Helper(pid: 104, kind: "gpu", rendererClientID: nil),
            ])

        let page = try #require(report["pages"]?.arrayValue?.first)
        #expect(Set(page.objectValue?.keys.map { $0 } ?? []) == Self.pageKeys)
        #expect(page["engine"]?.stringValue == "chromium")
        #expect(page["state"]?.stringValue == "hidden")
        #expect(page["group"]?.stringValue == "solo")
        #expect(page["browser_id"]?.doubleValue == 7)
        #expect(page["renderer_pids"] == .array([.number(100)]))
        #expect(page["webkit_pid"] == .null)
        #expect(page["spare"] == .null)

        let spare = try #require(report["spares"]?.arrayValue?.first)
        #expect(spare["spare"]?.stringValue == "cef_window")
        #expect(spare["renderer_pids"] == .array([.number(102)]))
        #expect(report["browser_tabs"]?.arrayValue?.first?["renderer_pids"] == .array([.number(103)]))

        let processes = try #require(report["processes"]?.arrayValue)
        let hosts = Dictionary(uniqueKeysWithValues: processes.compactMap { row -> (Double, [String])? in
            guard let pid = row["pid"]?.doubleValue else { return nil }
            return (pid, row["hosts"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        })
        #expect(hosts[100] == ["page:\(descriptor.id)#\(instance)"])
        #expect(hosts[101] == [])
        #expect(hosts[102] == ["spare:cef_window"])
        #expect(hosts[103] == ["browser_tab:tab-1"])
        #expect(hosts[104] == [])
        #expect(processes.first { $0["pid"]?.doubleValue == 101 }?["kind"]?.stringValue == "extension_renderer")
    }

    @Test func aWebKitPageReportsItsWebContentPidAndTheNewTabSpareIsMarked() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let host = makeHost(nil)
        let spare = try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [])))
        let shown = try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [])))
        defer {
            host.close(spare)
            host.close(shown)
        }
        let window = makeWindow()
        window.contentView?.addSubview(shown)

        let rows = try #require(census(host, newTabSpare: spare).report(helpers: [])["pages"]?.arrayValue)
        #expect(rows.count == 2)
        let spareRow = try #require(rows.first)
        #expect(spareRow["engine"]?.stringValue == "webkit")
        #expect(spareRow["webkit_pid"]?.doubleValue == 4242)
        #expect(spareRow["renderer_pids"] == .array([]))
        #expect(spareRow["spare"]?.stringValue == "new_tab")
        #expect(!keepReasons(spareRow).contains("visible"))
        let shownRow = try #require(rows.last)
        #expect(shownRow["spare"] == .null)
        #expect(shownRow["state"]?.stringValue == "visible")
        #expect(shownRow["window_number"]?.doubleValue == Double(window.windowNumber))
        #expect(keepReasons(shownRow).contains("visible"))
        // Only a spare with no page view gets a row of its own.
        #expect(census(host, newTabSpare: spare).report(helpers: [])["spares"]?.arrayValue?.count == 1)
    }

    /// A New Tab spare the census has no row for (none of the pages it was given is the spare)
    /// still gets a `spares` row with its WebContent pid.
    @Test func aViewlessNewTabSpareGetsASpareRow() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let host = makeHost(nil)
        let elsewhere = makeHost(nil)
        let spare = try #require(elsewhere.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [])))
        defer { elsewhere.close(spare) }
        let spares = try #require(census(host, newTabSpare: spare).report(helpers: [])["spares"]?.arrayValue)
        #expect(spares.count == 2)
        let newTab = try #require(spares.first { $0["spare"]?.stringValue == "new_tab" })
        #expect(newTab["state"] == .null)
        #expect(newTab["webkit_pid"]?.doubleValue == 4242)
        #expect(newTab["renderer_clients"] == .array([]))
    }

    /// A parking view tells the page views nested in what it parks (a New Tab spare's page sits
    /// inside its agent pane view).
    @Test func aPageNestedInAParkedViewIsParked() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let host = makeHost(nil)
        let view = try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [])))
        defer { host.close(view) }
        let window = makeWindow()
        let pane = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        pane.addSubview(view)
        window.contentView?.addSubview(pane)
        #expect(!view.census.hidden)

        PageWebView.noteCensusParked(true, in: pane)
        #expect(view.census.hidden)
        #expect(view.census.engineVisible)
        PageWebView.noteCensusParked(false, in: pane)
        #expect(!view.census.hidden)
    }
}

/// A view that takes first responder, for the `focused` keep reason.
private final class FocusTarget: NSView {
    override var acceptsFirstResponder: Bool { true }
}
#endif

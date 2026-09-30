import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextDaemon
import Foundation
import Testing

/// Daemon-owned browser tabs: creation selects the tab and publishes
/// `browserFocused`; the engine choice; debounced record write-back.
@MainActor
struct BrowserTabTests {
    final class Recorder {
        var created: [(PaneID, String, BrowserEngineTag)] = []
        var updates: [(SurfaceID, BrowserRecordUpdate)] = []
    }

    /// A tree with one pane holding one daemon-rendered (non-frontend) browser
    /// tab, so the pane starts with no app content; optionally a frontend tab.
    static func tree(frontendSurface: Int? = nil, url: String = "about:blank") throws -> DaemonTree {
        var tabs = [#"{"kind":"browser","name":"cdp","surface":4,"dead":false,"browser_renderer":"daemon"}"#]
        if let frontendSurface {
            tabs.append(#"{"kind":"browser","name":"","surface":\#(frontendSurface),"dead":false,"browser_renderer":"frontend","browser_engine":"webkit","url":"\#(url)"}"#)
        }
        let json = """
        {"generation":"g1","workspace_revision":1,"workspaces":[{"active":true,"id":1,"key":"0b6c4a52-6d3f-4c55-9d53-8f1f4e0f1a03","name":"w",
        "screens":[{"active":true,"id":2,"layout":{"pane":3,"type":"leaf"},"name":null,"panes":[{"active_tab":0,"id":3,"name":null,
        "tabs":[\(tabs.joined(separator: ","))]}]}]}]}
        """
        return try JSONDecoder().decode(DaemonTree.self, from: Data(json.utf8))
    }

    static func settle(_ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() { await Task.yield() }
    }

    @Test func openBrowserSelectsTheNewTabAndPublishesBrowserFocused() async throws {
        let services = ActionBindingCoverageTests.boundServices()
        let store = services.daemon.store
        store.apply(snapshot: try Self.tree())
        let recorder = Recorder()
        let browserTabs = try #require(services.cache.browserTabs)
        browserTabs.isAvailable = { true }
        browserTabs.cefAvailable = { false }
        browserTabs.create = { pane, url, engine in
            recorder.created.append((pane, url, engine))
            return SurfaceID(rawValue: 9)
        }
        let workspace = try #require(store.workspaces.first)
        let state = WindowState(workspaceID: workspace.id)
        let content = WorkspaceContentController(workspace: workspace, daemon: services.daemon, services: services, state: state)
        let paneModel = try #require(workspace.screens.first?.panes.first)
        let paneID = LayoutPaneIDFixture.id(paneModel)
        await Self.settle { content.panes[paneID] != nil }
        if content.panes[paneID] == nil { _ = content.makeContentView(for: paneID) }
        let pane = try #require(content.panes[paneID])
        content.layoutModel.focus(paneID)

        pane.newBrowserTab(engine: "cef")
        await Self.settle { !recorder.created.isEmpty }
        #expect(recorder.created.count == 1)
        #expect(recorder.created.first?.1 == "about:blank")
        #expect(recorder.created.first?.2 == .webkit, "cef falls back to webkit when the runtime is missing")

        // The daemon reports the new tab.
        store.apply(snapshot: try Self.tree(frontendSurface: 9))
        await Self.settle { pane.selectedTab?.surface == SurfaceID(rawValue: 9) }
        #expect(pane.selectedTab?.surface == SurfaceID(rawValue: 9))
        #expect(services.registry.context.contains(.browserFocused))
        #expect(services.registry.isAvailable("browserBack"))
        #expect(browserTabs.isTracking(try #require(pane.selectedTab).id))
        content.teardown()
        withExtendedLifetime((services, state)) {}
    }

    /// The engine-specific entries: Chromium is disabled with its reason
    /// when CEF is missing (menus and palette show it), never falls back to
    /// WebKit when asked for explicitly, and opens a CEF tab when present.
    @Test func chromiumEntryIsDisabledWithAReasonWhenCEFIsMissing() async throws {
        let services = ActionBindingCoverageTests.boundServices()
        let store = services.daemon.store
        store.apply(snapshot: try Self.tree())
        let recorder = Recorder()
        let browserTabs = try #require(services.cache.browserTabs)
        browserTabs.isAvailable = { true }
        browserTabs.cefAvailable = { false }
        browserTabs.cefUnavailableReason = { "no CEF here" }
        browserTabs.create = { pane, url, engine in
            recorder.created.append((pane, url, engine))
            return SurfaceID(rawValue: 9)
        }
        let registry = services.registry
        #expect(!registry.canPerform("openBrowser.chromium"))
        #expect(registry.unavailableReason(for: "openBrowser.chromium") == "no CEF here")
        #expect(registry.canPerform("openBrowser.webkit"))
        let menu = registry.makeContextMenu(for: .newTab, target: ActionTargetRef(kind: .pane, id: "pane:3"))
        let chromium = try #require(menu.items.first { $0.title == "New Chromium Tab" })
        #expect(chromium.subtitle == "no CEF here")
        #expect(menu.items.map(\.title) == ["New Terminal Tab", "New WebKit Tab", "New Chromium Tab"])

        let pane = ActionTargetRef(kind: .pane, id: "pane:3")
        let refusal = registry.capturingRefusal {
            registry.perform("openBrowser", invocation: ActionInvocation(target: pane, arguments: ["engine": .string("cef")]))
        }
        #expect(refusal == "no CEF here")
        registry.perform("openBrowser.webkit", invocation: ActionInvocation(target: pane))
        await Self.settle { !recorder.created.isEmpty }
        #expect(recorder.created.first?.2 == .webkit)

        browserTabs.cefAvailable = { true }
        browserTabs.cefUnavailableReason = { nil }
        #expect(registry.canPerform("openBrowser.chromium"))
        registry.perform("openBrowser.chromium", invocation: ActionInvocation(target: pane))
        await Self.settle { recorder.created.count == 2 }
        #expect(recorder.created.last?.2 == .cef)
        withExtendedLifetime(services) {}
    }

    @Test func cefIsChosenOnlyWhenRequestedAndAvailable() {
        let services = ActionBindingCoverageTests.boundServices()
        let browserTabs = services.cache.browserTabs!
        browserTabs.cefAvailable = { true }
        #expect(browserTabs.engine(requested: nil) == .webkit)
        #expect(browserTabs.engine(requested: "webkit") == .webkit)
        #expect(browserTabs.engine(requested: "cef") == .cef)
        browserTabs.cefAvailable = { false }
        #expect(browserTabs.engine(requested: "cef") == .webkit)
    }

    @Test func recordUpdateSendsOnlyWhatChanged() {
        let record = BrowserRecord(url: "https://a.test/", title: "A", faviconURL: "https://a.test/f.ico")
        var page = BrowserTabState(url: URL(string: "https://a.test/"), title: "A", faviconURL: URL(string: "https://a.test/f.ico"))
        #expect(record.update(toward: page) == nil)
        page.title = "A2"
        #expect(record.update(toward: page) == BrowserRecordUpdate(url: nil, title: "A2", favicon: .unchanged))
        page = BrowserTabState(url: URL(string: "https://b.test/"), title: nil, faviconURL: nil, phase: .committed)
        #expect(record.update(toward: page) == BrowserRecordUpdate(url: "https://b.test/", title: nil, favicon: .unchanged))
        page.phase = .finished
        #expect(record.update(toward: page) == BrowserRecordUpdate(url: "https://b.test/", title: nil, favicon: .clear))
        // Nothing committed yet: keep the record.
        #expect(record.update(toward: BrowserTabState()) == nil)
        #expect(record.applying(BrowserRecordUpdate(url: "u", title: nil, favicon: .clear)) == BrowserRecord(url: "u", title: "A", faviconURL: nil))
    }

    @Test func writerDebouncesABurstIntoOneUpdate() async throws {
        let engine = MockBrowserEngine()
        let page = engine.makeMockTab(BrowserTabConfiguration())
        let gate = SleepGate()
        var sent: [BrowserRecordUpdate] = []
        let writer = BrowserRecordWriter(tab: page, recorded: BrowserRecord(url: "about:blank"), delay: .milliseconds(500),
                                         sleep: { _ in try await gate.wait() }) { update in
            sent.append(update)
            return true
        }
        page.load(URL(string: "https://one.test/")!)
        page.simulate(.titleChanged("One"))
        await Self.settle { gate.waiters > 0 }
        page.load(URL(string: "https://two.test/")!)
        page.simulate(.titleChanged("Two"))
        await Self.settle { false }
        #expect(sent.isEmpty, "nothing is sent before the delay ends")
        gate.releaseAll()
        await Self.settle { !sent.isEmpty }
        await Self.settle { false }
        #expect(sent == [BrowserRecordUpdate(url: "https://two.test/", title: "Two", favicon: .unchanged)])
        #expect(writer.recorded.url == "https://two.test/")
        writer.cancel()
    }
}

/// A sleep the test releases by hand; a cancelled sleep throws.
@MainActor
final class SleepGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    var waiters: Int { continuations.count }

    func wait() async throws {
        await withCheckedContinuation { continuations.append($0) }
        try Task.checkCancellation()
    }

    func releaseAll() {
        let pending = continuations
        continuations.removeAll()
        for continuation in pending { continuation.resume() }
    }
}

enum LayoutPaneIDFixture {
    static func id(_ pane: PaneModel) -> LayoutPaneID { LayoutPaneID(pane.id) }
}

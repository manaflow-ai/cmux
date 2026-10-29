import AppKit
import CmuxNextCompat
import CmuxNextDesign
@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import Foundation
import Testing
import WebKit

/// ``WebUIHost`` makes page views with its own Chromium host, open panel and registry (no static
/// state), tracks every page it opened, and ends the engine page on ``WebUIHost/close(_:)``.
@MainActor
struct WebUIHostTests {
    private let root: URL
    private let descriptor = PageDescriptor(id: "test.webui-host", resource: "webui-host", processGroup: .solo, namespaces: [])

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("webui-host-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<!doctype html><title>Page</title>".utf8).write(to: root.appendingPathComponent("index.html"))
    }

    private func makeHost(_ hosting: FakeChromiumHosting?, openPanel: MadeAheadOpenPanel? = nil,
                          everySharingPage: Bool = false) -> WebUIHost {
        WebUIHost(chromium: hosting, openPanel: openPanel,
                  memory: QuietMemoryRegistry(),
                  deadlines: LifecycleDeadlineRig.never,
                  processGroups: WebProcessGroups(pagesPerProcess: 8, groupsEverySharingPage: everySharingPage))
    }

    @Test func openMakesThePageWithTheHostsChromiumAndListsIt() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        let host = makeHost(hosting)
        let view = try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [], route: "#/start")))
        #expect(view.engineDecision == .chromium)
        await view.chromiumStart?.value
        let page = try #require(hosting.made.first)
        #expect(page.loaded == [descriptor.url(route: "#/start")])
        #expect(host.openPages.map(ObjectIdentifier.init) == [ObjectIdentifier(view)])
        #expect(host.registry.pages(id: descriptor.id).map(ObjectIdentifier.init) == [ObjectIdentifier(view)])
        // The host's own registry, not the process-wide one the static forwarders read.
        #expect(!PageRegistry.processWide.pages(id: descriptor.id).contains { $0 === view })
        host.close(view)
    }

    @Test func closeEndsTheEnginePageAndForgetsTheView() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        let host = makeHost(hosting)
        let view = try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [])))
        await view.chromiumStart?.value
        let page = try #require(hosting.made.first)
        host.close(view)
        // The lists drop it in the close's turn; the engine page ends at the retirer's deadline.
        #expect(!page.closed)
        #expect(host.openPages.isEmpty)
        #expect(host.registry.pages().isEmpty)
        host.retirer.closeRetired()
        #expect(page.closed)
        // A second close (a provider and the tab store both closing) changes nothing.
        host.close(view)
        #expect(host.openPages.isEmpty)
    }

    @Test func eachHostKeepsItsOwnPages() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let first = makeHost(nil)
        let second = makeHost(nil)
        let a = try #require(first.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [])))
        let b = try #require(second.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [])))
        #expect(first.openPages.map(ObjectIdentifier.init) == [ObjectIdentifier(a)])
        #expect(second.openPages.map(ObjectIdentifier.init) == [ObjectIdentifier(b)])
        // Without a Chromium host the page shows in WebKit.
        #expect(a.engineDecision.engine != .cef)
        first.close(a)
        second.close(b)
    }

    @Test func aFirstPartyPageAtAForeignRootIsRefused() {
        defer { try? FileManager.default.removeItem(at: root) }
        let host = makeHost(FakeChromiumHosting())
        #expect(host.open(PageOpenRequest(descriptor: .settings, root: root, routes: [])) == nil)
        #expect(host.openPages.isEmpty)
        #expect(host.registry.pages().isEmpty)
    }

    @Test func theHostsOpenPanelAnswersFileInputs() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let withPanel = makeHost(nil, openPanel: MadeAheadOpenPanel())
        let answered = try #require(withPanel.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [])))
        #expect((answered.webView.uiDelegate as? PageUIDelegate)?.fileInputs != nil)
        let withoutPanel = makeHost(nil)
        let unanswered = try #require(withoutPanel.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [])))
        // Its UI delegate still hears Web Inspector; a file input gets no chooser.
        #expect(unanswered.webView.uiDelegate is PageUIDelegate)
        #expect((unanswered.webView.uiDelegate as? PageUIDelegate)?.fileInputs == nil)
        withPanel.close(answered)
        withoutPanel.close(unanswered)
    }

    /// Pages that ask to share WebKit processes (the agent pages) join the host's process groups:
    /// one data store, the next page related to the first, so many New Tab pages and chats do not
    /// start a process each (sequoia-lag.md: 55 tabs had run 54 WebContent processes). A page that
    /// does not ask keeps a store of its own; the warm-up view gets the pool and the agent group's store.
    @Test func pagesThatShareWebKitProcessesJoinTheHostsGroup() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let host = makeHost(nil)
        let shared = PageEngineOptions(sharesWebKitProcess: true)
        let first = try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [], options: shared)))
        let second = try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [], options: shared)))
        let alone = try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [])))
        let groups = try #require(host.processGroups)
        let store = groups.dataStore(for: .page(descriptor.id))
        #expect(first.webView.configuration.websiteDataStore === store)
        #expect(second.webView.configuration.websiteDataStore === store)
        #expect(second.webView.configuration.value(forKey: "_relatedWebView") as? WKWebView === first.webView)
        #expect(alone.webView.configuration.websiteDataStore !== store)
        let warmup = host.groupedWebKitConfiguration()
        #expect(warmup.websiteDataStore === groups.dataStore(for: .group(.agent)))
        #expect(warmup.websiteDataStore !== store)
        #expect(warmup.processPool === first.webView.configuration.processPool)
        for view in [first, second, alone] { host.close(view) }
    }

    /// A page that shows in Chromium has no WebKit process to share: it has no WebKit view,
    /// and the one a host forces stays out of the group, so it never becomes the
    /// group's first page.
    @Test func aSharedPageInChromiumStaysOutOfTheGroup() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let host = makeHost(FakeChromiumHosting())
        let view = try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [],
                                                          options: PageEngineOptions(sharesWebKitProcess: true))))
        #expect(view.engineDecision == .chromium)
        #expect(view.webKitPieces == nil)
        await view.chromiumStart?.value
        #expect(view.webKitPieces == nil)
        #expect(view.webView.configuration.websiteDataStore !== host.processGroups?.dataStore(for: .page(descriptor.id)))
        #expect(!view.crash.sharesWebKitProcess)
        host.close(view)
    }

    /// With `webKitPageProcessGroups` every page of a sharing group joins it without asking, so the
    /// pages of one group start one WebContent process and their crashes count against one budget;
    /// a solo page keeps its own store and process. The group's store is its own,
    /// not the agent group's the warm-up has: pages of different groups never share localStorage.
    @Test func everyPageOfASharingGroupJoinsItWithWebKitPageProcessGroups() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let host = makeHost(nil, everySharingPage: true)
        let privileged = PageDescriptor(id: "test.webui-host-privileged", resource: "webui-host", processGroup: .privileged, namespaces: [])
        let first = try #require(host.open(PageOpenRequest(descriptor: privileged, root: root, routes: [])))
        let second = try #require(host.open(PageOpenRequest(descriptor: privileged, root: root, routes: [])))
        let alone = try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [])))
        let store = try #require(host.processGroups).dataStore(for: .group(.privileged))
        #expect(first.webView.configuration.websiteDataStore === store)
        #expect(store !== host.groupedWebKitConfiguration().websiteDataStore)
        #expect(second.webView.configuration.value(forKey: "_relatedWebView") as? WKWebView === first.webView)
        #expect(first.crash.sharesWebKitProcess && second.crash.sharesWebKitProcess)
        #expect(alone.webView.configuration.websiteDataStore !== store)
        #expect(alone.webView.configuration.value(forKey: "_relatedWebView") == nil)
        #expect(!alone.crash.sharesWebKitProcess)
        for view in [first, second, alone] { host.close(view) }
    }

    /// A host made without groups starts a process for every WebKit page, also one that asks to share.
    @Test func aHostWithoutGroupsGroupsNoPage() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let host = WebUIHost(chromium: nil, openPanel: nil, memory: QuietMemoryRegistry(), deadlines: LifecycleDeadlineRig.never)
        let shared = PageEngineOptions(sharesWebKitProcess: true)
        let first = try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [], options: shared)))
        let second = try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [], options: shared)))
        #expect(host.processGroups == nil)
        #expect(second.webView.configuration.value(forKey: "_relatedWebView") == nil)
        #expect(first.webView.configuration.websiteDataStore !== second.webView.configuration.websiteDataStore)
        #expect(!first.crash.sharesWebKitProcess)
        for view in [first, second] { host.close(view) }
    }
}

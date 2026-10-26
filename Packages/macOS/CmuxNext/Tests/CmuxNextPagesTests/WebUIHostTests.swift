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

    private func makeHost(_ hosting: FakeChromiumHosting?, openPanel: MadeAheadOpenPanel? = nil) -> WebUIHost {
        WebUIHost(chromium: hosting, openPanel: openPanel,
                  memoryPressure: MemoryPressureEvents(source: ManualMemoryPressureSource()),
                  clock: PageTestClock.never)
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
        #expect(page.closed)
        #expect(host.openPages.isEmpty)
        #expect(host.registry.pages().isEmpty)
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
        #expect(answered.webKitView.uiDelegate is PageOpenPanel)
        let withoutPanel = makeHost(nil)
        let unanswered = try #require(withoutPanel.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [])))
        #expect(unanswered.webKitView.uiDelegate == nil)
        withPanel.close(answered)
        withoutPanel.close(unanswered)
    }
}

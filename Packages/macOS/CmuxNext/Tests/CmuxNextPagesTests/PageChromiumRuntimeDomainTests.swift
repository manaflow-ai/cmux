@testable import CmuxNextPages
import AppKit
import CmuxNextDesign
import CmuxNextPagesTestSupport
import Foundation
import Testing

/// Every page kind in Chromium keeps the page host binding while the Runtime domain is off from each
/// main-frame commit (``ChromiumPageHostBridge``): the binding is in the document before the page's first
/// host call, the commit turns the domain off, the call is still answered, and a reload turns the domain
/// on (with the binding) before it navigates.
@MainActor
struct PageChromiumRuntimeDomainTests {
    /// One page kind the page host shows in Chromium.
    struct Kind: Sendable, CustomTestStringConvertible {
        var name: String
        var id: String
        var surface: SurfaceKind?
        var testDescription: String { name }
    }

    nonisolated static let kinds: [Kind] = [
        Kind(name: "agent chat", id: "cmux.agent", surface: .agentPane),
        Kind(name: "new tab page (the agent page before a session)", id: "cmux.agent", surface: .newTabPage),
        Kind(name: "Home", id: "cmux.home-channels", surface: .home),
        Kind(name: "Settings", id: "cmux.settings", surface: .settings),
        Kind(name: "a viewer (Markdown)", id: "cmux.markdown", surface: .internalPage),
    ]

    /// The calls that switch the Runtime domain and add the binding.
    nonisolated static let switches: Set<String> = ["Runtime.enable", "Runtime.disable", "Runtime.addBinding"]

    @Test(arguments: kinds)
    func theBindingIsThereBeforeThePagesFirstHostCallAndSurvivesTheRuntimeDomainGoingOff(_ kind: Kind) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("page-runtime-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("<!doctype html><title>Page</title>".utf8).write(to: root.appendingPathComponent("index.html"))
        let descriptor = PageDescriptor(id: kind.id, resource: kind.id, namespaces: [])
        let hosting = FakeChromiumHosting()
        // What the page had been sent when its first document started loading.
        var atFirstLoad: [String] = []
        hosting.onMade = { page in
            page.onNavigate = { if atFirstLoad.isEmpty { atFirstLoad = page.calls.map(\.method) } }
        }
        let view = try #require(PageWebView(descriptor: descriptor, root: root, testRoot: true, routes: [],
                                           options: PageEngineOptions(chromiumAgentChat: true), surface: kind.surface,
                                           chromium: hosting))
        defer { view.close() }
        view.chromiumClock = PageTestClock.never
        await view.chromiumStart?.value
        let page = try #require(hosting.made.first)
        #expect(view.chromiumSession != nil, "\(kind.name) shows in Chromium")

        // Before the first document: the domain on, then the binding and the page script, and no
        // `Runtime.disable` yet.
        let enable = try #require(atFirstLoad.firstIndex(of: "Runtime.enable"))
        let binding = try #require(atFirstLoad.firstIndex(of: "Runtime.addBinding"))
        #expect(enable < binding)
        #expect(page.calls[binding].params["name"] as? String == ChromiumPageHostBridge.bindingName)
        #expect(page.calls.contains { $0.method == "Page.addScriptToEvaluateOnNewDocument" &&
            ($0.params["source"] as? String)?.contains(ChromiumPageHostBridge.bindingName) == true })
        #expect(!atFirstLoad.contains("Runtime.disable"))
        #expect(page.loaded == [descriptor.url()])

        // The main frame commits: the domain goes off and the binding is added again.
        let committed = page.calls.count
        let turnedOff: [String]? = await PageTestWait.value("commit") { done in
            page.onCall = {
                let methods = page.calls[committed...].map(\.method).filter(Self.switches.contains)
                if methods.count == 2 { done(methods) }
            }
            page.onEvent?(.devTools(#"{"method":"Page.frameNavigated","params":{"frame":{"id":"A","url":"\#(descriptor.url().absoluteString)"}}}"#))
        }
        #expect(turnedOff == ["Runtime.disable", "Runtime.addBinding"])

        // The page's first host call (its paint probe) still reaches the host, checked in its context.
        let painted: Bool? = await PageTestWait.value("first host call") { done in
            page.onCall = nil
            view.whenPainted { done(true) }
            page.onEvent?(.devTools(FakeChromiumPage.bindingCall(["name": PagePaintProbe.handlerName, "body": 1])))
        }
        #expect(painted == true)
        #expect(page.calls.contains { $0.method == "Runtime.evaluate" && $0.params["contextId"] as? Int == 9 })

        // A reload turns the domain on and adds the binding before the page reloads.
        let beforeReload = page.calls.count
        let sentFirst: [String]? = await PageTestWait.value("reload") { done in
            page.onNavigate = { done(page.calls[beforeReload...].map(\.method).filter(Self.switches.contains)) }
            view.reload()
        }
        #expect(sentFirst == ["Runtime.enable", "Runtime.addBinding"])
        #expect(page.reloads == 1)
    }
}

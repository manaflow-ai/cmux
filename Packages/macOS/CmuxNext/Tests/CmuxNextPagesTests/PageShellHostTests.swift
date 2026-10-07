import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing
import WebKit

/// The pooled page host's rules (react-pages.md "Page shell"): one scheme handler for every
/// first-party page, each answer with that page's own CSP; a router that rebinds to another
/// page with nothing of the old one left; a claim that does not navigate.
@MainActor
@Suite struct PageShellHostTests {
    final class Source: PageDynamicResourceSource {
        var requests: [PageResourceRequest] = []
        func resource(for request: PageResourceRequest) async -> PageResource? {
            requests.append(request)
            return PageResource(data: Data("png".utf8), mimeType: "image/png")
        }
    }

    final class Provider: PageProvider {
        var cancelled = 0
        var calls: [String] = []
        func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
            calls.append(op)
            return ["ok": true]
        }

        func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                       onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
            PageSubscription { [weak self] in self?.cancelled += 1 }
        }
    }

    static func root() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "page-shell-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["shell-page.html", "diff-page.html", "index.html"] {
            try Data("<!doctype html><title>t</title>".utf8).write(to: dir.appending(path: name))
        }
        return dir
    }

    func handler(current: PageDescriptor, source: Source? = nil, roots: [String: URL]) -> PageSchemeHandler {
        PageSchemeHandler { host in
            PageServedHosts.served(host: host, current: current, dynamicSource: source,
                                   root: { roots[$0.id] })
        }
    }

    static func url(_ string: String) -> URL { URL(string: string) ?? URL(fileURLWithPath: "/invalid") }

    // MARK: One handler, every first-party page

    @Test func eachFirstPartyHostIsServedWithItsOwnCSP() async throws {
        let root = try Self.root()
        let handler = handler(current: .shell, roots: ["cmux.shell": root, "cmux.diff": root])
        let shell = try #require(await handler.reply(to: Self.url("cmux-page://cmux.shell/")))
        #expect(shell.response.statusCode == 200)
        #expect(shell.response.value(forHTTPHeaderField: "Content-Security-Policy") == PageDescriptor.shell.csp.header)
        let diff = try #require(await handler.reply(to: Self.url("cmux-page://cmux.diff/")))
        #expect(diff.response.value(forHTTPHeaderField: "Content-Security-Policy") == PageDescriptor.diff.csp.header)
        #expect(diff.response.value(forHTTPHeaderField: "Content-Security-Policy")?.contains("'wasm-unsafe-eval'") == true)
        #expect(shell.response.value(forHTTPHeaderField: "Content-Security-Policy")?.contains("wasm") == false)
    }

    @Test func aHostThatIsNotFirstPartyIsRefused() async throws {
        let root = try Self.root()
        let handler = handler(current: .shell, roots: ["cmux.shell": root, "com.example.app": root])
        #expect(await handler.reply(to: Self.url("cmux-page://com.example.app/")) == nil)
        #expect(await handler.reply(to: Self.url("cmux-page://cmux.agentx/")) == nil)
    }

    @Test func anUnregisteredFirstPartyHostIsRefused() async throws {
        let root = try Self.root()
        // cmux.keybindings is first party but has no descriptor in the pooled host's table; cmux.history
        // has one but no root here.
        let handler = handler(current: .shell, roots: ["cmux.shell": root, "cmux.keybindings": root])
        #expect(await handler.reply(to: Self.url("cmux-page://cmux.keybindings/")) == nil)
        #expect(await handler.reply(to: Self.url("cmux-page://cmux.history/")) == nil)
        // A shell page has no document of its own.
        #expect(await handler.reply(to: Self.url("cmux-page://cmux.icon-picker/")) == nil)
    }

    @Test func aClaimedPagesDynamicResourcesAreServedUnderTheShellOrigin() async throws {
        let root = try Self.root()
        let source = Source()
        let handler = handler(current: PageDescriptor.shell.serving(PageShellFixture.iconPicker), source: source, roots: ["cmux.shell": root])
        let reply = try #require(await handler.reply(to: Self.url("cmux-page://cmux.shell/__symbol/star.fill.png")))
        #expect(reply.response.statusCode == 200)
        #expect(reply.response.value(forHTTPHeaderField: "Content-Security-Policy") == PageDescriptor.shell.csp.header)
        #expect(source.requests.map(\.path) == [["star.fill.png"]])
        // Without the claim the prefix is a plain (missing) file.
        let bare = self.handler(current: .shell, source: source, roots: ["cmux.shell": root])
        #expect(await bare.reply(to: Self.url("cmux-page://cmux.shell/__symbol/star.fill.png")) == nil)
    }

    @Test func thirdPartyPagesNeverMountInTheShell() {
        let page = PageDescriptor(id: "com.example.app", resource: "x", namespaces: ["com.example.app."], inShell: true)
        #expect(!page.inShell)
        #expect(PageShellFixture.iconPicker.inShell)
    }

    // MARK: Router rebinding

    @Test func aRebindEndsTheOldPageBeforeTheNewOneIsAdmitted() async throws {
        let provider = Provider()
        let router = PageRouter(descriptor: PageShellFixture.iconPicker, routes: [PageRoute(prefix: "cmux.iconPicker.", provider: provider)])
        var sent: [JSONValue] = []
        router.send = { sent.append($0) }
        _ = await router.handle(["t": "sub", "id": 1, "stream": "cmux.iconPicker.session", "filter": [:]])
        #expect(router.subscriptionCount == 1)
        var pending: Result<JSONValue, PageError>?
        router.sendCall("page.claim", params: [:]) { pending = $0 }
        #expect(sent.count == 1)

        router.bind(.history, routes: [PageRoute(prefix: "cmux.history.", provider: provider)])
        #expect(router.subscriptionCount == 0)
        #expect(provider.cancelled == 1)
        #expect(pending == .failure(.closed))
        let old = await router.handle(["t": "call", "id": 2, "op": "cmux.iconPicker.prefs.load", "params": [:]])
        #expect(old["code"] == "cmux.protocol.unknown_op")
        let new = await router.handle(["t": "call", "id": 3, "op": "cmux.history.entries.list", "params": [:]])
        #expect(new["t"] == "ok")
    }

    @Test func theTitleBarActionFollowsTheBindingAndSurvivesARebind() async {
        let router = PageRouter(descriptor: PageShellFixture.iconPicker, routes: [])
        var actions = 0
        router.titleBarDoubleClick = { actions += 1 }
        let call: JSONValue = ["t": "call", "id": 1, "op": .string(PageNativeOp.titleBarDoubleClick), "params": [:]]
        router.unbind()
        #expect(await router.handle(call)["code"] == "cmux.protocol.unknown_op")
        #expect(actions == 0)
        router.bind(.history, routes: [PageRoute(prefix: "cmux.history.", provider: Provider())])
        #expect(await router.handle(call)["t"] == "ok")
        #expect(actions == 1)
        // The host still refuses an origin or a confirmation from the newly bound page.
        let forged: JSONValue = ["t": "call", "id": 2, "op": "cmux.history.entries.list", "params": ["confirmed": true]]
        #expect(await router.handle(forged)["code"] == "cmux.protocol.invalid_params")
    }

    @Test func anUnboundRouterAdmitsNothingNotEvenTheBuiltInStreams() async {
        let provider = Provider()
        let router = PageRouter(descriptor: PageShellFixture.iconPicker, routes: [PageRoute(prefix: "cmux.iconPicker.", provider: provider)])
        router.unbind()
        let call = await router.handle(["t": "call", "id": 1, "op": "cmux.iconPicker.prefs.load", "params": [:]])
        #expect(call["code"] == "cmux.protocol.unknown_op")
        let sub = await router.handle(["t": "sub", "id": 2, "stream": .string(PageNativeOp.pageCommand), "filter": [:]])
        #expect(sub["code"] == "cmux.protocol.unknown_op")
        #expect(provider.calls.isEmpty)
    }

    // MARK: Pooled host retarget

    @Test func aShellClaimDoesNotNavigateAndRekeysTheView() throws {
        PageID.registerBundledRoot(PageShellFixture.webviewsApp, for: PageDescriptor.shell.id)
        let host = try #require(PageWebView(pooledHost: .shell))
        defer { host.close() }
        // A previous page's attributes and surface.
        host.webKitView.configuration.userContentController.addUserScript(
            WKUserScript(source: "1", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        host.themeSurface = .diff
        #expect(host.retarget(descriptor: PageShellFixture.iconPicker, routes: [], route: "/emoji"))
        #expect(host.descriptor.id == "cmux.icon-picker")
        #expect(host.servedDescriptor.id == "cmux.shell")
        #expect(host.accessibilityIdentifier() == "cmux.page.cmux.icon-picker")
        #expect(PageRegistry.pages(id: "cmux.icon-picker").contains { $0 === host })
        #expect(!PageRegistry.pages(id: "cmux.shell").contains { $0 === host })
        #expect(host.router.descriptor.id == "cmux.icon-picker")
        // The previous page's script is gone; the theme bootstrap and the paint probe stay.
        let scripts = host.webKitView.configuration.userContentController.userScripts.map(\.source)
        #expect(scripts == [WebTheme.bootstrapScript, PagePaintProbe.script])
        #expect(!host.hasPainted)
        #expect(host.themeSurface == nil)
        #expect(host.route == "#/emoji")
        // The trust check still reads the shell origin.
        let shellFrame = PageHostMessage(frameURL: Self.url("cmux-page://cmux.shell/"), isMainFrame: true, body: [:])
        #expect(PageHostTrust.isTrusted(shellFrame, page: host.servedDescriptor))
        #expect(!PageHostTrust.isTrusted(PageHostMessage(frameURL: Self.url("cmux-page://cmux.icon-picker/"), isMainFrame: true, body: [:]),
                                         page: host.servedDescriptor))
    }

    @Test func aNavigatingRetargetLoadsTheNewOriginWithNothingOfTheOldPage() async throws {
        PageID.registerBundledRoot(PageShellFixture.webviewsApp, for: PageDescriptor.shell.id)
        let provider = Provider()
        let host = try #require(PageWebView(pooledHost: .shell))
        defer { host.close() }
        host.retarget(descriptor: PageShellFixture.iconPicker, routes: [PageRoute(prefix: "cmux.iconPicker.", provider: provider)])
        _ = await host.router.handle(["t": "sub", "id": 1, "stream": "cmux.iconPicker.session", "filter": [:]])
        var pending: Result<JSONValue, PageError>?
        host.router.sendCall("page.claim", params: [:]) { pending = $0 }
        #expect(host.retarget(descriptor: .history, routes: []))
        #expect(host.router.subscriptionCount == 0)
        #expect(pending == .failure(.closed))
        #expect(host.servedDescriptor.id == "cmux.history")
        #expect(!host.isLoaded)
        #expect(host.route == nil)
        #expect(host.accessibilityIdentifier() == "cmux.page.cmux.history")
    }

    @Test func everyHostSharesTheAppsOneProcessPoolButNotItsDataStore() throws {
        PageID.registerBundledRoot(PageShellFixture.webviewsApp, for: PageDescriptor.shell.id)
        let first = try #require(PageWebView(pooledHost: .shell))
        let second = try #require(PageWebView(pooledHost: .shell))
        let page = PageDescriptor(id: "com.example.app", resource: "x", namespaces: ["com.example.app."])
        let plain = try #require(PageWebView(descriptor: page, root: try Self.root(), routes: []))
        defer { first.close(); second.close(); plain.close() }
        let pools = [first, second, plain].map { $0.webKitView.configuration.processPool }
        #expect(pools.allSatisfy { $0 === PageProcessPool.shared })
        let stores = [first, second].map { $0.webKitView.configuration.websiteDataStore }
        #expect(stores[0] !== stores[1])
        #expect(!stores[0].isPersistent && !stores[1].isPersistent)
    }

    @Test func onlyAPooledHostCanBeRetargeted() throws {
        let page = PageDescriptor(id: "com.example.app", resource: "x", namespaces: ["com.example.app."])
        let view = try #require(PageWebView(descriptor: page, root: try Self.root(), routes: []))
        defer { view.close() }
        #expect(!view.retarget(descriptor: .history, routes: []))
        #expect(view.descriptor.id == "com.example.app")
    }
}

/// The real webviews-app build (it holds shell-page.html), from this file's place in the repo.
enum PageShellFixture {
    /// The icon picker as a shell page (the app's descriptor is CmuxNextApp's PageDescriptor.iconPicker).
    static let iconPicker = PageDescriptor(
        id: "cmux.icon-picker", resource: "icon-picker", namespaces: ["cmux.iconPicker."],
        dynamicPrefixes: ["__symbol"], inShell: true)

    static var webviewsApp: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "../../../../../Resources/markdown-viewer/webviews-app", directoryHint: .isDirectory)
            .standardizedFileURL
    }
}

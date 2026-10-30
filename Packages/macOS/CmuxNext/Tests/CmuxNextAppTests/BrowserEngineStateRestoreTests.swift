import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextBrowserHistory
@testable import CmuxNextDaemon
import Foundation
import Network
import Testing

/// cx-p0im9 and hq#1925 bug 2: a person loads a page, follows two links, scrolls the last page down, quits and
/// reopens cmux. The page comes back with its real back list (`history.length` 3, Back to the
/// page before), at the scroll position it had, and loads once. Runs real WebKit pages against
/// a local web server, with the app's history writer and its relaunch start; the daemon's
/// stored history is the value the first page's writer sent.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2))) struct BrowserEngineStateRestoreTests {
    @Test func aRelaunchedPageKeepsItsBackListAndScrollAndLoadsOnce() async throws {
        let server = try await PageServer.start()
        defer { server.stop() }
        try await Self.relaunch(server.url("/a"), server.url("/b"), server.url("/c"), loads: { server.count("/c") })
    }

    /// A history read slower than `BrowserHistoryStarts.budget` does not keep the page waiting:
    /// it loads its address as before (one entry, the saved ones around it), still once.
    @Test func aSlowHistoryReadLoadsTheAddressOnce() async throws {
        let server = try await PageServer.start()
        defer { server.stop() }
        try await Self.relaunch(server.url("/a"), server.url("/b"), server.url("/c"), loads: { server.count("/c") }, slowRead: true)
    }

    /// A page that shows a password field never saves the engine's state, which keeps its form:
    /// the tab reopens from its saved entries as before.
    @Test func aPageWithAPasswordFieldSavesNoEngineState() async throws {
        let server = try await PageServer.start()
        defer { server.stop() }
        let login = server.url("/login")
        var stored: FrontendBrowserHistory?
        let page = WebKitEngine(fileInput: NoFileInput(), stores: .inMemory()).makeWebKitTab()
        defer { page.close() }
        let (service, tab) = Self.service(record: login, stored: { nil }, store: { stored = $0 })
        page.load(login)
        service.track(page, for: tab)
        try await Self.until("the login page loads") {
            (try? await page.evaluate("document.readyState === 'complete' && document.title", world: .page, gesture: .agent)) == .string("login")
        }
        _ = try await page.evaluate("document.getElementById('password').value = 'rj-typed-secret'; true", world: .page, gesture: .agent)
        try await Self.until("the history writer starts") { service.historyWriters[tab.id] != nil }
        await service.historyWriters[tab.id]?.flushNow()
        service.untrack(tab.id)
        #expect(stored?.entries.count == 1)
        #expect(stored != nil && stored?.engineState == nil, "a page with a password field saved its engine state")
    }

    /// The same for local pages: a local file that links to its sibling files.
    @Test func aRelaunchedLocalPageKeepsItsBackListAndScroll() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("cn-engine-state-\(UUID().uuidString.prefix(8).lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // An image beside the pages' folder, not in it: c tries to show it, which a page loaded
        // with access to its own folder cannot do, before the quit or after the reopen.
        let pages = folder.appendingPathComponent("pages", isDirectory: true), outside = folder.appendingPathComponent("outside.png")
        try FileManager.default.createDirectory(at: pages, withIntermediateDirectories: true)
        try Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==")?
            .write(to: outside)
        func page(_ name: String) throws -> URL {
            let url = pages.appendingPathComponent("\(name).html")
            let probe = name == "c" ? "<img id='probe' src='\(outside.absoluteString)'>" : ""
            try ("<!doctype html>" + PageServer.body("/" + name).replacingOccurrences(of: "'/b'", with: "'b.html'")
                .replacingOccurrences(of: "'/c'", with: "'c.html'") + probe).write(to: url, atomically: true, encoding: .utf8)
            return url
        }
        try await Self.relaunch(try page("a"), try page("b"), try page("c"), loads: nil)
    }

    /// Shows `a`, follows its link to `b` and on to `c`, scrolls `c` down and quits; then
    /// reopens the tab's page as a relaunch does and checks the back list, the scroll position,
    /// that `c` loaded once (`loads`, the requests for it so far), and Back to `b`.
    private static func relaunch(_ a: URL, _ b: URL, _ c: URL, loads: (() -> Int)?, slowRead: Bool = false) async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        defer {
            window.orderOut(nil)
            window.close()
        }
        var stored: FrontendBrowserHistory?
        // By name: a temporary folder's path may come back through its /private link.
        func same(_ url: URL?, _ expected: URL) -> Bool { url?.lastPathComponent == expected.lastPathComponent }
        // The page `url` has loaded in `tab`: its document is complete and titled with its name.
        func shows(_ tab: WebKitTab, _ url: URL) async -> Bool {
            let name = url.deletingPathExtension().lastPathComponent
            return (try? await tab.evaluate("document.readyState === 'complete' && document.title", world: .page, gesture: .agent)) == .string(name)
        }

        // Before the quit: a, then two link clicks, then a scroll; quit saves the history.
        let first = WebKitEngine(fileInput: NoFileInput(), stores: .inMemory()).makeWebKitTab()
        window.contentView = first.contentView
        let (before, beforeTab) = service(record: a, stored: { stored }, store: { stored = $0 })
        first.load(a)
        before.track(first, for: beforeTab)
        try await until("a loads") { await shows(first, a) }
        for next in [b, c] {
            _ = try await first.evaluate("document.querySelector('a').click(); true", world: .page, gesture: .agent)
            try await until("\(next.lastPathComponent) loads") { await shows(first, next) }
        }
        _ = try await first.evaluate("scrollTo(0, 1500); true", world: .page, gesture: .agent)
        try await until("the history writer starts") { before.historyWriters[beforeTab.id] != nil }
        await before.historyWriters[beforeTab.id]?.flushNow()
        before.untrack(beforeTab.id)
        first.close()
        #expect(stored?.entries.count == 3)
        #expect(stored?.engineState != nil, "no engine state was saved")

        // After the relaunch: the tab's page starts from the saved history.
        let loadsBefore = loads?() ?? 0
        let (after, afterTab) = service(record: c, stored: { stored }, store: { stored = $0 })
        if slowRead {
            let saved = stored
            after.fetchHistory = { _, _ in
                try? await Task.sleep(for: BrowserHistoryStarts.budget + .milliseconds(500))
                return saved
            }
        }
        let page = WebKitEngine(fileInput: NoFileInput(), stores: .inMemory()).makeWebKitTab(id: BrowserTabID(rawValue: afterTab.id))
        window.contentView = page.contentView
        defer { page.close() }
        after.historyStarts.hold(page, url: c, tabID: afterTab.id)
        after.track(page, for: afterTab)
        // A local page restores once its folder load ends.
        try await until("the page starts") { ![nil, "engine-waiting-file"].contains(after.historyStarts.outcomes[afterTab.id]) }
        try await until("c loads again") { await shows(page, c) }

        func number(_ script: String) async -> Double? {
            if case .number(let value)? = try? await page.evaluate(script, world: .page, gesture: .agent) { return value }
            return nil
        }
        let length = await number("history.length")
        #expect(length == (slowRead ? 1 : 3), "the reopened page's back list has \(String(describing: length)) entries")
        #expect(after.historyStarts.outcomes[afterTab.id] == (slowRead ? "address" : "engine"))
        try? await until("the page scrolls back") { (await number("scrollY") ?? 0) >= 1400 }
        let scrollY = await number("scrollY")
        #expect((scrollY ?? 0) >= 1400, "the reopened page is at scrollY \(String(describing: scrollY))")
        if let loads {
            // Past the slow read's fallback and the read itself, which must load nothing more.
            try await Task.sleep(for: BrowserHistoryStarts.budget * 2 + .milliseconds(500))
            #expect(loads() - loadsBefore == 1, "the reopened page loaded \(loads() - loadsBefore) times")
        }

        // A local page shows no file outside its folder, after the reopen too.
        if case .bool(true)? = try? await page.evaluate("!!document.getElementById('probe')", world: .page, gesture: .agent) {
            try await Task.sleep(for: .seconds(1))
            let shown = try? await page.evaluate("document.getElementById('probe').naturalWidth > 0", world: .page, gesture: .agent)
            #expect(shown == .bool(false), "the reopened local page shows a file outside its folder")
        }

        page.goBack()
        try? await until("Back reaches b") { same(page.state.url, b) }
        #expect(same(page.state.url, b), "Back from the reopened page shows \(page.state.url?.lastPathComponent ?? "nothing")")
        after.untrack(afterTab.id)
    }

    /// A browser tab service for one app process: its daemon stores one tab's history in memory.
    private static func service(record url: URL, stored: @escaping () -> FrontendBrowserHistory?,
                                store: @escaping (FrontendBrowserHistory) -> Void) -> (BrowserTabService, TabModel) {
        let service = BrowserTabService(daemon: DaemonService(), cef: CEFEngine(layout: nil, stores: .inMemory(), signInCallbacks: CEFSignInCallbacks()))
        let tab = TabModel(TabSnapshot(surface: SurfaceID(rawValue: 7), kind: .browser, url: url.absoluteString,
                                       browserRenderer: "frontend", browserEngine: "webkit"))
        service.tabModel = { $0 == tab.id ? tab : nil }
        service.writeBackDelay = .seconds(3600)
        service.update = { _, _, _ in true }
        service.updateState = { _, _, _ in true }
        service.fetchHistory = { _, _ in stored() }
        service.storeHistory = { _, _, history in
            store(history)
            return true
        }
        return (service, tab)
    }

    private static func until(_ what: String, _ done: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(20)
        while !(await done()) {
            guard ContinuousClock.now < deadline else {
                Issue.record("timed out: \(what)")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// A local web server for three linked pages (`/c` is tall); counts the requests per path.
    nonisolated final class PageServer: @unchecked Sendable {
        private let listener: NWListener
        private let queue = DispatchQueue(label: "cn-engine-state-pages")
        private let lock = NSLock()
        private var counts: [String: Int] = [:]
        private(set) var port: UInt16 = 0
        private var ready: Bool?

        private init(listener: NWListener) { self.listener = listener }

        static func start() async throws -> PageServer {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            let server = PageServer(listener: try NWListener(using: parameters))
            server.listener.newConnectionHandler = { [server] connection in server.serve(connection) }
            let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
                // The handler runs on the server's queue only, so it reads and sets `ready` there.
                server.listener.stateUpdateHandler = { [server] state in
                    guard server.ready == nil else { return }
                    switch state {
                    case .ready:
                        server.ready = true
                        continuation.resume(returning: server.listener.port?.rawValue ?? 0)
                    case .failed(let error):
                        server.ready = false
                        continuation.resume(throwing: error)
                    default: break
                    }
                }
                server.listener.start(queue: server.queue)
            }
            server.port = port
            return server
        }

        func url(_ path: String) -> URL {
            URL(string: "http://127.0.0.1:\(port)\(path)")! // swiftlint:disable:this force_unwrapping
        }

        func count(_ path: String) -> Int {
            lock.lock()
            defer { lock.unlock() }
            return counts[path] ?? 0
        }

        func stop() { listener.cancel() }

        /// The page at `path`: `/a` links to `/b`, `/b` to `/c`, and `/c` is tall.
        static func body(_ path: String) -> String {
            switch path {
            case "/a": "<title>a</title><a href='/b'>b</a>"
            case "/b": "<title>b</title><a href='/c'>c</a>"
            case "/login": "<title>login</title><input id='name'><input id='password' type='password'>"
            case "/c": "<title>c</title><div style='height:5000px'>tall</div>"
            default: ""
            }
        }

        private func serve(_ connection: NWConnection) {
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, _, _ in
                let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                lock.lock()
                counts[path, default: 0] += 1
                lock.unlock()
                let body = Self.body(path)
                let status = body.isEmpty ? "404 Not Found" : "200 OK"
                let page = "<!doctype html>" + body
                let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html\r\nCache-Control: no-store\r\n"
                    + "Content-Length: \(page.utf8.count)\r\nConnection: close\r\n\r\n\(page)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }
}

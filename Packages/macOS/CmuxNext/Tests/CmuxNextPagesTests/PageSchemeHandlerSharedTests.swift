import CmuxNextCompat
@testable import CmuxNextPages
import Foundation
import Testing
import WebKit

/// The shared chunk table (``PageSharedChunkCache``) and the scheme handler's one-turn answer from it
/// (plans/cmux-next/chrome-parity/p13-webui.md, task 093): only bundled `.js` and `.css` files are in
/// the table, a shared request is finished before `webView(_:start:)` returns, and a dev server, dev
/// override, web update (``WebBundleOverlay/bundledShared``) or navigation takes the async path.
@MainActor
struct PageSchemeHandlerSharedTests {
    /// A scheme task that records what the handler sent, in order.
    final class RecordingTask: NSObject, WKURLSchemeTask {
        enum Event: Equatable {
            case response(Int, [String: String])
            case data(Data)
            case finish
            case fail
        }

        let request: URLRequest
        private(set) var events: [Event] = []

        init(_ request: URLRequest) {
            self.request = request
        }

        func didReceive(_ response: URLResponse) {
            let http = response as? HTTPURLResponse
            let headers = (http?.allHeaderFields ?? [:]).reduce(into: [String: String]()) { result, pair in
                if let key = pair.key as? String, let value = pair.value as? String { result[key] = value }
            }
            events.append(.response(http?.statusCode ?? 0, headers))
        }

        func didReceive(_ data: Data) { events.append(.data(data)) }
        func didFinish() { events.append(.finish) }
        func didFailWithError(_ error: any Error) { events.append(.fail) }
    }

    /// A files lane that runs the body at once and records the priority it was given.
    nonisolated final class RecordingRunner: MayBlockRunner {
        let priorities = Mutex<[MayBlockPriority]>([])

        func runFiles<T: Sendable>(_ priority: MayBlockPriority, shutdown: MayBlockShutdown,
                                   _ body: @escaping @Sendable () throws -> T) async throws -> T {
            priorities.withLock { $0.append(priority) }
            return try body()
        }

        func runSystem<T: Sendable>(_ priority: MayBlockPriority, shutdown: MayBlockShutdown,
                                    _ body: @escaping @Sendable () throws -> T) async throws -> T {
            try body()
        }

        func postFiles(_ priority: MayBlockPriority, shutdown: MayBlockShutdown, _ body: @escaping @Sendable () -> Void) {
            body()
        }
    }

    private nonisolated static let react = Data("export const React = 1;".utf8)
    private nonisolated static let style = Data("body{margin:0}".utf8)

    /// A shared folder with two served files, one nested, and files the table must leave out. The tests
    /// that read it run off the main actor, as the launch read does (the blocking seams check it).
    private nonisolated static func sharedRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("page-shared-\(UUID().uuidString)", isDirectory: true)
        let nested = root.appendingPathComponent("chunks", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Self.react.write(to: root.appendingPathComponent("react-3F2A.js"))
        try Self.style.write(to: nested.appendingPathComponent("app-91B0.css"))
        try Data("{}".utf8).write(to: root.appendingPathComponent("manifest.json"))
        try Data("<p>".utf8).write(to: root.appendingPathComponent("index.html"))
        try Data("x".utf8).write(to: root.appendingPathComponent(".hidden.js"))
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("page-shared-outside-\(UUID().uuidString).js")
        try Data("secret".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.js"), withDestinationURL: outside)
        return root
    }

    private func makeHandler(table: PageSharedChunkCache?, overlay: Bool = false) -> PageSchemeHandler {
        let root = URL(fileURLWithPath: "/nonexistent-page-root", isDirectory: true)
        let handler = PageSchemeHandler(page: .settings, root: root, devServer: nil, sharedChunks: { table })
        let live = overlay ? WebDevOverride(overlay: URL(fileURLWithPath: "/tmp/overlay")) : WebDevOverride()
        handler.liveOverride = { live }
        return handler
    }

    private func request(_ path: String, origin: String? = PageDescriptor.settings.origin,
                         method: String = "GET", navigation: Bool = false) throws -> URLRequest {
        let url = try #require(URL(string: "cmux-page://cmux.shared/" + path))
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.mainDocumentURL = navigation ? url : URL(string: PageDescriptor.settings.origin + "/")
        if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
        return request
    }

    @Test @concurrent nonisolated func theTableHoldsOnlyRegularJSAndCSSFilesInsideTheRoot() async throws {
        let root = try Self.sharedRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let table = try PageSharedChunkCache(reading: root)

        #expect(Set(table.chunks.keys) == ["react-3F2A.js", "chunks/app-91B0.css"])
        #expect(table.chunks["react-3F2A.js"] == .init(mimeType: "text/javascript", body: Self.react))
        #expect(table.chunks["chunks/app-91B0.css"]?.mimeType == "text/css")
    }

    @Test @concurrent nonisolated func aFilePastTheByteLimitIsLeftOut() async throws {
        let root = try Self.sharedRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let table = try PageSharedChunkCache(reading: root, byteLimit: Self.style.count)

        #expect(Set(table.chunks.keys) == ["chunks/app-91B0.css"])
    }

    @Test @concurrent nonisolated func aMissingRootThrows() async {
        let missing = URL(fileURLWithPath: "/nonexistent-shared-\(UUID().uuidString)", isDirectory: true)
        #expect(throws: PageSharedChunkCache.LoadError.notADirectory(missing)) { _ = try PageSharedChunkCache(reading: missing) }
    }

    @Test @concurrent nonisolated func theLaunchReadRunsOnTheFilesLaneAtADeclaredPriority() async throws {
        let root = try Self.sharedRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = RecordingRunner()

        let table = try await PageSharedChunkCache.load(from: root, runner: runner)

        #expect(table.chunks.count == 2)
        #expect(runner.priorities.withLock { $0 } == [.userVisible])
    }

    @Test func theOverlayHandsOutTheTableOnlyWhileTheBundleIsServed() throws {
        let overlay = WebBundleOverlay(bases: [])
        let table = PageSharedChunkCache(chunks: [:])
        #expect(overlay.bundledShared == nil)

        overlay.setBundledShared(table)
        #expect(overlay.bundledShared === table)

        overlay.activate(URL(fileURLWithPath: "/tmp/web-update-tree", isDirectory: true))
        #expect(overlay.bundledShared == nil)
        overlay.activate(nil)
        #expect(overlay.bundledShared === table)

        // While the launch check of a kept update runs, the update may still win: no table.
        overlay.load { URL(fileURLWithPath: "/tmp/web-update-tree", isDirectory: true) }
        #expect(overlay.bundledShared == nil)
    }

    @Test func onlySharedOriginPathsInTheTableResolve() throws {
        let table = PageSharedChunkCache(chunks: ["a.js": .init(mimeType: "text/javascript", body: Self.react)])

        func found(_ text: String) throws -> Bool {
            table.chunk(for: try #require(URL(string: text))) != nil
        }

        #expect(try found("cmux-page://cmux.shared/a.js"))
        #expect(try found("cmux-page://CMUX.SHARED/a.js"))
        #expect(try !found("cmux-page://cmux.settings/a.js"))
        #expect(try !found("https://cmux.shared/a.js"))
        #expect(try !found("cmux-page://cmux.shared/x/../a.js"))
        #expect(try !found("cmux-page://cmux.shared/"))
    }

    @Test func aSharedRequestIsAnsweredBeforeStartReturns() throws {
        let table = PageSharedChunkCache(chunks: ["react-3F2A.js": .init(mimeType: "text/javascript", body: Self.react)])
        let handler = makeHandler(table: table)
        let task = RecordingTask(try request("react-3F2A.js"))
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())

        handler.webView(webView, start: task)

        // No await between start and the check: the whole answer happened in that call.
        #expect(task.events.count == 3)
        guard case .response(let status, let headers)? = task.events.first else {
            Issue.record("no response: \(task.events)")
            return
        }
        #expect(status == 200)
        #expect(headers["Content-Type"] == "text/javascript")
        #expect(headers["X-Content-Type-Options"] == "nosniff")
        #expect(headers["Access-Control-Allow-Origin"] == PageDescriptor.settings.origin)
        #expect(Array(task.events.dropFirst()) == [.data(Self.react), .finish])
    }

    @Test func onlyAServedFirstPartyOriginGetsACORSGrant() throws {
        let table = PageSharedChunkCache(chunks: ["a.js": .init(mimeType: "text/javascript", body: Self.react)])
        let handler = makeHandler(table: table)

        for origin in ["https://example.com", "cmux-page://cmux.history", "cmux-page://cmux.shared", "null"] {
            let sent = try request("a.js", origin: origin)
            let reply = try #require(handler.sharedReply(to: sent))
            #expect(reply.response.value(forHTTPHeaderField: "Access-Control-Allow-Origin") == nil, "\(origin)")
        }
        let anonymous = try request("a.js", origin: nil)
        let none = try #require(handler.sharedReply(to: anonymous))
        #expect(none.response.value(forHTTPHeaderField: "Access-Control-Allow-Origin") == nil)
    }

    @Test func overridesUpdatesNavigationsAndMissesTakeTheAsyncPath() throws {
        let table = PageSharedChunkCache(chunks: ["a.js": .init(mimeType: "text/javascript", body: Self.react)])

        #expect(try makeHandler(table: table).sharedReply(to: request("a.js")) != nil)
        #expect(try makeHandler(table: nil).sharedReply(to: request("a.js")) == nil)
        #expect(try makeHandler(table: table, overlay: true).sharedReply(to: request("a.js")) == nil)
        #expect(try makeHandler(table: table).sharedReply(to: request("a.js", navigation: true)) == nil)
        #expect(try makeHandler(table: table).sharedReply(to: request("a.js", method: "POST")) == nil)
        #expect(try makeHandler(table: table).sharedReply(to: request("missing.js")) == nil)

        let server = try #require(PageDevServer.resolve(
            environment: [PageDevServer.variable: "http://127.0.0.1:4190/"], allowsDevServer: true))
        let dev = PageSchemeHandler(page: .settings, root: URL(fileURLWithPath: "/nonexistent-page-root"),
                                    devServer: server, sharedChunks: { table })
        dev.liveOverride = { WebDevOverride() }
        #expect(try dev.sharedReply(to: request("a.js")) == nil)
    }
}

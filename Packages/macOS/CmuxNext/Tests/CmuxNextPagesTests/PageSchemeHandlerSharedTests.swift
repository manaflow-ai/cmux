import CmuxNextCompat
@testable import CmuxNextPages
import CmuxNextWakeups
import Foundation
import Testing
import WebKit

/// The shared chunk table (``PageSharedChunkCache``) and the WebKit scheme handler's answer from it in the
/// start turn (plans/cmux-next/chrome-parity/p13-webui.md, task 093): only regular `.js` and `.css` files of
/// the bundled shared folder are in the table, it is read once on the files lane, a shared request is
/// finished before `webView(_:start:)` returns with the async path's exact answer, and an overlay, a Debug
/// override, a web update, another folder's table or a file the table lacks takes the async path.
@MainActor
struct PageSchemeHandlerSharedTests {
    /// A scheme task that records what the handler sent, in order.
    final class RecordingTask: NSObject, WKURLSchemeTask {
        enum Event: Equatable {
            case response(Int)
            case data(Data)
            case finish
            case fail
        }

        let request: URLRequest
        private(set) var events: [Event] = []
        private(set) var response: HTTPURLResponse?
        /// Called once the task finished or failed.
        var ended: () -> Void = {}

        init(_ request: URLRequest) {
            self.request = request
        }

        func didReceive(_ response: URLResponse) {
            self.response = response as? HTTPURLResponse
            events.append(.response(self.response?.statusCode ?? 0))
        }

        func didReceive(_ data: Data) { events.append(.data(data)) }
        func didFinish() { events.append(.finish); ended() }
        func didFailWithError(_ error: any Error) { events.append(.fail); ended() }
    }

    /// The app's real lanes, recording the priority of each posted files item once it ran.
    nonisolated struct RecordingRunner: MayBlockRunner {
        let lanes: BackgroundWork
        let ran: AsyncStream<MayBlockPriority>.Continuation

        func runFiles<T: Sendable>(_ priority: MayBlockPriority, shutdown: MayBlockShutdown, site: MayBlockCallSite,
                                   _ body: @escaping @Sendable () throws -> T) async throws -> T {
            try await lanes.runFiles(priority, shutdown: shutdown, site: site, body)
        }

        func runSystem<T: Sendable>(_ priority: MayBlockPriority, shutdown: MayBlockShutdown, site: MayBlockCallSite,
                                    _ body: @escaping @Sendable () throws -> T) async throws -> T {
            try await lanes.runSystem(priority, shutdown: shutdown, site: site, body)
        }

        func runHostResolution<T: Sendable>(_ priority: MayBlockPriority, shutdown: MayBlockShutdown, site: MayBlockCallSite,
                                            _ body: @escaping @Sendable () throws -> T) async throws -> T {
            try await lanes.runHostResolution(priority, shutdown: shutdown, site: site, body)
        }

        func postFiles(_ priority: MayBlockPriority, shutdown: MayBlockShutdown, site: MayBlockCallSite,
                       _ body: @escaping @Sendable () -> Void) {
            let ran = ran
            lanes.postFiles(priority, shutdown: shutdown, site: site) {
                body()
                ran.yield(priority)
            }
        }
    }

    private static let react = Data("export const React = 1;".utf8)
    private static let style = Data("body{margin:0}".utf8)

    /// A shared folder with two served files (one nested), files the table leaves out (a data file, a
    /// document, a hidden script, a link to a script outside the folder), and a page root beside it.
    private struct Fixture {
        let base: URL
        let shared: URL
        let pageRoot: URL

        init() throws {
            base = FileManager.default.temporaryDirectory
                .appendingPathComponent("page-shared-turn-\(UUID().uuidString)", isDirectory: true)
            shared = base.appendingPathComponent("_shared", isDirectory: true)
            pageRoot = base.appendingPathComponent("settings", isDirectory: true)
            let nested = shared.appendingPathComponent("chunks", isDirectory: true)
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: pageRoot, withIntermediateDirectories: true)
            try Data("<!doctype html>".utf8).write(to: pageRoot.appendingPathComponent("index.html"))
            try PageSchemeHandlerSharedTests.react.write(to: shared.appendingPathComponent("react-3F2A.js"))
            try PageSchemeHandlerSharedTests.style.write(to: nested.appendingPathComponent("app-91B0.css"))
            try Data("{}".utf8).write(to: shared.appendingPathComponent("manifest.json"))
            try Data("<p>".utf8).write(to: shared.appendingPathComponent("index.html"))
            try Data("x".utf8).write(to: shared.appendingPathComponent(".hidden.js"))
            let outside = base.appendingPathComponent("outside.js")
            try Data("secret".utf8).write(to: outside)
            try FileManager.default.createSymbolicLink(at: shared.appendingPathComponent("link.js"), withDestinationURL: outside)
        }

        /// The table of ``shared``, read on the files lane as the launch read is.
        func table(byteLimit: Int = PageSharedChunkCache.defaultByteLimit) async throws -> PageSharedChunkCache {
            let shared = shared
            return try await BackgroundWork().runFiles(.userVisible) { try PageSharedChunkCache(reading: shared, byteLimit: byteLimit) }
        }

        /// A Settings handler serving ``shared`` with `table` in memory, the live override `live` and the
        /// Debug shared override `debug`.
        func handler(table: PageSharedChunkCache?, live: WebDevOverride = WebDevOverride(), debug: URL? = nil,
                     trace: PageTraceRecorder = PageTraceRecorder()) -> PageSchemeHandler {
            let handler = PageSchemeHandler(page: .settings, root: pageRoot, devServer: nil, trace: trace,
                                            sharedRoot: shared, debugSharedRoot: debug)
            handler.liveOverride = { live }
            handler.sharedChunks = { table }
            return handler
        }

        func remove() { try? FileManager.default.removeItem(at: base) }
    }

    private static func url(_ path: String) throws -> URL {
        try #require(URL(string: "cmux-page://cmux.shared/" + path))
    }

    private static func request(_ path: String, origin: String? = PageDescriptor.settings.origin,
                                navigation: Bool = false) throws -> URLRequest {
        let url = try url(path)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.mainDocumentURL = navigation ? url : URL(string: PageDescriptor.settings.origin + "/")
        if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
        return request
    }

    private static func headers(_ reply: PageSchemeHandler.Reply) -> [String: String] {
        reply.response.allHeaderFields.reduce(into: [:]) { result, pair in
            if let key = pair.key as? String, let value = pair.value as? String { result[key] = value }
        }
    }

    // MARK: the table

    @Test func theTableHoldsOnlyRegularJSAndCSSFilesInsideTheRoot() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let table = try await fixture.table()

        #expect(Set(table.chunks.keys) == ["react-3F2A.js", "chunks/app-91B0.css"])
        #expect(table.chunks["react-3F2A.js"]?.body == Self.react)
        #expect(table.chunks["chunks/app-91B0.css"]?.body == Self.style)
        #expect(table.serves(fixture.shared))
        #expect(!table.serves(fixture.pageRoot))
    }

    @Test func aFilePastTheByteLimitIsLeftOut() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        // Path order reads chunks/app-91B0.css first; the script would pass the limit.
        let table = try await fixture.table(byteLimit: Self.style.count)

        #expect(Set(table.chunks.keys) == ["chunks/app-91B0.css"])
    }

    @Test func aMissingRootThrows() async {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("no-shared-\(UUID().uuidString)", isDirectory: true)
        await #expect(throws: PageSharedChunkCache.LoadError.notADirectory(missing)) {
            _ = try await BackgroundWork().runFiles(.userVisible) { try PageSharedChunkCache(reading: missing) }
        }
    }

    @Test func onlySharedOriginPathsInTheTableResolve() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let table = try await fixture.table()

        func found(_ text: String) throws -> Bool { table.chunk(for: try #require(URL(string: text))) != nil }

        #expect(try found("cmux-page://cmux.shared/react-3F2A.js"))
        #expect(try found("cmux-page://CMUX.SHARED/chunks/app-91B0.css"))
        #expect(try !found("cmux-page://cmux.settings/react-3F2A.js"))
        #expect(try !found("https://cmux.shared/react-3F2A.js"))
        #expect(try !found("cmux-page://cmux.shared/chunks/../react-3F2A.js"))
        #expect(try !found("cmux-page://cmux.shared/manifest.json"))
        #expect(try !found("cmux-page://cmux.shared/link.js"))
        #expect(try !found("cmux-page://cmux.shared/"))
    }

    // MARK: the launch read

    @Test func theLaunchReadRunsOnTheFilesLaneAtUserVisibleAndKeepsTheTable() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let overlay = WebBundleOverlay(bases: [])
        let (ran, record) = AsyncStream.makeStream(of: MayBlockPriority.self)
        let shared = fixture.shared

        #expect(overlay.bundledShared == nil)
        overlay.readShared(on: RecordingRunner(lanes: BackgroundWork(), ran: record)) { shared }
        var priorities = ran.makeAsyncIterator()

        #expect(await priorities.next() == .userVisible)
        let table = try #require(overlay.bundledShared)
        #expect(table.serves(fixture.shared))
        #expect(table.chunks.count == 2)
    }

    @Test func noSharedFolderKeepsNoTable() async {
        let overlay = WebBundleOverlay(bases: [])
        let (ran, record) = AsyncStream.makeStream(of: MayBlockPriority.self)

        overlay.readShared(on: RecordingRunner(lanes: BackgroundWork(), ran: record)) { nil }
        var priorities = ran.makeAsyncIterator()

        #expect(await priorities.next() == .userVisible)
        #expect(overlay.bundledShared == nil)
    }

    @Test func theOverlayHandsOutTheTableOnlyWhileTheBundleIsServed() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let overlay = WebBundleOverlay(bases: [])
        let (ran, record) = AsyncStream.makeStream(of: MayBlockPriority.self)
        let shared = fixture.shared
        overlay.readShared(on: RecordingRunner(lanes: BackgroundWork(), ran: record)) { shared }
        var priorities = ran.makeAsyncIterator()
        _ = await priorities.next()
        let update = fixture.base.appendingPathComponent("web-update", isDirectory: true)

        #expect(overlay.bundledShared != nil)
        overlay.activate(update)
        #expect(overlay.bundledShared == nil, "a web update serves its own shared files")
        overlay.activate(nil)
        #expect(overlay.bundledShared != nil)

        // While the launch check of a kept update runs, the update may still win: no table.
        let (gate, open) = AsyncStream.makeStream(of: Void.self)
        overlay.load {
            for await _ in gate {}
            return nil
        }
        #expect(overlay.bundledShared == nil)
        open.finish()
    }

    // MARK: the start turn

    @Test func aSharedRequestIsAnsweredBeforeStartReturnsWithNoTaskHop() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let trace = PageTraceRecorder()
        let handler = fixture.handler(table: try await fixture.table(), trace: trace)
        let task = RecordingTask(try Self.request("react-3F2A.js"))
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())

        handler.webView(webView, start: task)

        // No await between start and these checks: the whole answer happened in that call.
        #expect(task.events == [.response(200), .data(Self.react), .finish])
        let response = try #require(task.response)
        #expect(response.value(forHTTPHeaderField: "Content-Type") == "text/javascript")
        #expect(response.value(forHTTPHeaderField: "Access-Control-Allow-Origin") == PageDescriptor.settings.origin)
        #expect(response.value(forHTTPHeaderField: "Vary") == "Origin")
        #expect(response.value(forHTTPHeaderField: "Content-Security-Policy") == PageID.sharedChunkPolicy)
        #expect(response.value(forHTTPHeaderField: "X-Content-Type-Options") == "nosniff")
        let slices = try trace.schemeSlices()
        #expect(slices.map(\.part) == [PageSchemeHandler.TracePart.start.rawValue], "the answer took a reply or answer turn")
        #expect(slices.first?.outcome == 0)
        #expect(slices.first?.bytes == UInt64(Self.react.count))
    }

    @Test func theTurnsAnswerIsTheAsyncPathsAnswer() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let handler = fixture.handler(table: try await fixture.table())

        for path in ["react-3F2A.js", "chunks/app-91B0.css"] {
            let url = try Self.url(path)
            let origin = PageDescriptor.history.origin
            let mainDocument = URL(string: origin + "/")
            let turn = try #require(handler.sharedReplyInTurn(to: url, origin: origin, mainDocument: mainDocument))
            let async = try #require(await handler.sharedReply(to: url, origin: origin, mainDocument: mainDocument))
            #expect(turn.body == async.body, "\(path)")
            #expect(turn.response.statusCode == async.response.statusCode, "\(path)")
            #expect(Self.headers(turn) == Self.headers(async), "\(path)")
        }
    }

    @Test func refusedOriginsAndNavigationsGetNoAnswerFromTheTable() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let handler = fixture.handler(table: try await fixture.table())
        let url = try Self.url("react-3F2A.js")
        let mainDocument = URL(string: PageDescriptor.settings.origin + "/")

        for origin: String? in [nil, "null", "https://example.com", "cmux-page://cmux.shared", "cmux-page://com.example.notes"] {
            #expect(handler.sharedReplyInTurn(to: url, origin: origin, mainDocument: mainDocument) == nil, "\(origin ?? "no Origin")")
        }
        #expect(handler.sharedReplyInTurn(to: url, origin: PageDescriptor.settings.origin, mainDocument: url) == nil)
        let page = try #require(URL(string: PageDescriptor.settings.origin + "/react-3F2A.js"))
        #expect(handler.sharedReplyInTurn(to: page, origin: PageDescriptor.settings.origin, mainDocument: mainDocument) == nil)

        // Through the start callback a refused origin fails in its start turn, as before.
        let task = RecordingTask(try Self.request("react-3F2A.js", origin: "https://example.com"))
        handler.webView(WKWebView(frame: .zero, configuration: WKWebViewConfiguration()), start: task)
        #expect(task.events == [.fail])
    }

    @Test func overlaysOverridesOtherTablesAndMissesTakeTheAsyncPath() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let table = try await fixture.table()
        let url = try Self.url("react-3F2A.js")
        let origin = PageDescriptor.settings.origin
        let mainDocument = URL(string: origin + "/")
        func inTurn(_ handler: PageSchemeHandler, _ url: URL) -> Bool {
            handler.sharedReplyInTurn(to: url, origin: origin, mainDocument: mainDocument) != nil
        }

        #expect(inTurn(fixture.handler(table: table), url))
        #expect(!inTurn(fixture.handler(table: nil), url), "no table yet, or a web update serves")
        #expect(!inTurn(fixture.handler(table: table, live: WebDevOverride(overlay: fixture.base)), url),
                "a web-dev.json overlay serves its own shared files")
        #expect(!inTurn(fixture.handler(table: table, debug: fixture.base), url), "the Debug shared override serves")
        let other = PageSharedChunkCache(root: fixture.pageRoot, chunks: table.chunks)
        #expect(!inTurn(fixture.handler(table: other), url), "a table of another folder never answers")
        #expect(!inTurn(fixture.handler(table: table), try Self.url("link.js")), "a file the table left out")
    }

    @Test func aFileTheTableLacksIsStillServedOnTheAsyncPath() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let trace = PageTraceRecorder()
        let empty = PageSharedChunkCache(root: fixture.shared, chunks: [:])
        let handler = fixture.handler(table: empty, trace: trace)
        let task = RecordingTask(try Self.request("react-3F2A.js"))

        let ended: Bool? = await PageTestWait.value("answer") { done in
            task.ended = { done(true) }
            handler.webView(WKWebView(frame: .zero, configuration: WKWebViewConfiguration()), start: task)
        }

        #expect(ended == true)
        #expect(task.events == [.response(200), .data(Self.react), .finish])
        #expect(try trace.schemeSlices().last?.part == PageSchemeHandler.TracePart.answer.rawValue)
    }
}

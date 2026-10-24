@testable import CmuxNextPages
import CmuxNextErrorJournal
import CmuxNextPagesTestSupport
import Foundation
import Testing

/// A page's console errors go to the recorder the page was made with, in both engines. Before,
/// PageWebView read an ambient static (`PageWebView.errorJournal`) that AppDelegate set during
/// launch: a page made before that line (a launch path or prewarm that moved earlier, Home's
/// start) or in a composition that never set it (tests, previews, a second host) recorded
/// nothing, and the log harvest leaves the page console subsystem out, so `cmux errors` never
/// showed those errors.
@MainActor
struct PageConsoleErrorsTests {
    private let root: URL
    private let descriptor = PageDescriptor(id: "test.console-page", resource: "console-page", namespaces: [])

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("page-console-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<!doctype html><title>Page</title>".utf8).write(to: root.appendingPathComponent("index.html"))
    }

    @Test(.timeLimit(.minutes(1))) func aWebKitPagesConsoleErrorReachesItsRecorder() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let errors = RecordedErrors()
        let view = try #require(PageWebView(descriptor: descriptor, root: root, routes: [], route: "#/", chromium: nil,
                                            errors: errors))
        await view.waitUntilLoaded()
        _ = try await view.webKitView.evaluateJavaScript("console.error('boom from the page'); 1")
        var events = errors.events.makeAsyncIterator()
        let event = try #require(await events.next())
        #expect(event.source == "page:\(descriptor.id)")
        #expect(event.level == .error)
        #expect(event.message == "boom from the page")
        view.close()
    }

    @Test(.timeLimit(.minutes(1))) func aChromiumPagesConsoleErrorReachesItsRecorder() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        let errors = RecordedErrors()
        let view = try #require(PageWebView(descriptor: descriptor, root: root, routes: [], route: "#/", chromium: hosting,
                                            errors: errors))
        view.chromiumClock = PageTestClock.never
        await view.chromiumStart?.value
        let page = try #require(hosting.made.first)
        page.onEvent?(.devTools(FakeChromiumPage.bindingCall([
            "name": ConsoleErrorCapture.handlerName,
            "body": ["level": "warn", "message": "theme token missing", "stack": ""],
        ])))
        var events = errors.events.makeAsyncIterator()
        let event = try #require(await events.next())
        #expect(event.source == "page:\(descriptor.id)")
        #expect(event.level == .warning)
        view.close()
    }
}

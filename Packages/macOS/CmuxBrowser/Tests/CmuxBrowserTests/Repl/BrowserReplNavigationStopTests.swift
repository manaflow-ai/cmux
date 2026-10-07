import Foundation
import Testing
import WebKit

@testable import CmuxBrowser

/// A session's navigation of a user's tab is its doing only while the
/// session may use the tab. When the user moves the tab to another
/// workspace before the navigation commits, the session leaves the tab and
/// its navigation is stopped there: the load is cancelled before any
/// response commits, and the session's wait ends at once.
@MainActor
@Suite("Browser REPL: a navigation stopped before it commits", .serialized)
struct BrowserReplNavigationStopTests {
    @Test func aStoppedNavigationNeverCommits() async throws {
        let handler = HeldPageSchemeHandler()
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(handler, forURLScheme: "cmux-held")
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 300, height: 200), configuration: configuration)
        webView.load(URLRequest(url: URL(string: "cmux-held://tab.test/")!))
        try await Self.until { webView.url?.path == "/" && !webView.isLoading }

        let coordinator = BrowserAutomationNavigationCoordinator()
        let instanceID = UUID()
        coordinator.bind(to: instanceID)
        let target = URL(string: "cmux-held://tab.test/held")!
        let ticket = coordinator.begin(instanceID: instanceID, targetURL: target)
        let navigation = webView.load(URLRequest(url: target))
        coordinator.didStart(ticket, navigationID: navigation.map { ObjectIdentifier($0) })
        let wait = Task { @MainActor in await coordinator.wait(for: ticket) }
        try await Self.until { handler.heldTask != nil }

        #expect(coordinator.stop(ticket, loading: webView))
        #expect(await wait.value == .cancelled)
        try await Self.until { handler.heldTaskStopped }
        // The response the page server sends now reaches no task.
        #expect(!handler.releaseHeld())
        #expect(webView.url?.path == "/")
        // A navigation that already ended is not stopped again.
        #expect(!coordinator.stop(ticket, loading: webView))
    }

    static func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw BrowserReplDriverError(code: "timeout", message: "condition not met") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

/// Answers `/` at once and holds `/held` until ``releaseHeld()``.
final class HeldPageSchemeHandler: NSObject, WKURLSchemeHandler {
    private(set) var heldTask: (any WKURLSchemeTask)?
    private(set) var heldTaskStopped = false

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        if url.path == "/held" {
            heldTask = task
            return
        }
        respond(task, url: url)
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        if task === heldTask { heldTaskStopped = true }
    }

    /// Answers the held request unless WebKit stopped it; whether it answered.
    func releaseHeld() -> Bool {
        guard let task = heldTask, !heldTaskStopped, let url = task.request.url else { return false }
        respond(task, url: url)
        return true
    }

    private func respond(_ task: any WKURLSchemeTask, url: URL) {
        task.didReceive(URLResponse(url: url, mimeType: "text/html", expectedContentLength: -1, textEncodingName: "utf-8"))
        task.didReceive(Data("<p>\(url.path)</p>".utf8))
        task.didFinish()
    }
}

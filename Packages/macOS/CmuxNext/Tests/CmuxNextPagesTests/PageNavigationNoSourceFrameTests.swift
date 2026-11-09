@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import Foundation
import Testing
import WebKit

/// macOS 14's WebKit asks a page's navigation delegate about some navigations with no source frame
/// (`sourceFrame` nil although WebKit declares it nonnull). Reading its request through the Swift
/// type bridged a nil `NSURLRequest` and trapped: the app ended at launch on macOS 14.8.7 (Tart smoke
/// of 66339d310c0, `URLRequest._unconditionallyBridgeFromObjectiveC` under
/// `PageWebView.webView(_:decidePolicyFor:)`). The policy is answered as with an unknown source.
@MainActor
struct PageNavigationNoSourceFrameTests {
    @Test func aNavigationWithNoSourceFrameGetsThePolicyNotATrap() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("page-no-source-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("<!doctype html><title>Page</title>".utf8).write(to: root.appendingPathComponent("index.html"))
        let hosting = FakeChromiumHosting()
        hosting.preference = .webkit
        let descriptor = PageDescriptor(id: "test.no-source-frame", resource: "no-source-frame", namespaces: [])
        let view = try #require(PageWebView(descriptor: descriptor, root: root, routes: [], chromium: hosting))
        defer { view.close() }
        var opened: [URL] = []
        view.onOpenExternal = { opened.append($0) }

        #expect(await view.webView(view.webView, decidePolicyFor: FakeNavigationAction(url: descriptor.url())) == .allow)

        let link = try #require(URL(string: "https://example.com/docs"))
        #expect(await view.webView(view.webView, decidePolicyFor: FakeNavigationAction(url: link, type: .linkActivated)) == .cancel)
        #expect(opened == [link])

        let redirect = try #require(URL(string: "https://example.com/elsewhere"))
        #expect(await view.webView(view.webView, decidePolicyFor: FakeNavigationAction(url: redirect)) == .cancel)
        #expect(opened == [link])
    }
}

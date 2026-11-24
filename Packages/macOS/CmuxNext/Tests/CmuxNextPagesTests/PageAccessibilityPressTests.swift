import AppKit
@testable import CmuxNextPages
import Foundation
import Testing
import WebKit

/// manaflow-ai/cmux#37809, cmux#40314 F1: a VoiceOver press (AXPress) on a WebKit page reaches the
/// page as a trusted click with no key or mouse event in the view (``PageAccessibilityPress``). With
/// VoiceOver running it backs the next page call as the person's gesture, with a mouse event's expiry;
/// page script's own clicks, and page script posting to the press handler, never do.
@MainActor @Suite(.serialized)
struct PageAccessibilityPressTests {
    static let html = "<!doctype html><title>Press</title><button id=b>Open</button>"

    /// A WebKit page on a fixture document, loaded, with VoiceOver on or off.
    static func page(voiceOver: Bool) async throws -> (PageWebView, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("page-ax-press-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(html.utf8).write(to: root.appendingPathComponent("index.html"))
        let descriptor = PageDescriptor(id: "test.ax-press", resource: "ax-press", namespaces: [])
        let view = try #require(PageWebView(descriptor: descriptor, root: root, testRoot: true, routes: [], chromium: nil))
        view.webView.isVoiceOverRunning = { voiceOver }
        await view.waitUntilLoaded()
        return (view, root)
    }

    /// Runs `body` in the page's own world (`.page`), where page script runs.
    static func pageScript(_ view: PageWebView, _ body: String) async throws -> Any? {
        try await view.webView.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: .page)
    }

    /// The press world's post, as its click listener makes it for a trusted click (an AXPress has no other
    /// trace a test can make without the Accessibility grant: WebKit's press runs in the web process).
    static func trustedClickPost(_ view: PageWebView) async throws {
        _ = try await view.webView.callAsyncJavaScript(
            "window.webkit.messageHandlers.\(PageAccessibilityPress.handlerName).postMessage(1); return true;",
            arguments: [:], in: nil, contentWorld: PageAccessibilityPress.world)
    }

    @Test func thePressScriptRunsInItsOwnWorldOnTheWebKitPageOnly() async throws {
        let (view, root) = try await Self.page(voiceOver: true)
        defer { view.close(); try? FileManager.default.removeItem(at: root) }
        let sources = view.webView.configuration.userContentController.userScripts.map(\.source)
        #expect(sources.filter { $0 == PageAccessibilityPress.script }.count == 1)
        let press = view.webView.configuration.userContentController.userScripts.filter { $0.source == PageAccessibilityPress.script }
        #expect(press.allSatisfy { $0.isForMainFrameOnly })
        // Chromium gets its own press path (ChromiumAccessibilityPress), never this script.
        #expect(!PageChromiumDocumentScripts(controller: view.webView.configuration.userContentController).sources
            .contains { $0.contains(PageAccessibilityPress.handlerName) })
        // Page script sees no handler of that name and so cannot post to it.
        #expect(try await Self.pageScript(view, "return typeof window.webkit.messageHandlers.\(PageAccessibilityPress.handlerName);") as? String
            == "undefined")
        #expect(try await view.webView.callAsyncJavaScript("return window.__cmuxAccessibilityPress === true;", arguments: [:], in: nil,
                                                          contentWorld: PageAccessibilityPress.world) as? Bool == true)
    }

    @Test func aTrustedClickWithNoMouseEventIsAGestureWhileVoiceOverRuns() async throws {
        let (view, root) = try await Self.page(voiceOver: true)
        defer { view.close(); try? FileManager.default.removeItem(at: root) }
        #expect(view.recentUserGestureEvent() == nil, "no key or mouse event reached the view")
        try await Self.trustedClickPost(view)
        let gesture = try #require(view.router.userGestureEvent?())
        // A mouse event's expiry: one second.
        #expect(view.recentUserGestureEvent(now: gesture + 0.9) == gesture)
        #expect(view.recentUserGestureEvent(now: gesture + 1.1) == nil)
    }

    @Test func withoutVoiceOverATrustedClickAloneIsNoGesture() async throws {
        let (view, root) = try await Self.page(voiceOver: false)
        defer { view.close(); try? FileManager.default.removeItem(at: root) }
        try await Self.trustedClickPost(view)
        #expect(view.recentUserGestureEvent() == nil)
        #expect(!view.webView.noteAccessibilityPress())
    }

    /// Page script's own clicks are untrusted: `click()`, a dispatched click, a click forwarded through a
    /// label. None posts, so none is a gesture, VoiceOver on or not.
    @Test func pageScriptClicksAreRefused() async throws {
        let (view, root) = try await Self.page(voiceOver: true)
        defer { view.close(); try? FileManager.default.removeItem(at: root) }
        _ = try await Self.pageScript(view, """
            const b = document.getElementById('b');
            b.click();
            b.dispatchEvent(new MouseEvent('click', { bubbles: true, detail: 0 }));
            const label = document.createElement('label');
            label.htmlFor = 'b';
            document.body.append(label);
            label.click();
            return true;
            """)
        // A round trip in the press world: any post the clicks made would have arrived before its reply.
        #expect(try await view.webView.callAsyncJavaScript("return true;", arguments: [:], in: nil,
                                                          contentWorld: PageAccessibilityPress.world) as? Bool == true)
        #expect(view.recentUserGestureEvent() == nil)
    }
}

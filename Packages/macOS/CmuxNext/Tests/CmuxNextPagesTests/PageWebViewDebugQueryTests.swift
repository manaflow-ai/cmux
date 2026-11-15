#if DEBUG
@testable import CmuxNextPages
import CmuxNextSettings
import AppKit
import Foundation
import Testing

/// `debug.page {action: "query"}` (and `debug.agent_pane`'s, PageDebugQuery): a capture's read-back of a
/// toast stack checks that it is a region named "Notifications" (cmux#42016), so the query answers each
/// element's `role` and accessible `label` beside its data, classes and text.
@MainActor
struct PageWebViewDebugQueryTests {
    private let root: URL
    private let descriptor = PageDescriptor(id: "test.query-page", resource: "query-page", namespaces: [])

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("page-query-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    @Test func aQueryAnswersRoleAndAccessibleName() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let view = try await webKitPage("""
        <!doctype html><title>Query</title>
        <div class="ui-notice-stack" role="region" aria-label="Notifications" data-layout="stacked"></div>
        <h2 id="t">Needs you</h2><section class="named" role="group" aria-labelledby="t"><p>row</p></section>
        <p class="plain">Couldn't start the chat.</p>
        <p class="ready">ready</p>
        """)
        defer { view.close() }
        let stack = await view.debugQuery(".ui-notice-stack")
        #expect(stack == ["elements": [["data": ["layout": "stacked"], "classes": ["ui-notice-stack"], "text": "",
                                        "role": "region", "label": "Notifications"]]])
        let named = await view.debugQuery(".named")
        #expect(named["elements"]?.arrayValue?.first?["role"] == "group")
        #expect(named["elements"]?.arrayValue?.first?["label"] == "Needs you")
        // No role and no name: neither key, so a read-back of `label` never matches an empty string.
        let plain = await view.debugQuery(".plain")
        #expect(plain == ["elements": [["data": [:], "classes": ["plain"], "text": "Couldn't start the chat."]]])
    }

    @Test func anAnswerThatIsNotJSONIsAnError() {
        #expect(PageDebugQuery.answer(nil) == ["error": "query failed"])
        #expect(PageDebugQuery.answer("[]") == ["elements": []])
    }

    /// A WebKit page that shows `html`, 400 by 300 points, once `.ready` is drawn.
    private func webKitPage(_ html: String) async throws -> PageWebView {
        try Data(html.utf8).write(to: root.appendingPathComponent("index.html"))
        let view = try #require(PageWebView(descriptor: descriptor, root: root, testRoot: true, routes: [], route: "#/", chromium: nil))
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        var ready: JSONValue = ["matched": false]
        for _ in 0..<20 where ready["matched"] != true {
            ready = await view.debugWait(selector: ".ready", timeoutMilliseconds: 5_000)
        }
        try #require(ready["matched"] == true, "the test page did not load: \(ready)")
        return view
    }
}
#endif

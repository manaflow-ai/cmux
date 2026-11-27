#if DEBUG
@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import CmuxNextSettings
import AppKit
import Foundation
import Testing

/// `debug.page {action: "scroll"}`: the matching element scrolled into view by page script, so a
/// capture shows a Settings card below the fold with no wheel or key event.
@MainActor
struct PageWebViewDebugScrollTests {
    private let root: URL
    private let descriptor = PageDescriptor(id: "test.scroll-page", resource: "scroll-page", namespaces: [])

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("page-scroll-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<!doctype html><title>Page</title>".utf8).write(to: root.appendingPathComponent("index.html"))
    }

    private func chromiumPage(answer: String?) async throws -> (PageWebView, FakeChromiumPage) {
        let hosting = FakeChromiumHosting()
        let view = try #require(PageWebView(descriptor: descriptor, root: root, routes: [], route: "#/", chromium: hosting))
        view.chromiumClock = PageTestClock.never
        await view.chromiumStart?.value
        let page = try #require(hosting.made.first)
        page.answer = { method, params in
            guard method == "Runtime.evaluate", let expression = params["expression"] as? String,
                  expression.contains("scrollIntoView") else { return nil }
            guard let answer else { return #"{"result":{"type":"object","subtype":"null","value":null}}"# }
            return #"{"result":{"type":"string","value":\#(JSONValue.string(answer).compactText)}}"#
        }
        return (view, page)
    }

    @Test func scrollReportsWhereTheElementLanded() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (view, page) = try await chromiumPage(answer: #"{"top":0,"height":180,"viewport":720}"#)
        let result = await view.debugScroll(#"[data-card="tailnet"]"#, block: "start")
        #expect(result == ["scrolled": true, "top": 0, "height": 180, "viewport": 720])
        let call = try #require(page.calls.first { ($0.params["expression"] as? String)?.contains("scrollIntoView") == true })
        let expression = try #require(call.params["expression"] as? String)
        #expect(expression.contains("tailnet"))
        #expect(expression.contains("start"))
        view.close()
    }

    @Test func scrollOfNoMatchingElementIsNotAScroll() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (view, _) = try await chromiumPage(answer: #"{"reason":"no match"}"#)
        #expect(await view.debugScroll(".missing") == ["scrolled": false, "reason": "no match"])
        view.close()
    }

    /// A chat table's last heading, scrolled to, while the pointer rests on the table: the Open and
    /// Copy pill (`.cv-table-tools`, `pointer-events: auto` on hover) sits in the room the heading
    /// keeps after its word, over the middle of a short heading's box. The word shows, so it is in
    /// view (markdown-table-motion on capture mini cmux24 failed "is not in view after the scroll").
    @Test func aHeadingWhoseWordShowsBesideAnOverlayIsInView() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let view = try await webKitPage(Self.tablePage(overlay: "top: 0; right: 0; width: 64px; height: 30px;"))
        let result = await view.debugScroll("thead th:last-child", block: "nearest")
        #expect(result["scrolled"] == true, "\(result)")
        view.close()
    }

    /// A sheet over all of the element, its words included, still fails the scroll.
    @Test func anElementUnderASheetIsStillNotInView() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let view = try await webKitPage(Self.tablePage(overlay: "inset: 0;"))
        let result = await view.debugScroll("thead th:last-child", block: "nearest")
        #expect(result == ["scrolled": false, "reason": "not in view"])
        view.close()
    }

    /// The chat's table shape: a 300 px sideways scroller whose last heading keeps 70 px after its
    /// word, and an absolutely placed layer over the block (`overlay`: its box) that takes the pointer.
    private static func tablePage(overlay: String) -> String {
        """
        <!doctype html><title>Page</title>
        <style>
          body { margin: 0; font: 13px -apple-system, sans-serif; }
          .block { position: relative; width: fit-content; max-width: 300px; }
          .wrap { overflow-x: auto; }
          table { border-collapse: collapse; }
          th { padding: 8px 12px; white-space: nowrap; text-align: left; }
          th:last-child { padding-right: 70px; }
          .tools { position: absolute; z-index: 1; pointer-events: auto; background: #ddd; \(overlay) }
        </style>
        <div class="block"><div class="tools"></div><div class="wrap"><table><thead><tr>
          <th>Area</th><th>File</th><th>Owner</th><th>State</th><th>Opened</th><th>Rows</th><th>Why</th>
        </tr></thead></table></div></div>
        <p class="ready">ready</p>
        """
    }

    /// A WebKit page that shows `html`, 400 by 300 points, once `.ready` is drawn.
    private func webKitPage(_ html: String) async throws -> PageWebView {
        try Data(html.utf8).write(to: root.appendingPathComponent("index.html"))
        let view = try #require(PageWebView(descriptor: descriptor, root: root, routes: [], route: "#/", chromium: nil))
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        // The view's first navigation replaces the blank document: a wait that started on it ends
        // "page left", so it is asked again on the loaded page.
        var ready: JSONValue = ["matched": false]
        for _ in 0..<20 where ready["matched"] != true {
            ready = await view.debugWait(selector: ".ready", timeoutMilliseconds: 5_000)
        }
        try #require(ready["matched"] == true, "the test page did not load: \(ready)")
        return view
    }

    /// A match with no box (`display: none`) or one still out of view is never a scroll, so a capture
    /// does not shoot the unchanged fold as a pass.
    @Test func aHiddenOrClippedElementIsNotAScroll() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        for reason in ["not rendered", "not in view"] {
            let (view, _) = try await chromiumPage(answer: #"{"reason":"\#(reason)"}"#)
            #expect(await view.debugScroll(".card") == ["scrolled": false, "reason": .string(reason)])
            view.close()
        }
    }
}
#endif

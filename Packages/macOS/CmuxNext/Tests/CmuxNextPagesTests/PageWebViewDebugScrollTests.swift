#if DEBUG
@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import CmuxNextSettings
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

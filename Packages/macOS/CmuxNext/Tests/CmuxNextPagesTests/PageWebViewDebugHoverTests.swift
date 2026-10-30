#if DEBUG
@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import CmuxNextSettings
import Foundation
import Testing

/// `debug.page {action: "hover"}` on a Chromium page: a trusted DevTools mouse move to the
/// matching element's center, so the page gets real hover (`:hover`, `mouseenter`) in a window
/// that never activates (a capture slot), where no AppKit pointer reaches it.
@MainActor
struct PageWebViewDebugHoverTests {
    private let root: URL
    private let descriptor = PageDescriptor(id: "test.hover-page", resource: "hover-page", namespaces: [])

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("page-hover-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<!doctype html><title>Page</title>".utf8).write(to: root.appendingPathComponent("index.html"))
    }

    private func chromiumPage(center: String?, hoveredAfter: Bool = true) async throws -> (PageWebView, FakeChromiumPage) {
        let hosting = FakeChromiumHosting()
        let view = try #require(PageWebView(descriptor: descriptor, root: root, routes: [], route: "#/", chromium: hosting))
        view.chromiumClock = PageTestClock.never
        await view.chromiumStart?.value
        let page = try #require(hosting.made.first)
        page.answer = { method, params in
            guard method == "Runtime.evaluate", let expression = params["expression"] as? String else { return nil }
            if expression.contains("matches(':hover')") {
                return #"{"result":{"type":"boolean","value":\#(hoveredAfter)}}"#
            }
            guard expression.contains("getBoundingClientRect") else { return nil }
            guard let center else { return #"{"result":{"type":"object","subtype":"null","value":null}}"# }
            return #"{"result":{"type":"string","value":\#(JSONValue.string(center).compactText)}}"#
        }
        return (view, page)
    }

    @Test func hoverMovesTheMouseToTheElementsCenter() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (view, page) = try await chromiumPage(center: #"{"x":120.5,"y":40,"hit":true}"#)
        let result = await view.debugHover(".chief-pet-card")
        let moves = page.calls.filter { $0.method == "Input.dispatchMouseEvent" }
        #expect(moves.count == 1)
        let move = try #require(moves.first)
        #expect(move.params["type"] as? String == "mouseMoved")
        #expect(move.params["x"] as? Double == 120.5)
        #expect(move.params["y"] as? Double == 40)
        #expect(move.params["button"] as? String == "none")
        #expect(result == ["hovered": true, "native": true, "x": 120.5, "y": 40])
        let call = try #require(page.calls.first { ($0.params["expression"] as? String)?.contains("getBoundingClientRect") == true })
        #expect((call.params["expression"] as? String)?.contains(#"[true,".chief-pet-card"]"#) == true)
        view.close()
    }

    /// The element's size comes back with the point, so a caller can check the point is inside it.
    @Test func hoverReportsTheElementsSize() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (view, _) = try await chromiumPage(center: #"{"x":120.5,"y":40,"w":81,"h":30,"hit":true}"#)
        let result = await view.debugHover(".chief-pet-card")
        #expect(result == ["hovered": true, "native": true, "x": 120.5, "y": 40, "width": 81, "height": 30])
        view.close()
    }

    /// DevTools mouse input is in the viewport's CSS pixels, so a zoomed page (UI scale, a zoomed
    /// agent chat) gets the same center `getBoundingClientRect` gave.
    @Test func hoverOfAZoomedPageMovesToTheCSSCenter() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (view, page) = try await chromiumPage(center: #"{"x":120.5,"y":40,"hit":true}"#)
        view.additionalZoom = 2
        #expect(view.pageZoom != 1)
        let result = await view.debugHover(".chief-pet-card")
        let move = try #require(page.calls.first { $0.method == "Input.dispatchMouseEvent" })
        #expect(move.params["x"] as? Double == 120.5)
        #expect(move.params["y"] as? Double == 40)
        #expect(result == ["hovered": true, "native": true, "x": 120.5, "y": 40])
        view.close()
    }

    /// A move after which the page does not report the element hovered (it landed elsewhere)
    /// answers `hovered: false`, never a pass.
    @Test func aMoveThatMissedIsNotAHover() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (view, page) = try await chromiumPage(center: #"{"x":120.5,"y":40,"hit":true}"#, hoveredAfter: false)
        let result = await view.debugHover(".chief-pet-card")
        #expect(page.calls.contains { $0.method == "Input.dispatchMouseEvent" })
        #expect(result["hovered"] == false)
        view.close()
    }

    @Test func hoverOfACoveredElementSendsNothing() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (view, page) = try await chromiumPage(center: #"{"x":120.5,"y":40,"hit":false}"#)
        let result = await view.debugHover(".chief-pet-card")
        #expect(!page.calls.contains { $0.method == "Input.dispatchMouseEvent" })
        #expect(result["hovered"] == false)
        view.close()
    }

    @Test func hoverOfNoMatchingElementSendsNothing() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (view, page) = try await chromiumPage(center: nil)
        let result = await view.debugHover(".missing")
        #expect(!page.calls.contains { $0.method == "Input.dispatchMouseEvent" })
        #expect(result == ["hovered": false])
        view.close()
    }
}
#endif

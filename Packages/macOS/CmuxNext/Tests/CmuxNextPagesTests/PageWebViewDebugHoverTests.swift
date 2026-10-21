#if DEBUG
@testable import CmuxNextPages
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

    private func chromiumPage(center: String?) async throws -> (PageWebView, FakeChromiumPage) {
        let hosting = FakeChromiumHosting()
        let view = try #require(PageWebView(descriptor: descriptor, root: root, routes: [], route: "#/", chromium: hosting))
        view.chromiumClock = PageTestClock.never
        await view.chromiumStart?.value
        let page = try #require(hosting.made.first)
        page.answer = { method, params in
            guard method == "Runtime.evaluate", (params["expression"] as? String)?.contains("getBoundingClientRect") == true else {
                return nil
            }
            guard let center else { return #"{"result":{"type":"object","subtype":"null","value":null}}"# }
            return #"{"result":{"type":"string","value":\#(JSONValue.string(center).compactText)}}"#
        }
        return (view, page)
    }

    @Test func hoverMovesTheMouseToTheElementsCenter() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (view, page) = try await chromiumPage(center: #"{"x":120.5,"y":40}"#)
        let result = await view.debugHover(".chief-pet-card")
        let moves = page.calls.filter { $0.method == "Input.dispatchMouseEvent" }
        #expect(moves.count == 1)
        let move = try #require(moves.first)
        #expect(move.params["type"] as? String == "mouseMoved")
        #expect(move.params["x"] as? Double == 120.5)
        #expect(move.params["y"] as? Double == 40)
        #expect(move.params["button"] as? String == "none")
        #expect(result == ["hovered": true, "native": true, "x": 120.5, "y": 40])
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

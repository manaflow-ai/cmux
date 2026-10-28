import AppKit
@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import CmuxNextSettings
import Foundation
import Testing

/// A Chromium page's pictures (window image, cover snapshot, debug snapshot), debug
/// click and hover, menu Copy and selected text go through the engine's paths that attach no DevTools agent
/// (the fork's surface copy, native click and move, and `tabEvaluate`), because one DevTools agent ends
/// main-frame renderer reuse for the whole browser. DevTools stays only where the engine has no such
/// path (a fork before them).
@MainActor
struct PageChromiumDevToolsFreeTests {
    private let root: URL
    private let descriptor = PageDescriptor(id: "test.devtools-free", resource: "devtools-free", processGroup: .solo, namespaces: [])
    /// A 1x1 PNG.
    private static let onePixel = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
    /// The DevTools methods these sites sent before 078.
    private static let replaced: Set<String> = ["Page.captureScreenshot", "Input.dispatchMouseEvent"]

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("page-devtools-free-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<!doctype html><title>Page</title>".utf8).write(to: root.appendingPathComponent("index.html"))
    }

    private func started() async throws -> (PageWebView, FakeChromiumPage) {
        let hosting = FakeChromiumHosting()
        let view = try #require(PageWebView(descriptor: descriptor, root: root, routes: [], route: "#/", chromium: hosting))
        view.chromiumDeadlines = LifecycleDeadlineRig.never
        await view.chromiumStart?.value
        view.frame = NSRect(x: 0, y: 0, width: 30, height: 20)
        return (view, try #require(hosting.made.first))
    }

    /// Calls of `page` with a method these sites no longer send, or a script one of them ran.
    private static func devToolsSites(_ page: FakeChromiumPage) -> [String] {
        page.calls.compactMap { call in
            let expression = call.params["expression"] as? String ?? ""
            let replacedScript = call.method == "Runtime.evaluate" && (expression.contains("getSelection") || expression.contains("execCommand('copy')"))
            return replaced.contains(call.method) || replacedScript ? call.method : nil
        }
    }

    @Test func everyPictureIsTheSurfaceCopyWithNoDevToolsCall() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (view, page) = try await started()
        let png = try #require(Data(base64Encoded: Self.onePixel))
        page.copiesSurface = true
        page.surfaceCopy = PageSurfaceCopy(base64: Self.onePixel, pixelSize: CGSize(width: 1, height: 1))

        let image = try #require(await view.chromiumImage())
        #expect(image.width == 1 && image.height == 1)
        let snapshot = try #require(await view.snapshot())
        #expect(snapshot.size == NSSize(width: 30, height: 20))
        #expect(view.snapshotKeepsClearAreas, "a surface copy keeps alpha: the pane's color shows through")
        var copies = 2
        #if DEBUG
        let file = root.appendingPathComponent("snapshot.png")
        #expect(await view.debugSnapshot(to: file))
        #expect(try Data(contentsOf: file) == png)
        copies += 1
        #endif
        // At the view's size in pixels (2x with no window).
        #expect(page.surfaceCopies == Array(repeating: CGSize(width: 60, height: 40), count: copies))
        #expect(Self.devToolsSites(page).isEmpty, "\(Self.devToolsSites(page))")
        view.close()
    }

    /// A fork without the surface copy keeps today's DevTools picture, and its JPEG cover is not used
    /// over clear areas.
    @Test func aForkWithoutTheSurfaceCopyTakesItsPictureThroughDevTools() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (view, page) = try await started()
        page.answer = { method, _ in method == "Page.captureScreenshot" ? #"{"data":"\#(Self.onePixel)"}"# : nil }

        let image = try #require(await view.chromiumImage())
        #expect(image.width == 1)
        #expect(!view.snapshotKeepsClearAreas)
        #expect(page.surfaceCopies.isEmpty)
        #expect(page.calls.filter { $0.method == "Page.captureScreenshot" }.count == 1)
        view.close()
    }

    /// The menu's Copy and the selected text run in the page with no DevTools call.
    @Test func theMenusCopyAndTheSelectedTextMakeNoDevToolsCall() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (view, page) = try await started()
        page.rendererEvaluate = { script in script.contains("getSelection") ? #""picked""# : "null" }
        #expect(await view.selectedText() == "picked")

        var shown: NSMenu?
        view.chromiumMenuPresenter = { menu, _, _ in shown = menu }
        page.onEvent?(.contextMenu(PageChromiumContextMenu(location: .zero, selection: "picked", isEditable: false) {}))
        let copy = try #require(shown?.items.first { $0.identifier?.rawValue == PageSelectionMenu.copyItem })
        (copy.target as? PageMenuAction)?.run()
        #expect(page.selectionCopies == 1)
        #expect(Self.devToolsSites(page).isEmpty, "\(Self.devToolsSites(page))")
        view.close()
    }

    #if DEBUG
    /// A debug press is the native click at the page's CSS point times its zoom, and says so; with no native
    /// click (a fork before API 29) it is a DevTools press and release, reported as DevTools.
    @Test func aDebugPressIsTheNativeClick() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (view, page) = try await started()
        page.nativeClicks = true
        #expect(await view.debugPress(x: 10, y: 20) == .native)
        #expect(page.clicks == [CGPoint(x: 10 * view.pageZoom, y: 20 * view.pageZoom)])
        #expect(Self.devToolsSites(page).isEmpty, "\(Self.devToolsSites(page))")

        page.nativeClicks = false
        #expect(await view.debugPress(x: 10, y: 20) == .devtools)
        let presses = page.calls.filter { $0.method == "Input.dispatchMouseEvent" }.map { $0.params["type"] as? String }
        #expect(presses == ["mousePressed", "mouseReleased"])
        view.close()
    }

    /// A debug hover is the native mouse move at the element's CSS center times the zoom, says so, and
    /// counts only once the page reports `:hover`; with no native move (a fork before API 40) it is a
    /// DevTools `mouseMoved`, reported as DevTools.
    @Test func aDebugHoverIsTheNativeMouseMove() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (view, page) = try await started()
        page.rendererEvaluate = { script in
            if script.contains("scrollIntoView") { return #""{\"x\":10,\"y\":20,\"w\":4,\"h\":2,\"hit\":true}""# }
            return script.contains(":hover") ? "true" : "null"
        }
        page.nativeMoves = true
        guard case .object(let native) = await view.debugHover("#target") else { Issue.record("no object"); return }
        #expect(native["hovered"] == .bool(true) && native["delivered"] == .string("native"), "\(native)")
        #expect(page.mouseMoves == [CGPoint(x: 10 * view.pageZoom, y: 20 * view.pageZoom)])
        #expect(Self.devToolsSites(page).isEmpty, "\(Self.devToolsSites(page))")

        page.nativeMoves = false
        guard case .object(let devTools) = await view.debugHover("#target") else { Issue.record("no object"); return }
        #expect(devTools["delivered"] == .string("devtools"), "\(devTools)")
        let moves = page.calls.filter { $0.method == "Input.dispatchMouseEvent" }.map { $0.params["type"] as? String }
        #expect(moves == ["mouseMoved"])
        view.close()
    }
    #endif
}

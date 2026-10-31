import AppKit
@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import CmuxNextTestSupport
import Foundation
import Testing

/// A window image (`debug.window_snapshot`, `cmux window screenshot`) paints Chromium's own image
/// of each React page the window shows on the Chromium engine: without the Screen Recording grant
/// the window server leaves out what Chromium's GPU process draws, so on a capture slot an agent
/// or Settings page came out blank.
@MainActor
@Suite(.closesItsWindows)
struct PageChromiumWindowImageTests {
    private let root: URL
    private let descriptor = PageDescriptor(id: "test.window-image", resource: "window-image", namespaces: [])
    /// A 1x1 PNG, as `Page.captureScreenshot` answers it.
    private static let onePixel = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("page-window-image-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<!doctype html><title>Page</title>".utf8).write(to: root.appendingPathComponent("index.html"))
    }

    private func chromiumView() async throws -> (PageWebView, FakeChromiumPage) {
        let hosting = FakeChromiumHosting()
        let view = try #require(PageWebView(descriptor: descriptor, root: root, routes: [], route: "#/", chromium: hosting))
        view.chromiumClock = PageTestClock.never
        await view.chromiumStart?.value
        return (view, try #require(hosting.made.first))
    }

    @Test func aWindowListsTheChromiumPagesItShows() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let (shown, _) = try await chromiumView()
        shown.frame = NSRect(x: 100, y: 50, width: 300, height: 200)
        window.contentView?.addSubview(shown)
        let (hidden, _) = try await chromiumView()
        hidden.frame = NSRect(x: 0, y: 0, width: 100, height: 100)
        hidden.isHidden = true
        window.contentView?.addSubview(hidden)
        let (elsewhere, _) = try await chromiumView()
        // The New Tab spare waits in an alpha-0 parking view far outside the content.
        let parking = NSView(frame: NSRect(x: 100_000, y: 100_000, width: 800, height: 600))
        parking.alphaValue = 0
        window.contentView?.addSubview(parking)
        let (spare, _) = try await chromiumView()
        spare.frame = parking.bounds
        parking.addSubview(spare)
        // A page holding its paint is alpha 0 itself, even inside the content.
        let (holding, _) = try await chromiumView()
        holding.frame = NSRect(x: 0, y: 0, width: 100, height: 100)
        holding.alphaValue = 0
        window.contentView?.addSubview(holding)
        let (offWindow, _) = try await chromiumView()
        offWindow.frame = NSRect(x: 5_000, y: 0, width: 100, height: 100)
        window.contentView?.addSubview(offWindow)

        let listed = PageRegistry.shownChromiumPages(in: window)
        #expect(listed.map { ObjectIdentifier($0.page) } == [ObjectIdentifier(shown)])
        #expect(listed.first?.rect == NSRect(x: 100, y: 50, width: 300, height: 200))
        for view in [shown, hidden, elsewhere, spare, holding, offWindow] { view.close() }
        window.close()
    }

    @Test func aChromiumPageGivesItsImage() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (view, page) = try await chromiumView()
        page.answer = { method, _ in
            method == "Page.captureScreenshot" ? #"{"data":"\#(Self.onePixel)"}"# : nil
        }
        let image = try #require(await view.chromiumImage())
        #expect(image.width == 1 && image.height == 1)
        #expect(page.calls.contains { $0.method == "Page.captureScreenshot" })
        view.close()
    }

    /// A chat that shares its pane's tab row leaves the strip and toolbar out of its page window
    /// (`nativeRects`); the window image must leave them out too, or it paints the chat over the
    /// tabs that show on screen.
    @Test func aChromiumPageGivesItsHolesInWindowCoordinates() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let (view, _) = try await chromiumView()
        view.frame = NSRect(x: 100, y: 50, width: 300, height: 200)
        window.contentView?.addSubview(view)
        view.layoutSubtreeIfNeeded()
        #expect(view.chromiumWindowHoles.isEmpty, "a page with no native UI over it has holes: \(view.chromiumWindowHoles)")
        view.nativeRects = [CGRect(x: 0, y: 0, width: 200, height: 36), CGRect(x: 267, y: 0, width: 33, height: 36)]
        #expect(view.chromiumWindowHoles == [CGRect(x: 100, y: 214, width: 200, height: 36), CGRect(x: 367, y: 214, width: 33, height: 36)])
        view.nativeRects = []
        #expect(view.chromiumWindowHoles.isEmpty)
        view.close()
        window.close()
    }
}

import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextPages
import Foundation
import Testing

/// Review 3 of #37289 (F1): the toast page in the overlay panel cannot blur the window under it, so with
/// the native toast view gone terminal text read sharp through the toast. The page's view now puts the
/// window's glass under each toast the page reports, and takes it away with the toast.
@MainActor
struct CmuxToastPageGlassTests {
    @Test func eachReportedToastGetsTheWindowsGlassUnderThePage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("toast-glass-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("<!doctype html><title>Toasts</title>".utf8).write(to: root.appendingPathComponent("index.html"))
        let pool = OverlayPagePool(route: "/toasts") { CmuxToastPageProvider() }
        pool.testRoot = root
        let (page, _) = try #require(pool.claim())
        defer { page.close() }
        let view = CmuxToastPageView(page: page)
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        let glass = { view.subviews.compactMap { $0 as? OverlaySurfaceView } }

        let first = NSRect(x: 100, y: 20, width: 300, height: 44)
        view.placeGlass(resting: [(1, first)], fading: [])
        #expect(glass().map(\.frame) == [first])
        // Under the page, which draws the toast's contents over it.
        #expect(view.subviews.last === page)

        let second = NSRect(x: 100, y: 72, width: 280, height: 44)
        view.placeGlass(resting: [(2, second)], fading: [(1, first)])
        #expect(Set(glass().map(\.frame)) == [first, second])
        // The fade ended: the page no longer reports toast 1.
        view.placeGlass(resting: [(2, second)], fading: [])
        #expect(glass().map(\.frame) == [second])

        view.releasePage()
        #expect(glass().isEmpty)
        #expect(page.superview == nil)
    }
}

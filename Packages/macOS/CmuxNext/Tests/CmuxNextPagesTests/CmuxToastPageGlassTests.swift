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
        let pool = CmuxToastWebHost.makePool()
        pool.testRoot = root
        let (page, _) = try #require(pool.claim())
        defer { page.close() }
        let view = CmuxToastPageView(page: page)
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        let glass: () -> [OverlaySurfaceView] = { view.subviews.compactMap { $0 as? OverlaySurfaceView } }
        let frames: () -> [NSRect] = { glass().map(\.frame) }

        // The page's rects are in its own (flipped) coordinates; the glass goes where they show in the view.
        let inView: (NSRect) -> NSRect = { view.convert($0, from: page) }
        let byY: (NSRect, NSRect) -> Bool = { $0.minY < $1.minY }
        let first = NSRect(x: 100, y: 336, width: 300, height: 44)
        view.placeGlass(resting: [(1, first)], fading: [])
        let firstPlace: NSRect = inView(first)
        #expect(frames() == [firstPlace])
        // Review 5 of #37289 (F1): near the page's bottom, so near the view's bottom too, not mirrored.
        let firstBottom: CGFloat = glass().first?.frame.minY ?? .infinity
        #expect(firstBottom < view.bounds.midY)
        // Under the page, which draws the toast's contents over it.
        #expect(view.subviews.last === page)

        let second = NSRect(x: 100, y: 284, width: 280, height: 44)
        view.placeGlass(resting: [(2, second)], fading: [(1, first)])
        // CGRect is Hashable only from macOS 15: compare the frames in order of y.
        let drawn: [NSRect] = frames().sorted(by: byY)
        let expected: [NSRect] = [inView(first), inView(second)].sorted(by: byY)
        #expect(drawn == expected)
        // The fade ended: the page no longer reports toast 1.
        view.placeGlass(resting: [(2, second)], fading: [])
        let secondPlace: NSRect = inView(second)
        #expect(frames() == [secondPlace])

        // Review 5 of #37289 (F3): a toast replaced under its id takes its predecessor's place in one
        // frame, so it keeps the predecessor's glass instead of rising in again under still text.
        let kept = glass().first
        view.placeGlass(resting: [(3, second)], fading: [])
        #expect(glass().count == 1)
        #expect(glass().first === kept)

        view.releasePage()
        #expect(glass().isEmpty)
        #expect(page.superview == nil)
    }

    /// The toast's glass sits in the overlay panel, a clear window over the window it covers. Liquid Glass
    /// there has nothing in its own window to bend: its lens drew a dark 1 px line and a bright bevel
    /// inside the toast's rim, as it did on the dialog card (Lawrence 2026-11-07, the Leave site? dialog:
    /// "weird roundness", "weird border"). Each toast's glass is the blur of what is behind the window,
    /// with the toast's rim as its one edge.
    @Test func eachToastsGlassBlursWhatIsBehindItsClearWindowNeverLiquidGlass() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("toast-blur-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("<!doctype html><title>Toasts</title>".utf8).write(to: root.appendingPathComponent("index.html"))
        let pool = CmuxToastWebHost.makePool()
        pool.testRoot = root
        let (page, _) = try #require(pool.claim())
        defer { page.close() }
        let view = CmuxToastPageView(page: page)
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        view.placeGlass(resting: [(1, NSRect(x: 100, y: 336, width: 300, height: 44))], fading: [])
        let surface = try #require(view.subviews.compactMap { $0 as? OverlaySurfaceView }.first)
        #expect(surface.prefersBlurToLiquidGlass)
        #expect(surface.samplesBehindWindow)
        #expect(surface.material != .liquidGlass)
        // One edge: the toast's rim, at the toast's corner.
        let rim = try #require(surface.rimView)
        #expect(rim.cornerRadius == SurfaceRole.toast.cornerRadius)
        view.releasePage()
    }

    /// Review of #37289 at 97fe7eab (F1): the toast page took the overlay page's answer, no first
    /// mouse, so in an inactive window a toast's Undo or close only brought the window forward and
    /// needed a second click; the native toast's buttons answered the first. The toasts' page takes
    /// the first click now; a dialog's page still only brings its window forward.
    @Test func aToastsPageTakesTheFirstClickADialogsDoesNot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("toast-first-mouse-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("<!doctype html><title>Overlay</title>".utf8).write(to: root.appendingPathComponent("index.html"))
        let toasts = CmuxToastWebHost.makePool()
        toasts.testRoot = root
        let (toastPage, _) = try #require(toasts.claim())
        defer { toastPage.close() }
        let dialogs = OverlayPagePool(route: "/dialog", refusesProbes: true) { OverlayDialogProvider() }
        dialogs.testRoot = root
        let (dialogPage, _) = try #require(dialogs.claim())
        defer { dialogPage.close() }
        #expect(toastPage.webView.acceptsFirstMouse(for: nil))
        #expect(!dialogPage.webView.acceptsFirstMouse(for: nil))
    }
}

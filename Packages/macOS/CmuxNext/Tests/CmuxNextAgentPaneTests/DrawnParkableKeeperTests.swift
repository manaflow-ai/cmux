import AppKit
import CmuxNextPages
import CmuxNextTestSupport
import Testing
@testable import CmuxNextAgentPane

/// The drawn-parking keeper (``AgentPageDrawnParking``) holds any ``DrawnParkable`` page, not only chats: an internal page
/// (Settings, Markdown) waits drawn too, so its switch back shows its last frame. These pin the keeper's limits and
/// eviction across view types with stub pages (no engine), mixed in one window.
@Suite(.serialized, .closesItsWindows)
@MainActor
struct DrawnParkableKeeperTests {
    private static let size = NSRect(x: 0, y: 0, width: 800, height: 600)

    /// A page of another kind than a chat, counting what the keeper tells it.
    private final class StubPage: NSView, DrawnParkable {
        var keepsDrawnNow = true
        var away = 0, back = 0, placed = 0, shown = 0, wentOver = 0
        var picture: NSImage?
        func parkedAway() { away += 1 }
        func parkedBack() { back += 1 }
        func placeAfterDrawnPark() { placed += 1 }
        func shownAfterDrawnPark() { shown += 1 }
        func drawnPicture() async -> NSImage? { picture }
        func standOverDrawnPicture() {}
        func drawnPictureWent() { wentOver += 1 }
        func afterDrawnFrame(_ run: @escaping @MainActor () -> Void) { run() }
    }

    private func window(with pages: [StubPage]) -> (NSWindow, NSView) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: Self.size, styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSView(frame: Self.size)
        window.contentView = host
        for page in pages { page.frame = host.bounds; host.addSubview(page) }
        return (window, host)
    }

    @Test func anInternalKindOfPageIsKeptDrawnAndComesBackDrawn() throws {
        let page = StubPage()
        let (window, _) = window(with: [page])
        defer { window.close() }
        #expect(AgentPageDrawnParking.park(page))
        #expect(page.away == 1)
        #expect(!page.isHiddenOrHasHiddenAncestor)
        #expect(page.frame.size == Self.size.size)
        guard case .drawn = AgentPageDrawnParking.takeBack(page) else { Issue.record("came back hidden"); return }
        #expect(page.back == 1 && page.placed == 1)
    }

    @Test func aPageThatIsNotReadyIsNotKept() throws {
        let page = StubPage()
        page.keepsDrawnNow = false
        let (window, _) = window(with: [page])
        defer { window.close() }
        #expect(!AgentPageDrawnParking.park(page), "a page that never drew in Chromium was moved")
        #expect(AgentPageDrawnParking.of(window) == nil)
    }

    @Test func pastTheLimitTheOldestOfAnyKindGoesHiddenWithItsPicture() async throws {
        let pages = (0...AgentPageDrawnParking.limit).map { _ in StubPage() }
        let (window, _) = window(with: pages)
        defer { window.close() }
        let picture = NSImage(size: Self.size.size)
        #expect(AgentPageDrawnParking.park(pages[0]))
        let keeper = try #require(AgentPageDrawnParking.of(window))
        keeper.snapshotOverride = { _ in picture }
        for page in pages.dropFirst() { #expect(AgentPageDrawnParking.park(page)) }
        for _ in 0..<100 where !pages[0].isHidden { await Task.yield() }
        #expect(pages[0].isHidden)
        #expect(keeper.drawnCount == AgentPageDrawnParking.limit)
        guard case .hidden(let cover) = AgentPageDrawnParking.takeBack(pages[0]) else { Issue.record("came back drawn"); return }
        #expect(cover === picture)
    }

    @Test func installPutsAParkedPageBackInItsHostAndTellsItItIsShown() throws {
        let page = StubPage()
        let (window, host) = window(with: [page])
        defer { window.close() }
        #expect(AgentPageDrawnParking.park(page))
        let pane = NSView(frame: Self.size)
        host.addSubview(pane)
        final class Cover: NSView, AgentPaneMoveCoverHost {
            var launchImageView: NSView?
            var launchImageInvokesResizeCallback = false
            var onLaunchImageCleared: (() -> Void)?
            func showLaunchImage(_ image: NSImage, limit: Duration) {}
            func clearLaunchImage(ifShowing image: NSView) {}
        }
        let installed = AgentPageDrawnParking.install(page, in: pane, at: pane.bounds, fills: true, cover: Cover())
        #expect(installed)
        #expect(page.superview === pane && !page.isHidden)
        #expect(page.shown == 1)
        #expect(!AgentPageDrawnParking.install(page, in: pane, at: pane.bounds, fills: true, cover: Cover()), "a page not waiting came back through the keeper")
    }
}

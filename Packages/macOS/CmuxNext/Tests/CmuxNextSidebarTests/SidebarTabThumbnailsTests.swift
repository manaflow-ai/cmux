import AppKit
@testable import CmuxNextSidebar
import Testing

/// #51768: the hover card's split miniature drew each pane as an empty tile with its kind's mark; it now shows the
/// pane's front tab's picture, kept across cards so a card opened again never flashes back to the mark.
@MainActor
@Suite struct SidebarTabThumbnailsTests {
    private static let chat = TabID("tab-chat")
    private static let page = TabID("tab-page")
    private static let split = SidebarPaneShape.split(
        axis: .horizontal, ratio: 0.5,
        .pane(.init(kind: .harness, tab: chat, focused: true)),
        .pane(.init(kind: .browser, tab: page))
    )

    private static func picture(_ gray: CGFloat) -> CGImage {
        let context = CGContext(data: nil, width: 8, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 4))
        return context.makeImage()!
    }

    @Test func eachTileShowsItsFrontTabsPicture() async {
        let (chatPicture, pagePicture) = (Self.picture(0.2), Self.picture(0.8))
        let store = SidebarTabThumbnails { tab, _ in tab == Self.chat ? chatPicture : pagePicture }
        let view = WorkspacePaneShapeView()
        view.thumbnails = store
        view.shape = Self.split
        #expect(view.thumbnail(ofTile: 0) == nil) // nothing asked yet: the marks draw
        for tab in Self.split.tabs { await store.refresh(tab, maxPixelSize: WorkspacePaneShapeView.pictureSize) }
        #expect(view.thumbnail(ofTile: 0) === chatPicture)
        #expect(view.thumbnail(ofTile: 1) === pagePicture)
    }

    @Test func aRefreshWithNoPictureKeepsTheLastOne() async {
        let first = Self.picture(0.5)
        let reply = Reply(first)
        let store = SidebarTabThumbnails { _, _ in reply.image }
        #expect(await store.refresh(Self.chat, maxPixelSize: .zero))
        reply.image = nil  // a hidden page, a capture that timed out
        #expect(await store.refresh(Self.chat, maxPixelSize: .zero) == false)
        #expect(store.image(for: Self.chat) === first)
        reply.image = first  // the same picture again: nothing to redraw
        #expect(await store.refresh(Self.chat, maxPixelSize: .zero) == false)
    }

    @Test func everyShowOfTheSameWorkspaceAsksForNewerPictures() async {
        let (asked, ask) = AsyncStream.makeStream(of: TabID.self)
        let store = SidebarTabThumbnails { tab, _ in ask.yield(tab); return nil }
        let card = WorkspaceHoverCardView()
        card.paneShape.thumbnails = store
        var requests = asked.makeAsyncIterator()
        card.configurePaneShape(Self.split)
        #expect(Set([await requests.next(), await requests.next()]) == Set([Self.chat, Self.page]))
        // The same split again (the card shown once more): before #51768 an unchanged shape asked for nothing.
        card.configurePaneShape(Self.split)
        #expect(Set([await requests.next(), await requests.next()]) == Set([Self.chat, Self.page]))
    }

    @Test func theStoreKeepsOnlyItsCapacity() async {
        let picture = Self.picture(0.3)
        let store = SidebarTabThumbnails { _, _ in picture }
        for index in 0...SidebarTabThumbnails.capacity { await store.refresh(TabID("tab-\(index)"), maxPixelSize: .zero) }
        #expect(store.image(for: TabID("tab-0")) == nil)  // least recently asked goes first
        #expect(store.image(for: TabID("tab-\(SidebarTabThumbnails.capacity)")) === picture)
    }

    @Test func aPictureFillsItsTileFromTheTop() {
        let tile = CGRect(x: 10, y: 20, width: 100, height: 40)
        // A tall page: as wide as the tile, its top on the tile's top, the rest clipped below.
        #expect(WorkspacePaneShapeView.fillRect(for: CGSize(width: 50, height: 100), in: tile) == CGRect(x: 10, y: 20, width: 100, height: 200))
        // A wide picture: as tall as the tile, centered across.
        #expect(WorkspacePaneShapeView.fillRect(for: CGSize(width: 400, height: 40), in: tile) == CGRect(x: -140, y: 20, width: 400, height: 40))
    }

    @Test func theShapeListsEachFrontTabOnce() {
        let twice = SidebarPaneShape.split(axis: .vertical, ratio: 0.5, .pane(.init(kind: .terminal, tab: Self.chat)),
                                           .split(axis: .horizontal, ratio: 0.5, .pane(.init(kind: nil)), .pane(.init(kind: .terminal, tab: Self.chat))))
        #expect(twice.tabs == [Self.chat])
        #expect(Self.split.tabs == [Self.chat, Self.page])
    }
}

/// What a test's provider answers next.
@MainActor
private final class Reply {
    var image: CGImage?
    init(_ image: CGImage?) { self.image = image }
}

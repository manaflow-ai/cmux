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

    // Each tab kind's tile says what it is until its picture comes (#51768: "make sure that they all work").

    private static func says(_ label: WorkspacePaneShapeView.Label, _ title: String, _ detail: String?) -> Bool {
        label.title == title && label.detail == detail
    }

    @Test func aChatTileWithNoPictureSaysItsTitleAndFolder() {
        let chat = SidebarTab(id: Self.chat, title: "Cloud first-token speed", kind: .agentChat, folder: "~/src/cmux")
        #expect(Self.says(WorkspacePaneShapeView.label(for: chat), "Cloud first-token speed", "~/src/cmux"))
    }

    @Test func aTerminalTileWithNoPictureSaysItsTitleAndFolder() {
        let shell = SidebarTab(id: Self.chat, title: "zsh", kind: .terminal, folder: "~", branch: "main")
        #expect(Self.says(WorkspacePaneShapeView.label(for: shell), "zsh", "~"))
        let untitled = SidebarTab(id: Self.chat, title: " ", kind: .terminal, branch: "main")
        #expect(Self.says(WorkspacePaneShapeView.label(for: untitled), "main", nil))
    }

    @Test func aPageTileWithNoPictureSaysItsTitleAndHost() {
        let page = SidebarTab(id: Self.page, title: "Pull requests", kind: .browser, host: "github.com")
        #expect(Self.says(WorkspacePaneShapeView.label(for: page), "Pull requests", "github.com"))
    }

    @Test func aBlankOrLoadingPageTileIsNeverAnEmptyBox() {
        let blank = SidebarTab(id: Self.page, title: "about:blank", kind: .browser)
        #expect(Self.says(WorkspacePaneShapeView.label(for: blank), Strings.hoverCardNewTab, nil))
        let untitled = SidebarTab(id: Self.page, title: "", kind: .browser)
        #expect(WorkspacePaneShapeView.label(for: untitled).title == Strings.hoverCardNewTab)
        let loading = SidebarTab(id: Self.page, title: "", kind: .browser, host: "example.com")  // no title yet
        #expect(Self.says(WorkspacePaneShapeView.label(for: loading), "example.com", nil))
        let newTab = SidebarTab(id: Self.chat, title: "", kind: .newTab)
        #expect(Self.says(WorkspacePaneShapeView.label(for: newTab), Strings.hoverCardNewTab, nil))
    }

    @Test func theCardNamesEachPicturelessTileByItsTab() {
        let card = WorkspaceHoverCardView()
        card.configurePaneShape(Self.split, tabs: [
            SidebarTab(id: Self.chat, title: "Cloud first-token speed", kind: .agentChat),
            SidebarTab(id: Self.page, title: "about:blank", kind: .browser),
        ])
        #expect(card.paneShape.label(ofTile: 0)?.title == "Cloud first-token speed")
        #expect(card.paneShape.label(ofTile: 1)?.title == Strings.hoverCardNewTab)
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

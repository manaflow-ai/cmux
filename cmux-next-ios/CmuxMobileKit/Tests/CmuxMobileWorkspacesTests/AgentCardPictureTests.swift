// AgentCardRasterizer is iOS-only: these run in the iOS simulator test pass.
#if os(iOS)
import CmuxMobileModel
import Foundation
import SwiftUI
import Testing
import UIKit
import CmuxTabsKit
@testable import CmuxMobileAgentChat
@testable import CmuxMobileWorkspaces

/// Review of #27664: an agent tab's grid card is a picture drawn by a synchronous
/// `ImageRenderer` (`AgentCardRasterizer.render`), which never runs a view's `.task`. What a
/// card shows must be ready when it is drawn, and its key must change when what it shows lands
/// (decoded thumbnails, computed diffs), so the picture is drawn again. The card is laid out at
/// the grid's page size, whichever page was shown first.
@MainActor @Suite(.serialized) struct AgentCardPictureTests {
    final class Silent: AgentSessionSource {
        let summary = AgentSessionSummary(id: "s", name: "S", harness: "codex", agentName: "Codex", cwd: "~", workspaceTitle: "w", macName: "m")
        func events() -> AsyncStream<AgentSessionEvent> { AsyncStream { _ in } }
        func send(_ intent: AgentClientIntent) {}
    }

    static let page = CGSize(width: 402, height: 874)

    static func key(_ feed: AgentCardFeed, turns: [AgentTurn]) -> AgentCardRasterKey {
        AgentCardRasterKey.current(feed, turns: turns, colorScheme: .dark, page: page, visibleHeight: page.height,
                                   topInset: 70, bottomInset: 110, scale: 1)
    }

    /// A solid red PNG.
    static func redPNG() throws -> Data {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 48)).image { context in
            UIColor(red: 1, green: 0, blue: 0, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        }
        return try #require(image.pngData())
    }

    /// Pixels of `image` that are pure red (the thumbnail; the placeholder is a gray fill).
    static func redPixels(_ image: UIImage) throws -> Int {
        let cg = try #require(image.cgImage)
        let width = cg.width, height = cg.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        try #require(drawn)
        var count = 0
        for pixel in 0 ..< width * height {
            let r = bytes[pixel * 4], g = bytes[pixel * 4 + 1], b = bytes[pixel * 4 + 2]
            if r > 200, g < 60, b < 60 { count += 1 }
        }
        return count
    }

    /// Blocker 3: an image attachment's thumbnail was decoded in its view's `.task`, so a card
    /// picture drew the gray placeholder for good. The card's key waits for the thumbnail
    /// (decoded off the main thread), and the picture drawn then shows the image.
    @Test func aCardPictureShowsTheImageAttachment() async throws {
        var turn = AgentTurn(id: "t1", prompt: "Look at this", promptAt: Date(timeIntervalSince1970: 0))
        turn.attachments = [AgentAttachment(id: "red", kind: .image, name: "red.png", data: try Self.redPNG())]
        turn.status = .completed
        let feed = AgentCardFeed(store: AgentChatStore(source: Silent()))
        var key = Self.key(feed, turns: [turn])
        for _ in 0 ..< 200 where !key.isDrawable {
            try await Task.sleep(for: .milliseconds(10))
            key = Self.key(feed, turns: [turn])
        }
        try #require(key.isDrawable, "the thumbnail is decoded")
        let image = try #require(AgentCardRasterizer.render(feed, key))
        let red = try Self.redPixels(image)
        #expect(red > 5000, "the card shows the 200x150 thumbnail, not its placeholder: \(red) red pixels")
    }

    /// Review of #27664 (follow-up P2): the rasterizer drew a card only when every thumbnail it
    /// shows was in the cache at once. A thumbnail evicted while the card waited for another one
    /// to decode again was decoded again too (and, past the bound, the two evicted each other on
    /// every frame). The rasterizer holds the card's thumbnails it already has while it waits and
    /// draws: the evicted one is decoded once, and the card is drawn with both images.
    @Test func anEvictedThumbnailIsDecodedOnceThenTheCardIsDrawn() async throws {
        let png = try Self.redPNG()
        var turn = AgentTurn(id: "t-held", prompt: "Look at these", promptAt: Date(timeIntervalSince1970: 0))
        // Ids unique to this run: the thumbnail cache is shared and remembers settled keys.
        let a = "held-a-\(UUID().uuidString)", b = "held-b-\(UUID().uuidString)"
        turn.attachments = [AgentAttachment(id: a, kind: .image, name: "a.png", data: png),
                            AgentAttachment(id: b, kind: .image, name: "b.png", data: png)]
        turn.status = .completed
        let feed = AgentCardFeed(store: AgentChatStore(source: Silent()))
        var key = Self.key(feed, turns: [turn])
        for _ in 0 ..< 200 where !key.isDrawable {
            try await Task.sleep(for: .milliseconds(10))
            key = Self.key(feed, turns: [turn])
        }
        try #require(key.isDrawable, "the thumbnails are decoded")
        let cache = SentAttachmentThumbnails.shared
        cache.evict(attachmentID: a)
        let rasterizer = AgentCardRasterizer()
        rasterizer.want(feed, key)
        rasterizer.setIdle(true)
        defer { rasterizer.setIdle(false) }
        func decodes() -> Int { cache.decodes(attachmentID: a) + cache.decodes(attachmentID: b) }
        let before = decodes()
        // The card waits for its first image to decode again; meanwhile the cache lets the second go.
        rasterizer.frame()
        cache.evict(attachmentID: b)
        for _ in 0 ..< 300 where feed.raster?.key != key {
            try await Task.sleep(for: .milliseconds(10))
            rasterizer.frame()
        }
        let picture = try #require(feed.raster, "the card is drawn")
        #expect(picture.key == key)
        // Counted for this card's attachments only: another suite drawing sent images through the
        // shared cache at the same time cannot move it.
        #expect(decodes() - before == 1, "only the evicted image is decoded again: \(decodes() - before) decodes")
        let red = try Self.redPixels(picture.image)
        #expect(red > 12_000, "both 96x96 thumbnails are drawn, not placeholders: \(red) red pixels")
    }

    /// Review of #30681 (P2): every waiting card held its thumbnails until drawn, beyond the cache's
    /// bound and after the grid moved or hid (about 175 MB with 30 cards waiting). One card at a
    /// time holds now: the card waiting stays first until its decode lands, and a moving grid or a
    /// memory warning lets the hold go. Every card is still drawn.
    @Test func onlyTheCardWaitingHoldsAndAMovingGridOrMemoryWarningLetsGo() async throws {
        let png = try Self.redPNG()
        let run = UUID().uuidString
        func card(_ name: String) async throws -> (AgentCardFeed, AgentCardRasterKey) {
            var turn = AgentTurn(id: "t-\(name)", prompt: "Look", promptAt: Date(timeIntervalSince1970: 0))
            turn.attachments = [AgentAttachment(id: "bound-\(name)-\(run)", kind: .image, name: "\(name).png", data: png)]
            turn.status = .completed
            let feed = AgentCardFeed(store: AgentChatStore(source: Silent()))
            var key = Self.key(feed, turns: [turn])
            for _ in 0 ..< 200 where !key.isDrawable {
                try await Task.sleep(for: .milliseconds(10))
                key = Self.key(feed, turns: [turn])
            }
            try #require(key.isDrawable, "the thumbnail is decoded")
            return (feed, key)
        }
        let first = try await card("a"), second = try await card("b")
        let cache = SentAttachmentThumbnails.shared
        cache.evict(attachmentID: "bound-a-\(run)")
        cache.evict(attachmentID: "bound-b-\(run)")
        let rasterizer = AgentCardRasterizer()
        rasterizer.want(first.0, first.1)
        rasterizer.want(second.0, second.1)
        rasterizer.setIdle(true)
        rasterizer.frame()
        #expect(rasterizer.holdsThumbnails, "the first card waits for its decode, holding")
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        #expect(!rasterizer.holdsThumbnails, "a memory warning lets the hold go")
        for _ in 0 ..< 300 where first.0.raster?.key != first.1 || second.0.raster?.key != second.1 {
            try await Task.sleep(for: .milliseconds(10))
            rasterizer.frame()
        }
        #expect(first.0.raster?.key == first.1 && second.0.raster?.key == second.1, "both cards are drawn")
        #expect(!rasterizer.holdsThumbnails, "nothing is held once every card is drawn")

        let third = try await card("c")
        cache.evict(attachmentID: "bound-c-\(run)")
        rasterizer.want(third.0, third.1)
        rasterizer.frame()
        #expect(rasterizer.holdsThumbnails)
        rasterizer.setIdle(false)
        #expect(!rasterizer.holdsThumbnails, "the grid moved: nothing is held for a card it is not drawing")
    }

    /// Blocker 4: a card drawn while its edit's diff was still computing showed the loading
    /// snippet, and its key did not change when the diff landed, so the picture kept it. The
    /// key follows the chat's diffs: once they land, the picture is stale and drawn again.
    @Test func aCardDrawnBeforeItsDiffLandedIsDrawnAgain() async throws {
        let store = AgentChatStore(source: Silent())
        let feed = AgentCardFeed(store: store)
        let old = (0 ..< 40).map { "line \($0)" }.joined(separator: "\n")
        let new = (0 ..< 40).map { $0 % 5 == 0 ? "changed \($0)" : "line \($0)" }.joined(separator: "\n")
        var turn = AgentTurn(id: "t1", prompt: "Edit it", promptAt: Date(timeIntervalSince1970: 0))
        turn.items = [.tool(ACPToolCall(id: "c1", title: "Edit a.swift", kind: .edit, status: .completed,
                                        content: [.diff(path: "a.swift", oldText: old, newText: new)]))]
        turn.status = .completed
        let drawn = Self.key(feed, turns: [turn])
        try #require(drawn.isDrawable)
        let rasterizer = AgentCardRasterizer()
        let start = store.diffs.version
        // Drawing the card asks for the diff (computed off the main thread).
        feed.raster = (drawn, try #require(AgentCardRasterizer.render(feed, drawn)))
        for _ in 0 ..< 300 where store.diffs.version == start { try await Task.sleep(for: .milliseconds(10)) }
        try #require(store.diffs.version != start, "the diff landed")
        let now = Self.key(feed, turns: [turn])
        #expect(now != drawn, "the key changes when the diff lands")
        #expect(!rasterizer.isDone(feed, now), "the picture drawn before it is stale")
        #expect(now.mayShow(drawn), "the older picture stands in until the new one is drawn")
    }

    /// Hosts an agent tab's card at `size`, inside the grid's scaled page (`pageSize` set, as
    /// TabsKit's grid card does) or at its own size (`pageSize` nil: the card's long-press menu
    /// preview and drag preview), and lets it lay out.
    func hostCard(size: CGSize, pageSize: CGSize?) async throws -> (WorkspaceTabsSource, UIWindow) {
        let store = AppStore.mock(tabMemory: .inMemory())
        let source = WorkspaceTabsSource(store: store, workspaceID: "ws-cmux", sessions: AgentSessionDirectory())
        let workspace = try #require(source.listedWorkspace)
        let agent = try #require(workspace.tabs.first { $0.kind == .agent })
        let host = UIHostingController(rootView: WorkspaceTabCard(source: source, tabID: agent.id, insets: EdgeInsets())
            .frame(width: size.width, height: size.height)
            .environment(\.tabsKitCardPageSize, pageSize))
        let window = UIWindow(frame: CGRect(origin: .zero, size: CGSize(width: max(size.width, 402), height: max(size.height, 874))))
        window.rootViewController = host
        window.makeKeyAndVisible()
        for _ in 0 ..< 20 {
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(16))
        }
        return (source, window)
    }

    /// Edge P1: the page size came only from a page's `onAppear`, so a grid shown before any
    /// page (or rotated with the grid up) drew its agent cards at 402x874. A grid card takes
    /// the page size the kit lays it out at.
    @Test func aCardTakesTheGridsPageSizeBeforeAnyPageShows() async throws {
        let size = CGSize(width: 874, height: 402)
        let (source, window) = try await hostCard(size: size, pageSize: size)
        defer { window.isHidden = true }
        #expect(source.pageWidth == size.width && source.pageHeight == size.height,
                "the source's page size: \(source.pageWidth)x\(source.pageHeight)")
        #expect(source.rasterizer.lastKey?.page == size, "the card's picture key: \(String(describing: source.rasterizer.lastKey?.page))")
    }

    /// Review of 2a38f796 (P1): the page size was read from the card's own geometry, and a
    /// card is also laid out at its own size (about 177x249) by its long-press menu preview and
    /// its drag preview. A long press set the page to that size, and every agent card redrew
    /// with its transcript 177 pt wide. A card laid out outside the grid's page leaves it.
    @Test func aCardsPreviewLeavesThePageSize() async throws {
        let (source, window) = try await hostCard(size: CGSize(width: 177, height: 249), pageSize: nil)
        defer { window.isHidden = true }
        #expect(source.pageWidth == 402 && source.pageHeight == 874, "the source's page size: \(source.pageWidth)x\(source.pageHeight)")
        #expect(source.rasterizer.lastKey.map { $0.page == CGSize(width: 402, height: 874) } ?? true,
                "the card's picture key: \(String(describing: source.rasterizer.lastKey?.page))")
    }
}
#endif

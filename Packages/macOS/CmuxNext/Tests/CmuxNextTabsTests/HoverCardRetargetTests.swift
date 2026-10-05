import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextTabs

@MainActor
final class HoverRetargetPreviews: TabPreviewProvider {
    var calls: [TabID] = []
    var images: [TabID: CGImage] = [:]
    func previewImage(for tab: TabID, maxPixelSize: CGSize) async -> CGImage? {
        calls.append(tab)
        return images[tab]
    }
}

private func image(_ gray: CGFloat, size: Int = 8) -> CGImage {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    context.setFillColor(gray: gray, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: size, height: size))
    return context.makeImage()!
}

/// R131 (Lawrence): "the hover card thing when moving from hovering one tab
/// to another has lag." Chrome retargets the visible card in the same frame:
/// the same card body, no blank thumbnail or placeholder numbers while the
/// next tab's arrive, no slide animation, and a tab seen before shows its
/// thumbnail at once.
@MainActor
@Suite(.serialized)
struct HoverCardRetargetTests {
    func strip(_ previews: HoverRetargetPreviews) -> TabStripView {
        let tabs = (1...3).map { TabItem(id: TabID("t\($0)"), title: "Tab \($0)") }
        let strip = TabStripView(model: TabStripModel(tabs: tabs, selectedID: TabID("t1")))
        strip.hoverCard.previewProvider = previews
        strip.hoverCard.strip = strip
        return strip
    }

    func settle() async { for _ in 0..<50 { await Task.yield() } }

    @Test func retargetKeepsTheBodyAndItsThumbnailUntilTheNextOneLands() async throws {
        let previews = HoverRetargetPreviews()
        let a = image(0.2), b = image(0.8)
        previews.images = [TabID("t1"): a]
        let strip = strip(previews)
        let card = strip.hoverCard
        card.cardIsShowing = { true }  // a card is visible: deactivations are retargets
        let t1 = TabHoverCardController.targetID("t1"), t2 = TabHoverCardController.targetID("t2")

        card.hoverCardActivated(t1)
        let first = try #require(card.hoverCardBody(for: t1)?.view as? TabHoverCardView)
        await settle()
        #expect(first.thumbnailImage === a)

        // Slide to t2 before its thumbnail exists.
        card.hoverCardDeactivated(t1)
        card.hoverCardActivated(t2)
        let second = try #require(card.hoverCardBody(for: t2)?.view as? TabHoverCardView)
        #expect(second === first, "one card body, retargeted")
        #expect(second.thumbnailImage === a, "no blank thumbnail while t2's loads")
        previews.images[TabID("t2")] = b
        card.hoverCardDeactivated(t2)
        card.hoverCardActivated(t2)
        _ = card.hoverCardBody(for: t2)
        await settle()
        #expect(second.thumbnailImage === b)

        // Back to t1: its thumbnail shows at once, without a new fetch.
        let fetches = previews.calls.count
        card.hoverCardDeactivated(t2)
        card.hoverCardActivated(t1)
        _ = card.hoverCardBody(for: t1)
        #expect(second.thumbnailImage === a)
        await settle()
        #expect(previews.calls.count == fetches, "a cached thumbnail is not fetched again")
    }

    /// A retarget to a tab that has no thumbnail (a page never captured)
    /// shows the placeholder once its fetch answers, never the previous
    /// tab's picture as if it were this tab's.
    @Test func aTabWithNoThumbnailShowsThePlaceholderNotThePreviousTabs() async throws {
        let previews = HoverRetargetPreviews()
        let a = image(0.2)
        previews.images = [TabID("t1"): a]
        let strip = strip(previews)
        let card = strip.hoverCard
        card.cardIsShowing = { true }
        let t1 = TabHoverCardController.targetID("t1"), t2 = TabHoverCardController.targetID("t2")
        card.hoverCardActivated(t1)
        let body = try #require(card.hoverCardBody(for: t1)?.view as? TabHoverCardView)
        await settle()
        #expect(body.thumbnailImage === a)

        card.hoverCardDeactivated(t1)
        card.hoverCardActivated(t2)
        _ = card.hoverCardBody(for: t2)
        await settle()
        #expect(previews.calls.contains(TabID("t2")))
        #expect(body.thumbnailImage == nil, "t2 has no thumbnail: the placeholder, not t1's picture")
    }

    @Test func thumbnailCacheIsBoundedByCountAndBytes() {
        var cache = TabThumbnailCache(maxCount: 2, maxBytes: 1 << 20)
        cache.insert(image(0.1), for: TabID("a"))
        cache.insert(image(0.2), for: TabID("b"))
        _ = cache.image(for: TabID("a"))  // a is now the most recent
        cache.insert(image(0.3), for: TabID("c"))
        #expect(cache.image(for: TabID("b")) == nil, "the least recently used goes first")
        #expect(cache.image(for: TabID("a")) != nil)
        var small = TabThumbnailCache(maxCount: 10, maxBytes: 8 * 8 + 1)
        small.insert(image(0.1), for: TabID("a"))
        small.insert(image(0.2), for: TabID("b"))
        #expect(small.image(for: TabID("a")) == nil, "over the byte budget, the oldest goes")
        cache.remove(TabID("a"))
        #expect(cache.image(for: TabID("a")) == nil)
        cache.removeAll()
        #expect(cache.count == 0)
    }
}

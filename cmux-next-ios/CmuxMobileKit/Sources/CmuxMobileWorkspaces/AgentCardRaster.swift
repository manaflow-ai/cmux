#if os(iOS)
import CmuxMobileAgentChat
import CmuxMobileDesign
import Observation
import QuartzCore
import SwiftUI
import UIKit

/// What an agent card's snapshot was drawn from: the turns it shows and how
/// it is drawn. A card shows its snapshot only while every field matches.
struct AgentCardRasterKey: Equatable {
    var turns: [AgentTurn]
    var colorScheme: ColorScheme
    /// The page size the card is laid out at (the kit scales it down).
    var page: CGSize
    /// Page points from the top the card shows (the rest is clipped).
    var visibleHeight: CGFloat
    var topInset: CGFloat
    var bottomInset: CGFloat
    /// Pixels per page point: the card's on-screen resolution.
    var scale: CGFloat
    /// What the rows load before they can be drawn as a still is ready: their sent images'
    /// thumbnails (`AgentChatPreview.picturesReady`; a picture runs no `.task`).
    var pictures = true
    /// The chat's diffs as drawn (`ChatDiffCache.version`): an edit's snippet and the
    /// edited-files card draw once their diff lands, and the picture is drawn again then.
    var diffs = 0

    /// Drawn the same way (scheme, size, insets, resolution), whatever the
    /// turns: an older picture of the same layout stands in until the new
    /// one is drawn, as a terminal's last frame does.
    func sameLayout(_ other: AgentCardRasterKey) -> Bool {
        colorScheme == other.colorScheme && page == other.page && visibleHeight == other.visibleHeight
            && topInset == other.topInset && bottomInset == other.bottomInset && scale == other.scale
    }

    /// Whether a card for this key may show `picture`: one drawn for this
    /// key, or (while a newer one waits) an older one of the same layout when
    /// this key can be drawn at all. A key that cannot be drawn (an image
    /// still loading) shows the live preview: an older picture would freeze
    /// the card on what it showed before the image arrived.
    func mayShow(_ picture: AgentCardRasterKey) -> Bool {
        picture == self || (isDrawable && picture.sameLayout(self))
    }

    /// A card is a still of its page, a running turn included (its working
    /// label would animate every frame on a live card; the card's copy follows
    /// the chat at most once a second, `AgentCardFeed`). An image attachment
    /// without its bytes loads them in a `.task`, which never runs in a
    /// picture: that turn is drawn live (bytes already in the turn draw).
    var isDrawable: Bool {
        let pendingImage = turns.contains { $0.attachments.contains { $0.kind == .image && $0.data == nil } }
        return !pendingImage && pictures && page.width > 0 && visibleHeight > 0
    }
}

extension AgentCardRasterKey {
    /// The key a card for `feed` asks for now: a built card's (`AgentTabCard`) and one drawn
    /// before it is built (`WorkspaceTabsSource.nextAgentCardAhead`).
    @MainActor
    /// Reads (and so observes) what the card waits for: decoded thumbnails and the chat's diffs.
    static func current(_ feed: AgentCardFeed, turns: [AgentTurn]? = nil, colorScheme: ColorScheme, page: CGSize,
                        visibleHeight: CGFloat, topInset: CGFloat, bottomInset: CGFloat, scale: CGFloat) -> AgentCardRasterKey {
        let turns = turns ?? feed.turns
        return AgentCardRasterKey(turns: turns, colorScheme: colorScheme, page: page, visibleHeight: visibleHeight,
                                  topInset: topInset, bottomInset: bottomInset, scale: scale,
                                  pictures: AgentChatPreview.picturesReady(turns), diffs: feed.store.diffs.version)
    }
}

/// Agent cards drawn once as pictures. A chat's preview is a full page of
/// transcript (markdown, edits, attachments) and cost about 45 ms to build,
/// so a grid card that scrolled into view (or came back after it was
/// released) missed frames. Terminal and browser cards are already pictures
/// of their pages; an agent card becomes one too, drawn while the grid rests
/// (`TabsDataSource.overviewIdleChanged`), one per frame, for cards the grid
/// has built, each time their turns or appearance change, and shown by every
/// later build of the card.
@MainActor
final class AgentCardRasterizer: NSObject {
    /// Feeds waiting for a picture, oldest request first.
    private var queue: [(feed: AgentCardFeed, key: AgentCardRasterKey)] = []
    /// Most recently drawn last; the oldest picture goes past `limit`.
    private var drawn: [ObjectIdentifier] = []
    private var owners: [ObjectIdentifier: AgentCardFeed] = [:]
    private var link: CADisplayLink?
    private(set) var idle = false
    /// How pictures are drawn now (scheme, size, resolution): the last key
    /// a card asked for, the template for cards not built yet.
    private(set) var lastKey: AgentCardRasterKey?
    /// While the grid rests and no built card waits: the next card not built
    /// yet to draw (nearest first), or nil when the nearest `limit` are drawn.
    var ahead: (@MainActor (AgentCardRasterKey) -> (AgentCardFeed, AgentCardRasterKey)?)?
    /// Pictures kept (about 1.6 MB each at a column card's resolution): an
    /// 80-tab grid's agent cards, at most about 48 MB.
    let limit: Int
    /// Pictures drawn (tests and the rig's log).
    private(set) var renders = 0

    init(limit: Int = 30) {
        self.limit = limit
    }

    /// The card wants its picture for `key` (it shows the live preview until then).
    func want(_ feed: AgentCardFeed, _ key: AgentCardRasterKey) {
        lastKey = key
        if feed.raster?.key == key { return }
        queue.removeAll { $0.feed === feed }
        guard key.isDrawable else { return }
        queue.append((feed, key))
        startIfNeeded()
    }

    func setIdle(_ idle: Bool) {
        self.idle = idle
        if idle { startIfNeeded() } else { stop() }
    }

    private func startIfNeeded() {
        guard idle, link == nil, !queue.isEmpty || ahead != nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(frame))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func frame() {
        guard idle else { return stop() }
        let next: (AgentCardFeed, AgentCardRasterKey)?
        if !queue.isEmpty {
            next = queue.removeFirst()
        } else if let template = lastKey {
            next = ahead?(template)
        } else {
            next = nil
        }
        guard let (feed, key) = next else { return stop() }
        // A thumbnail the cache let go since the key was ready is decoded again first: this card
        // waits at the end of the queue rather than being drawn with a placeholder.
        if feed.raster?.key != key, key.isDrawable, !AgentChatPreview.picturesResident(key.turns) {
            queue.append((feed, key))
            return
        }
        if feed.raster?.key != key, key.isDrawable, let image = Self.render(feed, key) {
            feed.raster = (key, image)
            renders += 1
            remember(feed)
        }
    }

    /// Whether `feed` has a picture for `key` (or never can: a running turn).
    func isDone(_ feed: AgentCardFeed, _ key: AgentCardRasterKey) -> Bool {
        feed.raster?.key == key || !key.isDrawable
    }

    private func remember(_ feed: AgentCardFeed) {
        let id = ObjectIdentifier(feed)
        drawn.removeAll { $0 == id }
        drawn.append(id)
        owners[id] = feed
        while drawn.count > limit {
            let old = drawn.removeFirst()
            owners.removeValue(forKey: old)?.raster = nil
        }
    }

    /// Forgets a feed's picture (its tab closed).
    func drop(_ feed: AgentCardFeed) {
        let id = ObjectIdentifier(feed)
        queue.removeAll { $0.feed === feed }
        drawn.removeAll { $0 == id }
        owners[id] = nil
    }

    /// The card's preview as the kit lays it out (full page, top aligned,
    /// clipped to what the card shows), at the card's pixel resolution.
    static func render(_ feed: AgentCardFeed, _ key: AgentCardRasterKey) -> UIImage? {
        let content = AgentChatPreview(store: feed.store, turns: key.turns, topInset: key.topInset, bottomInset: key.bottomInset)
            .frame(width: key.page.width, height: key.page.height)
            .frame(width: key.page.width, height: key.visibleHeight, alignment: .top)
            .clipped()
            .environment(\.colorScheme, key.colorScheme)
        let renderer = ImageRenderer(content: content)
        renderer.scale = key.scale
        renderer.isOpaque = true
        return renderer.uiImage
    }
}

/// An agent tab's grid card: its picture when one matches, else the live
/// preview (and a request for the picture).
struct AgentTabCard: View {
    let feed: AgentCardFeed
    let rasterizer: AgentCardRasterizer
    /// Card width over page width (`WorkspaceTabsSource.cardScale`).
    let cardScale: CGFloat
    let page: CGSize
    let topInset: CGFloat
    let bottomInset: CGFloat
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale

    private struct PictureRequest: Equatable {
        var key: AgentCardRasterKey
        var drawn: Bool
    }

    /// TabsKit's card aspect (`OverviewLayout.cardAspect`): the page height a card shows per page width.
    static let cardAspect: CGFloat = 249.3 / 177.0

    var body: some View {
        let key = AgentCardRasterKey.current(feed, colorScheme: colorScheme, page: page,
                                             visibleHeight: min(page.height, page.width * Self.cardAspect),
                                             topInset: topInset, bottomInset: bottomInset, scale: displayScale * cardScale)
        Group {
            // The picture, also while a newer one waits for the grid to rest:
            // building a card never lays out a page of transcript then.
            if let raster = feed.raster, key.mayShow(raster.key) {
                Image(uiImage: raster.image)
                    .resizable()
                    .frame(width: page.width, height: key.visibleHeight)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .background(Color.cmuxMobileBackground)
            } else {
                AgentChatPreview(store: feed.store, turns: feed.turns, topInset: topInset, bottomInset: bottomInset)
            }
        }
        // Asked again when its picture is dropped (the cache's oldest goes).
        .onChange(of: PictureRequest(key: key, drawn: feed.raster?.key == key), initial: true) { _, request in
            guard !request.drawn else { return }
            // A key that cannot be drawn: the old picture goes (the card is live until it can).
            if !request.key.isDrawable, feed.raster != nil { rasterizer.drop(feed); feed.raster = nil }
            rasterizer.want(feed, request.key)
        }
    }
}
#endif

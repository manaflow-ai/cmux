#if os(iOS)
import CmuxMobileAgentChat
import CmuxMobileDesign
import CmuxMobileModel
import Observation
import OSLog
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
    /// The person's text size: `ImageRenderer` draws with a default environment, so the
    /// picture is drawn at this one, as the page is (the card's own environment's).
    var textSize: DynamicTypeSize = .large
    /// The chat's Text and Width (its text size step and column), which its page draws in.
    var display = ChatDisplaySettings()

    /// Drawn the same way (scheme, size, insets, resolution, text), whatever the
    /// turns: an older picture of the same layout stands in until the new
    /// one is drawn, as a terminal's last frame does.
    func sameLayout(_ other: AgentCardRasterKey) -> Bool {
        colorScheme == other.colorScheme && page == other.page && visibleHeight == other.visibleHeight
            && topInset == other.topInset && bottomInset == other.bottomInset && scale == other.scale
            && textSize == other.textSize && display == other.display
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
                        visibleHeight: CGFloat, topInset: CGFloat, bottomInset: CGFloat, scale: CGFloat,
                        textSize: DynamicTypeSize = .large) -> AgentCardRasterKey {
        let turns = turns ?? feed.turns
        return AgentCardRasterKey(turns: turns, colorScheme: colorScheme, page: page, visibleHeight: visibleHeight,
                                  topInset: topInset, bottomInset: bottomInset, scale: scale,
                                  pictures: AgentChatPreview.picturesReady(turns), diffs: feed.store.diffs.version,
                                  textSize: textSize, display: ChatDisplayPreferences.shared.settings(for: feed.store.summary))
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
    /// The thumbnails of the one card waiting for a picture (`AgentChatPreview.picturesResident(_:holding:)`):
    /// held until its picture is drawn, so one let go by the cache's bound while the card waits for
    /// another is not decoded again (two that do not fit the bound together evicted each other on
    /// every frame). One card at a time: the card waiting stays first in the queue until its
    /// decodes land, so held images never add up across cards beyond the cache's bound (one card
    /// shows at most six cropped thumbnails), and the hold is let go when the grid moves or hides
    /// and on a memory warning.
    private var held: (id: ObjectIdentifier, hold: AgentChatPreview.PictureHold)?
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
    /// Pictures thrown away because they held the system's cannot-draw mark (tests and the rig's log).
    private(set) var refusals = 0
    /// Per feed, the key whose picture held the mark: the card shows its live preview for that key
    /// (where the UIKit view draws) and the picture is not drawn again until the key changes.
    private var refused: [ObjectIdentifier: AgentCardRasterKey] = [:]
    /// Where each drawn picture is also kept across launches (`TabCardSnapshots`).
    var snapshots = TabCardSnapshots.shared

    /// Built cards on screen now, per feed (`setShown`; a grid card and its long-press preview
    /// are two): a memory warning keeps their pictures.
    private var shown: [ObjectIdentifier: Int] = [:]

    init(limit: Int = 30, memoryPressure: MemoryPressure = .shared) {
        self.limit = limit
        super.init()
        memoryPressure.register(self) { [weak self] in self?.relieveMemoryPressure() }
    }

    /// A memory warning: the thumbnails held for the card waiting go, and so does every
    /// picture no card on screen shows (about 1.6 MB each). A card built again asks for its
    /// picture (`AgentTabCard`) and shows the live preview until it is drawn, as a card never
    /// drawn does; the cards on screen keep theirs, so nothing the person sees changes.
    func relieveMemoryPressure() {
        held = nil
        for id in drawn where shown[id] == nil { owners.removeValue(forKey: id)?.raster = nil }
        drawn.removeAll { shown[$0] == nil }
    }

    /// A built card is on screen (`AgentTabCard` appeared) or left it.
    func setShown(_ feed: AgentCardFeed, _ shown: Bool) {
        let id = ObjectIdentifier(feed)
        let count = (self.shown[id] ?? 0) + (shown ? 1 : -1)
        self.shown[id] = count > 0 ? count : nil
    }

    /// Whether a waiting card holds thumbnails now (tests).
    var holdsThumbnails: Bool { held != nil }

    /// The card wants its picture for `key` (it shows the live preview until then).
    func want(_ feed: AgentCardFeed, _ key: AgentCardRasterKey) {
        lastKey = key
        if feed.raster?.key == key || refused[ObjectIdentifier(feed)] == key { return }
        queue.removeAll { $0.feed === feed }
        guard key.isDrawable else {
            if held?.id == ObjectIdentifier(feed) { held = nil }
            return
        }
        queue.append((feed, key))
        startIfNeeded()
    }

    func setIdle(_ idle: Bool) {
        self.idle = idle
        if idle {
            startIfNeeded()
        } else {
            // The grid moves or hides: no card is drawn until it rests, so nothing is held for one.
            held = nil
            stop()
        }
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

    /// One display frame: draws the next card waiting (internal for tests).
    @objc func frame() {
        guard idle else { return stop() }
        let next: (AgentCardFeed, AgentCardRasterKey)?
        if let first = queue.first {
            next = first
        } else if let template = lastKey {
            next = ahead?(template)
        } else {
            next = nil
        }
        guard let (feed, key) = next else { return stop() }
        let id = ObjectIdentifier(feed)
        guard feed.raster?.key != key, key.isDrawable else {
            dequeue(feed)
            if held?.id == id { held = nil }
            return
        }
        // One card at a time holds its thumbnails: another card's are let go.
        let hold = (held?.id == id ? held?.hold : nil) ?? AgentChatPreview.PictureHold()
        held = (id, hold)
        // A thumbnail the cache let go since the key was ready is decoded again first: this card
        // stays first and waits for that decode (it lands in `hold`), holding the thumbnails it
        // has, rather than being drawn with a placeholder.
        guard AgentChatPreview.picturesResident(key.turns, holding: hold) else {
            if queue.first?.feed !== feed {
                dequeue(feed)
                queue.insert((feed, key), at: 0)
            }
            return
        }
        dequeue(feed)
        held = nil
        if let image = draw(feed, key, hold) {
            // The tab's last-known picture, for the next launch and for a card whose chat
            // has not loaded yet. A chat still loading is not one: its empty page would
            // replace the picture of its turns.
            if let snapshotKey = feed.snapshotKey, !feed.awaitingHistory { snapshots.put(image, for: snapshotKey) }
        }
    }

    /// Draws `feed`'s picture for `key` (its thumbnails resident in `hold`) and makes it the
    /// card's picture; nil when the drawing held the system's cannot-draw mark.
    private func draw(_ feed: AgentCardFeed, _ key: AgentCardRasterKey, _ hold: AgentChatPreview.PictureHold) -> UIImage? {
        let id = ObjectIdentifier(feed)
        guard let image = AgentChatPreview.drawing(hold, { Self.render(feed, key) }) else { return nil }
        // Leo, 2026-11-22: "isn't this literally apple telling you theres nothing there?" A row
        // that reached a UIKit-backed view drew the mark: never show it; the live preview stays.
        if CannotDrawMark.isIn(image) {
            refused[id] = key
            refusals += 1
            Self.log.fault("agent card picture held the system's cannot-draw mark; showing the live preview")
            return nil
        }
        refused[id] = nil
        feed.raster = (key, image)
        renders += 1
        remember(feed)
        return image
    }

    /// The person left the tab (for the grid or another tab) or the app went to the background:
    /// the card's picture of the chat as it is now becomes the tab's last-known picture
    /// (`TabCardSnapshots`), so its card is never empty while its history loads after a relaunch.
    /// Only the grid drew agent pictures before, so a tab left for another tab kept none.
    /// A picture already drawn for `key` is kept as it is. Otherwise, with `drawNow`, it is drawn
    /// here once (a page of transcript, tens of milliseconds on the main thread: the caller picks
    /// a moment no animation runs), else asked for when the grid next rests (`want`). A chat
    /// still loading keeps its earlier picture. True when a picture was kept.
    @discardableResult
    func keepLastKnown(_ feed: AgentCardFeed, _ key: AgentCardRasterKey, drawNow: Bool) -> Bool {
        guard let snapshotKey = feed.snapshotKey, !feed.awaitingHistory else { return false }
        if let raster = feed.raster, raster.key == key {
            snapshots.put(raster.image, for: snapshotKey)
            return true
        }
        guard key.isDrawable, refused[ObjectIdentifier(feed)] != key else { return false }
        let hold = AgentChatPreview.PictureHold()
        guard drawNow, AgentChatPreview.picturesResident(key.turns, holding: hold) else {
            want(feed, key)
            return false
        }
        dequeue(feed)
        guard let image = draw(feed, key, hold) else { return false }
        snapshots.put(image, for: snapshotKey)
        return true
    }

    private func dequeue(_ feed: AgentCardFeed) {
        if queue.first?.feed === feed { queue.removeFirst() } else { queue.removeAll { $0.feed === feed } }
    }

    /// Whether `feed` has a picture for `key` (or never can: a running turn).
    func isDone(_ feed: AgentCardFeed, _ key: AgentCardRasterKey) -> Bool {
        feed.raster?.key == key || !key.isDrawable || refused[ObjectIdentifier(feed)] == key
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
        shown[id] = nil
        refused[id] = nil
        if held?.id == id { held = nil }
    }

    /// The card's preview as the kit lays it out (full page, top aligned,
    /// clipped to what the card shows), at the card's pixel resolution.
    static let log = Logger(subsystem: "com.cmux.app", category: "agent-card-raster")

    static func render(_ feed: AgentCardFeed, _ key: AgentCardRasterKey) -> UIImage? {
        let content = AgentChatPreview(store: feed.store, turns: key.turns, topInset: key.topInset, bottomInset: key.bottomInset,
                                       cardSlice: key.visibleHeight)
            .frame(width: key.page.width, height: key.page.height)
            .frame(width: key.page.width, height: key.visibleHeight, alignment: .top)
            .clipped()
            .environment(\.colorScheme, key.colorScheme)
            .environment(\.dynamicTypeSize, key.textSize)
            .drawnAsStillPicture()
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
    /// The tab's last-known picture (`TabCardSnapshots`), from an earlier launch too.
    var snapshot: TabSnapshotEntry?
    /// The chat's last turns as the Mac laid them out in text (its `tabs` service,
    /// `MacCardEntry.screen`): what a card shows for a chat this phone has no turns of.
    var macScreen: String?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @Environment(\.dynamicTypeSize) private var textSize

    private struct PictureRequest: Equatable {
        var key: AgentCardRasterKey
        var drawn: Bool
    }

    /// What a card draws.
    enum Face: Equatable {
        /// The picture drawn from the feed's turns (`AgentCardRasterizer`).
        case picture
        /// The tab's last-known picture (`TabCardSnapshots`).
        case lastKnown
        /// The live preview: a page of transcript laid out in the card.
        case live
        /// The chat's last turns as text from the Mac (`macScreen`).
        case macScreen
    }

    /// A card is a still whenever one exists. Its own picture when that may
    /// show; the last-known one while the chat's history is still loading (an
    /// empty page otherwise, on every launch) and while a picture that can be
    /// drawn waits for the grid to rest (a page of transcript laid out in a
    /// scroll frame otherwise, which is what moved in the grid: Leo,
    /// 2026-11-22, "why are they moving???"). The live preview is left for a
    /// card with no picture at all, and for one whose image is still loading,
    /// which only a live row loads. A chat this phone has no turns of (never
    /// opened here, or its session hibernated) shows the Mac's text of its last
    /// turns, not an empty page (Leo, 2026-11-25, "there are too many empty
    /// previews in the safari grid").
    nonisolated static func face(awaitingHistory: Bool, mayShowPicture: Bool, drawable: Bool, hasLastKnown: Bool,
                                 hasTurns: Bool = true, hasMacScreen: Bool = false) -> Face {
        if awaitingHistory, hasLastKnown { return .lastKnown }
        // A picture of the chat beats the Mac's text of it.
        if !hasTurns, hasLastKnown { return .lastKnown }
        if !hasTurns, hasMacScreen { return .macScreen }
        if mayShowPicture { return .picture }
        if drawable, hasLastKnown { return .lastKnown }
        return .live
    }

    /// TabsKit's card aspect (`OverviewLayout.cardAspect`): the page height a card shows per page width.
    static let cardAspect: CGFloat = 249.3 / 177.0

    var body: some View {
        let key = AgentCardRasterKey.current(feed, colorScheme: colorScheme, page: page,
                                             visibleHeight: min(page.height, page.width * Self.cardAspect),
                                             topInset: topInset, bottomInset: bottomInset, scale: displayScale * cardScale,
                                             textSize: textSize)
        let lastKnown = snapshot?.image
        let face = Self.face(awaitingHistory: feed.awaitingHistory,
                             mayShowPicture: feed.raster.map { key.mayShow($0.key) } ?? false,
                             drawable: key.isDrawable, hasLastKnown: snapshot?.hasKnownPicture == true || lastKnown != nil,
                             hasTurns: !feed.turns.isEmpty, hasMacScreen: !(macScreen ?? "").isEmpty)
        Group {
            // The picture, also while a newer one waits for the grid to rest:
            // building a card never lays out a page of transcript then.
            switch face {
            case .picture:
                if let raster = feed.raster {
                    Image(uiImage: raster.image)
                        .resizable()
                        .frame(width: page.width, height: key.visibleHeight)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .background(Color.cmuxMobileBackground)
                }
            case .lastKnown:
                TabSnapshotPicture(image: lastKnown, pixelWidth: snapshot?.pixelWidth ?? 0,
                                   pixelHeight: snapshot?.pixelHeight ?? 0)
                    .background(Color.cmuxMobileBackground)
            case .live:
                AgentChatPreview(store: feed.store, turns: feed.turns, topInset: topInset, bottomInset: bottomInset,
                                 cardSlice: key.visibleHeight)
            case .macScreen:
                Text(verbatim: macScreen ?? "")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Color.primary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, topInset + 48).padding(.horizontal, 16)
                    .clipped()
                    .background(Color.cmuxMobileBackground)
            }
        }
        .onAppear { rasterizer.setShown(feed, true) }
        .onDisappear { rasterizer.setShown(feed, false) }
        .modifier(TabCardFaceRecord(tabID: feed.snapshotKey?.tabID, face: "\(face)"))
        // Asked again when its picture is dropped (the cache's oldest goes, or a memory warning).
        .onChange(of: PictureRequest(key: key, drawn: feed.raster?.key == key), initial: true) { _, request in
            guard !request.drawn else { return }
            // A key that cannot be drawn: the old picture goes (the card is live until it can).
            if !request.key.isDrawable, feed.raster != nil { rasterizer.drop(feed); feed.raster = nil }
            rasterizer.want(feed, request.key)
        }
    }
}
/// The mark `ImageRenderer` draws in place of a view it cannot draw (any UIKit-backed view): a
/// yellow square with a red prohibition sign. A card picture holding it is never shown.
enum CannotDrawMark {
    /// Whether `image` holds the mark: its yellow and its red together. Every second pixel of every
    /// second row is read (the mark is many points wide), about a millisecond for a card picture.
    static func isIn(_ image: UIImage) -> Bool {
        let (yellow, red) = pixels(image, stride: 2)
        return yellow >= 32 && red >= 4
    }

    /// Pixels in the mark's yellow and in its red, reading every `stride`-th pixel and row.
    static func pixels(_ image: UIImage, stride step: Int = 1) -> (yellow: Int, red: Int) {
        guard let cg = image.cgImage else { return (0, 0) }
        let width = cg.width, height = cg.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return (0, 0) }
        var yellow = 0, red = 0
        for y in Swift.stride(from: 0, to: height, by: step) {
            for x in Swift.stride(from: 0, to: width, by: step) {
                let i = (y * width + x) * 4
                let r = bytes[i], g = bytes[i + 1], b = bytes[i + 2]
                if r > 200, g > 180, b < 90 { yellow += 1 } else if r > 180, g < 80, b < 80 { red += 1 }
            }
        }
        return (yellow, red)
    }
}
#endif

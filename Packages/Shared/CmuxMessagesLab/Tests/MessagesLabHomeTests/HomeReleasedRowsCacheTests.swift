import AppKit
import CmuxHomeCore
import Testing
@testable import MessagesLabHome

/// A hidden conversation that gives back its rows (`MessagesWindowView.releaseRows`) also gives back
/// the pixels they drew in the process-wide caches: their row bitmaps (`RowBitmaps`), long-text tiles (`TileCache`)
/// and decoded media (`MediaCache`). What another live transcript still lays out keeps its pixels.
@MainActor @Suite(.serialized) struct HomeReleasedRowsCacheTests {
    final class NoWake: ChatWakeScheduler {
        func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) {}
        func cancel() {}
    }

    static let me = ParticipantID("user_me")
    static let them = ParticipantID("agent_chief")

    /// Home in an offscreen window, 40 messages whose text carries `salt` (no other test's rows equal them).
    private func home(salt: String) -> (NSWindow, MessagesLabHomeView) {
        let people = [CmuxHomeCore.Participant(id: Self.me, kind: .human, displayName: "Me"),
                      CmuxHomeCore.Participant(id: Self.them, kind: .agent, displayName: "Chief", agentClass: .chief)]
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let items = (1...40).map { seq in
            TranscriptItem(key: IdempotencyKey("k\(seq)"), seq: UInt64(seq), author: seq.isMultiple(of: 2) ? Self.me : Self.them,
                           parts: [.text("Message \(seq) \(salt)")], createdAt: base.addingTimeInterval(Double(seq)),
                           delivery: .committed, messageID: MessageID("msg_\(seq)"))
        }
        let id = ConversationID("conv_released_cache")
        let summary = ConversationSummary(id: id, title: "Chief", participants: people, lastSeq: 40,
                                          createdAt: base, updatedAt: base, readCursors: [:], readCursorTimes: [:])
        let view = MessagesLabHomeView(store: HomeStore(source: MockHomeSource(options: .immediate)), conversation: id, me: Self.me, wake: NoWake())
        var core = ProjectionCore(me: Self.me)
        let (conv, w) = core.install(id, items: items, summary: summary)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 700), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 700))
        window.contentView = container
        view.frame = container.bounds
        container.addSubview(view)
        view.controller.install(conv, windowStart: w.start, total: w.total)
        container.layoutSubtreeIfNeeded()
        return (window, view)
    }

    /// `demo`'s message rows drawn as one bitmap each (not long-text tiles).
    private func messageRows(_ demo: MessagesWindowView) -> [RowSpec] {
        demo.model.rows.map(\.spec).filter { spec in
            guard case .part = spec.kind else { return false }
            return !TiledBubble.applies(spec)
        }
    }

    /// Bitmaps of `demo`'s newest message rows, drawn and put in the shared cache as its cells' renders would.
    private func drawMessageRows(_ demo: MessagesWindowView) -> [(RowSpec, CGImage)] {
        let images = messageRows(demo).suffix(12).compactMap { spec in RowBitmaps.render(spec, scale: demo.renderScale).map { (spec, $0) } }
        RowBitmaps.shared.insert(images, scale: demo.renderScale)
        return images
    }

    /// The engine's cleanup runs past every fade of the first page, as its wakes would (rows that move are not released).
    private func settle(_ demo: MessagesWindowView) {
        for later in [2.0, 10, 60, 700, 1_400] { demo.settle(at: demo.clock() + later) }
    }

    @Test func theReleaseLetsTheRowsBitmapsGo() throws {
        let (window, view) = home(salt: String(UUID().uuidString.prefix(8)))
        defer { window.close() }
        let demo = try #require(view.controller.demo)
        settle(demo)
        let scale = demo.renderScale
        let images = drawMessageRows(demo)
        try #require(!images.isEmpty, "no message row to draw")
        for (spec, _) in images { try #require(RowBitmaps.shared.image(for: spec, scale: scale) != nil) }
        let bytes = RowBitmaps.shared.bytes
        let mine = images.reduce(0) { $0 + $1.1.bytesPerRow * $1.1.height }

        view.removeFromSuperview()
        #expect(view.releaseLayout())
        for (spec, _) in images {
            #expect(RowBitmaps.shared.image(for: spec, scale: scale) == nil, "the released row \(spec.key) kept its bitmap")
        }
        #expect(RowBitmaps.shared.bytes <= bytes - mine, "the shared cache still holds the released rows' \(mine) bytes")
    }

    @Test func aRowAnotherLiveTranscriptLaysOutKeepsItsBitmap() throws {
        let salt = String(UUID().uuidString.prefix(8))
        let (hiddenWindow, hidden) = home(salt: salt)
        let (shownWindow, shown) = home(salt: salt)
        defer {
            hiddenWindow.close()
            shownWindow.close()
        }
        let demo = try #require(hidden.controller.demo)
        let other = try #require(shown.controller.demo)
        settle(demo)
        let images = drawMessageRows(demo)
        try #require(!images.isEmpty)
        let laidOut = Set(other.model.rows.map(\.spec))
        try #require(images.allSatisfy { laidOut.contains($0.0) }, "the two transcripts' rows differ")

        hidden.removeFromSuperview()
        #expect(hidden.releaseLayout())
        for (spec, _) in images {
            #expect(RowBitmaps.shared.image(for: spec, scale: demo.renderScale) != nil, "the shown transcript's row \(spec.key) lost its bitmap")
        }
    }

    @Test func theRowBitmapEvictionKeepsOtherScalesAndKeptRows() throws {
        let (window, view) = home(salt: String(UUID().uuidString.prefix(8)))
        defer { window.close() }
        let demo = try #require(view.controller.demo)
        let specs = Array(messageRows(demo).suffix(3))
        try #require(specs.count == 3)
        let (gone, kept, otherScale) = (specs[0], specs[1], specs[2])
        let cache = RowBitmaps()
        let atTwo = try [gone, kept].map { spec in (spec, try #require(RowBitmaps.render(spec, scale: 2))) }
        cache.insert(atTwo, scale: 2)
        cache.insert([(otherScale, try #require(RowBitmaps.render(otherScale, scale: 1)))], scale: 1)

        cache.evict([gone, kept, otherScale], keeping: [kept], scale: 2)
        #expect(cache.image(for: gone, scale: 2) == nil)
        #expect(cache.image(for: kept, scale: 2) != nil, "a kept row lost its bitmap")
        #expect(cache.image(for: otherScale, scale: 1) != nil, "a bitmap at another scale went")
        #expect(cache.count == 2)
    }

    @Test func theTileAndMediaCachesLetOnlyTheNamedEntriesGo() throws {
        let image = try #require(WideBitmap.make(size: CGSize(width: 8, height: 8), scale: 2, opaque: false) { _ in })
        let each = image.bytesPerRow * image.height
        let tiles = TileCache()
        func tile(_ lineage: Int) -> TileCache.Key {
            TileCache.Key(lineage: lineage, start: 0, end: 10, final: true, column: 300, chunk: 0, outgoing: false, scale: 2, palette: 0)
        }
        tiles.put(tile(1), image)
        tiles.put(tile(2), image)
        tiles.evict(lineages: [1, 3])
        #expect(tiles.get(tile(1)) == nil, "the released text's tile stayed")
        #expect(tiles.get(tile(2)) != nil, "another text's tile went")
        #expect(tiles.bytes == each)

        let media = MediaCache()
        let at2 = "@" + String(describing: CGFloat(2)), at1 = "@" + String(describing: CGFloat(1))
        media.store("released.png" + at2, UIImage(cgImage: image, scale: 2))
        media.store("kept.png" + at2, UIImage(cgImage: image, scale: 2))
        media.store("released.png" + at1, UIImage(cgImage: image, scale: 1))
        media.evict(refs: ["released.png"], scale: 2)
        #expect(media.cached("released.png" + at2) == nil, "the released row's decoded image stayed")
        #expect(media.cached("kept.png" + at2) != nil, "an image no released row drew went")
        #expect(media.cached("released.png" + at1) != nil, "the image at another scale went")
    }
}

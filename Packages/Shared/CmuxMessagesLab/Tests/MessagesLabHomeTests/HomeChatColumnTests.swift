import CmuxHomeCore
import CoreGraphics
import Foundation
import Testing
@testable import MessagesLabHome

/// The chat column has one layout (the user, 2026-11-09, on a Chief reply whose Before|After card started left of
/// its text bubble and of the "Chief" name: "from first principles, fix all alignment issues"): every frame of a
/// sender (a text bubble, a table card, a comparison card, a drawn bubble row) starts at one leading edge, a
/// wide card ends at the trailing edge my own bubbles end at, and every frame's content (the sender's name, a
/// bubble's text, a card's text and pictures) starts one content inset inside it. Each case measures the edges of
/// the rows `RowBuilder` derives or of the pixels a card draws.
@Suite(.serialized) @MainActor struct HomeChatColumnTests {
    typealias G = HomeGroupSenderTests
    static let bubbleKind = "test.column.bubble"
    static let width: CGFloat = 900

    init() {
        HomeMarkdownPolicy.install()
        CustomRows.unregister(HomeTableRowProvider.kind)
        CustomRows.unregister(HomePlanRowProvider.kind)
        HomeTableRowProvider.install()
        CustomRows.register(DrawnRowProvider(kind: Self.bubbleKind, layout: .bubbleIncoming, height: { _, _ in 40 }, draw: { _, _, _, _ in }))
    }

    static let words = HomeTable(header: ["Check", "Result"], alignments: [.leading, .leading],
                                 rows: [["Compile", "passed"], ["Tests", "19 of 19"]], pictures: nil, loading: nil)

    /// The part rows of a group chat where the Chief sends one message of `parts` (after a line of mine).
    static func rows(_ parts: [Part], width: CGFloat = width) throws -> [PartRow] {
        var core = ProjectionCore(me: G.me)
        var (conv, _) = core.install(G.id, items: G.items([G.me, G.chief]), summary: G.summary([G.me, G.alice, G.chief]))
        let last = try #require(conv.messages.indices.last)
        conv.messages[last].parts = parts
        return RowBuilder.rows(AppState(conversation: conv), messages: conv.messages, now: G.date(60), width: width).compactMap { row in
            guard case let .part(p) = row.kind, !p.outgoing else { return nil }
            return p
        }
    }

    static func body(_ row: PartRow, width: CGFloat = width) -> CGRect {
        RowDraw.bodyRect(RowSpec(key: "k", kind: .part(row), gap: 0, height: row.size.height, width: width))
    }

    static func tablePart(_ table: HomeTable) throws -> Part {
        try #require(HomeTableRowProvider.part(table, raw: "raw"))
    }

    static func comparison(before: CGSize, after: CGSize) async throws -> HomeTable {
        let f = HomePictureViewerTests.folder()
        try HomePictureViewerTests.png(at: f.appendingPathComponent("b.png"), width: Int(before.width), height: Int(before.height), gray: 1)
        try HomePictureViewerTests.png(at: f.appendingPathComponent("a.png"), width: Int(after.width), height: Int(after.height), gray: 1)
        let pictures = HomeTablePictures()
        for name in ["b", "a"] { _ = await pictures.prepare(f.appendingPathComponent("\(name).png").path) }
        let text = """
        | | Before | After |
        |---|---|---|
        | Light | ![before](\(f.appendingPathComponent("b.png").path)) | ![after](\(f.appendingPathComponent("a.png").path)) |
        """
        return try HomePictureViewerTests.table(text, media: { pictures.asset($0) })
    }

    /// `grid` drawn at the origin of a 1x bitmap: its RGBA bytes, rows top to bottom.
    static func pixels(_ grid: HomeTableGrid) throws -> (bytes: [UInt8], width: Int, height: Int) {
        let size = CGSize(width: grid.cardWidth.rounded(.up), height: grid.height.rounded(.up))
        let image = try #require(WideBitmap.make(size: size, scale: 1, opaque: false) { ctx in grid.draw(ctx, at: .zero) })
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = bytes.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        #expect(drawn)
        return (bytes, w, h)
    }

    static func differs(_ p: (bytes: [UInt8], width: Int, height: Int), _ x: Int, _ y: Int, from o: (Int, Int)) -> Bool {
        let a = (y * p.width + x) * 4, b = (o.1 * p.width + o.0) * 4
        return (0..<3).contains { abs(Int(p.bytes[a + $0]) - Int(p.bytes[b + $0])) > 24 }
    }

    // MARK: One leading edge, one trailing edge

    @Test func aTableCardStartsAtItsSendersBubbleEdgeAndEndsAtTheTrailingEdge() throws {
        let rows = try Self.rows([.text("Here are the checks.", runs: []), try Self.tablePart(Self.words)])
        #expect(rows.count == 2)
        let bubble = Self.body(rows[0]), card = Self.body(rows[1])
        #expect(card.minX == bubble.minX, "the card and the bubble above it share the sender's leading edge")
        #expect(RowDraw.senderNameLeft == bubble.minX + Fixture.bubblePadX, "the name starts at the bubble's text")
        // The card's row is as wide as the column from that edge to where my own bubbles end.
        #expect(card.maxX == Metrics(width: Self.width).rightEdge)
    }

    @Test func aComparisonCardSharesThoseEdges() async throws {
        let table = try await Self.comparison(before: CGSize(width: 2560, height: 1600), after: CGSize(width: 2560, height: 1600))
        let rows = try Self.rows([.text("Before and after.", runs: []), try Self.tablePart(table)])
        let bubble = Self.body(rows[0]), card = Self.body(rows[1])
        #expect(card.minX == bubble.minX)
        #expect(card.maxX == Metrics(width: Self.width).rightEdge)
        // The card is measured for the width it draws in: its pictures end inside it.
        let grid = HomeTableGrid(table, available: card.width)
        #expect(rows[1].size.height == grid.height.rounded())
        #expect(grid.pictureRects(at: .zero).allSatisfy { $0.rect.maxX <= card.width - Fixture.bubblePadX + 0.5 })
    }

    @Test func aDrawnBubbleRowStartsAtThatEdgeToo() throws {
        let custom = CustomPart(kind: Self.bubbleKind, version: 1, payload: Data())
        let rows = try Self.rows([.text("A card follows.", runs: []), .custom(custom)])
        #expect(Self.body(rows[1]).minX == Self.body(rows[0]).minX)
    }

    @Test func theSendersAvatarSitsBesideTheLastFrameOfTheRunACardToo() throws {
        let rows = try Self.rows([.text("Here are the checks.", runs: []), try Self.tablePart(Self.words)])
        #expect(rows[0].cmuxAvatar == nil)
        #expect(rows[1].cmuxAvatar != nil, "the run ends with the card: the avatar sits beside it")
    }

    @Test func theGapAboveACardIsTheGapBetweenTwoBubblesOfOneMessage() throws {
        var core = ProjectionCore(me: G.me)
        var (conv, _) = core.install(G.id, items: G.items([G.me, G.chief]), summary: G.summary([G.me, G.alice, G.chief]))
        let last = try #require(conv.messages.indices.last)
        conv.messages[last].parts = [.text("one", runs: []), .text("two", runs: []), try Self.tablePart(Self.words), .text("three", runs: [])]
        let gaps = RowBuilder.rows(AppState(conversation: conv), messages: conv.messages, now: G.date(60), width: Self.width)
            .filter { $0.key.hasPrefix("part:\(conv.messages[last].id):") }.dropFirst().map(\.gap)
        #expect(gaps == [3, 3, 3])
    }

    // MARK: One content inset

    @Test func aTableCardsTextStartsOneContentInsetInsideTheCard() throws {
        let grid = HomeTableGrid(Self.words, available: 600)
        let p = try Self.pixels(grid)
        // The first ink of the first body row's text band (clear of the rules over and under it), left to right.
        let top = Int(HomeTableGrid.pad + grid.heights[0]) + 3
        let bottom = Int(HomeTableGrid.pad + grid.heights[0] + grid.heights[1]) - 3
        let background = (p.width / 2, 2)
        var first: Int?
        for x in 3..<p.width where first == nil {
            for y in top..<bottom where Self.differs(p, x, y, from: background) { first = x; break }
        }
        let ink = CGFloat(try #require(first))
        // A glyph's side bearing is under 2 pt.
        #expect(ink >= Fixture.bubblePadX - 0.5 && ink < Fixture.bubblePadX + 2.5, "text starts \(ink) pt in; a bubble's starts \(Fixture.bubblePadX)")
    }

    // MARK: A comparison's pairs

    @Test func aPairsPicturesShareOneCentreLineWhateverTheirShapes() async throws {
        let table = try await Self.comparison(before: CGSize(width: 2560, height: 1600), after: CGSize(width: 1600, height: 1600))
        let rects = HomeTableGrid(table, available: 800).pictureRects(at: .zero).map(\.rect)
        #expect(rects.count == 2)
        #expect(rects[0].height != rects[1].height)
        #expect(abs(rects[0].midY - rects[1].midY) <= 0.5, "a wide and a square shot sit on one centre line, not one top line")
    }

    @Test func aPicturesNameIsNotDrawnOverThePicture() async throws {
        let table = try await Self.comparison(before: CGSize(width: 2560, height: 1600), after: CGSize(width: 2560, height: 1600))
        let grid = HomeTableGrid(table, available: 800)
        let p = try Self.pixels(grid)
        let rect = try #require(grid.pictureRects(at: .zero).first?.rect)
        // The pictures are white: every pixel well inside one is the picture's own (no label over its corner).
        let centre = (Int(rect.midX), Int(rect.midY))
        var covered = 0
        for x in stride(from: Int(rect.minX) + 6, to: Int(rect.maxX) - 6, by: 2) {
            for y in stride(from: Int(rect.minY) + 6, to: Int(rect.maxY) - 6, by: 2) where Self.differs(p, x, y, from: centre) { covered += 1 }
        }
        #expect(covered == 0, "\(covered) sampled points of the picture are covered")
    }

    @Test func aPairsCaptionStartsAtItsPicturesLeadingEdge() async throws {
        let table = try await Self.comparison(before: CGSize(width: 2560, height: 1600), after: CGSize(width: 2560, height: 1600))
        let compare = try #require(HomeTableGrid(table, available: 800).compare)
        let row = try #require(compare.rows.first)
        #expect(row.captionRect.minX == row.pictures[0].rect.minX)
        #expect(row.pictures[0].rect.minX == Fixture.bubblePadX, "pictures start one content inset inside the card")
    }
}

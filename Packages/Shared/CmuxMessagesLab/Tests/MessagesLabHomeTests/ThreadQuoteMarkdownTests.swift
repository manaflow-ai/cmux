import CmuxHomeCore
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import MessagesLabHome

/// Lawrence, 2026-11-20 ("this preview thing is not very good"): the quote above a reply to the Chief's before/after
/// table showed the table's Markdown ("| | Before | After ||---|---|---|| Light | ![before,") in bold grey beside an
/// empty grey square. A preview of a message (the reply quote, the Home list row) shows its words, never its syntax:
/// a table is named by its columns, a picture shows as a real thumbnail, a link as its label.
///
/// Each case maps HomeStore items through `ProjectionCore`, derives rows with `RowBuilder` and reads or draws the quote
/// the transcript draws (`RowDraw`).
@MainActor @Suite(.serialized) struct ThreadQuoteMarkdownTests {
    static let me = ParticipantID("user_me")
    static let chief = ParticipantID("agent_chief")
    static let id = ConversationID("conv_quote_markdown")
    static let root = MessageID("msg_root")
    static let width: CGFloat = 628

    init() {
        HomeMarkdownPolicy.install()
        HomeTableRowProvider.reinstall()
    }

    static func date(_ t: Double) -> Date { Replay.base.addingTimeInterval(t) }

    static let summary = ConversationSummary(
        id: id,
        participants: [
            CmuxHomeCore.Participant(id: me, kind: .human, displayName: "Me"),
            CmuxHomeCore.Participant(id: chief, kind: .agent, displayName: "Chief", agentClass: .chief),
        ],
        lastSeq: 8, createdAt: date(-100), updatedAt: date(0))

    /// A solid PNG of `rgb` (0...1) at `url`, 2560 x 1600 like a 2x screenshot.
    static func png(_ url: URL, rgb: (CGFloat, CGFloat, CGFloat)) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try #require(CGContext(data: nil, width: 2560, height: 1600, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 2560, height: 1600))
        let out = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(out, try #require(ctx.makeImage()), nil)
        #expect(CGImageDestinationFinalize(out))
    }

    /// The Chief's before/after table, as it sent it (Light and Dark rows of Before and After shots, each a red PNG
    /// on disk), with its pictures' thumbnails made, and the media lookup that resolves them.
    static func beforeAfterTable() async throws -> (text: String, media: HomeMapping.Media) {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("quote-markdown-\(UUID().uuidString)", isDirectory: true)
        for name in ["bl", "al", "bd", "ad"] { try png(f.appendingPathComponent("\(name).png"), rgb: (0.95, 0.15, 0.1)) }
        let pictures = HomeTablePictures()
        for name in ["bl", "al", "bd", "ad"] { _ = await pictures.prepare(f.appendingPathComponent("\(name).png").path) }
        let text = """
            | | Before | After |
            |---|---|---|
            | Light | ![before, light](\(f.appendingPathComponent("bl.png").path)) | ![after, light](\(f.appendingPathComponent("al.png").path)) |
            | Dark | ![before, dark](\(f.appendingPathComponent("bd.png").path)) | ![after, dark](\(f.appendingPathComponent("ad.png").path)) |
            """
        return (text, { pictures.asset($0) })
    }

    /// The Chief's root `text`, three unrelated messages, then my reply to the root: the reply's rows carry a quote.
    static func rows(root text: String, media: @escaping HomeMapping.Media = { _ in nil }, width: CGFloat = width) -> [RowSpec] {
        var items = [TranscriptItem(key: IdempotencyKey("k1"), seq: 1, author: chief, parts: [.text(text)], createdAt: date(2),
                                    delivery: .committed, messageID: root)]
        let between = ["Started a1315 on the UI pass.", "a1316 owns the diff viewer.", "Both report back with shots.",
                       "Nothing needs you yet.", "Next update in an hour."]
        for (i, words) in between.enumerated() {
            items.append(TranscriptItem(key: IdempotencyKey("k\(i + 2)"), seq: Seq(i + 2), author: chief, parts: [.text(words)],
                                        createdAt: date(Double(70 * (i + 1))), delivery: .committed, messageID: MessageID("msg_\(i + 2)")))
        }
        items.append(TranscriptItem(key: IdempotencyKey("k9"), seq: 8, author: me, parts: [.text("this preview thing is not very good")],
                                    createdAt: date(600), delivery: .committed, replyTo: PartRef(message: root), threadRoot: root,
                                    messageID: MessageID("msg_reply")))
        var core = ProjectionCore(me: me)
        core.media = media
        let (conv, _) = core.install(id, items: items, summary: summary)
        return Fixture.withRenderScale(2) {
            RowBuilder.rows(AppState(conversation: conv), messages: conv.messages, now: date(700), width: width, scale: 2)
        }
    }

    static func preview(_ rows: [RowSpec]) throws -> (RowSpec, ThreadPreview) {
        let row = try #require(rows.first { $0.key.hasPrefix("preview:") }, "no quote above the reply: \(rows.map(\.key))")
        guard case let .threadPreview(pv) = row.kind else { throw CancellationError() }
        return (row, pv)
    }

    /// Every word the quote draws, its card lines or its wrapped text lines.
    static func shownWords(_ pv: ThreadPreview) -> String {
        pv.isText ? pv.textLines.joined(separator: " ") : [pv.lines.0, pv.lines.1].joined(separator: "\n")
    }

    /// The quote drawn as the transcript draws it, 2 px a point, RGBA, top row first; `rgba` reads points from the
    /// row's content top.
    struct Drawn {
        var pixels: [UInt8]
        var width: Int, height: Int
        func rgba(_ x: CGFloat, _ y: CGFloat) -> (r: Double, g: Double, b: Double, a: Double) {
            let px = min(width - 1, max(0, Int(x * 2))), py = min(height - 1, max(0, Int((y + RowDraw.margin) * 2)))
            let i = (py * width + px) * 4
            return (Double(pixels[i]), Double(pixels[i + 1]), Double(pixels[i + 2]), Double(pixels[i + 3]))
        }
    }

    static func draw(_ spec: RowSpec) throws -> Drawn {
        let size = CGSize(width: spec.width, height: spec.height + 2 * RowDraw.margin)
        let image = try #require(Fixture.withRenderScale(2) {
            WideBitmap.make(size: size, scale: 2, opaque: false) { ctx in RowDraw.drawStatic(spec, ctx, windowY: .nan) }
        })
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        pixels.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return Drawn(pixels: pixels, width: w, height: h)
    }

    // MARK: The reply quote

    @Test func aQuotedTableIsNamedByItsColumnsNotItsMarkdown() async throws {
        let (text, media) = try await Self.beforeAfterTable()
        let (_, pv) = try Self.preview(Self.rows(root: text, media: media))
        let words = Self.shownWords(pv)
        #expect(!words.contains("|"), "the quote shows the table's pipes: \(words.debugDescription)")
        #expect(!words.contains("!["), "the quote shows picture syntax: \(words.debugDescription)")
        #expect(!words.contains("---"), "the quote shows the delimiter row: \(words.debugDescription)")
        #expect(pv.lines.0 == "Table: Before / After")
        #expect(pv.lines.1 == "4 images")
    }

    @Test func aQuotedTableShowsItsFirstPictureAsTheThumbnail() async throws {
        let (text, media) = try await Self.beforeAfterTable()
        let (row, pv) = try Self.preview(Self.rows(root: text, media: media))
        let d = try Self.draw(row)
        // The card's thumbnail square (8 pt in, 11.25 pt down, 26 pt): the red shot, not an empty grey box.
        let c = d.rgba(pv.cmuxLeft + 8 + 13, 11.25 + 13)
        #expect(c.r > c.g + 60 && c.r > c.b + 60, "the thumbnail is not the table's picture: \(c)")
    }

    @Test func aQuotedMarkdownTextShowsItsWordsNotItsMarkers() throws {
        let root = "**Done.** See [PR 12](https://github.com/manaflow-ai/cmux/pull/12), run `bun test` ![shot](/tmp/none.png)"
        let (_, pv) = try Self.preview(Self.rows(root: root))
        #expect(pv.isText)
        #expect(Self.shownWords(pv) == "Done. See PR 12, run bun test")
    }

    @Test func aQuotedTextWithOnlyPicturesSaysHowMany() throws {
        let (_, pv) = try Self.preview(Self.rows(root: "![before](/tmp/a.png) ![after](/tmp/b.png)"))
        #expect(Self.shownWords(pv) == "2 images")
    }

    // MARK: The Home list row

    @Test func aRowPreviewOfATableNamesItsColumns() {
        let table = "| | Before | After |\n|---|---|---|\n| Light | ![b](/tmp/b.png) | ![a](/tmp/a.png) |"
        #expect(HomeMarkdownPreview(table, author: Self.chief, in: Self.summary).text == "Table: Before / After")
        #expect(HomeMarkdownPreview("Shots: ![b](/tmp/b.png) and [the PR](https://example.com/pr/1)", author: Self.chief, in: Self.summary).text
                == "Shots: and the PR")
        #expect(HomeMarkdownPreview("![b](/tmp/b.png)", author: Self.chief, in: Self.summary).text == "Image")
        // A person's text stays as typed.
        #expect(HomeMarkdownPreview("a | b **c**", author: Self.me, in: Self.summary).text == "a | b **c**")
    }
}
